#!/bin/bash
# Common guest initialization for virtme-ng (source this, run as root inside the guest).
#
# targetcli queries tcmu-runner over the D-Bus system bus at startup, so a system bus
# must exist even though we do not use user: backstores. AlmaLinux 9 ships dbus-broker,
# whose launcher wants a socket-activated listening fd and a journald socket; virtme-ng
# guests have neither, so provide both.

export HOME=/tmp   # targetcli writes its prefs under $HOME

# The module built for the running kernel: build/<release>/ for other kernels
# (make KVER=<release>, e.g. AlmaLinux 9), src/ for the development kernel.
FCSIM_KO="$TOP/build/$(uname -r)/tcm_fcsim.ko"
[ -e "$FCSIM_KO" ] || FCSIM_KO="$TOP/src/tcm_fcsim.ko"

# load_fcsim [module parameters]: its dependencies may be modules (they are
# built in on the development kernel), and insmod does not resolve them.
load_fcsim() {
	modprobe target_core_mod
	modprobe scsi_transport_fc
	insmod "$FCSIM_KO" "$@"
}

guest_start_dbus() {
	[ -S /run/dbus/system_bus_socket ] && return 0

	mkdir -p /run/dbus /run/systemd/journal
	if [ ! -S /run/systemd/journal/socket ]; then
		python3 -c '
import socket
s = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
s.bind("/run/systemd/journal/socket")
while True:
    s.recv(65536)
' &
	fi

	systemd-socket-activate -l /run/dbus/system_bus_socket \
		dbus-broker-launch --scope system >/tmp/dbus.log 2>&1 &

	for _ in $(seq 50); do
		[ -S /run/dbus/system_bus_socket ] && return 0
		sleep 0.1
	done
	echo "guest-setup: D-Bus system bus did not come up" >&2
	return 1
}

guest_start_dbus
targetcli set global auto_save_on_exit=false >/dev/null
