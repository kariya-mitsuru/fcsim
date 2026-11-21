#!/bin/bash
# Boot the development kernel with virtme-ng, or another kernel image given in
# KIMG (e.g. /lib/modules/<release>/vmlinuz of an installed distro kernel; its
# modules come from /lib/modules/<release>, and virtme-ng needs busybox to
# build an initramfs for it: BUSYBOX or busybox in PATH).
# The project directory is exported read-write so built modules and logs are shared.
# Usage: [KIMG=...] scripts/vng-run.sh [-- command ...]
set -euo pipefail

KDIR=${KDIR:-$HOME/build/linux-6.18}
PROJ=$(cd "$(dirname "$0")/.." && pwd)

if [ -n "${KIMG:-}" ]; then
	run=(--run "$KIMG")
	bb=${BUSYBOX:-$(command -v busybox || true)}
	[ -n "$bb" ] && run+=(--busybox "$bb")
else
	run=(--run "$KDIR")
fi

exec vng "${run[@]}" \
	--qemu /usr/libexec/qemu-kvm \
	--disable-microvm \
	--qemu-opts="-machine q35" \
	--cpus 4 --memory 4G \
	--rwdir "$PROJ" \
	--cwd "$PROJ" \
	"$@"
