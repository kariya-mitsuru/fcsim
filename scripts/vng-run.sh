#!/bin/bash
# Boot the development kernel with virtme-ng.
# The project directory is exported read-write so built modules and logs are shared.
# Usage: scripts/vng-run.sh [-- command ...]
set -euo pipefail

KDIR=${KDIR:-$HOME/build/linux-6.18}
PROJ=$(cd "$(dirname "$0")/.." && pwd)

exec vng --run "$KDIR" \
	--qemu /usr/libexec/qemu-kvm \
	--disable-microvm \
	--qemu-opts="-machine q35" \
	--cpus 4 --memory 4G \
	--rwdir "$PROJ" \
	--cwd "$PROJ" \
	"$@"
