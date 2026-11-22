#!/bin/bash
# tcm_fcsim: FPINs from the fabric (run inside the guest as root).
#
#   1. Delivery and accounting: who receives which FPIN (zoning aware), the
#      FC transport's fpin_* statistics, the FC netlink event.
#   2. multipathd with "marginal_pathgroups fpin": a Link Integrity FPIN
#      about a target port makes its paths marginal (rport Marginal, own
#      path group, no I/O while others are usable); LINKUP clears it.
set -euo pipefail

TOP=$(cd "$(dirname "$0")/.." && pwd)
. "$TOP/tests/lib.sh"

CTL="$TOP/tools/fcsimctl"
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

rport_of() {	# rport_of <hostN> <target wwpn> -> rport-X:Y-Z
	local rp
	for rp in /sys/class/scsi_host/$1/device/rport-*; do
		[ "$(cat /sys/class/fc_remote_ports/$(basename $rp)/port_name)" = "0x${2//:/}" ] &&
			{ basename $rp; return 0; }
	done
	return 1
}
rstat() { hexval /sys/class/fc_remote_ports/$(rport_of $1 $2)/statistics/$3; }	# rstat <host> <target> <stat>
hstat() { hexval /sys/class/fc_host/$1/statistics/$2; }

step "setup: one ramdisk behind T1 and T2, initiators I1 and I2"
modprobe dm_multipath
modprobe dm_service_time
load_fcsim
$TCLI /backstores/ramdisk create shared ${SIZE_MB}M >/dev/null
make_tport $T1 /backstores/ramdisk/shared $I1 $I2
make_tport $T2 /backstores/ramdisk/shared $I1 $I2
$CTL host create $I1
$CTL host create $I2
H1=$(host_of $I1); H2=$(host_of $I2)
wait_for 10 sh -c "[ \$(ls -d /sys/class/fc_transport/target*/device/*/block/* 2>/dev/null | wc -l) = 4 ]" \
	|| fail "expected 4 paths"
udevadm settle

# ---------------------------------------------------------------------------
step "1. LI about T1: both initiators get it, the T1 rports count it"
start_events 3 /tmp/ev
$CTL fpin li $T1 loss_of_sync count=5
wait $EV
grep LINK_FPIN /tmp/ev | sed 's/^/  /'
[ "$(grep -c LINK_FPIN /tmp/ev)" = 2 ] || fail "expected 2 FPIN events"
for h in $H1 $H2; do
	[ "$(rstat $h $T1 fpin_li)" = 1 ] && [ "$(rstat $h $T1 fpin_li_loss_of_sync_count)" = 1 ] \
		|| fail "$h: T1 rport fpin_li"
	[ "$(rstat $h $T2 fpin_li)" = 0 ] || fail "$h: T2 rport counted an LI about T1"
done
echo "  rport statistics ok"

step "1. zoning limits the recipients"
$CTL zone create z1 $I1 $T1
$CTL zone create z2 $I1 $I2 $T2
$CTL zone mode on
$CTL zone commit
$CTL fpin li $T1
[ "$(rstat $H1 $T1 fpin_li)" = 2 ] || fail "I1 did not get the second LI"
dmesg | grep "FPIN li about $T1" | tail -1 | sed 's/^/  /'
dmesg | grep "FPIN li about $T1" | tail -1 | grep -q "sent to 1 port" || fail "LI about T1 reached I2 outside the zone"
$CTL zone mode off
$CTL zone commit
wait_for 10 sh -c "[ \$(ls -d /sys/class/fc_transport/target*/device/*/block/* 2>/dev/null | wc -l) = 4 ]" \
	|| fail "paths not back after zoning off"

step "1. other FPINs"
$CTL fpin cn $I1 credit_stall severity=error
[ "$(hstat $H1 fpin_cn)" = 1 ] && [ "$(hstat $H1 fpin_cn_credit_stall)" = 1 ] || fail "cn not counted on $H1"
[ "$(hstat $H2 fpin_cn)" = 0 ] || fail "cn about I1 reached $H2"
$CTL fpin li $I2 invalid_crc
[ "$(hstat $H2 fpin_li)" = 1 ] && [ "$(hstat $H2 fpin_li_invalid_crc_count)" = 1 ] || fail "LI about I2's own link"
$CTL fpin dn $T2 unable_to_route
[ "$(rstat $H1 $T2 fpin_dn)" = 1 ] && [ "$(rstat $H1 $T2 fpin_dn_unable_to_route)" = 1 ] || fail "dn"
$CTL fpin pn $T2 oversubscription
[ "$(rstat $H1 $T2 fpin_cn)" = 1 ] && [ "$(rstat $H1 $T2 fpin_cn_oversubscription)" = 1 ] || fail "pn"
echo "  cn / li (own link) / dn / pn ok"

step "1. invalid requests"
F=/sys/kernel/config/fcsim/fpin
for bad in "xx $T1" "li 12:34" "li 21:00:00:00:00:00:00:99" "li $T1 bogus" "li $T1 period=5" "cn $T1"; do
	if echo "$bad" > $F 2>/dev/null; then fail "accepted: $bad"; fi
done
echo "  rejected as expected"
splat_check

# ---------------------------------------------------------------------------
step "2. multipathd with marginal_pathgroups fpin"
mkdir -p /etc/multipath
rm -f /etc/multipath/bindings /etc/multipath/wwids
cat > /etc/multipath.conf <<'EOF'
defaults {
	polling_interval	1
	user_friendly_names	yes
	find_multipaths		off
	marginal_pathgroups	fpin
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
		path_grouping_policy	multibus
		hardware_handler	"0"
		prio			const
		path_selector		"round-robin 0"
		path_checker		tur
		failback		immediate
		no_path_retry		8
	}
}
EOF
multipathd -d -s -v3 > /tmp/multipathd.log 2>&1 &
# keep multipathd's log next to the test output for debugging
trap 'cp /tmp/multipathd.log "$TOP/.test-out/fpin-multipathd.log" 2>/dev/null; cleanup' EXIT
MPD_PID=$!
wait_for 20 sh -c "multipathd show maps raw format '%n' 2>/dev/null | grep -q ." \
	|| { tail -30 /tmp/multipathd.log; fail "multipathd built no map"; }
MAP=$(multipathd show maps raw format '%n' | head -1)
wait_for 20 sh -c "[ \$(multipathd show paths raw format '%t' | grep -c '^active') = 4 ]" \
	|| fail "not all paths active"
multipath -ll "$MAP" | sed 's/^/  /'

# the sd devices behind T1 / T2
T1DEVS=""; T2DEVS=""
for h in $H1 $H2; do
	for t in T1 T2; do
		eval w=\$$t
		d=$(ls /sys/class/scsi_host/$h/device/$(rport_of $h $w)/target*/*/block/)
		eval ${t}DEVS=\"\$${t}DEVS $d\"
	done
done
echo "  via T1:$T1DEVS   via T2:$T2DEVS"
ios() { local n=0 d; for d in "$@"; do n=$((n + $(awk '{print $1 + $5}' /sys/block/$d/stat))); done; echo $n; }

step "2. LI about T1: its paths become marginal"
$CTL fpin li $T1 link_failure
for h in $H1 $H2; do
	wait_for 10 sh -c "[ \$(cat /sys/class/fc_remote_ports/$(rport_of $h $T1)/port_state) = Marginal ]" \
		|| { grep -i -E "fpin|marginal" /tmp/multipathd.log | tail; fail "$h: T1 rport not Marginal"; }
done
grep -iE "marginal" /tmp/multipathd.log | sed 's/^/  /' | tail -4
wait_for 10 sh -c "[ \$(multipath -ll $MAP | grep -c 'policy=') = 2 ]" || fail "no separate marginal path group"
multipath -ll "$MAP" | sed 's/^/  /'
for rp in /sys/class/fc_remote_ports/rport-*; do
	echo "  $(basename $rp) $(cat $rp/port_name) $(cat $rp/port_state)"
done

step "2. I/O avoids the marginal paths while others are usable"
head -c $((SIZE_MB << 20)) /dev/urandom > /tmp/pat
t1_before=$(ios $T1DEVS); t2_before=$(ios $T2DEVS)
dd if=/tmp/pat of=/dev/mapper/$MAP bs=1M oflag=direct status=none
dd if=/dev/mapper/$MAP of=/tmp/pat.rd bs=1M iflag=direct status=none
cmp /tmp/pat /tmp/pat.rd || fail "data mismatch"
t1=$(( $(ios $T1DEVS) - t1_before )); t2=$(( $(ios $T2DEVS) - t2_before ))
echo "  I/Os via T1 (marginal): $t1, via T2: $t2"
[ "$t1" = 0 ] && [ "$t2" -gt 0 ] || fail "I/O went to marginal paths"

step "2. LINKUP clears the marginal state"
for i in $I1 $I2; do $CTL link $i down; $CTL link $i up; done
for h in $H1 $H2; do
	wait_for 20 sh -c "[ \$(cat /sys/class/fc_remote_ports/$(rport_of $h $T1)/port_state) = Online ]" \
		|| fail "$h: T1 rport still $(cat /sys/class/fc_remote_ports/$(rport_of $h $T1)/port_state)"
done
wait_for 30 sh -c "[ \$(multipath -ll $MAP | grep -c 'policy=') = 1 ] && [ \$(multipathd show paths raw format '%t' | grep -c '^active') = 4 ]" \
	|| { multipath -ll "$MAP"; fail "paths not back in one group"; }
multipath -ll "$MAP" | sed 's/^/  /'
t1_before=$(ios $T1DEVS)
dd if=/dev/mapper/$MAP of=/dev/null bs=1M iflag=direct status=none
[ $(( $(ios $T1DEVS) - t1_before )) -gt 0 ] || fail "T1 paths unused after clearing"
echo "  T1 paths carry I/O again"
splat_check

step "teardown"
udevadm settle
wait_for 10 multipath -F || fail "multipath -F: map stays in use"
cleanup
$CTL clear
teardown_all
splat_check
echo
echo "PASS"
