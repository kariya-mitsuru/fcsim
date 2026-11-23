#!/bin/bash
# tcm_fcsim: SCSI EH paths that the other tests do not reach (run inside
# the guest as root).
#
#   1. a target reset that succeeds: every LUN of the target port gets a
#      LUN RESET, the target port's exchanges are terminated (also one the
#      fabric still holds) and retried, another target port's exchange is
#      left alone
#   2. fast_io_fail_tmo expiring while EH runs: a command stuck in the
#      backend times out, its ABORT TASK gets no answer, the link goes down
#      meanwhile; EH ends with FAST_IO_FAIL instead of a host reset, and
#      everything recovers with the link and the backend
set -euo pipefail

TOP=$(cd "$(dirname "$0")/.." && pwd)
. "$TOP/tests/lib.sh"

T1=21:00:00:00:00:00:00:01	# LUN 0 rd0, LUN 1 rd1
T2=21:00:00:00:00:00:00:02	# rd2
T3=21:00:00:00:00:00:00:03	# dm device that can be frozen
I1=10:00:00:00:c9:00:00:01
DM=fcsim_eh

step "setup"
modprobe loop
truncate -s 64M /tmp/eh.img
LOOP=$(losetup -f --show /tmp/eh.img)
dmsetup create $DM --table "0 $(blockdev --getsz "$LOOP") linear $LOOP 0"
modprobe target_core_iblock
load_fcsim tmr_timeout=3
for r in rd0 rd1 rd2; do $TCLI /backstores/ramdisk create $r 16M >/dev/null; done
$TCLI /backstores/block create hang /dev/mapper/$DM >/dev/null
make_tport $T1 /backstores/ramdisk/rd0 $I1
$TCLI "/fcsim/$(wwpn_naa $T1)/luns" create /backstores/ramdisk/rd1 >/dev/null
make_tport $T2 /backstores/ramdisk/rd2 $I1
make_tport $T3 /backstores/block/hang $I1
mkdir "$HOSTS/$I1"
echo up > "$HOSTS/$I1/link"
H1=$(host_of $I1)
for r in rd0 rd1 rd2 hang; do wait_for 10 disk_of "$H1" $r || fail "$r missing"; done
D0=$(disk_of "$H1" rd0); D1=$(disk_of "$H1" rd1); D2=$(disk_of "$H1" rd2)
DH=$(disk_of "$H1" hang)
echo "rd0 /dev/$D0, rd1 /dev/$D1 (T1); rd2 /dev/$D2 (T2); hang /dev/$DH (T3)"
head -c 65536 /dev/urandom > /tmp/pat
for d in $D0 $D2; do dd if=/tmp/pat of=/dev/$d bs=64k oflag=direct status=none; done
udevadm settle

ms() { echo $(( $(date +%s%N) / 1000000 )); }
resets() { cat $LIO/core/rd_mcp_*/"$1"/statistics/scsi_lu/resets; }
rule() {	# rule <target> <attr=value>...
	local f=$HOSTS/$I1/faults/$1 kv; shift
	[ -d "$f" ] && rmdir "$f"
	mkdir "$f"
	for kv in "$@"; do echo "${kv#*=}" > "$f/${kv%%=*}"; done
}
bg_read() {	# bg_read <disk> <out>: pid in IO
	dd if=/dev/"$1" of="$2" bs=64k count=1 iflag=direct status=none &
	IO=$!
}

# ---------------------------------------------------------------------------
step "1. target reset with a held READ on each of T1 and T2"
rule $T1 delay_ms=5000 count=1
rule $T2 delay_ms=3000 count=1
r0=$(resets rd0); r1=$(resets rd1); r2=$(resets rd2)
t0=$(ms)
bg_read "$D0" /tmp/rd0.out; IO0=$IO
bg_read "$D2" /tmp/rd2.out; IO2=$IO
wait_for 5 grep -qx 1 "$HOSTS/$I1/faults/$T1/injected" || fail "the T1 READ was not held"
wait_for 5 grep -qx 1 "$HOSTS/$I1/faults/$T2/injected" || fail "the T2 READ was not held"
# Through LUN 1, which has nothing outstanding: the reset covers the target.
sg_reset -N -t "/dev/$D1" >/tmp/reset.out 2>&1 || { cat /tmp/reset.out; fail "target reset failed"; }
echo "  target reset through /dev/$D1: ok"
wait "$IO0" || fail "the T1 READ failed"
t1=$(ms)
wait "$IO2" || fail "the T2 READ failed"
t2=$(ms)
echo "  T1 READ done after $((t1 - t0)) ms (held for 5000), T2 READ after $((t2 - t0)) ms (held for 3000)"
[ $((t1 - t0)) -lt 5000 ] || fail "the T1 exchange was not terminated by the target reset"
[ $((t2 - t0)) -ge 3000 ] || fail "the T2 exchange was terminated by T1's target reset"
cmp -s /tmp/pat /tmp/rd0.out && cmp -s /tmp/pat /tmp/rd2.out || fail "data mismatch"
echo "  LIO resets: rd0 $r0 -> $(resets rd0), rd1 $r1 -> $(resets rd1), rd2 $r2 -> $(resets rd2)"
[ "$(resets rd0)" = $((r0 + 1)) ] && [ "$(resets rd1)" = $((r1 + 1)) ] ||
	fail "not every LUN of T1 got a LUN RESET"
[ "$(resets rd2)" = "$r2" ] || fail "T2's LUN was reset"
rmdir "$HOSTS/$I1/faults/$T1" "$HOSTS/$I1/faults/$T2"
splat_check

# ---------------------------------------------------------------------------
step "2. fast_io_fail_tmo expires while EH waits for the target"
RP=$(rport_of "$H1" $T3)
echo 2 > "/sys/class/fc_remote_ports/$RP/fast_io_fail_tmo"
echo 30 > "/sys/class/fc_remote_ports/$RP/dev_loss_tmo"
echo 2 > "/sys/block/$DH/device/timeout"
AB=/sys/class/fc_host/$H1/statistics/fcp_packet_aborts
a0=$(hexval "$AB")
dmesg -C
dmsetup suspend --noflush $DM
t0=$(ms)
dd if=/dev/"$DH" of=/dev/null bs=4k count=1 iflag=direct status=none &
IO=$!
# EH has started on the stuck READ (its ABORT TASK now waits for an answer
# that the frozen backend never lets come): take the link away.
wait_for 10 sh -c "[ \$(printf '%d' \$(cat $AB)) -gt $a0 ]" || fail "EH did not start"
echo down > "$HOSTS/$I1/link"
if wait "$IO"; then fail "the stuck READ succeeded"; fi
t=$(( $(ms) - t0 ))
echo "  the READ failed after $t ms"
dmesg | grep -E "fast_io_fail_tmo expired|host reset" | sed 's/^/  /'
dmesg | grep -q "fast_io_fail_tmo expired" || fail "EH did not end with FAST_IO_FAIL"
dmesg | grep -q "host reset: terminated" && fail "EH escalated to a host reset despite FAST_IO_FAIL"
[ $t -lt 20000 ] || fail "FAST_IO_FAIL took $t ms"

step "2. the backend and the link come back"
dmsetup resume $DM
echo up > "$HOSTS/$I1/link"
wait_for 30 disk_of "$H1" hang || fail "the hang LUN did not come back"
DH=$(disk_of "$H1" hang)
[ "$(cat /sys/block/$DH/device/state)" = running ] || fail "device state $(cat /sys/block/$DH/device/state)"
dd if=/dev/"$DH" of=/dev/null bs=4k count=1 iflag=direct status=none || fail "READ after recovery"
echo "  ok"

step "teardown"
splat_check
teardown_all
dmsetup remove $DM
losetup -d "$LOOP"
rm -f /tmp/eh.img
splat_check
echo
echo "PASS"
