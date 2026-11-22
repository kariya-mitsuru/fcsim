#!/bin/bash
# tcm_fcsim: a backend that stops responding (run inside the guest as root).
#
# The backend of target port T1 is a dm device suspended with --noflush, so
# commands reach LIO and then hang in the backend.  T2 is a healthy ramdisk.
#
#   1. While I1's READ is stuck and I1 goes through SCSI EH, the fabric stays
#      usable: other hosts keep doing I/O, link changes / host creation /
#      attribute reads return promptly.  TMRs to the stuck LUN time out and
#      EH escalates to a host reset, which terminates the exchanges.  A
#      logged-out session with stuck commands drains in the background and
#      its pair does not log in again until it is gone.
#   2. The backend comes back: the old session drains, I1 logs in to T1
#      again and the retried READ completes.
#   3. The backend stays stuck: EH keeps terminating exchanges, the READ
#      fails once its retries are used up, the device stays usable and
#      everything recovers when the backend does.
set -euo pipefail

TOP=$(cd "$(dirname "$0")/.." && pwd)
. "$TOP/tests/lib.sh"

T1=21:00:00:00:00:00:00:01	# backend: suspended dm device "hang"
T2=21:00:00:00:00:00:00:02	# backend: ramdisk "rd0"
I1=10:00:00:00:c9:00:00:01
I2=10:00:00:00:c9:00:00:02
I3=10:00:00:00:c9:00:00:03
DM=fcsim_hang

ntargets() { wc -l < "$HOSTS/$1/targets"; }

step "setup: dm-linear over a loop device as a backend we can freeze"
# (a loop device rather than null_blk, which e.g. the WSL2 kernel lacks)
modprobe loop
truncate -s 256M /tmp/hang.img
LOOP=$(losetup -f --show /tmp/hang.img)
dmsetup create $DM --table "0 $(blockdev --getsz $LOOP) linear $LOOP 0"
modprobe target_core_mod
modprobe target_core_iblock
load_fcsim tmr_timeout=1
$TCLI /backstores/block create hang /dev/mapper/$DM >/dev/null
$TCLI /backstores/ramdisk create rd0 16M >/dev/null
make_tport $T1 /backstores/block/hang $I1 $I2
make_tport $T2 /backstores/ramdisk/rd0 $I1 $I2
mkdir "$HOSTS/$I1" "$HOSTS/$I2"
echo up > "$HOSTS/$I1/link"; echo up > "$HOSTS/$I2/link"
H1=$(host_of $I1); H2=$(host_of $I2)
wait_for 10 disk_of "$H1" hang || fail "I1 hang LUN missing"
wait_for 10 disk_of "$H1" rd0 || fail "I1 rd0 LUN missing"
wait_for 10 disk_of "$H2" rd0 || fail "I2 rd0 LUN missing"
HANG1=$(disk_of "$H1" hang); RD2=$(disk_of "$H2" rd0)
echo "I1=$H1 hang=/dev/$HANG1   I2=$H2 rd0=/dev/$RD2"
echo 2 > /sys/block/$HANG1/device/timeout
udevadm settle

# ---------------------------------------------------------------------------
step "1. backend frozen: READ on I1 gets stuck, EH escalates"
dmsetup suspend --noflush $DM
dd if=/dev/$HANG1 of=/dev/null bs=4k count=1 iflag=direct status=none &
DD=$!
wait_for 30 sh -c "dmesg | grep -q 'host reset: terminated'" \
	|| fail "EH did not reach host reset"
dmesg | grep -E "no response to TMR|host reset" | sed 's/^/  /'

step "1. fabric stays usable while the backend is stuck"
within 3 sh -c "echo down > $HOSTS/$I2/link"
within 3 sh -c "echo up > $HOSTS/$I2/link"
wait_for 10 disk_of "$H2" rd0 || fail "I2 did not log back in"
RD2=$(disk_of "$H2" rd0)
within 5 dd if=/dev/$RD2 of=/dev/null bs=1M count=4 iflag=direct status=none
within 5 mkdir "$HOSTS/$I3"
within 5 sh -c "echo up > $HOSTS/$I3/link"
within 3 cat "$HOSTS/$I3/targets"
within 5 rmdir "$HOSTS/$I3"
within 3 cat "$LIO/fcsim/$T1/tpgt_1/sessions"
# Logging I1 out leaves its T1 session with commands stuck in the backend:
# that drain must not hold up the fabric.
within 3 sh -c "echo down > $HOSTS/$I1/link"
echo "  I1 draining sessions: $(cat "$HOSTS/$I1/draining")"
[ "$(cat "$HOSTS/$I1/draining")" -ge 1 ] || fail "stuck session is not draining"
within 3 sh -c "echo down > $HOSTS/$I2/link"
within 3 sh -c "echo up > $HOSTS/$I2/link"
within 3 sh -c "echo up > $HOSTS/$I1/link"
within 3 cat "$HOSTS/$I1/targets"
[ "$(ntargets $I1)" = 1 ] || fail "I1 logged in to T1 again while its old session drains"
kill -0 $DD 2>/dev/null || fail "READ finished while the backend is frozen?"

# ---------------------------------------------------------------------------
step "2. backend recovers"
dmsetup resume $DM
wait_for 20 sh -c "[ \$(cat $HOSTS/$I1/draining) = 0 ]" || fail "session did not drain"
wait_for 10 sh -c "[ \$(wc -l < $HOSTS/$I1/targets) = 2 ]" || fail "I1 did not log in to T1 again"
wait $DD || fail "READ failed after the backend recovered"
echo "  READ completed"
wait_for 10 disk_of "$H1" hang || fail "hang LUN gone after recovery"
HANG1=$(disk_of "$H1" hang)
[ "$(cat /sys/block/$HANG1/device/state)" = running ] \
	|| fail "device state $(cat /sys/block/$HANG1/device/state)"
dd if=/dev/$HANG1 of=/dev/null bs=1M count=4 iflag=direct status=none || fail "I/O after recovery"
splat_check
echo "OK: recovered once the backend came back"

# ---------------------------------------------------------------------------
step "3. backend stays frozen: EH terminates exchanges, the READ fails"
echo 2 > /sys/block/$HANG1/device/timeout
dmesg -C
dmsetup suspend --noflush $DM
start=$(date +%s)
if timeout 120 dd if=/dev/$HANG1 of=/dev/null bs=4k count=1 iflag=direct status=none; then
	fail "READ succeeded on a frozen backend?"
fi
echo "  READ failed after $(( $(date +%s) - start ))s; host resets: $(dmesg | grep -c 'host reset: terminated')"
dmesg | grep -E "I/O error|offline" | sed 's/^/  /' | head -5
[ "$(cat /sys/block/$HANG1/device/state)" = running ] \
	|| fail "device state $(cat /sys/block/$HANG1/device/state)"
within 5 dd if=/dev/$RD2 of=/dev/null bs=1M count=4 iflag=direct status=none
dmsetup resume $DM
dd if=/dev/$HANG1 of=/dev/null bs=1M count=4 iflag=direct status=none || fail "I/O after recovery"
splat_check
echo "OK: EH terminated the exchanges, the device stayed usable"

step "teardown"
teardown_all
dmsetup remove $DM
losetup -d $LOOP
rm -f /tmp/hang.img
splat_check
echo
echo "PASS"
