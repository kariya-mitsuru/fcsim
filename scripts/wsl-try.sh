#!/bin/bash
# Try tcm_fcsim on the real WSL2 kernel, step by step, with confirmations.
#
#   sudo scripts/wsl-try.sh [--yes]
#
# The WSL2 kernel is shared by every WSL distro (and Docker): a kernel bug
# can stop all of them ("wsl --shutdown" from Windows recovers).  Run the
# virtme-ng tests first (make test-wsl).
#
#   1. load and unload the module only
#   2. a ramdisk LUN behind one target port, one initiator port, data written
#      and read back, link down / up
#
# Everything this script creates is removed again, also on failure; other
# LIO configuration is left alone.  The disk used for I/O is found through
# the fcsim HBA in sysfs and checked to be the script's own ramdisk.
set -euo pipefail

TOP=$(cd "$(dirname "$0")/.." && pwd)
REL=$(uname -r)
KO="$TOP/build/$REL/tcm_fcsim.ko"
TCLI="$TOP/tools/fcsim-targetcli"
CTL="$TOP/tools/fcsimctl"
RD=fcsim_try_rd			# backstore name (also the LUN's INQUIRY product)
T=21:00:00:00:00:00:00:f1
I=10:00:00:00:c9:00:00:f1
YES=0
[ "${1:-}" = "--yes" ] && YES=1

say() { printf '\n== %s\n' "$*"; }
die() { printf 'wsl-try: %s\n' "$*" >&2; exit 1; }
confirm() {
	[ $YES = 1 ] && return 0
	local a
	read -r -p "$* [y/N] " a
	[ "$a" = y ] || [ "$a" = Y ]
}
naa() { echo "naa.${1//:/}"; }

# ------------------------------------------------------------------ checks

[ "$(id -u)" = 0 ] || die "run as root: sudo $0"
case "$REL" in
*microsoft*WSL2*) ;;
*) die "not a WSL2 kernel ($REL); this script is for the real WSL2 kernel" ;;
esac
[ -e "$KO" ] || die "no module for $REL: run scripts/build-wsl-kernel.sh (if the WSL2 kernel changed) and make wsl"
[ "$(modinfo -F vermagic "$KO" | awk '{print $1}')" = "$REL" ] || die "$KO was built for another kernel"
[ -d /sys/module/tcm_fcsim ] && die "tcm_fcsim is already loaded"
[ -e /sys/kernel/config/target/fcsim ] && die "/sys/kernel/config/target/fcsim exists already"
# The cleanup deletes the ramdisk by name: never let that be someone else's.
for d in /sys/kernel/config/target/core/rd_mcp_*/"$RD"; do
	[ -e "$d" ] && die "a ramdisk backstore named $RD exists already ($d)"
done
modprobe -n target_core_mod || die "target_core_mod is not available"

cat <<EOF
This loads tcm_fcsim into the running WSL2 kernel ($REL).
The kernel is shared by every WSL distro and by Docker: if something goes
wrong, all of them may stop.  Save your work first; "wsl --shutdown" from
Windows recovers.  Watching "sudo dmesg -w" in another terminal helps.
EOF
confirm "Continue?" || exit 0

# ------------------------------------------------------------------ cleanup

LOADED=0 CREATED=0 RD_CREATED=0 AUTOSAVE=
# Only look at what happens from here on.  Counting lines would not do: once
# the ring buffer is full, the line count hardly grows.
MARK="wsl-try: start $$.$(date +%s%N)"
echo "$MARK" > /dev/kmsg
cleanup() {
	local rc=$?
	trap - EXIT
	set +e
	if [ $CREATED = 1 ]; then
		say "cleanup"
		[ -d "/sys/kernel/config/fcsim/hosts/$I" ] && "$CTL" host delete "$I"
		[ -d "/sys/kernel/config/target/fcsim/$T" ] && "$TCLI" /fcsim delete "$(naa $T)" >/dev/null
		[ $RD_CREATED = 1 ] && "$TCLI" /backstores/ramdisk delete "$RD" >/dev/null
		rmdir /sys/kernel/config/target/fcsim 2>/dev/null
	fi
	if [ -n "$AUTOSAVE" ]; then
		"$TCLI" set global auto_save_on_exit="$AUTOSAVE" >/dev/null
	fi
	if [ $LOADED = 1 ]; then
		rmmod tcm_fcsim && echo "tcm_fcsim unloaded"
	fi
	echo
	dmesg | awk -v m="$MARK" 'seen || index($0, m) { seen = 1; print }' > /tmp/wsl-try.dmesg
	if [ ! -s /tmp/wsl-try.dmesg ]; then
		echo "wsl-try: the start marker is gone from the kernel log (ring buffer" \
			"wrapped); look for warnings yourself (journalctl -k)" >&2
		rc=1
	fi
	grep -E 'tcm_fcsim|BUG:|WARNING:|Call Trace' /tmp/wsl-try.dmesg | tail -15
	if grep -E 'BUG:|WARNING:|Call Trace' /tmp/wsl-try.dmesg >/dev/null; then
		echo "wsl-try: kernel warnings in dmesg, see above" >&2
		rc=1
	fi
	[ $rc = 0 ] && echo "wsl-try: OK" || echo "wsl-try: FAILED ($rc)" >&2
	exit $rc
}
trap cleanup EXIT

# ------------------------------------------------------------------ step 1

say "step 1: load and unload"
modprobe target_core_mod
insmod "$KO"
LOADED=1
echo "loaded: $(cat /sys/kernel/config/fcsim/version)"
rmmod tcm_fcsim
LOADED=0
echo "unloaded"

confirm "Step 2: a 64 MiB ramdisk LUN, I/O to it, link down / up. Continue?" || exit 0

# ------------------------------------------------------------------ step 2

say "step 2: target port $T, initiator port $I"
insmod "$KO"
LOADED=1
# targetcli would save the configuration (with fcsim in it) when it exits.
AUTOSAVE=$("$TCLI" get global auto_save_on_exit | sed -n 's/^auto_save_on_exit=//p')
"$TCLI" set global auto_save_on_exit=false >/dev/null
CREATED=1
"$TCLI" /backstores/ramdisk create "$RD" 64M >/dev/null
RD_CREATED=1			# only now is it ours to delete
"$TCLI" /fcsim create "$(naa $T)" >/dev/null
"$TCLI" "/fcsim/$(naa $T)/luns" create "/backstores/ramdisk/$RD" >/dev/null
"$TCLI" "/fcsim/$(naa $T)/acls" create "$(naa $I)" >/dev/null
"$CTL" host create "$I"
HOST=$(cat "/sys/kernel/config/fcsim/hosts/$I/scsi_host")

# The disk: under the fcsim HBA, LIO-ORG, product = our backstore name.
DISK=
for _ in $(seq 50); do
	for b in /sys/class/scsi_host/$HOST/device/rport-*/target*/*:*:*:*/block/*; do
		[ -e "$b" ] || continue
		dev=$(dirname "$(dirname "$b")")
		[ "$(tr -d ' ' < "$dev/vendor")" = LIO-ORG ] || continue
		[ "$(tr -d ' ' < "$dev/model")" = "$RD" ] || continue
		blockdev --getsz "/dev/$(basename "$b")" >/dev/null 2>&1 || continue
		DISK=/dev/$(basename "$b")
	done
	[ -n "$DISK" ] && break
	sleep 0.1
done
[ -n "$DISK" ] || die "the LUN did not appear"
"$CTL" status

echo
echo "I/O device: $DISK ($HOST, LIO-ORG $RD, $(($(blockdev --getsz $DISK) / 2048)) MiB)"
confirm "Write 16 MiB of random data to $DISK and read it back?" || exit 0

say "data"
PAT=$(mktemp)
RDBK=$(mktemp)
head -c $((16 << 20)) /dev/urandom > "$PAT"
dd if="$PAT" of="$DISK" bs=1M oflag=direct status=none
dd if="$DISK" of="$RDBK" bs=1M count=16 iflag=direct status=none
cmp "$PAT" "$RDBK" || die "data mismatch"
echo "16 MiB written and read back: identical"

say "link down / up"
"$CTL" link "$I" down
sleep 1
"$CTL" link "$I" up
for _ in $(seq 50); do
	[ "$(cat /sys/class/fc_host/$HOST/port_state)" = Online ] &&
		blockdev --getsz "$DISK" >/dev/null 2>&1 && break
	sleep 0.1
done
dd if="$DISK" of="$RDBK" bs=1M count=16 iflag=direct status=none
cmp "$PAT" "$RDBK" || die "data mismatch after link up"
echo "read back after link down / up: identical"
"$CTL" stats "$I" | grep -E '^(fcp_(input|output)_megabytes|link_failure_count) '
rm -f "$PAT" "$RDBK"
