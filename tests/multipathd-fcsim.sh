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
MPD_PID=

cleanup() {
	[ -n "$MPD_PID" ] || return 0
	multipathd shutdown >/dev/null 2>&1 || true
	wait "$MPD_PID" 2>/dev/null || true
	MPD_PID=
}
trap cleanup EXIT

step "setup: one ramdisk behind T1 and T2, initiators I1 and I2"
modprobe target_core_mod
modprobe dm_multipath
modprobe dm_service_time
insmod "$TOP/src/tcm_fcsim.ko" tmr_timeout=1
$TCLI /backstores/ramdisk create shared ${SIZE_MB}M >/dev/null
make_tport $T1 /backstores/ramdisk/shared $I1 $I2
make_tport $T2 /backstores/ramdisk/shared $I1 $I2
mkdir "$HOSTS/$I1" "$HOSTS/$I2"
wait_for 10 sh -c "[ \$(ls -d /sys/class/fc_transport/target*/device/*/block/* 2>/dev/null | wc -l) = 4 ]" \
	|| fail "expected 4 paths"
udevadm settle

step "start multipathd"
mkdir -p /etc/multipath
rm -f /etc/multipath/bindings /etc/multipath/wwids
cat > /etc/multipath.conf <<'EOF'
defaults {
	polling_interval	1
	user_friendly_names	yes
	find_multipaths		off
}
blacklist {
	device {
		vendor	".*"
		product	".*"
	}
}
blacklist_exceptions {
	device {
		vendor	"LIO-ORG"
	}
}
devices {
	device {
		vendor			"LIO-ORG"
		product			".*"
		path_grouping_policy	group_by_prio
		hardware_handler	"1 alua"
		prio			alua
		path_selector		"service-time 0"
		path_checker		tur
		failback		immediate
		no_path_retry		8
		fast_io_fail_tmo	2
		dev_loss_tmo		30
	}
}
EOF
multipathd -d -s -v2 > /tmp/multipathd.log 2>&1 &
MPD_PID=$!
wait_for 20 sh -c "multipathd show maps raw format '%n' 2>/dev/null | grep -q ." \
	|| { cat /tmp/multipathd.log; fail "multipathd built no map"; }
MAP=$(multipathd show maps raw format '%n' | head -1)
DEV=/dev/mapper/$MAP

paths_state() {	# "<active>/<total> active, checker: <ready> ready"
	multipathd show paths raw format '%d %t %T' |
		awk '{n++; if ($2 == "active") a++; if ($3 == "ready") r++}
		     END {printf "%d/%d active, %d ready\n", a, n, r}'
}
active_paths() { multipathd show paths raw format '%t' | grep -c '^active' || true; }
wait_active() {	# wait_active <n> <seconds>
	wait_for "$2" sh -c "[ \$(multipathd show paths raw format '%t' | grep -c '^active') = $1 ]"
}

wait_active 4 20 || fail "not all paths active: $(paths_state)"
multipath -ll "$MAP" | sed 's/^/  /'
multipath -ll "$MAP" | grep -q "hwhandler='1 alua'" || fail "ALUA handler not in use"
for rp in /sys/class/fc_remote_ports/rport-*; do
	echo "  $(basename $rp): fast_io_fail_tmo=$(cat $rp/fast_io_fail_tmo) dev_loss_tmo=$(cat $rp/dev_loss_tmo)"
	[ "$(cat $rp/fast_io_fail_tmo)" = 2 ] && [ "$(cat $rp/dev_loss_tmo)" = 30 ] \
		|| fail "multipathd did not tune $(basename $rp)"
done

head -c $((SIZE_MB << 20)) /dev/urandom > /tmp/pat
dd if=/tmp/pat of=$DEV bs=1M oflag=direct status=none

writer() {	# rewrite the pattern chunk by chunk until /tmp/stop exists
	local i=0
	while [ ! -e /tmp/stop ]; do
		dd if=/tmp/pat of=$DEV bs=1M count=1 skip=$i seek=$i \
			oflag=direct status=none || { echo "write $i failed" > /tmp/writer.err; return 1; }
		i=$(( (i + 1) % SIZE_MB ))
	done
}

with_writer() {	# with_writer <break> <active paths while broken> <repair>
	rm -f /tmp/stop /tmp/writer.err
	writer & local w=$!
	sleep 1
	eval "$1"
	wait_active "$2" 30 || { touch /tmp/stop; fail "expected $2 active paths: $(paths_state)"; }
	echo "  broken:   $(paths_state)"
	sleep 2
	eval "$3"
	wait_active 4 30 || { touch /tmp/stop; fail "paths not reinstated: $(paths_state)"; }
	echo "  repaired: $(paths_state)  (reinstated by multipathd)"
	sleep 1
	touch /tmp/stop
	wait $w || fail "writer: $(cat /tmp/writer.err 2>/dev/null)"
	cmp /tmp/pat $DEV || fail "data mismatch"
	echo "  data intact"
}

step "link down on I1: 2 paths fail, multipathd reinstates them after link up"
with_writer "echo down > $HOSTS/$I1/link" 2 "echo up > $HOSTS/$I1/link"

step "T2 disabled: the 2 paths through T2 fail, then come back"
with_writer "echo 0 > $LIO/fcsim/$T2/tpgt_1/enable" 2 "echo 1 > $LIO/fcsim/$T2/tpgt_1/enable"

step "all paths down briefly: I/O is queued (no_path_retry 8) and completes"
echo down > "$HOSTS/$I1/link"; echo down > "$HOSTS/$I2/link"
wait_active 0 20 || fail "paths still active: $(paths_state)"
dd if=/tmp/pat of=$DEV bs=1M count=1 skip=3 seek=3 oflag=direct status=none &
DD=$!
sleep 3
kill -0 $DD 2>/dev/null || fail "I/O did not queue while all paths were down"
echo "  I/O queued; bringing the links back"
echo up > "$HOSTS/$I1/link"; echo up > "$HOSTS/$I2/link"
wait $DD || fail "queued I/O failed"
wait_active 4 30 || fail "paths not reinstated: $(paths_state)"
cmp /tmp/pat $DEV || fail "data mismatch"
echo "  queued I/O completed, $(paths_state)"

step "all paths down for longer than no_path_retry: I/O fails"
echo down > "$HOSTS/$I1/link"; echo down > "$HOSTS/$I2/link"
wait_active 0 20 || fail "paths still active: $(paths_state)"
t0=$(date +%s)
if dd if=$DEV of=/dev/null bs=4k count=1 iflag=direct status=none; then
	fail "read succeeded with no path"
fi
echo "  read failed after $(( $(date +%s) - t0 ))s"
echo up > "$HOSTS/$I1/link"; echo up > "$HOSTS/$I2/link"
wait_active 4 30 || fail "paths not reinstated: $(paths_state)"
cmp /tmp/pat $DEV || fail "data mismatch after recovery"
echo "  recovered: $(paths_state)"
splat_check

step "teardown"
multipath -F
cleanup
teardown_all
splat_check
echo
echo "PASS"
