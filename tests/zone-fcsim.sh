#!/bin/bash
# tcm_fcsim: zoning (run inside the guest as root).
set -euo pipefail

TOP=$(cd "$(dirname "$0")/.." && pwd)
. "$TOP/tests/lib.sh"

CTL="$TOP/tools/fcsimctl"
T1=21:00:00:00:00:00:00:01
T2=21:00:00:00:00:00:00:02
I1=10:00:00:00:c9:00:00:01
I2=10:00:00:00:c9:00:00:02
Z=/sys/kernel/config/fcsim/zoning

tgts() { tr '\n' ' ' < "$HOSTS/$1/targets" | sed 's/ $//'; }	# targets of an initiator
expect() {	# expect <initiator> "<targets>"
	[ "$(tgts $1)" = "$2" ] || fail "$1 logged in to [$(tgts $1)], expected [$2]"
}
events() {	# events <seconds> <command...>: FC netlink events during the command
	python3 "$TOP/tests/fc-events.py" "$1" > /tmp/events & local ev=$!
	sleep 0.5
	shift
	"$@"
	wait $ev
	grep -v '^listening' /tmp/events | sort || true
}

step "setup: T1, T2; I1, I2 with ACLs everywhere"
load_fcsim
$TCLI /backstores/ramdisk create rd0 16M >/dev/null
$TCLI /backstores/ramdisk create rd1 16M >/dev/null
make_tport $T1 /backstores/ramdisk/rd0 $I1 $I2
make_tport $T2 /backstores/ramdisk/rd1 $I1 $I2
$CTL host create $I1
$CTL host create $I2
H1=$(host_of $I1); H2=$(host_of $I2)
T1PID=$(cat $LIO/fcsim/$T1/tpgt_1/port_id); T2PID=$(cat $LIO/fcsim/$T2/tpgt_1/port_id)
expect $I1 "$T1 $T2"; expect $I2 "$T1 $T2"
cat $Z/active
[ "$(cat $Z/pending)" = 0 ] || fail "pending without changes"

step "staged edits do not touch the fabric"
$CTL zone create z1 $I1 $T1
$CTL zone mode on
[ "$(cat $Z/pending)" = 1 ] || fail "pending not set"
grep -q "^mode off" $Z/active || fail "active changed before commit"
expect $I1 "$T1 $T2"; expect $I2 "$T1 $T2"
$CTL zone list | sed 's/^/  /'

step "commit: only I1-T1 stays; RSCNs to exactly the initiators whose view changed"
events 3 $CTL zone commit | tee /tmp/ev1 | sed 's/^/  /'
expect $I1 "$T1"; expect $I2 ""
[ "$(cat $Z/pending)" = 0 ] || fail "pending after commit"
cat > /tmp/ev1.want <<EOF
$H1 RSCN $T2PID
$H2 RSCN $T1PID
$H2 RSCN $T2PID
EOF
sort -o /tmp/ev1.want /tmp/ev1.want
diff -u /tmp/ev1.want /tmp/ev1 || fail "unexpected RSCNs"
cat $Z/active | sed 's/^/  /'

step "second zone for I2 with both targets"
$CTL zone create z2 $I2 $T1 $T2
events 3 $CTL zone commit | tee /tmp/ev2 | sed 's/^/  /'
expect $I1 "$T1"; expect $I2 "$T1 $T2"
printf '%s\n' "$H2 RSCN $T1PID" "$H2 RSCN $T2PID" | sort > /tmp/ev2.want
diff -u /tmp/ev2.want /tmp/ev2 || fail "unexpected RSCNs"

step "T2 leaves the fabric: RSCN only to I2 (I1 is not zoned with T2)"
events 3 sh -c "echo 0 > $LIO/fcsim/$T2/tpgt_1/enable; echo 1 > $LIO/fcsim/$T2/tpgt_1/enable" \
	| tee /tmp/ev3 | sed 's/^/  /'
printf '%s\n' "$H2 RSCN $T2PID" "$H2 RSCN $T2PID" > /tmp/ev3.want
diff -u /tmp/ev3.want /tmp/ev3 || fail "unexpected RSCNs"
expect $I2 "$T1 $T2"

step "zone add/remove and revert"
$CTL zone remove z2 $T1
$CTL zone delete z1
[ "$(cat $Z/pending)" = 1 ] || fail "pending not set"
$CTL zone revert
[ "$(cat $Z/pending)" = 0 ] || fail "revert did not restore the active configuration"
[ "$(cat /sys/kernel/config/fcsim/zones/z2/members | wc -l)" = 3 ] || fail "z2 members after revert"
expect $I1 "$T1"; expect $I2 "$T1 $T2"
echo "  ok"

step "mode off: everyone sees everything again"
$CTL zone mode off
$CTL zone commit
expect $I1 "$T1 $T2"; expect $I2 "$T1 $T2"

step "invalid input"
if echo "12:34" > /sys/kernel/config/fcsim/zones/z2/members 2>/dev/null; then fail "bad WWPN accepted"; fi
if mkdir "/sys/kernel/config/fcsim/zones/bad name" 2>/dev/null; then fail "zone name with a space accepted"; fi
if echo 0 > $Z/commit 2>/dev/null; then fail "commit 0 accepted"; fi
if echo maybe > $Z/mode 2>/dev/null; then fail "bad mode accepted"; fi
[ "$(cat /sys/kernel/config/fcsim/zones/z2/members | wc -l)" = 3 ] || fail "members changed by a bad write"
echo "  ok"

step "save / clear / restore keep the zoning"
$CTL zone delete z2
$CTL zone mode on
$CTL zone commit
expect $I1 "$T1"; expect $I2 ""
$CTL save /tmp/z.json
python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["zoning"])' /tmp/z.json
$CTL clear
[ -z "$(ls /sys/kernel/config/fcsim/zones)" ] && grep -q "^mode off" $Z/active || fail "clear left zoning"
$CTL restore /tmp/z.json
$CTL save /tmp/z2.json
diff -u /tmp/z.json /tmp/z2.json || fail "restore differs"
expect $I1 "$T1"; expect $I2 ""
$CTL status | sed 's/^/  /' | head -8

step "active configuration larger than a page"
for i in $(seq 60); do
	mkdir /sys/kernel/config/fcsim/zones/zone$i
	# one write(): every write replaces the whole list
	echo "$I1 $I2 $T1" > /sys/kernel/config/fcsim/zones/zone$i/members
done
$CTL zone commit
bytes=$(wc -c < $Z/active); zones=$(grep -c '^zone ' $Z/active)
echo "  active: $bytes bytes, $zones zones"
[ "$bytes" -gt 4096 ] && [ "$zones" = 61 ] || fail "active truncated"
expect $I1 "$T1"; expect $I2 "$T1"

step "a slow commit does not overwrite a newer one"
# The first commit sleeps between its snapshot and making it active
# (dbg_commit_delay_ms); meanwhile the staged mode changes and is committed.
# The slow commit must not then make its older snapshot active.
echo on > $Z/mode
$CTL zone commit
echo 1500 > /sys/module/tcm_fcsim/parameters/dbg_commit_delay_ms
echo 1 > $Z/commit &
SLOW=$!
sleep 0.5
echo off > $Z/mode
echo 1 > $Z/commit
wait $SLOW
grep '^mode' $Z/active | sed 's/^/  active: /'
grep -q '^mode off$' $Z/active || fail "the slow commit replaced the newer configuration"
[ "$(cat $Z/pending)" = 0 ] || fail "pending after both commits"

step "teardown"
$CTL clear
teardown_all
splat_check
echo
echo "PASS"
