#!/bin/bash
# Smoke test (run inside the virtme-ng guest):
# create a LIO ramdisk LUN exported through tcm_loop and check it appears as a SCSI disk.
set -euxo pipefail

. "$(dirname "$0")/guest-setup.sh"

WWN=naa.5001405000000001

targetcli /backstores/ramdisk create rd0 64M
targetcli /loopback create $WWN
targetcli /loopback/$WWN/luns create /backstores/ramdisk/rd0
udevadm settle 2>/dev/null || sleep 1

targetcli ls
lsscsi
for h in /sys/class/scsi_host/host*; do
	echo "$h: $(cat "$h/proc_name")"
done
ls /sys/class/fc_host /sys/class/fc_remote_ports
