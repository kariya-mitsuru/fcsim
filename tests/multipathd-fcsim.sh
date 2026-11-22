#!/bin/bash
# tcm_fcsim with multipathd (device-mapper-multipath), configured like a
# typical ALUA FC array (run inside the guest as root; the guest's /etc is
# an overlay, so the host's multipath.conf is untouched).
#
# One ramdisk behind T1 and T2, seen by I1 and I2: 4 paths.  Checks that
# multipathd builds an ALUA map, tunes the FC rports (fast_io_fail_tmo /
# dev_loss_tmo through fc_remote_ports), fails and reinstates paths by
# itself, and queues I/O while all paths are down for up to no_path_retry.
set -euo pipefail

TOP=$(cd "$(dirname "$0")/.." && pwd)
. "$TOP/tests/lib.sh"

T1=21:00:00:00:00:00:00:01
T2=21:00:00:00:00:00:00:02
I1=10:00:00:00:c9:00:00:01
I2=10:00:00:00:c9:00:00:02
SIZE_MB=32

step "setup: one ramdisk behind T1 and T2, initiators I1 and I2"
modprobe dm_multipath
modprobe dm_service_time
load_fcsim tmr_timeout=1
$TCLI /backstores/ramdisk create shared ${SIZE_MB}M >/dev/null
make_tport $T1 /backstores/ramdisk/shared $I1 $I2
make_tport $T2 /backstores/ramdisk/shared $I1 $I2
mkdir "$HOSTS/$I1" "$HOSTS/$I2"
echo up > "$HOSTS/$I1/link"; echo up > "$HOSTS/$I2/link"
wait_paths 4 || fail "expected 4 paths"
udevadm settle

step "start multipathd"
# ALUA needs the scsi_dh_alua device handler (built in on the development
# and AlmaLinux 9 kernels, missing on WSL2); without it, use the paths as
# equals.
if modprobe scsi_dh_alua 2>/dev/null || [ -d /sys/module/scsi_dh_alua ]; then
	ALUA=1
	HWH='"1 alua"'; PRIO=alua
else
	ALUA=0
	HWH='"0"'; PRIO=const
	echo "  no scsi_dh_alua: hardware_handler 0, prio const"
fi
write_multipath_conf "" "
	path_grouping_policy	group_by_prio
	hardware_handler	$HWH
	prio			$PRIO
	path_selector		\"service-time 0\"
	path_checker		tur
	failback		immediate
	no_path_retry		8
	fast_io_fail_tmo	2
	dev_loss_tmo		30"
start_multipathd 2 4
DEV=/dev/mapper/$MAP

paths_state() {	# "<active>/<total> active, checker: <ready> ready"
	multipathd show paths raw format '%d %t %T' |
		awk '{n++; if ($2 == "active") a++; if ($3 == "ready") r++}
		     END {printf "%d/%d active, %d ready\n", a, n, r}'
}
multipath -ll "$MAP" | sed 's/^/  /'
if [ $ALUA = 1 ]; then
	multipath -ll "$MAP" | grep -q "hwhandler='1 alua'" || fail "ALUA handler not in use"
fi
for rp in /sys/class/fc_remote_ports/rport-*; do
	echo "  $(basename $rp): fast_io_fail_tmo=$(cat $rp/fast_io_fail_tmo) dev_loss_tmo=$(cat $rp/dev_loss_tmo)"
	[ "$(cat $rp/fast_io_fail_tmo)" = 2 ] && [ "$(cat $rp/dev_loss_tmo)" = 30 ] \
		|| fail "multipathd did not tune $(basename $rp)"
done

head -c $((SIZE_MB << 20)) /dev/urandom > /tmp/pat
dd if=/tmp/pat of=$DEV bs=1M oflag=direct status=none

with_writer() {	# with_writer <break> <active paths while broken> <repair>
	writer_start $DEV $SIZE_MB
	sleep 1
	eval "$1"
	wait_mp_active "$2" 30 || { touch /tmp/stop; fail "expected $2 active paths: $(paths_state)"; }
	echo "  broken:   $(paths_state)"
	sleep 2
	eval "$3"
	wait_mp_active 4 30 || { touch /tmp/stop; fail "paths not reinstated: $(paths_state)"; }
	echo "  repaired: $(paths_state)  (reinstated by multipathd)"
	sleep 1
	writer_stop
	cmp /tmp/pat $DEV || fail "data mismatch"
	echo "  data intact"
}

step "link down on I1: 2 paths fail, multipathd reinstates them after link up"
with_writer "echo down > $HOSTS/$I1/link" 2 "echo up > $HOSTS/$I1/link"

step "T2 disabled: the 2 paths through T2 fail, then come back"
with_writer "echo 0 > $LIO/fcsim/$T2/tpgt_1/enable" 2 "echo 1 > $LIO/fcsim/$T2/tpgt_1/enable"

step "all paths down briefly: I/O is queued (no_path_retry 8) and completes"
echo down > "$HOSTS/$I1/link"; echo down > "$HOSTS/$I2/link"
wait_mp_active 0 20 || fail "paths still active: $(paths_state)"
dd if=/tmp/pat of=$DEV bs=1M count=1 skip=3 seek=3 oflag=direct status=none &
DD=$!
sleep 3
kill -0 $DD 2>/dev/null || fail "I/O did not queue while all paths were down"
echo "  I/O queued; bringing the links back"
echo up > "$HOSTS/$I1/link"; echo up > "$HOSTS/$I2/link"
wait $DD || fail "queued I/O failed"
wait_mp_active 4 30 || fail "paths not reinstated: $(paths_state)"
cmp /tmp/pat $DEV || fail "data mismatch"
echo "  queued I/O completed, $(paths_state)"

step "all paths down for longer than no_path_retry: I/O fails"
echo down > "$HOSTS/$I1/link"; echo down > "$HOSTS/$I2/link"
wait_mp_active 0 20 || fail "paths still active: $(paths_state)"
t0=$(date +%s)
if dd if=$DEV of=/dev/null bs=4k count=1 iflag=direct status=none; then
	fail "read succeeded with no path"
fi
echo "  read failed after $(( $(date +%s) - t0 ))s"
echo up > "$HOSTS/$I1/link"; echo up > "$HOSTS/$I2/link"
wait_mp_active 4 30 || fail "paths not reinstated: $(paths_state)"
cmp /tmp/pat $DEV || fail "data mismatch after recovery"
echo "  recovered: $(paths_state)"
splat_check

step "teardown"
# udev may still be probing the map after the last reinstatement.
udevadm settle
wait_for 10 multipath -F || fail "multipath -F: map stays in use"
stop_multipathd
teardown_all
splat_check
echo
echo "PASS"
