#!/bin/bash
# Build the development kernel for virtme-ng.
# Usage: scripts/build-kernel.sh [KERNEL_DIR]
set -euo pipefail

KDIR=${1:-${KDIR:-$HOME/build/linux-6.18}}

CONFIG_ITEMS=(
	# SCSI initiator side + FC transport class
	CONFIG_SCSI=y
	CONFIG_BLK_DEV_SD=y
	CONFIG_CHR_DEV_SG=y
	CONFIG_SCSI_FC_ATTRS=y
	CONFIG_SCSI_DEBUG=m

	# LIO target core and backstores
	CONFIG_CONFIGFS_FS=y
	CONFIG_TARGET_CORE=m
	CONFIG_TCM_IBLOCK=m
	CONFIG_TCM_FILEIO=m
	CONFIG_TCM_PSCSI=m
	CONFIG_TCM_USER2=m
	CONFIG_LOOPBACK_TARGET=m
	CONFIG_ISCSI_TARGET=m   # targetcli 'ls' always probes the iSCSI fabric
	CONFIG_BLK_DEV_NULL_BLK=m

	# NVMe over FC loopback (reference implementation: fcloop)
	CONFIG_NVME_CORE=m
	CONFIG_NVME_FABRICS=m
	CONFIG_NVME_FC=m
	CONFIG_NVME_TARGET=m
	CONFIG_NVME_TARGET_FC=m
	CONFIG_NVME_TARGET_FCLOOP=m

	# Multipath, as on a RHEL FC host: ALUA device handler and the
	# service-time / queue-length path selectors
	CONFIG_MD=y
	CONFIG_BLK_DEV_DM=m
	CONFIG_DM_MULTIPATH=m
	CONFIG_DM_MULTIPATH_ST=m
	CONFIG_DM_MULTIPATH_QL=m
	CONFIG_SCSI_DH=y
	CONFIG_SCSI_DH_ALUA=y

	# Debugging aids
	CONFIG_DEBUG_INFO_DWARF5=y
	CONFIG_KASAN=y
	CONFIG_KASAN_GENERIC=y
	CONFIG_KASAN_INLINE=y
	CONFIG_PROVE_LOCKING=y
	CONFIG_DEBUG_ATOMIC_SLEEP=y
	CONFIG_DEBUG_LIST=y
	# Leaks: tests/kmemleak.sh scans after every test (no background scans)
	CONFIG_DEBUG_KMEMLEAK=y
	CONFIG_DEBUG_KMEMLEAK_AUTO_SCAN=n
	CONFIG_DEBUG_KMEMLEAK_MEM_POOL_SIZE=16000
	CONFIG_UBSAN=y
	CONFIG_UBSAN_BOUNDS=y
	CONFIG_UBSAN_SHIFT=y
	# Timers and work items freed or re-initialized while still active (the
	# exchanges come from a SLAB_TYPESAFE_BY_RCU cache)
	CONFIG_DEBUG_OBJECTS=y
	CONFIG_DEBUG_OBJECTS_FREE=y
	CONFIG_DEBUG_OBJECTS_TIMERS=y
	CONFIG_DEBUG_OBJECTS_WORK=y
	CONFIG_DEBUG_OBJECTS_RCU_HEAD=y
	CONFIG_DYNAMIC_DEBUG=y
	CONFIG_FTRACE=y
	CONFIG_FUNCTION_TRACER=y
	CONFIG_KALLSYMS_ALL=y
)

args=()
for item in "${CONFIG_ITEMS[@]}"; do
	args+=(--configitem "$item")
done

cd "$KDIR"
# 'vng --build' leaves an existing .config untouched (it ignores --configitem then),
# so regenerate .config from the virtme defconfig + our items first, then build.
vng --kconfig "${args[@]}"
exec vng --build
