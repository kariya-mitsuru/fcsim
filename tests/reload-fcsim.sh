#!/bin/bash
# tcm_fcsim: load / use / unload, many times over (run inside the guest as
# root).  Each round creates target and initiator ports, a fault rule, a
# zone and an FPIN, does I/O and takes everything down again before rmmod.
# A zone left behind keeps the module in use: rmmod must refuse, and work
# once the zone is gone.  Leaks across the rounds show up in kmemleak
# (tests/kmemleak.sh, on the development kernel) and any splat fails.
set -euo pipefail

TOP=$(cd "$(dirname "$0")/.." && pwd)
. "$TOP/tests/lib.sh"

ROUNDS=${1:-20}
CTL=$TOP/tools/fcsimctl
T1=21:00:00:00:00:00:00:01
I1=10:00:00:00:c9:00:00:01
Z=/sys/kernel/config/fcsim/zones

modprobe target_core_mod
$TCLI /backstores/ramdisk create rd0 16M >/dev/null

step "$ROUNDS rounds of load, use, unload"
for r in $(seq "$ROUNDS"); do
	load_fcsim
	make_tport $T1 /backstores/ramdisk/rd0 $I1
	$CTL host create $I1
	$CTL fault set $I1 $T1 delay_ms=1 count=5
	$CTL zone create z1 $I1 $T1
	$CTL zone mode on
	$CTL zone commit
	H1=$(host_of $I1)
	wait_for 10 disk_of "$H1" rd0 || fail "round $r: LUN missing"
	dd if="/dev/$(disk_of "$H1" rd0)" of=/dev/null bs=64k count=4 iflag=direct status=none ||
		fail "round $r: READ failed"
	$CTL fpin li $T1 >/dev/null
	echo down > "$HOSTS/$I1/link"
	echo up > "$HOSTS/$I1/link"
	# Everything down, the zone last: with it still there rmmod is refused.
	$CTL clear >/dev/null		# hosts, fault rules, zoning off
	mkdir $Z/z_left
	"$TOP/tools/fcsim-targetctl" clear
	$TCLI /backstores/ramdisk create rd0 16M >/dev/null	# targetctl clear took it
	rmdir "$LIO/fcsim"
	if rmmod tcm_fcsim 2>/tmp/rmmod.err; then fail "round $r: rmmod with a zone left succeeded"; fi
	grep -q "in use" /tmp/rmmod.err || fail "round $r: rmmod: $(cat /tmp/rmmod.err)"
	rmdir $Z/z_left
	rmmod tcm_fcsim || fail "round $r: rmmod failed"
	printf '.'
done
echo
echo "  $ROUNDS rounds"
splat_check
$TCLI /backstores/ramdisk delete rd0 >/dev/null
echo
echo "PASS"
