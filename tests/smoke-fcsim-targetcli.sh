#!/bin/bash
# tcm_fcsim: target side managed entirely through targetcli (fcsim-targetcli
# wrapper), plus targetctl save / clear / restore.  Run inside the guest.
set -euo pipefail

TOP=$(cd "$(dirname "$0")/.." && pwd)
. "$TOP/tests/guest-setup.sh"

TCLI="$TOP/tools/fcsim-targetcli"
TCTL="$TOP/tools/fcsim-targetctl"
T=naa.2100000000000001		# target WWPN 21:00:00:00:00:00:00:01
I=naa.10000000c9000001		# initiator WWPN 10:00:00:00:c9:00:00:01
IWWPN=10:00:00:00:c9:00:00:01
HOSTS=/sys/kernel/config/fcsim/hosts

step() { echo; echo "=== $*"; }
fail() { echo "FAIL: $*" >&2; dmesg | tail -30 >&2; exit 1; }

fcsim_disks() {
	ls -d /sys/class/fc_transport/target*/device/*/block/* 2>/dev/null | sort
}

wait_disks() {	# wait_disks <count>
	local t=50
	while [ "$(fcsim_disks | wc -l)" -ne "$1" ]; do
		t=$((t - 1)); [ $t -gt 0 ] || return 1
		sleep 0.1
	done
}

step "load modules"
modprobe target_core_mod
load_fcsim

step "targetcli: two ramdisk LUNs on $T, ACL for $I"
$TCLI /backstores/ramdisk create rd0 32M
$TCLI /backstores/ramdisk create rd1 32M
$TCLI /fcsim create $T
$TCLI /fcsim/$T/luns create /backstores/ramdisk/rd0
$TCLI /fcsim/$T/luns create /backstores/ramdisk/rd1
$TCLI /fcsim/$T/acls create $I
$TCLI ls /fcsim
cat /sys/kernel/config/target/fcsim/21:00:00:00:00:00:00:01/tpgt_1/enable

step "initiator host"
mkdir "$HOSTS/$IWWPN"
wait_disks 2 || fail "expected 2 LUNs"
lsscsi

step "targetctl save / clear / restore"
$TCTL save /tmp/fcsim.json
python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); print([(t["fabric"], t["wwn"]) for t in c["targets"]])' /tmp/fcsim.json
$TCTL clear
[ "$(cat "$HOSTS/$IWWPN/targets")" = "" ] || fail "still logged in after clear"
echo "targets after clear: (none)"
$TCTL restore /tmp/fcsim.json
echo 1 > "/sys/class/fc_host/$(cat "$HOSTS/$IWWPN/scsi_host" )/issue_lip"
wait_disks 2 || fail "LUNs did not come back after restore"
echo "targets after restore: $(cat "$HOSTS/$IWWPN/targets")"
lsscsi

step "teardown"
rmdir "$HOSTS/$IWWPN"
$TCTL clear
rmdir /sys/kernel/config/target/fcsim	# the fabric dir pins the module
rmmod tcm_fcsim

step "dmesg check"
if dmesg | grep -E 'BUG:|WARNING:|KASAN|possible circular|INFO: task .* blocked|Call Trace'; then
	fail "kernel splat detected"
fi
echo
echo "PASS"
