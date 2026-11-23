#!/bin/bash
# tcm_fcsim: concurrent I/O while the fabric is disturbed at random (run
# inside the guest as root).
#
#   stress-fcsim.sh [seconds] [seed]     (default 60 s, a random seed)
#
# WORKERS background writers each own a 1 MiB region of a ramdisk LUN and
# loop: random chunk (4-64 KiB) -> write -> read back -> compare, keeping a
# shadow copy of the region; at the end each region is compared whole.
# Meanwhile a disturber picks, at random intervals, one of:
#
#   link down / up          (logout: open exchanges terminated, retried)
#   TPG disable / enable    (the target port goes away and comes back)
#   delay_ms rule           (exchanges held by a timer, some terminated)
#   drop=cmd rule, count=2  (command timeouts: EH abort of held exchanges)
#   error=busy rule         (retried by the midlayer)
#   issue_lip               (rediscovery while I/O runs)
#   sg_reset -d             (LUN RESET with I/O in flight)
#
# Every disturbance is one the midlayer must hide: no worker may see an
# error.  The seed is printed so that a failing run can be repeated.
set -euo pipefail

TOP=$(cd "$(dirname "$0")/.." && pwd)
. "$TOP/tests/lib.sh"

SECS=${1:-60}
SEED=${2:-$(( $(date +%s) % 32768 ))}
WORKERS=8
T1=21:00:00:00:00:00:00:01
I1=10:00:00:00:c9:00:00:01
F=$HOSTS/$I1/faults/$T1
TPG=$LIO/fcsim/$T1/tpgt_1
W=/tmp/stress
echo "stress: ${SECS}s, seed $SEED (repeat: $0 $SECS $SEED)"
RANDOM=$SEED

step "setup: T1 (rd0, 16 MiB), host I1, $WORKERS workers"
load_fcsim tmr_timeout=2
$TCLI /backstores/ramdisk create rd0 16M >/dev/null
make_tport $T1 /backstores/ramdisk/rd0 $I1
mkdir "$HOSTS/$I1"
echo up > "$HOSTS/$I1/link"
H1=$(host_of $I1)
wait_for 10 disk_of "$H1" rd0 || fail "LUN missing"
D=$(disk_of "$H1" rd0)
echo "disk /dev/$D on $H1"
# A timed-out command is aborted after 3 s, not 30: drop=cmd stays short.
echo 3 > "/sys/block/$D/device/timeout"
udevadm settle

rm -rf $W; mkdir -p $W
worker() {	# worker <n>: region n (1 MiB at n MiB) of the disk
	local n=$1 off len s
	s=$W/shadow.$n
	RANDOM=$((SEED + n))
	head -c $((1 << 20)) /dev/urandom > "$s"
	dd if="$s" of=/dev/$D bs=1M seek="$n" oflag=direct status=none ||
		{ echo "worker $n: initial write failed" > $W/err.$n; return 1; }
	while [ ! -e $W/stop ]; do
		off=$((RANDOM % 240))		# in 4 KiB blocks
		len=$((1 + RANDOM % 16))
		head -c $((len * 4096)) /dev/urandom |
			dd of="$s" bs=4k seek=$off conv=notrunc status=none
		dd if="$s" of=/dev/$D bs=4k skip=$off seek=$((n * 256 + off)) count=$len \
			oflag=direct status=none ||
			{ echo "worker $n: write at block $off failed" > $W/err.$n; return 1; }
		dd if=/dev/$D of=$W/rd.$n bs=4k skip=$((n * 256 + off)) count=$len \
			iflag=direct status=none ||
			{ echo "worker $n: read at block $off failed" > $W/err.$n; return 1; }
		cmp -s $W/rd.$n <(dd if="$s" bs=4k skip=$off count=$len status=none) ||
			{ echo "worker $n: mismatch at block $off" > $W/err.$n; return 1; }
		echo $(( $(cat $W/ops.$n 2>/dev/null || echo 0) + 1 )) > $W/ops.$n
	done
}
PIDS=()
for n in $(seq 0 $((WORKERS - 1))); do
	worker "$n" &
	PIDS+=($!)
done

rule() {	# rule <attr=value>...: (re)create the T1 rule
	[ -d "$F" ] && rmdir "$F"
	mkdir "$F"
	local kv
	for kv in "$@"; do echo "${kv#*=}" > "$F/${kv%%=*}"; done
}
online() {
	wait_for 15 grep -qx Online "/sys/class/fc_host/$H1/port_state" ||
		fail "link did not come back"
	wait_for 15 sh -c "[ \$(wc -l < $HOSTS/$I1/targets) = 1 ]" ||
		fail "the target did not come back"
}
msleep() { sleep "$(printf '%d.%03d' $(($1 / 1000)) $(($1 % 1000)))"; }

step "disturbing for ${SECS}s"
end=$(( $(date +%s) + SECS ))
declare -A done_
while [ "$(date +%s)" -lt "$end" ]; do
	for p in "${PIDS[@]}"; do
		kill -0 "$p" 2>/dev/null || fail "a worker stopped: $(cat $W/err.* 2>/dev/null)"
	done
	what=$((RANDOM % 7))
	case $what in
	0)	d=$((200 + RANDOM % 800))
		echo "  link down ${d} ms"
		echo down > "$HOSTS/$I1/link"; msleep $d
		echo up > "$HOSTS/$I1/link"; online ;;
	1)	d=$((200 + RANDOM % 800))
		echo "  TPG disable ${d} ms"
		echo 0 > "$TPG/enable"; msleep $d
		echo 1 > "$TPG/enable"; online ;;
	2)	d=$((10 + RANDOM % 500)); p=$((10 + RANDOM % 40))
		echo "  delay_ms=$d probability=$p"
		rule delay_ms=$d probability=$p ;;
	3)	echo "  drop=cmd probability=10 count=2"
		rule drop=cmd probability=10 count=2 ;;
	4)	echo "  error=busy probability=20 count=5"
		rule error=busy probability=20 count=5 ;;
	5)	echo "  issue_lip"
		echo 1 > "/sys/class/fc_host/$H1/issue_lip"; online ;;
	6)	echo "  sg_reset -d"
		sg_reset -d "/dev/$D" >/dev/null 2>&1 || echo "    (LUN reset failed)" ;;
	esac
	done_[$what]=1
	msleep $((300 + RANDOM % 1500))
	if [ -d "$F" ] && [ $((RANDOM % 2)) = 0 ]; then
		echo "  rule removed"
		rmdir "$F"
	fi
done
[ -d "$F" ] && rmdir "$F"
echo "  disturbances used: ${!done_[*]}"

step "stop the workers and compare every region"
touch $W/stop
rc=0
for p in "${PIDS[@]}"; do wait "$p" || rc=1; done
[ $rc = 0 ] || fail "worker error: $(cat $W/err.* 2>/dev/null)"
total=0
for n in $(seq 0 $((WORKERS - 1))); do
	total=$((total + $(cat $W/ops.$n 2>/dev/null || echo 0)))
	dd if=/dev/$D of=$W/rd.$n bs=1M skip="$n" count=1 iflag=direct status=none
	cmp -s $W/rd.$n $W/shadow.$n || fail "region $n differs from its shadow"
done
echo "  $total write/read/compare rounds, all regions intact"
[ $total -gt $((WORKERS * 10)) ] || fail "too little I/O got through ($total rounds)"
grep . /sys/class/fc_host/$H1/statistics/{fcp_packet_aborts,dumped_frames,link_failure_count} |
	sed 's|.*/||; s/^/  /'

step "teardown"
splat_check
teardown_all
splat_check
echo
echo "PASS (seed $SEED)"
