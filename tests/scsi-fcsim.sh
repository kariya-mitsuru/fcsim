#!/bin/bash
# tcm_fcsim: SCSI semantics through the fabric and the TPG attributes (run
# inside the guest as root).
#
#   - residual: a short INQUIRY reports how much data really came
#   - LIO's own CHECK CONDITION (READ past the end) reaches the initiator
#     with its sense data
#   - a LUN mapped while logged in: REPORTED LUNS DATA HAS CHANGED, the new
#     LUN appears on issue_lip; an unmapped LUN fails its I/O
#   - a LUN number above 255 (flat space addressing)
#   - TPG attributes: demo_mode_login_only, cache_dynamic_acls,
#     demo_mode_write_protect, prod_mode_write_protect
#
# Commands go through sg_raw where the block layer would get in the way
# (a read-only disk refuses writes before they reach the fabric).
set -euo pipefail

TOP=$(cd "$(dirname "$0")/.." && pwd)
. "$TOP/tests/lib.sh"

T1=21:00:00:00:00:00:00:01
T2=21:00:00:00:00:00:00:02	# demo mode (no ACL for I2)
T3=21:00:00:00:00:00:00:03	# prod_mode_write_protect
I1=10:00:00:00:c9:00:00:01
I2=10:00:00:00:c9:00:00:02
N1=$(wwpn_naa $T1)

step "setup: T1 (rd0) with an ACL for I1, host I1"
load_fcsim
for r in rd0 rd1 rd2 rd3 rd4; do $TCLI /backstores/ramdisk create $r 16M >/dev/null; done
make_tport $T1 /backstores/ramdisk/rd0 $I1
mkdir "$HOSTS/$I1"
echo up > "$HOSTS/$I1/link"
H1=$(host_of $I1)
wait_for 10 disk_of "$H1" rd0 || fail "rd0 missing"
D=$(disk_of "$H1" rd0)
echo "rd0: /dev/$D"
udevadm settle

sense_of() { sed -n '/Sense Information/,$p' "$1" | tr '\n' ' '; }
# A unit attention left over from a LUN map change would fail the next SG_IO
# command (SG_IO does not retry): take it with TEST UNIT READY first.
clear_ua() {
	local i
	for i in 1 2 3; do
		sg_raw -R "/dev/$1" 00 00 00 00 00 00 >/dev/null 2>&1 && return 0
	done
	fail "/dev/$1: TEST UNIT READY keeps failing"
}

step "residual: INQUIRY with a 255-byte allocation length"
sg_raw -R -r 255 -o /tmp/inq "/dev/$D" 12 00 00 00 ff 00 >/tmp/sg.out 2>&1 ||
	{ cat /tmp/sg.out; fail "INQUIRY failed"; }
len=$(( $(od -An -tu1 -j4 -N1 /tmp/inq) + 5 ))
got=$(stat -c %s /tmp/inq)
echo "  INQUIRY data: $len bytes, received $got of 255"
[ "$got" = "$len" ] || fail "residual not reported (received $got, data $len)"

step "LIO's own CHECK CONDITION: READ past the end of the LUN"
blocks=$(blockdev --getsz "/dev/$D")		# 512-byte sectors = LBAs here
lba=$(printf '%08x' $((blocks + 8)))
if sg_raw -R -r 512 "/dev/$D" 28 00 ${lba:0:2} ${lba:2:2} ${lba:4:2} ${lba:6:2} 00 00 01 00 \
		>/tmp/sg.out 2>&1; then
	cat /tmp/sg.out; fail "READ past the end succeeded"
fi
sense_of /tmp/sg.out | sed 's/^/  /'; echo
sense_of /tmp/sg.out | grep -qi "illegal request" || fail "no ILLEGAL REQUEST sense"
sense_of /tmp/sg.out | grep -qi "out of range" || fail "no LBA OUT OF RANGE in the sense"

step "a LUN mapped while logged in: unit attention, found by issue_lip"
dmesg -C
$TCLI "/fcsim/$N1/luns" create /backstores/ramdisk/rd1 >/dev/null	# also mapped for I1
# The next command to LUN 0 gets the unit attention (the midlayer retries it).
dd if="/dev/$D" of=/dev/null bs=4k count=1 iflag=direct status=none || fail "READ after the map change"
dmesg | grep -q "LUN assignments on this target have changed" ||
	fail "no REPORTED LUNS DATA HAS CHANGED unit attention"
disk_of "$H1" rd1 >/dev/null && fail "LUN 1 appeared without a rescan"
echo 1 > "/sys/class/fc_host/$H1/issue_lip"
wait_for 10 disk_of "$H1" rd1 || fail "LUN 1 not found by issue_lip"
D1=$(disk_of "$H1" rd1)
dd if="/dev/$D1" of=/dev/null bs=4k count=1 iflag=direct status=none || fail "READ from LUN 1"
echo "  LUN 1: /dev/$D1"

step "an unmapped LUN: its I/O fails"
udevadm settle
for l in "$LIO/fcsim/$T1/tpgt_1/lun"/lun_*; do
	[ "${l##*/}" = lun_0 ] || lun1=${l##*/lun_}
done
$TCLI "/fcsim/$N1/luns" delete "$lun1" >/dev/null
if dd if="/dev/$D1" of=/dev/null bs=4k count=1 iflag=direct status=none 2>/dev/null; then
	fail "READ from an unmapped LUN succeeded"
fi
echo "  ok: READ from the unmapped LUN failed"
echo 1 > "/sys/block/$D1/device/delete"

step "LUN 300 (flat space addressing)"
$TCLI "/fcsim/$N1/luns" create /backstores/ramdisk/rd2 lun=300 add_mapped_luns=false >/dev/null
$TCLI "/fcsim/$N1/acls/$(wwpn_naa $I1)" create mapped_lun=300 tpg_lun_or_backstore=300 >/dev/null
mapped=300
[ -e "$LIO/fcsim/$T1/tpgt_1/acls/$I1/lun_300" ] || fail "LUN 300 not mapped for I1"
echo 1 > "/sys/class/fc_host/$H1/issue_lip"
wait_for 10 disk_of "$H1" rd2 || fail "LUN $mapped not found"
D2=$(disk_of "$H1" rd2)
sdev=$(basename "$(readlink -f "/sys/block/$D2/device")")
echo "  /dev/$D2 = $sdev"
[ "${sdev##*:}" = "$mapped" ] || fail "the disk is LUN ${sdev##*:}, not $mapped"
head -c 65536 /dev/urandom > /tmp/pat
dd if=/tmp/pat of="/dev/$D2" bs=64k oflag=direct status=none || fail "WRITE to LUN $mapped"
dd if="/dev/$D2" of=/tmp/pat.rd bs=64k count=1 iflag=direct status=none
cmp -s /tmp/pat /tmp/pat.rd || fail "data mismatch on LUN $mapped"

# --------------------------------------------------------------- TPG attributes
A2=$LIO/fcsim/$T2/tpgt_1/attrib
step "demo mode: I2 without an ACL logs in to T2 but sees no LUN (demo_mode_login_only=1)"
$TCLI /fcsim create "$(wwpn_naa $T2)" >/dev/null
$TCLI "/fcsim/$(wwpn_naa $T2)/luns" create /backstores/ramdisk/rd3 >/dev/null
grep . $A2/{generate_node_acls,cache_dynamic_acls,demo_mode_login_only,demo_mode_write_protect} |
	sed 's|.*/||; s/^/  /'
mkdir "$HOSTS/$I2"
echo up > "$HOSTS/$I2/link"
H2=$(host_of $I2)
wait_for 10 grep -qx "$I2" "$LIO/fcsim/$T2/tpgt_1/sessions" || fail "I2 did not log in to T2"
sleep 1
disk_of "$H2" rd3 >/dev/null && fail "a LUN is visible with demo_mode_login_only=1"
echo "  ok: logged in, no LUN"

bounce() { echo down > "$HOSTS/$1/link"; echo up > "$HOSTS/$1/link"; }

step "cache_dynamic_acls=1 keeps the dynamic ACL: demo_mode_login_only=0 needs it dropped"
echo 0 > $A2/demo_mode_login_only
bounce $I2
wait_for 10 grep -qx "$I2" "$LIO/fcsim/$T2/tpgt_1/sessions" || fail "I2 did not log in again"
echo 1 > "/sys/class/fc_host/$H2/issue_lip"
sleep 1
disk_of "$H2" rd3 >/dev/null && fail "the cached dynamic ACL got LUNs"
echo "  ok: still no LUN (the cached ACL was made with login_only=1)"
echo 0 > $A2/cache_dynamic_acls
bounce $I2		# the logout now drops the dynamic ACL
wait_for 10 disk_of "$H2" rd3 || fail "no LUN after the dynamic ACL was dropped"
DD2=$(disk_of "$H2" rd3)
echo "  /dev/$DD2: visible through a new dynamic ACL"

step "demo_mode_write_protect=1: READ works, WRITE is DATA PROTECT"
dd if="/dev/$DD2" of=/dev/null bs=4k count=1 iflag=direct status=none || fail "READ in demo mode"
head -c 512 /dev/urandom > /tmp/blk
clear_ua "$DD2"
if sg_raw -R -s 512 -i /tmp/blk "/dev/$DD2" 2a 00 00 00 00 10 00 00 01 00 >/tmp/sg.out 2>&1; then
	cat /tmp/sg.out; fail "WRITE succeeded on a write-protected demo-mode LUN"
fi
sense_of /tmp/sg.out | grep -qi "data protect" || { cat /tmp/sg.out; fail "no DATA PROTECT sense"; }
echo "  ok: DATA PROTECT"

step "prod_mode_write_protect=1: LUNs mapped to explicit ACLs are read-only"
N3=$(wwpn_naa $T3)
$TCLI /fcsim create "$N3" >/dev/null
echo 1 > "$LIO/fcsim/$T3/tpgt_1/attrib/prod_mode_write_protect"
$TCLI "/fcsim/$N3/luns" create /backstores/ramdisk/rd4 >/dev/null
# Mapped through configfs: targetcli (rtslib) writes write_protect=0 itself.
TPG3=$LIO/fcsim/$T3/tpgt_1
mkdir -p "$TPG3/acls/$I1/lun_0"
ln -s "$TPG3/lun/lun_0" "$TPG3/acls/$I1/lun_0/map"
echo "  write_protect of I1's LUN 0: $(cat "$TPG3/acls/$I1/lun_0/write_protect")"
[ "$(cat "$TPG3/acls/$I1/lun_0/write_protect")" = 1 ] || fail "the mapping is not read-only"
# I1 was logged in to T3 already (demo mode, no LUNs): look again.
echo 1 > "/sys/class/fc_host/$H1/issue_lip"
wait_for 10 disk_of "$H1" rd4 || fail "rd4 missing on I1"
D4=$(disk_of "$H1" rd4)
clear_ua "$D4"
if sg_raw -R -s 512 -i /tmp/blk "/dev/$D4" 2a 00 00 00 00 10 00 00 01 00 >/tmp/sg.out 2>&1; then
	cat /tmp/sg.out; fail "WRITE succeeded with prod_mode_write_protect=1"
fi
sense_of /tmp/sg.out | grep -qi "data protect" || { cat /tmp/sg.out; fail "no DATA PROTECT sense"; }
echo "  ok: DATA PROTECT"
# T1's LUN 0, mapped while prod_mode_write_protect was 0, stays writable.
clear_ua "$D"
sg_raw -R -s 512 -i /tmp/blk "/dev/$D" 2a 00 00 00 00 10 00 00 01 00 >/dev/null 2>&1 ||
	fail "WRITE to T1 failed"

step "teardown"
splat_check
teardown_all
splat_check
echo
echo "PASS"
