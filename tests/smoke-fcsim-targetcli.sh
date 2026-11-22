#!/bin/bash
# tcm_fcsim: target side managed entirely through targetcli (fcsim-targetcli
# wrapper), plus targetctl save / clear / restore.  Run inside the guest.
set -euo pipefail

TOP=$(cd "$(dirname "$0")/.." && pwd)
. "$TOP/tests/lib.sh"

TCTL="$TOP/tools/fcsim-targetctl"
T=naa.2100000000000001		# target WWPN 21:00:00:00:00:00:00:01
I=naa.10000000c9000001		# initiator WWPN 10:00:00:00:c9:00:00:01
IWWPN=10:00:00:00:c9:00:00:01

step "load modules"
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
echo up > "$HOSTS/$IWWPN/link"
wait_paths 2 5 || fail "expected 2 LUNs"
lsscsi

step "targetctl save / clear / restore"
$TCTL save /tmp/fcsim.json
python3 -c 'import json,sys; c=json.load(open(sys.argv[1])); print([(t["fabric"], t["wwn"]) for t in c["targets"]])' /tmp/fcsim.json
$TCTL clear
[ "$(cat "$HOSTS/$IWWPN/targets")" = "" ] || fail "still logged in after clear"
echo "targets after clear: (none)"
$TCTL restore /tmp/fcsim.json
echo 1 > "/sys/class/fc_host/$(cat "$HOSTS/$IWWPN/scsi_host" )/issue_lip"
wait_paths 2 5 || fail "LUNs did not come back after restore"
echo "targets after restore: $(cat "$HOSTS/$IWWPN/targets")"
lsscsi

step "teardown"
rmdir "$HOSTS/$IWWPN"
$TCTL clear
rmdir /sys/kernel/config/target/fcsim	# the fabric dir pins the module
rmmod tcm_fcsim

step "dmesg check"
splat_check
echo
echo "PASS"
