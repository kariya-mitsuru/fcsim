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
insmod "$TOP/src/tcm_fcsim.ko"
$TCLI /backstores/ramdisk create rd0 16M >/dev/null
$TCLI /fcsim create "$(wwpn_naa $T1)" >/dev/null
$TCLI "/fcsim/$(wwpn_naa $T1)/luns" create /backstores/ramdisk/rd0 >/dev/null
echo 0 > $TPG/attrib/generate_node_acls
cat $TPG/attrib/generate_node_acls

step "refused login is logged once, not on every retry"
dmesg -C
mkdir "$HOSTS/$I1"
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
	mkdir "$HOSTS/$(printf '10:00:00:00:c9:00:%02x:%02x' $((i / 256)) $((i % 256)))"
done
lines=$(wc -l < $TPG/sessions)
tail -2 $TPG/sessions | sed 's/^/  /'
more=$(tail -1 $TPG/sessions | sed -n 's/^\.\.\. \([0-9]*\) more$/\1/p')
[ -n "$more" ] || fail "no '... N more' line"
[ $((lines - 1 + more)) = $N ] || fail "listed $((lines - 1)) + $more more != $N"
[ "$(wc -c < $TPG/sessions)" -le 4096 ] || fail "page overflow"
echo "  ok: $((lines - 1)) listed + $more more = $N"
for h in "$HOSTS"/*; do rmdir "$h"; done

step "teardown"
teardown_all
splat_check
echo
echo "PASS"
