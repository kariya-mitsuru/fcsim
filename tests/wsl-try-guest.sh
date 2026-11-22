#!/bin/bash
# scripts/wsl-try.sh, run non-interactively on the WSL2 kernel inside the
# guest (make test-wsl only: the script refuses any other kernel).
set -euo pipefail

TOP=$(cd "$(dirname "$0")/.." && pwd)
. "$TOP/tests/lib.sh"

TRY="$TOP/scripts/wsl-try.sh"
RD=fcsim_try_rd
CORE=$LIO/core

case $(uname -r) in
*microsoft*WSL2*) ;;
*) fail "not a WSL2 kernel ($(uname -r)): run this through make test-wsl" ;;
esac
modprobe target_core_mod

rd_exists() { compgen -G "$CORE/rd_mcp_*/$RD" >/dev/null; }
tmpdirs() { ls -d /tmp/wsl-try.*/ 2>/dev/null || true; }	# the script's own (mktemp -d)
leftovers() {	# what a run must not leave behind (BEFORE: tmpdirs before the run)
	[ ! -d /sys/module/tcm_fcsim ] || echo "module still loaded"
	[ ! -e "$LIO/fcsim" ] || echo "$LIO/fcsim left"
	[ "$(tmpdirs)" = "$BEFORE" ] || echo "temporary files left: $(tmpdirs)"
	return 0
}

step "an existing backstore of the script's name: refused and left alone"
targetcli /backstores/ramdisk create $RD 16M >/dev/null
BEFORE=$(tmpdirs)
if "$TRY" --yes > /tmp/try.out 2>&1; then cat /tmp/try.out; fail "ran despite the existing backstore"; fi
sed 's/^/  /' /tmp/try.out
grep -q "exists already" /tmp/try.out || fail "no reason given"
rd_exists || fail "the existing backstore was deleted"
[ -z "$(leftovers)" ] || fail "$(leftovers)"
targetcli /backstores/ramdisk delete $RD >/dev/null

step "a full run (a WARNING from before the run does not count)"
echo "WARNING: wsl-try-guest: before the run, must be ignored" > /dev/kmsg
BEFORE=$(tmpdirs)
if ! "$TRY" --yes > /tmp/try.out 2>&1; then cat /tmp/try.out; fail "wsl-try.sh failed"; fi
sed 's/^/  /' /tmp/try.out
[ "$(tail -1 /tmp/try.out)" = "wsl-try: OK" ] || fail "no OK at the end"
[ -z "$(leftovers)" ] || fail "$(leftovers)"
rd_exists && fail "the script's backstore was left behind"

echo
echo "PASS"
