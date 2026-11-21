#!/bin/bash
# tcm_fcsim stage-1 smoke test (run inside the virtme-ng guest as root).
#
#   target port 21:00:00:00:00:00:00:01 (ramdisk rd0 as LUN 0)
#   initiator   10:00:00:00:c9:00:00:01
#
# Checks: fc_host/rport/fc_transport sysfs, demo-mode login without LUNs,
# ACL -> LUN visible, data integrity, link down/up, clean teardown + rmmod,
# and no KASAN/lockdep/WARN splats in dmesg.
set -euo pipefail

TOP=$(cd "$(dirname "$0")/.." && pwd)
. "$TOP/tests/guest-setup.sh"

TWWPN=21:00:00:00:00:00:00:01
IWWPN=10:00:00:00:c9:00:00:01
LIO=/sys/kernel/config/target
TPG=$LIO/fcsim/$TWWPN/tpgt_1
HOSTS=/sys/kernel/config/fcsim/hosts

step() { echo; echo "=== $*"; }
fail() { echo "FAIL: $*" >&2; dmesg | tail -40 >&2; exit 1; }

wait_for() {	# wait_for <seconds> <command...>
	local t=$(( $1 * 10 )); shift
	while ! "$@" >/dev/null 2>&1; do
		t=$((t - 1)); [ $t -gt 0 ] || return 1
		sleep 0.1
	done
}

fcsim_disk() {	# print /dev/sdX of the fcsim LUN 0, if any
	local d
	for d in /sys/class/fc_transport/target*/device/*/block/*; do
		[ -e "$d" ] && blockdev --getsz "/dev/$(basename "$d")" >/dev/null 2>&1 &&
			{ echo "/dev/$(basename "$d")"; return 0; }
	done
	return 1
}

step "load modules"
modprobe target_core_mod	# includes the ramdisk (rd_mcp) backstore
load_fcsim
cat /sys/kernel/config/fcsim/version

step "target side: ramdisk LUN on $TWWPN"
targetcli /backstores/ramdisk create rd0 64M >/dev/null
RD=$(dirname "$(ls -d $LIO/core/rd_mcp_*/rd0)")/rd0
mkdir -p "$TPG"
mkdir "$TPG/lun/lun_0"
ln -s "$RD" "$TPG/lun/lun_0/rd0"
echo 1 > "$TPG/enable"
grep . "$TPG"/{node_name,port_id} "$TPG"/attrib/*

step "initiator side: create host $IWWPN"
mkdir "$HOSTS/$IWWPN"
HOST=$(cat "$HOSTS/$IWWPN/scsi_host")
echo "scsi host: $HOST  targets: $(cat "$HOSTS/$IWWPN/targets")  sessions: $(cat "$TPG/sessions")"
for a in port_name node_name port_id port_type port_state speed fabric_name symbolic_name; do
	printf '  fc_host/%-14s %s\n' "$a" "$(cat /sys/class/fc_host/$HOST/$a)"
done
RPORT=$(ls /sys/class/fc_remote_ports | head -1)
[ -n "$RPORT" ] || fail "no rport"
for a in port_name node_name port_id roles port_state dev_loss_tmo; do
	printf '  %s/%-12s %s\n' "$RPORT" "$a" "$(cat /sys/class/fc_remote_ports/$RPORT/$a)"
done
[ "$(cat /sys/class/fc_remote_ports/$RPORT/port_name)" = "0x2100000000000001" ] \
	|| fail "rport port_name mismatch"
# Without any visible LUN the SCSI layer reaps the scsi_target, so there is
# no fc_transport/target* yet (same as a real array with no LUN masked in).
sleep 1
lsscsi
if fcsim_disk; then fail "LUN visible without ACL (demo_mode_login_only should hide it)"; fi
echo "OK: logged in, no LUN without ACL"

step "add ACL for $IWWPN -> LUN 0, rescan via issue_lip"
mkdir -p "$TPG/acls/$IWWPN/lun_0"
ln -s "$TPG/lun/lun_0" "$TPG/acls/$IWWPN/lun_0/map"
echo 1 > /sys/class/fc_host/$HOST/issue_lip
wait_for 5 fcsim_disk || fail "LUN did not appear after ACL + issue_lip"
DISK=$(fcsim_disk)
lsscsi
echo "fcsim disk: $DISK"
STGT=$(ls /sys/class/fc_transport | head -1)
for a in port_name node_name port_id; do
	printf '  fc_transport/%s/%-9s %s\n' "$STGT" "$a" "$(cat /sys/class/fc_transport/$STGT/$a)"
done

step "data integrity on $DISK"
dd if=/dev/urandom of=/tmp/pattern bs=1M count=16 status=none
dd if=/tmp/pattern of="$DISK" bs=1M oflag=direct status=none
dd if="$DISK" of=/tmp/readback bs=1M count=16 iflag=direct status=none
cmp /tmp/pattern /tmp/readback || fail "data mismatch"
echo "OK: 16MiB written and read back"

step "link down / up"
echo down > "$HOSTS/$IWWPN/link"
echo "fc_host port_state: $(cat /sys/class/fc_host/$HOST/port_state)"
echo "rport port_state:   $(cat /sys/class/fc_remote_ports/$RPORT/port_state)"
[ "$(cat /sys/class/fc_remote_ports/$RPORT/port_state)" = "Blocked" ] || fail "rport not blocked"
# I/O issued while the link is down must wait and then complete after link up.
( dd if="$DISK" of=/dev/null bs=4k count=1 iflag=direct status=none && echo "  blocked read completed" ) &
DDPID=$!
sleep 1
echo up > "$HOSTS/$IWWPN/link"
wait $DDPID || fail "read during link down failed"
echo "rport port_state:   $(cat /sys/class/fc_remote_ports/$RPORT/port_state)"
[ "$(cat /sys/class/fc_remote_ports/$RPORT/port_state)" = "Online" ] || fail "rport not online"
dd if="$DISK" of=/tmp/readback bs=1M count=16 iflag=direct status=none
cmp /tmp/pattern /tmp/readback || fail "data mismatch after link up"
echo "OK: same rport came back, data intact"

step "remove ACL (session closed and re-logged in with dynamic ACL)"
rm "$TPG/acls/$IWWPN/lun_0/map"
rmdir "$TPG/acls/$IWWPN/lun_0"
rmdir "$TPG/acls/$IWWPN"
wait_for 5 grep -q "$TWWPN" "$HOSTS/$IWWPN/targets" || fail "not re-logged in"
echo "targets: $(cat "$HOSTS/$IWWPN/targets")"

step "teardown"
rmdir "$HOSTS/$IWWPN"
echo 0 > "$TPG/enable"
rm "$TPG/lun/lun_0/rd0"
rmdir "$TPG/lun/lun_0"
rmdir "$TPG"
rmdir "$LIO/fcsim/$TWWPN"
rmdir "$LIO/fcsim"
targetcli /backstores/ramdisk delete rd0 >/dev/null
rmmod tcm_fcsim
echo "OK: module unloaded"

step "dmesg check"
dmesg | grep tcm_fcsim | tail -20
if dmesg | grep -E 'BUG:|WARNING:|KASAN|possible circular|INFO: task .* blocked|Call Trace' ; then
	fail "kernel splat detected"
fi
echo
echo "PASS"
