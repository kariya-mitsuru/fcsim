#!/bin/bash
# Run one guest test, keeping its output and the guest dmesg in .test-out/.
#   [KIMG=... TEST_TAG=...] scripts/run-guest-test.sh <name> <test command...>
# TEST_TAG is appended to the output names (e.g. smoke-el9.log).
set -u
PROJ=$(cd "$(dirname "$0")/.." && pwd)
name=$1${TEST_TAG:+-$TEST_TAG}; shift
mkdir -p "$PROJ/.test-out"
rm -f "$PROJ/.test-out/$name".{log,dmesg}
timeout "${TEST_TIMEOUT:-300}" "$PROJ/scripts/vng-run.sh" -- bash -c \
	"$* > .test-out/$name.log 2>&1; echo exit=\$? >> .test-out/$name.log; dmesg > .test-out/$name.dmesg" \
	>/dev/null 2>&1
rc=$?
last=$(tail -1 "$PROJ/.test-out/$name.log" 2>/dev/null)
if [ "$last" = "exit=0" ]; then
	echo "$name: PASS"
	exit 0
fi
echo "$name: FAIL (vng rc=$rc, ${last:-no output})"
exit 1
