#!/bin/bash
# Build the WSL2 kernel tree that tcm_fcsim is built against for WSL2.
#
#   scripts/build-wsl-kernel.sh [<kernel release>]   (default: the running one)
#
# Fetches microsoft/WSL2-Linux-Kernel at the tag of that release into
# ~/build/wsl2-<version>, configures it exactly like the release (the running
# kernel's /proc/config.gz, or the tree's config-wsl for another release) and
# builds it: the module needs Module.symvers (CONFIG_MODVERSIONS), and the
# same kernel boots in virtme-ng for testing.  The configuration must not be
# changed, or the module may not match the real WSL2 kernel.
set -euo pipefail

REL=${1:-$(uname -r)}
VER=${REL%%-*}				# 6.18.58.1-microsoft-standard-WSL2 -> 6.18.58.1
TAG=linux-msft-wsl-$VER
DIR=${WSL_KDIR:-$HOME/build/wsl2-$VER}

if [ ! -d "$DIR/.git" ]; then
	git clone --depth 1 --branch "$TAG" \
		https://github.com/microsoft/WSL2-Linux-Kernel "$DIR"
fi
cd "$DIR"

# Set but empty: otherwise setlocalversion appends "+" to the release
# (the shallow clone is not at an upstream tag), and the module's vermagic
# would not match the real WSL2 kernel.
export LOCALVERSION=

if [ ! -e .config ]; then
	if [ "$REL" = "$(uname -r)" ] && [ -r /proc/config.gz ]; then
		zcat /proc/config.gz > .config
	else
		cp arch/x86/configs/config-wsl .config
	fi
	make olddefconfig
fi

got=$(make -s kernelrelease)
if [ "$got" != "$REL" ]; then
	echo "kernel release mismatch: tree $got, wanted $REL" >&2
	exit 1
fi

make -j"$(nproc)" bzImage modules
echo "WSL2 kernel tree ready: $DIR ($REL)"
