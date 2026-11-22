#!/bin/bash
# tcm_fcsim race regression tests (run inside the virtme-ng guest as root).
#
#   race-fcsim.sh abort   EH abort of a command that LIO has taken off its
#                         state list but not yet released (TASK_DOES_NOT_EXIST
#                         while the se_cmd is still alive): EH terminates the
#                         exchange, the retried command must not be disturbed
#                         by the late completion.  Same for a LUN reset.
#   race-fcsim.sh close   LIO close_session (ACL removal) racing with a
#                         fabric logout (link down)
#   race-fcsim.sh deliver EH (a host reset) terminating a delayed command
#                         between target_init_cmd() and the hand-over to
#                         LIO: the command must never reach the target
#
# They use the test-only module parameters dbg_release_delay_ms /
# dbg_close_delay_ms / dbg_deliver_delay_ms to widen the windows.  Run each scenario in its own
# guest: a regression may crash the kernel.
set -euo pipefail

TOP=$(cd "$(dirname "$0")/.." && pwd)
. "$TOP/tests/guest-setup.sh"

SCENARIO=${1:?usage: $0 abort|close|deliver}
TWWPN=21:00:00:00:00:00:00:01
IWWPN=10:00:00:00:c9:00:00:01
LIO=/sys/kernel/config/target
TPG=$LIO/fcsim/$TWWPN/tpgt_1
HOSTS=/sys/kernel/config/fcsim/hosts
PARAM=/sys/module/tcm_fcsim/parameters

step() { echo; echo "=== $*"; }
fail() { echo "FAIL: $*" >&2; dmesg | tail -60 >&2; exit 1; }

wait_for() {	# wait_for <seconds> <command...>
	local t=$(( $1 * 10 )); shift
	while ! "$@" >/dev/null 2>&1; do
		t=$((t - 1)); [ $t -gt 0 ] || return 1
		sleep 0.1
	done
}

fcsim_disk() {
	local d
	for d in /sys/class/fc_transport/target*/device/*/block/*; do
		[ -e "$d" ] && blockdev --getsz "/dev/$(basename "$d")" >/dev/null 2>&1 &&
			{ echo "/dev/$(basename "$d")"; return 0; }
	done
	return 1
}

splat_check() {
	if dmesg | grep -E 'BUG:|WARNING:|KASAN|possible circular|INFO: task .* blocked|Call Trace'; then
		fail "kernel splat detected"
	fi
}

step "setup: ramdisk LUN 0 on $TWWPN, explicit ACL for $IWWPN"
modprobe target_core_mod
load_fcsim
targetcli /backstores/ramdisk create rd0 16M >/dev/null
RD=$(dirname "$(ls -d $LIO/core/rd_mcp_*/rd0)")/rd0
mkdir -p "$TPG/lun/lun_0" "$TPG/acls/$IWWPN/lun_0"
ln -s "$RD" "$TPG/lun/lun_0/rd0"
ln -s "$TPG/lun/lun_0" "$TPG/acls/$IWWPN/lun_0/map"
echo 1 > "$TPG/enable"
mkdir "$HOSTS/$IWWPN"
HOST=$(cat "$HOSTS/$IWWPN/scsi_host")
wait_for 5 fcsim_disk || fail "LUN did not appear"
DISK=$(fcsim_disk)
echo "disk: $DISK"

case $SCENARIO in
abort)
	step "abort: READ times out while LIO holds it outside the state list"
	head -c 4096 /dev/urandom > /tmp/blk
	dd if=/tmp/blk of="$DISK" bs=4096 seek=10 oflag=direct status=none
	DEV=/sys/block/$(basename "$DISK")/device
	echo 2 > "$DEV/timeout"
	udevadm settle	# the write triggers a udev probe READ that would eat the one-shot delay
	echo 5000 > "$PARAM/dbg_release_delay_ms"	# one-shot, > timeout
	dd if="$DISK" of=/tmp/blk.rd bs=4096 skip=10 count=1 iflag=direct status=none \
		|| fail "READ failed"
	cmp /tmp/blk /tmp/blk.rd || fail "data mismatch after abort + retry"
	sleep 6		# let the delayed command finish in any case
	dmesg | sed -n '/ABORT_TASK/,$p' | head -100
	dmesg | grep -q 'ABORT_TASK: Sending TMR_TASK_DOES_NOT_EXIST' \
		|| fail "race window not hit (no TASK_DOES_NOT_EXIST)"
	splat_check
	[ "$(cat "$DEV/state")" = running ] || fail "device state $(cat "$DEV/state")"
	# The retried command must not have been completed twice: more I/O.
	dd if="$DISK" of=/dev/null bs=1M iflag=direct status=none || fail "I/O after abort"
	splat_check
	echo "OK: abort terminated the exchange, the late completion was dropped"

	step "LUN reset while a READ is held outside the state list"
	echo 30 > "$DEV/timeout"
	echo 3000 > "$PARAM/dbg_release_delay_ms"
	dd if="$DISK" of=/tmp/blk.rd2 bs=4096 skip=10 count=1 iflag=direct status=none &
	DD=$!
	sleep 1
	start=$(date +%s)
	sg_reset -d "$DISK" || fail "LUN reset failed"
	echo "sg_reset -d took $(( $(date +%s) - start ))s"
	wait $DD || fail "READ across LUN reset failed"
	cmp /tmp/blk /tmp/blk.rd2 || fail "data mismatch across LUN reset"
	[ "$(cat "$DEV/state")" = running ] || fail "device state $(cat "$DEV/state")"
	splat_check
	echo "OK: LUN reset"
	;;
close)
	step "close: ACL removal (close_session delayed) vs link down"
	echo 2000 > "$PARAM/dbg_close_delay_ms"
	rm "$TPG/acls/$IWWPN/lun_0/map"
	rmdir "$TPG/acls/$IWWPN/lun_0"
	rmdir "$TPG/acls/$IWWPN" &
	RMDIR=$!
	sleep 0.5	# rmdir is now sleeping inside close_session
	echo down > "$HOSTS/$IWWPN/link"	# reconcile logs the session out
	wait $RMDIR || fail "ACL rmdir failed"
	echo 0 > "$PARAM/dbg_close_delay_ms"
	echo up > "$HOSTS/$IWWPN/link"
	[ "$(cat "$TPG/sessions")" = "$IWWPN" ] || fail "no relogin after link up"
	echo "OK: sessions after link up: $(cat "$TPG/sessions")"
	;;
deliver)
	step "deliver: exchange terminated between target_init_cmd and the hand-over to LIO"
	STAT=$TPG/lun/lun_0/statistics/scsi_tgt_port/in_cmds
	udevadm settle
	before=$(cat "$STAT")
	echo 1 > "$PARAM/dbg_deliver_terminate"	# one-shot, TEST UNIT READY only
	# SG_IO does not retry: the terminated command is not sent again.
	# Read-only open: closing a writable one makes udev probe the disk.
	if sg_raw -R "$DISK" 00 00 00 00 00 00 >/tmp/turs.out 2>&1; then
		cat /tmp/turs.out
		fail "the terminated TEST UNIT READY succeeded"
	fi
	sed 's/^/  sg_raw: /' /tmp/turs.out
	dmesg | grep -q 'dbg: terminating TEST UNIT READY' || fail "the knob did not fire"
	udevadm settle
	after=$(cat "$STAT")
	echo "target port in_cmds: before $before, after $after"
	[ "$after" = "$before" ] || fail "a terminated command reached the target"
	dd if="$DISK" of=/dev/null bs=1M count=4 iflag=direct status=none || fail "I/O afterwards"
	# A leaked session command reference would hang the drain at teardown.
	splat_check
	echo "OK: the terminated command was dropped before LIO"
	;;
*)
	fail "unknown scenario $SCENARIO"
	;;
esac

step "teardown"
rmdir "$HOSTS/$IWWPN"
rm -f "$TPG/acls/$IWWPN/lun_0/map"
rmdir "$TPG/acls/$IWWPN/lun_0" "$TPG/acls/$IWWPN" 2>/dev/null || true
rm "$TPG/lun/lun_0/rd0"
rmdir "$TPG/lun/lun_0" "$TPG" "$LIO/fcsim/$TWWPN" "$LIO/fcsim"
rmmod tcm_fcsim

step "dmesg check"
splat_check
echo
echo "PASS ($SCENARIO)"
