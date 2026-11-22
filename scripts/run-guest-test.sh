#!/bin/bash
# Run one guest test, keeping its output and the guest dmesg in .test-out/.
#   [KIMG=... TEST_TAG=... TEST_TIMEOUT=...] scripts/run-guest-test.sh <name> <test command...>
# TEST_TAG is appended to the output names (e.g. smoke-el9.log) and passed to
# the test.  TEST_TIMEOUT (seconds, default 300) bounds the test inside the
# guest, so that the dmesg of a hung test is still saved; the guest as a
# whole gets 120 s more for booting and saving.
set -u
PROJ=$(cd "$(dirname "$0")/.." && pwd)
name=$1${TEST_TAG:+-$TEST_TAG}; shift
tmo=${TEST_TIMEOUT:-300}
mkdir -p "$PROJ/.test-out"
rm -f "$PROJ/.test-out/$name".{log,dmesg}
timeout $((tmo + 120)) "$PROJ/scripts/vng-run.sh" -- bash -c \
	"TEST_TAG='${TEST_TAG:-}' timeout -k 10 $tmo $* > .test-out/$name.log 2>&1
	rc=\$?; [ \$rc = 124 ] && echo 'TIMEOUT after ${tmo}s' >> .test-out/$name.log
	echo exit=\$rc >> .test-out/$name.log; dmesg > .test-out/$name.dmesg" \
	>/dev/null 2>&1
rc=$?
last=$(tail -1 "$PROJ/.test-out/$name.log" 2>/dev/null)
if [ "$last" = "exit=0" ]; then
	echo "$name: PASS"
	exit 0
fi
echo "$name: FAIL (vng rc=$rc, ${last:-no output})"
exit 1
