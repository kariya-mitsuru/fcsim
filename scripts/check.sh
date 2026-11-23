#!/bin/bash
# Fast checks on the host: no kernel module, no VM, no root (make check).
#
#   ShellCheck    every shell script (-S warning); SHELLCHECK=<command> to
#                 pick the binary
#   python        tools and test helpers compile
#   unittest      tests/test_fcsimctl.py (the pure parts of fcsimctl)
#   checkpatch    src/ against the kernel's checkpatch.pl (KDIR); the types
#                 ignored are false positives on this code (struct_group(),
#                 the attribute macros, sizeof("...\n"))
#
# A tool that is missing is reported as SKIP; any finding fails.
set -u
TOP=$(cd "$(dirname "$0")/.." && pwd)
cd "$TOP" || exit 1
KDIR=${KDIR:-$HOME/build/linux-6.18}
SHELLCHECK=${SHELLCHECK:-shellcheck}
rc=0

run() {	# run <name> <command...>
	local name=$1; shift
	if "$@"; then
		echo "check $name: ok"
	else
		echo "check $name: FAILED"
		rc=1
	fi
}
skip() { echo "check $1: SKIP ($2)"; }

if $SHELLCHECK --version >/dev/null 2>&1; then
	run shellcheck $SHELLCHECK -S warning -x tests/*.sh scripts/*.sh
else
	skip shellcheck "no '$SHELLCHECK'; set SHELLCHECK"
fi

pycompile() {
	local f
	for f in tools/fcsimctl tools/fcsim-targetcli tools/fcsim_rtslib.py \
			tests/fc-events.py tests/test_fcsimctl.py; do
		python3 -c 'import ast, sys; ast.parse(open(sys.argv[1]).read(), sys.argv[1])' "$f" ||
			return 1
	done
}
run python pycompile
run unittest python3 -B -m unittest -q tests/test_fcsimctl.py

checkpatch() {
	local out st
	# shellcheck disable=SC2046 # one argument per file
	out=$("$KDIR/scripts/checkpatch.pl" --no-tree -f --terse \
		--ignore LINE_SPACING,TRAILING_SEMICOLON,LINE_CONTINUATIONS,REPEATED_WORD,QUOTED_WHITESPACE_BEFORE_NEWLINE \
		$(git ls-files 'src/*.c' 'src/*.h'))
	st=$?
	grep -v '^total: ' <<< "$out"
	return $st
}
if [ -x "$KDIR/scripts/checkpatch.pl" ]; then
	run checkpatch checkpatch
else
	skip checkpatch "no $KDIR/scripts/checkpatch.pl; set KDIR"
fi

exit $rc
