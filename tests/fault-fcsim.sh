#!/bin/bash
# tcm_fcsim: fault injection, fast_io_fail_tmo and RSCN (run inside the
# guest as root).
set -euo pipefail

TOP=$(cd "$(dirname "$0")/.." && pwd)
. "$TOP/tests/lib.sh"

T1=21:00:00:00:00:00:00:01
T2=21:00:00:00:00:00:00:02
I1=10:00:00:00:c9:00:00:01
F=$HOSTS/$I1/faults/$T1

step "setup: T1 (rd0) and T2 (rd1), host I1"
modprobe target_core_mod
load_fcsim tmr_timeout=1
$TCLI /backstores/ramdisk create rd0 16M >/dev/null
$TCLI /backstores/ramdisk create rd1 16M >/dev/null
make_tport $T1 /backstores/ramdisk/rd0 $I1
make_tport $T2 /backstores/ramdisk/rd1 $I1
mkdir "$HOSTS/$I1"
H1=$(host_of $I1)
wait_for 10 disk_of "$H1" rd0 || fail "LUN missing"
D=$(disk_of "$H1" rd0)
DEV=/sys/block/$D/device
echo "disk /dev/$D on $H1"
head -c 65536 /dev/urandom > /tmp/pat
dd if=/tmp/pat of=/dev/$D bs=64k oflag=direct status=none
udevadm settle

rd() {	# rd: read the pattern back through the fabric and compare
	dd if=/dev/$D of=/tmp/pat.rd bs=64k count=1 iflag=direct status=none &&
		cmp -s /tmp/pat /tmp/pat.rd
}

rule() {	# rule <attr=value>...: (re)create the T1 rule
	[ -d "$F" ] && rmdir "$F"
	mkdir "$F"
	local kv
	for kv in "$@"; do echo "${kv#*=}" > "$F/${kv%%=*}"; done
}

ms() { echo $(( $(date +%s%N) / 1000000 )); }

step "delay_ms=300"
rule delay_ms=300
t0=$(ms); rd || fail "read with delay"; t1=$(ms)
echo "  read took $((t1 - t0)) ms, injected=$(cat $F/injected)"
[ $((t1 - t0)) -ge 300 ] || fail "delay not applied"

step "error=transport count=1: retried by the midlayer"
rule error=transport count=1
rd || fail "transient transport error not retried"
[ "$(cat $F/injected)" = 1 ] && [ "$(cat $F/count)" = 0 ] || fail "count/injected"
echo "  ok, injected=1"

step "error=busy / qfull count=3: retried"
rule error=busy count=3
rd || fail "BUSY not retried"
rule error=qfull count=3
rd || fail "TASK SET FULL not retried"
echo "  ok"

step "error=medium count=1: the READ fails with a medium error"
rule error=medium count=1
if rd; then fail "medium error not reported"; fi
# (decoded only with CONFIG_SCSI_CONSTANTS, which e.g. WSL2 lacks)
dmesg | grep -m1 -E "Unrecovered read error|ASC=0x11 ASCQ=0x0" | sed 's/^/  /' || fail "no sense in dmesg"
rd || fail "read after the one-shot error"

step "error=aborted count=1: ABORTED COMMAND is retried"
rule error=aborted count=1
rd || fail "ABORTED COMMAND not retried"
echo "  ok"

step "probability=50 delay_ms=20 over 40 reads"
rule delay_ms=20 probability=50
for _ in $(seq 40); do dd if=/dev/$D of=/dev/null bs=4k count=1 iflag=direct status=none; done
n=$(cat $F/injected); echo "  injected=$n"
[ "$n" -gt 5 ] && [ "$n" -lt 35 ] || fail "probability looks wrong ($n/40)"
rmdir "$F"

echo 2 > $DEV/timeout
echo 2 > $DEV/eh_timeout

step "drop=cmd count=1: timeout, EH takes the exchange back from the fabric"
dmesg -C
rule drop=cmd count=1
t0=$(ms); rd || fail "read after a dropped command"; t1=$(ms)
echo "  read took $((t1 - t0)) ms"
dmesg | grep -q "ABORT_TASK" && fail "ABORT_TASK sent for a command the target never saw"
[ "$(cat $DEV/state)" = running ] || fail "state $(cat $DEV/state)"

step "drop=rsp count=1: target executed it, the response is lost"
dmesg -C
rule drop=rsp count=1
rd || fail "read after a lost response"
dmesg | grep -E "ABORT_TASK" | sed 's/^/  /'

step "drop=rsp (all, TMRs too): unresponsive target, EH escalates to host reset"
dmesg -C
rule drop=rsp
if timeout 120 dd if=/dev/$D of=/dev/null bs=4k count=1 iflag=direct status=none; then
	fail "read succeeded on an unresponsive target?"
fi
dmesg | grep -E "dropping TMR|host reset|offline" | sed 's/^/  /' | sort -u -k3 | head -8
dmesg | grep -q "host reset: terminated" || fail "no host reset"
rmdir "$F"
echo running > $DEV/state
rd || fail "read after the target came back"
echo "  ok: recovered after removing the rule"
splat_check

step "fast_io_fail_tmo: I/O fails over quickly while the rport is blocked"
RPORT=$(ls -d /sys/class/scsi_host/$H1/device/rport-*/target*/*/block/$D | sed 's|.*/\(rport-[^/]*\)/.*|\1|')
RP=/sys/class/fc_remote_ports/$RPORT
echo 30 > $RP/dev_loss_tmo
echo 2 > $RP/fast_io_fail_tmo
grep . $RP/{port_state,dev_loss_tmo,fast_io_fail_tmo} | sed 's/^/  /'
echo down > "$HOSTS/$I1/link"
[ "$(cat $RP/port_state)" = Blocked ] || fail "rport not blocked"
t0=$(ms)
if dd if=/dev/$D of=/dev/null bs=4k count=1 iflag=direct status=none; then
	fail "read succeeded with the link down?"
fi
t1=$(ms)
echo "  read failed after $((t1 - t0)) ms (fast_io_fail_tmo=2, dev_loss_tmo=30)"
[ $((t1 - t0)) -lt 10000 ] || fail "fast_io_fail_tmo not honoured"
echo up > "$HOSTS/$I1/link"
wait_for 10 sh -c "[ \$(cat $RP/port_state) = Online ]" || fail "rport not back"
wait_for 10 rd || fail "read after link up"
echo "  ok: rport $(cat $RP/port_state) again"

step "RSCN and link events (netlink)"
python3 "$TOP/tests/fc-events.py" 4 > /tmp/events &
EV=$!
sleep 0.5
echo 0 > "$LIO/fcsim/$T2/tpgt_1/enable"
echo 1 > "$LIO/fcsim/$T2/tpgt_1/enable"
echo down > "$HOSTS/$I1/link"
echo up > "$HOSTS/$I1/link"
wait $EV
sed 's/^/  /' /tmp/events
T2PID=$(cat "$LIO/fcsim/$T2/tpgt_1/port_id")
[ "$(grep -c "^$H1 RSCN $T2PID" /tmp/events)" = 2 ] || fail "expected 2 RSCNs for $T2PID"
grep -q "^$H1 LINKDOWN" /tmp/events || fail "no LINKDOWN event"
grep -q "^$H1 LINKUP" /tmp/events || fail "no LINKUP event"

step "teardown"
teardown_all
splat_check
echo
echo "PASS"
