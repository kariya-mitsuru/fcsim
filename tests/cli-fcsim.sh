#!/bin/bash
# tcm_fcsim: fcsimctl (initiator side CLI) and fc_host statistics (run
# inside the guest as root).
set -euo pipefail

TOP=$(cd "$(dirname "$0")/.." && pwd)
. "$TOP/tests/lib.sh"

CTL="$TOP/tools/fcsimctl"
T1=21:00:00:00:00:00:00:01
T2=21:00:00:00:00:00:00:02
I1=10:00:00:00:c9:00:00:01
I2=10:00:00:00:c9:00:00:02


step "setup: targets via fcsim-targetcli"
modprobe target_core_mod
load_fcsim
$TCLI /backstores/ramdisk create rd0 64M >/dev/null
$TCLI /backstores/ramdisk create rd1 16M >/dev/null
make_tport $T1 /backstores/ramdisk/rd0 $I1 $I2
make_tport $T2 /backstores/ramdisk/rd1 $I1

step "fcsimctl host create / link / fault set (WWPNs in different notations)"
$CTL host create naa.10000000c9000001
$CTL host create 0x10000000c9000002 --wwnn 20:00:00:00:c9:00:00:99 --link down
$CTL fault set $I1 $T2 delay_ms=5 probability=50
$CTL fault set 10000000c9000001 any error=busy count=0
$CTL link $I2 up
H1=$(host_of $I1); H2=$(host_of $I2)
wait_for 10 disk_of "$H1" rd0 || fail "I1 rd0 missing"
wait_for 10 disk_of "$H2" rd0 || fail "I2 rd0 missing"
[ "$(cat $HOSTS/$I2/node_name)" = 20:00:00:00:c9:00:00:99 ] || fail "wwnn not set"
$CTL status
$CTL status | grep -q "fault $T2: delay_ms=5 probability=50" || fail "status: fault rule"
$CTL status --json | python3 -c 'import json,sys; s=json.load(sys.stdin); assert len(s["hosts"]) == 2 and len(s["targets"]) == 2'
$CTL fault list

step "fc_host statistics"
D=$(disk_of "$H1" rd0)
S=/sys/class/fc_host/$H1/statistics
udevadm settle
$CTL stats $I1 --reset
[ "$(hexval $S/fcp_input_requests)" = 0 ] || fail "reset did not clear"
dd if=/dev/$D of=/dev/null bs=1M count=8 iflag=direct status=none
dd if=/dev/zero of=/dev/$D bs=1M count=4 oflag=direct status=none
in_req=$(hexval $S/fcp_input_requests); out_req=$(hexval $S/fcp_output_requests)
in_mb=$(hexval $S/fcp_input_megabytes); out_mb=$(hexval $S/fcp_output_megabytes)
echo "  input requests $in_req, ${in_mb} MiB; output requests $out_req, ${out_mb} MiB"
[ "$in_mb" = 8 ] && [ "$out_mb" = 4 ] || fail "megabytes"
[ "$in_req" -ge 8 ] && [ "$out_req" -ge 4 ] || fail "requests"
[ "$(hexval $S/rx_frames)" -ge $((8 * 512)) ] || fail "rx_frames"	# 8 MiB / 2 KiB
[ "$(hexval $S/tx_frames)" -ge $((4 * 512)) ] || fail "tx_frames"
before=$(hexval $S/link_failure_count)
$CTL link $I1 down; $CTL link $I1 up
[ "$(hexval $S/link_failure_count)" = $((before + 1)) ] || fail "link_failure_count"
$CTL lip $I1
[ "$(hexval $S/lip_count)" -ge 1 ] || fail "lip_count"
wait_for 10 disk_of "$H1" rd0 || fail "I1 rd0 missing after link up"
$CTL stats $I1 | sed 's/^/  /'

step "drop=cmd shows up in dumped_frames and fcp_packet_aborts"
D=$(disk_of "$H1" rd0)
echo 2 > /sys/block/$D/device/timeout
$CTL stats $I1 --reset
$CTL fault set $I1 $T1 drop=cmd count=1
dd if=/dev/$D of=/dev/null bs=4k count=1 iflag=direct status=none || fail "read after one drop"
echo "  dumped_frames $(hexval $S/dumped_frames)  fcp_packet_aborts $(hexval $S/fcp_packet_aborts)"
[ "$(hexval $S/dumped_frames)" = 1 ] && [ "$(hexval $S/fcp_packet_aborts)" = 1 ] || fail "drop stats"
$CTL fault clear $I1 $T1

step "task management requests are counted as control requests"
# The fabric drops the one TMF of a LUN reset that is not escalated: it is
# then the only FCP_CMND, and the reset fails after tmr_timeout.
echo 1 > /sys/module/tcm_fcsim/parameters/tmr_timeout
$CTL fault set $I1 $T1 drop=cmd count=1
$CTL stats $I1 --reset
# Through the sg node: closing the block device makes udev probe it.
SG=/dev/$(basename /sys/block/$D/device/scsi_generic/*)
if sg_reset -d -N $SG 2>/dev/null; then fail "LUN reset succeeded without a response"; fi
ctl=$(hexval $S/fcp_control_requests); dumped=$(hexval $S/dumped_frames)
echo "  fcp_control_requests $ctl, dumped_frames $dumped"
[ "$ctl" = 1 ] && [ "$dumped" = 1 ] || fail "the dropped TMF was not counted"
$CTL fault clear $I1 $T1
echo 10 > /sys/module/tcm_fcsim/parameters/tmr_timeout

step "save / clear / restore"
$CTL save /tmp/fcsim.json
cat /tmp/fcsim.json
$CTL clear
[ -z "$(ls $HOSTS)" ] || fail "clear left hosts"
$CTL restore /tmp/fcsim.json
$CTL save /tmp/fcsim2.json
diff -u /tmp/fcsim.json /tmp/fcsim2.json || fail "restore differs from save"
H1=$(host_of $I1)
wait_for 10 disk_of "$H1" rd0 || fail "I1 rd0 missing after restore"
echo "  restored config matches"

step "errors"
if $CTL link 10:00:00:00:c9:00:00:77 up 2>/tmp/err; then fail "unknown host accepted"; fi
cat /tmp/err
if $CTL fault set $I1 $T1 bogus=1 2>/tmp/err; then fail "bogus attribute accepted"; fi
cat /tmp/err
if $CTL host create 12:34 2>/tmp/err; then fail "bad WWPN accepted"; fi
cat /tmp/err
# A zone name is a path component: it must not reach outside zones/
# (I2 has no fault rules, so rmdir of its port would succeed).
for a in delete add; do
	if $CTL zone $a ../hosts/$I2 $T1 2>/tmp/err; then fail "zone $a accepted ../hosts"; fi
	cat /tmp/err
done
[ -d $HOSTS/$I2 ] || fail "zone delete ../hosts removed an initiator port"

step "fault set is all or nothing"
R=$HOSTS/$I1/faults/$T1
$CTL fault clear $I1 $T1
if $CTL fault set $I1 $T1 drop=cmd probability=abc 2>/tmp/err; then fail "bad probability accepted"; fi
cat /tmp/err
[ ! -e $R ] || fail "failed fault set left a rule"
if $CTL fault set $I1 $T1 bogus=1 2>/tmp/err; then fail "bogus attribute accepted"; fi
[ ! -e $R ] || fail "unknown attribute left an empty rule"
# Updating a rule keeps the attributes not given, count included.
$CTL fault set $I1 $T1 drop=cmd count=0
$CTL fault set $I1 $T1 count=3 probability=40
$CTL fault set $I1 $T1 drop=rsp
[ "$(cat $R/drop) $(cat $R/count) $(cat $R/probability)" = "rsp 3 40" ] ||
	fail "rule update: $(cat $R/drop) $(cat $R/count) $(cat $R/probability)"
if $CTL fault set $I1 $T1 drop=none count=-2 2>/tmp/err; then fail "count=-2 accepted"; fi
[ "$(cat $R/drop) $(cat $R/count)" = "rsp 3" ] || fail "rejected update changed the rule"
$CTL fault clear $I1 $T1

step "restore rejects a bad file without touching the fabric"
$CTL save /tmp/fcsim-before.json
bad_restore() {	# <description> <python expression editing c>
	python3 -I -c 'import json,sys; c=json.load(open(sys.argv[1])); exec(sys.argv[2]); json.dump(c, open(sys.argv[3], "w"))' \
		/tmp/fcsim-before.json "$2" /tmp/fcsim-bad.json
	if $CTL restore /tmp/fcsim-bad.json 2>/tmp/err; then fail "restore accepted $1"; fi
	echo "  $1: $(cat /tmp/err)"
	$CTL save /tmp/fcsim-after.json
	diff -u /tmp/fcsim-before.json /tmp/fcsim-after.json || fail "restore of $1 changed the fabric"
}
bad_restore "a bad member WWPN" 'c["zoning"]["zones"]["zbad"] = ["12:34"]'
bad_restore "a bad host WWPN" 'c["hosts"].append({"wwpn": "10:00"})'
bad_restore "a target port WWPN" 'c["hosts"].append({"wwpn": "'$T2'"})'
bad_restore "a bad fault value" 'c["hosts"][0]["faults"].append({"target": "22:00:00:00:00:00:00:09", "probability": "abc"})'
echo '{"version": 1, "hosts": [' > /tmp/fcsim-bad.json
if $CTL restore /tmp/fcsim-bad.json 2>/tmp/err; then fail "truncated JSON accepted"; fi
cat /tmp/err
$CTL save /tmp/fcsim-after.json
diff -u /tmp/fcsim-before.json /tmp/fcsim-after.json || fail "truncated JSON changed the fabric"

step "teardown"
$CTL clear
teardown_all
splat_check
echo
echo "PASS"
