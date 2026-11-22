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

# fcsim_disk: /dev/sdX of the first fcsim LUN that can be opened.
fcsim_disk() {
	local d
	for d in /sys/class/fc_transport/target*/device/*/block/*; do
		[ -e "$d" ] && blockdev --getsz "/dev/$(basename "$d")" >/dev/null 2>&1 &&
			{ echo "/dev/$(basename "$d")"; return 0; }
	done
	return 1
}

# wait_paths <n> [seconds]: wait until there are <n> sd devices behind FC
# targets (paths to fcsim LUNs).
npaths() { ls -d /sys/class/fc_transport/target*/device/*/block/* 2>/dev/null | wc -l; }
wait_paths() {
	local n=$1 t=$(( ${2:-10} * 10 ))
	while [ "$(npaths)" != "$n" ]; do
		t=$((t - 1)); [ $t -gt 0 ] || return 1
		sleep 0.1
	done
}

rport_of() {	# rport_of <hostN> <target wwpn> -> rport-X:Y-Z
	local rp
	for rp in /sys/class/scsi_host/$1/device/rport-*; do
		[ "$(cat /sys/class/fc_remote_ports/$(basename $rp)/port_name)" = "0x${2//:/}" ] &&
			{ basename $rp; return 0; }
	done
	return 1
}

rport_of_disk() {	# rport_of_disk <sdX> -> rport-X:Y-Z
	ls -d /sys/class/scsi_host/*/device/rport-*/target*/*/block/"$1" |
		sed 's|.*/\(rport-[^/]*\)/.*|\1|'
}

# ---------------------------------------------------------------- multipath

# write_multipath_conf <extra defaults> <device settings>: multipath only
# the LIO devices, with the given settings; no stale bindings.
write_multipath_conf() {
	mkdir -p /etc/multipath
	rm -f /etc/multipath/bindings /etc/multipath/wwids
	cat > /etc/multipath.conf <<-END
	defaults {
		polling_interval	1
		user_friendly_names	yes
		find_multipaths		off
	$1
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
	$2
		}
	}
	END
}

# start_multipathd <verbosity> <active paths>: multipathd in the foreground
# (log /tmp/multipathd.log), stopped by stop_multipathd or on exit.  Waits
# for its map (MAP) to have <active paths>.
MPD_PID=
stop_multipathd() {
	[ -n "$MPD_PID" ] || return 0
	multipathd shutdown >/dev/null 2>&1 || true
	wait "$MPD_PID" 2>/dev/null || true
	MPD_PID=
}
start_multipathd() {
	trap stop_multipathd EXIT
	multipathd -d -s -v"$1" > /tmp/multipathd.log 2>&1 &
	MPD_PID=$!
	wait_for 20 sh -c "multipathd show maps raw format '%n' 2>/dev/null | grep -q ." \
		|| { tail -30 /tmp/multipathd.log; fail "multipathd built no map"; }
	MAP=$(multipathd show maps raw format '%n' | head -1)
	wait_mp_active "$2" 20 || fail "not all paths active"
}
wait_mp_active() {	# wait_mp_active <n> <seconds>
	wait_for "$2" sh -c "[ \$(multipathd show paths raw format '%t' | grep -c '^active') = $1 ]"
}

# writer_start <device> <size MiB>: rewrite /tmp/pat onto <device> chunk by
# chunk in the background until writer_stop, which fails the test if any
# write failed.
writer_start() {
	rm -f /tmp/stop /tmp/writer.err
	(
		i=0
		while [ ! -e /tmp/stop ]; do
			dd if=/tmp/pat of="$1" bs=1M count=1 skip=$i seek=$i \
				oflag=direct status=none || { echo "write $i failed" > /tmp/writer.err; exit 1; }
			i=$(( (i + 1) % $2 ))
		done
	) &
	WRITER=$!
}
writer_stop() {
	touch /tmp/stop
	wait "$WRITER" || fail "writer: $(cat /tmp/writer.err 2>/dev/null)"
}

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
