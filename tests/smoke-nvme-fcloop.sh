#!/bin/bash
# Smoke test (run inside the virtme-ng guest):
# NVMe over FC entirely in software using nvme-fcloop + nvmet-fc + nvme-fc.
# Used as a reference for how the kernel models a software-only FC fabric.
set -euxo pipefail

LNN=0x10000000000000a1 LPN=0x20000000000000a1   # host (initiator) local port
TNN=0x10000000000000b1 TPN=0x20000000000000b1   # target port
NQN=nqn.2026-11.test:fcloop-null0

modprobe nvme-fcloop
modprobe nvmet-fc
modprobe nvme-fc
modprobe null_blk nr_devices=1

CTL=/sys/class/fcloop/ctl
echo "wwnn=$LNN,wwpn=$LPN" > $CTL/add_local_port
echo "wwnn=$TNN,wwpn=$TPN" > $CTL/add_target_port
# roles must include FC_PORT_ROLE_NVME_TARGET (0x20) | NVME_DISCOVERY (0x40) = 96,
# otherwise nvme-fc refuses to create a controller (-EBADR).
echo "wwnn=$TNN,wwpn=$TPN,lpwwnn=$LNN,lpwwpn=$LPN,roles=96" > $CTL/add_remote_port

# nvmet: subsystem backed by null_blk, exposed on an FC port
CFG=/sys/kernel/config/nvmet
mkdir $CFG/subsystems/$NQN
echo 1 > $CFG/subsystems/$NQN/attr_allow_any_host
mkdir $CFG/subsystems/$NQN/namespaces/1
echo /dev/nullb0 > $CFG/subsystems/$NQN/namespaces/1/device_path
echo 1 > $CFG/subsystems/$NQN/namespaces/1/enable
mkdir $CFG/ports/1
echo fc > $CFG/ports/1/addr_trtype
echo fc > $CFG/ports/1/addr_adrfam
echo "nn-$TNN:pn-$TPN" > $CFG/ports/1/addr_traddr
ln -s $CFG/subsystems/$NQN $CFG/ports/1/subsystems/$NQN

# connect from the host side (equivalent of 'nvme connect -t fc ...')
echo "transport=fc,traddr=nn-$TNN:pn-$TPN,host_traddr=nn-$LNN:pn-$LPN,nqn=$NQN" > /dev/nvme-fabrics
sleep 1

ls /sys/class/nvme
for c in /sys/class/nvme/nvme*; do
	echo "$c: transport=$(cat "$c/transport") address=$(cat "$c/address")"
done
ls /dev/nvme*n* || true
ls /sys/class/fc_host /sys/class/fc_remote_ports
ls /sys/class/fc 2>/dev/null || true
