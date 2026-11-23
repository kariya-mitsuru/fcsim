#!/bin/bash
# tcm_fcsim: exchanges the fabric still holds (delay_ms, timer armed) when
# something else ends them (run inside the guest as root).
#
#   - link down (logout): the held exchange is terminated, the midlayer
#     retries after link up
#   - EH abort: the abort ends the held exchange before the delay is over
#   - the rule is deleted: the exchange keeps its delay and then goes on
#   - the delay timer firing around a logout (a sweep of offsets: not
#     deterministic, but each run crosses the window several times)
#   - the host is deleted: the held I/O fails, nothing hangs
#
# Each case checks that the late timer (if it was not deleted) does nothing:
# the test waits past the original delay before checking for splats.
set -euo pipefail

TOP=$(cd "$(dirname "$0")/.." && pwd)
. "$TOP/tests/lib.sh"

T1=21:00:00:00:00:00:00:01
I1=10:00:00:00:c9:00:00:01
F=$HOSTS/$I1/faults/$T1

step "setup: T1 (rd0), host I1"
load_fcsim
$TCLI /backstores/ramdisk create rd0 16M >/dev/null
make_tport $T1 /backstores/ramdisk/rd0 $I1
mkdir "$HOSTS/$I1"
echo up > "$HOSTS/$I1/link"
H1=$(host_of $I1)
wait_for 10 disk_of "$H1" rd0 || fail "LUN missing"
D=$(disk_of "$H1" rd0)
DEV=/sys/block/$D/device
echo "disk /dev/$D on $H1"
head -c 65536 /dev/urandom > /tmp/pat
dd if=/tmp/pat of=/dev/$D bs=64k oflag=direct status=none
udevadm settle

ms() { echo $(( $(date +%s%N) / 1000000 )); }

rule() {	# rule <attr=value>...: (re)create the T1 rule
	[ -d "$F" ] && rmdir "$F"
	mkdir "$F"
	local kv
	for kv in "$@"; do echo "${kv#*=}" > "$F/${kv%%=*}"; done
}

# bg_read: read the pattern back in the background (pid in IO); io_wait
# fails the test unless it succeeded and the data matches.
bg_read() {
	rm -f /tmp/pat.rd
	dd if=/dev/$D of=/tmp/pat.rd bs=64k count=1 iflag=direct status=none &
	IO=$!
}
io_wait() {
	wait "$IO" || fail "$1: the I/O failed"
	cmp -s /tmp/pat /tmp/pat.rd || fail "$1: data mismatch"
}
# held: the rule caught the command and the I/O is still waiting.
held() {
	wait_for 5 grep -qx 1 "$F/injected" || fail "the command was not held"
	kill -0 "$IO" 2>/dev/null || fail "the I/O did not wait for the delay"
}
link_bounce() {	# link_bounce <seconds down>
	echo down > "$HOSTS/$I1/link"
	sleep "$1"
	echo up > "$HOSTS/$I1/link"
	wait_for 10 grep -qx Online "/sys/class/fc_host/$H1/port_state" ||
		fail "link did not come back"
}

step "link down while a WRITE is held (delay_ms=3000)"
head -c 65536 /dev/urandom > /tmp/pat
rule delay_ms=3000 count=1
t0=$(ms)
dd if=/tmp/pat of=/dev/$D bs=64k oflag=direct status=none &
IO=$!
held
link_bounce 0.5
wait "$IO" || fail "the held WRITE was not retried after link up"
echo "  WRITE done after $(( $(ms) - t0 )) ms"
sleep 3		# past the original delay: a timer left behind would fire now
dd if=/dev/$D of=/tmp/pat.rd bs=64k count=1 iflag=direct status=none
cmp -s /tmp/pat /tmp/pat.rd || fail "data mismatch after the retried WRITE"
splat_check
echo "  ok"

step "EH abort of a held READ (timeout 2 s, delay_ms=6000)"
echo 2 > "$DEV/timeout"
rule delay_ms=6000 count=1
t0=$(ms)
bg_read
held
io_wait "abort"
t=$(( $(ms) - t0 ))
echo "  READ done after $t ms"
[ $t -lt 6000 ] || fail "the abort did not end the held command (waited the whole delay)"
sleep 5		# past the original delay
echo 30 > "$DEV/timeout"
splat_check
echo "  ok"

step "rule deleted while a READ is held (delay_ms=1500)"
rule delay_ms=1500 count=1
t0=$(ms)
bg_read
held
rmdir "$F"
io_wait "rule deleted"
t=$(( $(ms) - t0 ))
echo "  READ done after $t ms"
[ $t -ge 1500 ] || fail "the held command lost its delay"
splat_check
echo "  ok"

step "delay timer vs logout: link down around the moment the timer fires"
for off in 0.90 0.95 0.98 1.00 1.02 1.05 1.10; do
	rule delay_ms=1000 count=1
	bg_read
	sleep "$off"
	link_bounce 0.2
	io_wait "link down at ${off}s"
	echo "  link down at ${off}s: ok"
done
rmdir "$F"
sleep 1
splat_check

step "host deleted while a READ is held (delay_ms=5000)"
rule delay_ms=5000 count=1
bg_read
held
rmdir "$F"	# the host's rules go first; the held command stays held
within 10 rmdir "$HOSTS/$I1"
if wait "$IO"; then fail "the held READ succeeded on a deleted host"; fi
echo "  the held READ failed, as it must"
sleep 5		# past the original delay
splat_check

step "teardown"
teardown_all
splat_check
echo
echo "PASS"
