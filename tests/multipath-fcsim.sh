#!/bin/bash
# tcm_fcsim: dm-multipath over 2 initiator ports x 2 target ports (run inside
# the guest as root).  The map is built with dmsetup directly (no multipathd):
# the kernel fails paths on I/O errors and the test reinstates them.
#
# One ramdisk is exported through T1 and T2; I1 and I2 see it through both,
# i.e. 4 paths.  While a writer keeps rewriting a known pattern through the
# multipath device, paths are broken in different ways; the writes must never
# fail and the data must be intact at the end, through every path.
set -euo pipefail

TOP=$(cd "$(dirname "$0")/.." && pwd)
. "$TOP/tests/lib.sh"

T1=21:00:00:00:00:00:00:01
T2=21:00:00:00:00:00:00:02
I1=10:00:00:00:c9:00:00:01
I2=10:00:00:00:c9:00:00:02
MP=mpfc
SIZE_MB=32

step "setup: one ramdisk behind T1 and T2, initiators I1 and I2"
modprobe dm_multipath
modprobe dm_round_robin
load_fcsim tmr_timeout=1
$TCLI /backstores/ramdisk create shared ${SIZE_MB}M >/dev/null
make_tport $T1 /backstores/ramdisk/shared $I1 $I2
make_tport $T2 /backstores/ramdisk/shared $I1 $I2
mkdir "$HOSTS/$I1" "$HOSTS/$I2"
echo up > "$HOSTS/$I1/link"; echo up > "$HOSTS/$I2/link"
H1=$(host_of $I1); H2=$(host_of $I2)

paths() {	# all sd devices of the shared LUN, one per line
	local b
	for b in /sys/class/scsi_host/{$H1,$H2}/device/rport-*/target*/*/block/*; do
		[ -e "$b" ] && echo "${b##*/}"
	done | sort
}
wait_paths 4 || fail "expected 4 paths"
udevadm settle

# path name -> "I<n>->T<n> sdX maj:min"
declare -A PATH_OF
for d in $(paths); do
	rp=$(rport_of_disk $d)
	host=$(ls -d /sys/class/scsi_host/*/device/$rp | sed 's|/sys/class/scsi_host/\([^/]*\)/.*|\1|')
	tp=$(cat /sys/class/fc_remote_ports/$rp/port_name)
	i=$([ "$host" = "$H1" ] && echo I1 || echo I2)
	t=$([ "$tp" = 0x2100000000000001 ] && echo T1 || echo T2)
	PATH_OF[$i$t]=$d
	echo "  $i->$t  /dev/$d  $(cat /sys/block/$d/dev)  wwid=$(cat /sys/block/$d/device/wwid | cut -c1-40)"
	echo 3 > /sys/block/$d/device/timeout
	echo 2 > /sys/block/$d/device/eh_timeout
done
[ "$(for d in $(paths); do cat /sys/block/$d/device/wwid; done | sort -u | wc -l)" = 1 ] \
	|| fail "paths do not share one WWID"
for rp in /sys/class/fc_remote_ports/rport-*; do
	echo 30 > $rp/dev_loss_tmo
	echo 2 > $rp/fast_io_fail_tmo
done

SECTORS=$(blockdev --getsz /dev/${PATH_OF[I1T1]})
table="0 $SECTORS multipath 0 0 1 1 round-robin 0 4 1"
for p in I1T1 I2T1 I1T2 I2T2; do table+=" $(cat /sys/block/${PATH_OF[$p]}/dev) 1"; done
dmsetup create $MP --table "$table"
dmsetup table $MP | sed 's/^/  /'

mp_states() {	# per-path A/F in table order
	dmsetup status $MP | awk '{for (i = 1; i <= NF; i++) if ($i ~ /^[0-9]+:[0-9]+$/) printf "%s ", $(i + 1); print ""}'
}
failed_paths() { mp_states | tr ' ' '\n' | grep -c F || true; }
reinstate_all() {
	local p
	for p in I1T1 I2T1 I1T2 I2T2; do
		dmsetup message $MP 0 reinstate_path "$(cat /sys/block/${PATH_OF[$p]}/dev)"
	done
	echo "  states after reinstate: $(mp_states)"
	[ "$(failed_paths)" = 0 ] || fail "paths not reinstated"
}

head -c $((SIZE_MB << 20)) /dev/urandom > /tmp/pat
dd if=/tmp/pat of=/dev/mapper/$MP bs=1M oflag=direct status=none
echo "  initial states: $(mp_states)"

# While a writer rewrites the pattern through the multipath device (any
# failed write is fatal), break paths and repair them.
with_writer() {	# with_writer <break command> <expected failed paths> <repair command>
	writer_start /dev/mapper/$MP $SIZE_MB
	sleep 1
	eval "$1"
	wait_for 40 sh -c "[ \$(dmsetup status $MP | tr ' ' '\n' | grep -c '^F\$') = $2 ]" \
		|| { touch /tmp/stop; fail "expected $2 failed paths, have: $(mp_states)"; }
	echo "  states with the fault: $(mp_states)"
	sleep 2		# keep writing on the remaining paths
	writer_stop
	eval "$3"
	reinstate_all
	cmp /tmp/pat /dev/mapper/$MP || fail "data mismatch"
	echo "  data intact"
}

step "link down on I1: its 2 paths fail (fast_io_fail_tmo=2), I/O continues"
with_writer "echo down > $HOSTS/$I1/link" 2 \
	"echo up > $HOSTS/$I1/link; wait_for 10 sh -c '[ \$(wc -l < $HOSTS/$I1/targets) = 2 ]'"

step "T2 disabled: the 2 paths through T2 fail, I/O continues"
with_writer "echo 0 > $LIO/fcsim/$T2/tpgt_1/enable" 2 \
	"echo 1 > $LIO/fcsim/$T2/tpgt_1/enable; wait_for 10 sh -c '[ \$(wc -l < $HOSTS/$I1/targets) = 2 ]'"

step "I2->T1 stops responding (drop=cmd): that path fails via SCSI EH"
with_writer "mkdir $HOSTS/$I2/faults/$T1 && echo cmd > $HOSTS/$I2/faults/$T1/drop" 1 \
	"rmdir $HOSTS/$I2/faults/$T1; for p in ${PATH_OF[I2T1]}; do s=/sys/block/\$p/device/state; [ \$(cat \$s) = running ] || echo running > \$s; done"
dmesg | grep -E "host reset|offline" | sed 's/^/  /' | tail -3 || true

step "every path reads the same data"
for p in I1T1 I2T1 I1T2 I2T2; do
	cmp /tmp/pat /dev/${PATH_OF[$p]} || fail "path $p differs"
	echo "  $p ok"
done
splat_check

step "teardown"
dmsetup remove $MP
teardown_all
splat_check
echo
echo "PASS"
