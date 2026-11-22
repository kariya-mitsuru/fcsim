#!/bin/bash
# tcm_fcsim: refused-login logging, long attribute lists, TPG attributes
# (run inside the guest as root).
set -euo pipefail

TOP=$(cd "$(dirname "$0")/.." && pwd)
. "$TOP/tests/lib.sh"

T1=21:00:00:00:00:00:00:01
I1=10:00:00:00:c9:00:00:01
TPG=$LIO/fcsim/$T1/tpgt_1

step "setup: T1 without ACLs, demo mode off"
modprobe target_core_mod
load_fcsim
$TCLI /backstores/ramdisk create rd0 16M >/dev/null
$TCLI /fcsim create "$(wwpn_naa $T1)" >/dev/null
$TCLI "/fcsim/$(wwpn_naa $T1)/luns" create /backstores/ramdisk/rd0 >/dev/null
echo 0 > $TPG/attrib/generate_node_acls
cat $TPG/attrib/generate_node_acls

step "refused login is logged once, not on every retry"
dmesg -C
mkdir "$HOSTS/$I1"
echo up > "$HOSTS/$I1/link"
H1=$(host_of $I1)
for _ in 1 2 3; do
	echo 1 > /sys/class/fc_host/$H1/issue_lip
	echo down > "$HOSTS/$I1/link"; echo up > "$HOSTS/$I1/link"
done
dmesg | grep "rejected by target" | sed 's/^/  /'
n=$(dmesg | grep -c "rejected by target")
# The link toggles make each attempt "new" again: 1 initial + 3 after link up.
[ "$n" = 4 ] || fail "expected 4 'rejected' lines (1 + one per link up), got $n"
dmesg -C
for _ in $(seq 10); do echo 1 > /sys/class/fc_host/$H1/issue_lip; done
n=$(dmesg | grep -c "rejected by target" || true)
[ "$n" = 0 ] || fail "retries were logged again ($n)"
echo "  ok: 10 retries, no new log lines"
[ -z "$(cat $HOSTS/$I1/targets)" ] || fail "logged in without ACL"

step "TPG attribute: demo mode on lets the refused initiator in"
echo 1 > $TPG/attrib/generate_node_acls
wait_for 5 sh -c "[ -n \"\$(cat $HOSTS/$I1/targets)\" ]" || fail "no login after enabling demo mode"
echo "  targets: $(cat $HOSTS/$I1/targets)"
echo 0 > $TPG/attrib/generate_node_acls
cat $TPG/attrib/generate_node_acls
rmdir "$HOSTS/$I1"

step "sessions list longer than a page"
echo 1 > $TPG/attrib/generate_node_acls
N=180
for i in $(seq $N); do
	h=$HOSTS/$(printf '10:00:00:00:c9:00:%02x:%02x' $((i / 256)) $((i % 256)))
	mkdir "$h"
	echo up > "$h/link"
done
lines=$(wc -l < $TPG/sessions)
tail -2 $TPG/sessions | sed 's/^/  /'
more=$(tail -1 $TPG/sessions | sed -n 's/^\.\.\. \([0-9]*\) more$/\1/p')
[ -n "$more" ] || fail "no '... N more' line"
[ $((lines - 1 + more)) = $N ] || fail "listed $((lines - 1)) + $more more != $N"
[ "$(wc -c < $TPG/sessions)" -le 4096 ] || fail "page overflow"
echo "  ok: $((lines - 1)) listed + $more more = $N"
for h in "$HOSTS"/*; do rmdir "$h"; done

step "tmr_timeout range, TPG name"
P=/sys/module/tcm_fcsim/parameters/tmr_timeout
for v in 0 3601 x; do
	if echo $v > $P 2>/dev/null; then fail "tmr_timeout=$v accepted"; fi
done
echo 1 > $P && echo 3600 > $P && echo 10 > $P || fail "valid tmr_timeout refused"
[ "$(cat $P)" = 10 ] || fail "tmr_timeout reads $(cat $P)"
W=21:00:00:00:00:00:00:0e
mkdir "$LIO/fcsim/$W"
for t in tpgt_01 tpgt_+1 tpgt_2 tpgt_; do
	if mkdir "$LIO/fcsim/$W/$t" 2>/dev/null; then fail "$t accepted"; fi
done
mkdir "$LIO/fcsim/$W/tpgt_1" || fail "tpgt_1 refused"
rmdir "$LIO/fcsim/$W/tpgt_1" "$LIO/fcsim/$W"
echo "  OK"

step "a WWPN is never both an initiator and a target port"
# Create both at once: one of the two must be refused, however the
# (slow) Scsi_Host setup of the initiator port interleaves.
both=0
for n in $(seq 40); do
	W=10:00:00:00:c9:00:01:$(printf %02x $n)
	mkdir "$HOSTS/$W" 2>/dev/null &
	A=$!
	mkdir "$LIO/fcsim/$W" 2>/dev/null &
	B=$!
	ini=0 tgt=0
	wait $A && ini=1
	wait $B && tgt=1
	[ $ini$tgt = 11 ] && both=$((both + 1))
	[ $ini$tgt != 00 ] || fail "$W: both refused"
	[ -d "$HOSTS/$W" ] && rmdir "$HOSTS/$W"
	[ -d "$LIO/fcsim/$W" ] && rmdir "$LIO/fcsim/$W"
done
echo "  40 tries, $both with both ports created"
[ $both = 0 ] || fail "the same WWPN was created as initiator and target port"

step "teardown"
teardown_all
splat_check
echo
echo "PASS"
