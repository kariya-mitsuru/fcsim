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

step "a cleanup step that fails: reported, never OK"
# rmmod as the script sees it: the first call (step 1) works, the second (the
# cleanup) fails as if udev still held the disk.
FAKE=$(mktemp -d)
cat > "$FAKE/rmmod" <<EOF
#!/bin/bash
n=\$(cat "$FAKE/n" 2>/dev/null || echo 0); echo \$((n + 1)) > "$FAKE/n"
[ "\$n" = 0 ] && exec "$(command -v rmmod)" "\$@"
echo "rmmod: ERROR: Module \$1 is in use (fake)" >&2
exit 1
EOF
chmod +x "$FAKE/rmmod"
BEFORE=$(tmpdirs)
if PATH="$FAKE:$PATH" "$TRY" --yes > /tmp/try.out 2>&1; then
	cat /tmp/try.out; fail "a failed rmmod was not reported"
fi
sed 's/^/  /' /tmp/try.out
grep -q "wsl-try: OK" /tmp/try.out && fail "OK despite the failed rmmod"
grep -q "cleanup step failed: rmmod" /tmp/try.out || fail "the failed step was not named"
grep -q "tcm_fcsim is still loaded" /tmp/try.out || fail "the loaded module was not reported"
grep -q "FAILED" /tmp/try.out || fail "no FAILED at the end"
[ -d /sys/module/tcm_fcsim ] || fail "the fake rmmod did not keep the module"
rmmod tcm_fcsim
rd_exists && fail "the script's backstore was left behind"
# A failed run keeps its kernel log for the user: ours to remove here.
for d in $(tmpdirs); do
	case $BEFORE in *"$d"*) ;; *) rm -rf "$d" ;; esac
done
rm -rf "$FAKE"
[ -z "$(leftovers)" ] || fail "$(leftovers)"

echo
echo "PASS"
