# Common helpers for tcm_fcsim guest tests (source after setting TOP).
# shellcheck shell=bash

. "$TOP/tests/guest-setup.sh"

LIO=/sys/kernel/config/target
HOSTS=/sys/kernel/config/fcsim/hosts
PARAM=/sys/module/tcm_fcsim/parameters
TCLI="$TOP/tools/fcsim-targetcli"

step() { echo; echo "=== $*"; }
fail() { echo "FAIL: $*" >&2; dmesg | tail -60 >&2; exit 1; }

wait_for() {	# wait_for <seconds> <command...>
	local t=$(( $1 * 10 )); shift
	while ! "$@" >/dev/null 2>&1; do
		t=$((t - 1)); [ $t -gt 0 ] || return 1
		sleep 0.1
	done
}

# hexval <file>: a hex statistic as a decimal number.  A missing file is an
# error: printf would turn the empty string into 0 and an "= 0" check pass.
hexval() {
	[ -r "$1" ] || fail "no such statistic: $1"
	printf '%d' "$(cat "$1")"
}

# start_events <seconds> <file>: record FC netlink events into <file> in the
# background (pid in EV); returns once the listener is bound.
start_events() {
	python3 "$TOP/tests/fc-events.py" "$1" > "$2" &
	EV=$!
	wait_for 10 grep -q '^listening' "$2" || fail "fc-events.py did not start"
}

splat_check() {
	if dmesg | grep -E 'BUG:|WARNING:|KASAN|possible circular|INFO: task .* blocked|Call Trace'; then
		fail "kernel splat detected"
	fi
}

# within <seconds> <command...>: the command must finish in time.
within() {
	local s=$1; shift
	local t0 t1
	t0=$(date +%s%N)
	timeout "$s" "$@" || fail "'$*' did not finish within ${s}s"
	t1=$(date +%s%N)
	echo "  ok ($(( (t1 - t0) / 1000000 )) ms): $*"
}

wwpn_naa() { echo "naa.${1//:/}"; }	# 21:00:...:01 -> naa.2100...01

# Target port with LUN 0 = <backstore path> (e.g. /backstores/ramdisk/rd0)
# and ACLs for the given initiators.
make_tport() {	# make_tport <twwpn> <backstore> <iwwpn>...
	local t; t=$(wwpn_naa "$1")
	local bs=$2; shift 2
	$TCLI /fcsim create "$t" >/dev/null
	$TCLI "/fcsim/$t/luns" create "$bs" >/dev/null
	local i
	for i in "$@"; do
		$TCLI "/fcsim/$t/acls" create "$(wwpn_naa "$i")" >/dev/null
	done
}

host_of() { cat "$HOSTS/$1/scsi_host"; }	# host_of <iwwpn> -> hostN

# disk_of <hostN> <model>: sdX of the LUN whose INQUIRY product is <model>
# (LIO reports the backstore name).
disk_of() {
	local d
	for d in /sys/class/scsi_host/"$1"/device/rport-*/target*/*:*:*:*/block/*; do
		[ -e "$d" ] || continue
		if [ "$(tr -d ' ' < "$d/../../model")" = "$2" ]; then
			# The sysfs entry appears a little before the disk can be
			# opened (seen on the WSL2 kernel).
			blockdev --getsz "/dev/$(basename "$d")" >/dev/null 2>&1 || return 1
			basename "$d"
			return 0
		fi
	done
	return 1
}

# Tear everything down and unload; fails on leftovers.
teardown_all() {
	local h
	for h in "$HOSTS"/*; do
		[ -d "$h" ] || continue
		rmdir "$h"/faults/* 2>/dev/null || true
		rmdir "$h"
	done
	"$TOP/tools/fcsim-targetctl" clear
	rmdir "$LIO/fcsim" 2>/dev/null || true
	rmmod tcm_fcsim
}
