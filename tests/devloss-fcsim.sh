#!/bin/bash
# tcm_fcsim: dev_loss_tmo expiring (run inside the guest as root).
#
#   - link down longer than dev_loss_tmo: the rport becomes "Not Present",
#     its SCSI target and disk are removed; link up brings the same WWPN
#     back as a new disk with the data intact
#   - I/O queued while the rport is blocked (no fast_io_fail_tmo): it waits
#     for the whole dev_loss_tmo and then fails; nothing hangs
#   - a second target behind the same host is not affected
set -euo pipefail

TOP=$(cd "$(dirname "$0")/.." && pwd)
. "$TOP/tests/lib.sh"

T1=21:00:00:00:00:00:00:01
T2=21:00:00:00:00:00:00:02
I1=10:00:00:00:c9:00:00:01
TMO=3

step "setup: T1 (rd0), T2 (rd1), host I1"
load_fcsim
$TCLI /backstores/ramdisk create rd0 16M >/dev/null
$TCLI /backstores/ramdisk create rd1 16M >/dev/null
make_tport $T1 /backstores/ramdisk/rd0 $I1
make_tport $T2 /backstores/ramdisk/rd1 $I1
mkdir "$HOSTS/$I1"
echo up > "$HOSTS/$I1/link"
H1=$(host_of $I1)
wait_for 10 disk_of "$H1" rd0 || fail "rd0 missing"
wait_for 10 disk_of "$H1" rd1 || fail "rd1 missing"
D=$(disk_of "$H1" rd0)
D2=$(disk_of "$H1" rd1)
head -c 65536 /dev/urandom > /tmp/pat
dd if=/tmp/pat of=/dev/$D bs=64k oflag=direct status=none
udevadm settle
echo "rd0: /dev/$D, rd1: /dev/$D2"

rport_state() { cat "/sys/class/fc_remote_ports/$1/port_state"; }
setup_rport() {	# rport of T1, dev_loss_tmo=TMO, fast_io_fail_tmo off
	RP=$(rport_of "$H1" $T1) || fail "no rport for T1"
	echo off > "/sys/class/fc_remote_ports/$RP/fast_io_fail_tmo"
	echo $TMO > "/sys/class/fc_remote_ports/$RP/dev_loss_tmo"
	echo "  $RP: dev_loss_tmo=$(cat /sys/class/fc_remote_ports/$RP/dev_loss_tmo)" \
		"fast_io_fail_tmo=$(cat /sys/class/fc_remote_ports/$RP/fast_io_fail_tmo)"
}
gone() { [ ! -e "/sys/block/$1" ]; }

step "link down for longer than dev_loss_tmo=$TMO"
setup_rport
# Only T1 goes away: its TPG is disabled (the host's link would take T2 too).
echo 0 > "$LIO/fcsim/$T1/tpgt_1/enable"
wait_for 5 grep -qx Blocked "/sys/class/fc_remote_ports/$RP/port_state" ||
	fail "rport not blocked: $(rport_state "$RP")"
wait_for $((TMO + 5)) grep -qx "Not Present" "/sys/class/fc_remote_ports/$RP/port_state" ||
	fail "dev_loss_tmo did not expire: $(rport_state "$RP")"
wait_for 10 gone "$D" || fail "/dev/$D still there after dev_loss_tmo"
echo "  $RP: Not Present, /dev/$D removed"
dd if=/dev/$D2 of=/dev/null bs=64k count=1 iflag=direct status=none ||
	fail "I/O to T2 failed while T1 was gone"
grep -q "$T1" "$HOSTS/$I1/targets" && fail "T1 still listed in the host's targets"
"$TOP/tools/fcsimctl" status | sed 's/^/  /'

step "T1 comes back: a new disk, same data"
echo 1 > "$LIO/fcsim/$T1/tpgt_1/enable"
wait_for 10 disk_of "$H1" rd0 || fail "rd0 did not come back"
D=$(disk_of "$H1" rd0)
RP2=$(rport_of "$H1" $T1) || fail "no rport for T1"
echo "  $RP2: $(rport_state "$RP2"), disk /dev/$D"
[ "$(rport_state "$RP2")" = Online ] || fail "rport not Online"
dd if=/dev/$D of=/tmp/pat.rd bs=64k count=1 iflag=direct status=none ||
	fail "read after the target came back"
cmp -s /tmp/pat /tmp/pat.rd || fail "data mismatch after the target came back"
"$TOP/tools/fcsimctl" status | grep -q "$T1" || fail "fcsimctl status does not show T1"

step "I/O queued while blocked fails when dev_loss_tmo expires"
setup_rport
udevadm settle
echo 0 > "$LIO/fcsim/$T1/tpgt_1/enable"
wait_for 5 grep -qx Blocked "/sys/class/fc_remote_ports/$RP/port_state" ||
	fail "rport not blocked"
t0=$(date +%s%N)
dd if=/dev/$D of=/dev/null bs=64k count=1 iflag=direct status=none &
IO=$!
sleep 1
kill -0 $IO 2>/dev/null || fail "the I/O did not wait while the rport was blocked"
if wait $IO; then fail "the queued I/O succeeded"; fi
t=$(( ($(date +%s%N) - t0) / 1000000 ))
echo "  the queued READ failed after $t ms"
[ $t -lt $(( (TMO + 10) * 1000 )) ] || fail "the queued READ failed only after $t ms"
wait_for 10 gone "$D" || fail "/dev/$D still there"
echo 1 > "$LIO/fcsim/$T1/tpgt_1/enable"
wait_for 10 disk_of "$H1" rd0 || fail "rd0 did not come back"
D=$(disk_of "$H1" rd0)
dd if=/dev/$D of=/tmp/pat.rd bs=64k count=1 iflag=direct status=none
cmp -s /tmp/pat /tmp/pat.rd || fail "data mismatch"
echo "  rd0 back as /dev/$D"

step "teardown"
splat_check
teardown_all
splat_check
echo
echo "PASS"
