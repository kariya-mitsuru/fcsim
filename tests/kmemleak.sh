#!/bin/bash
# kmemleak around one guest test (scripts/run-guest-test.sh); a no-op on a
# kernel without CONFIG_DEBUG_KMEMLEAK (AlmaLinux 9, WSL2).
#   tests/kmemleak.sh start    forget what booting the guest leaked
#   tests/kmemleak.sh check    report what leaked since; exit 1 if anything did
set -u
K=/sys/kernel/debug/kmemleak
mountpoint -q /sys/kernel/debug || mount -t debugfs none /sys/kernel/debug 2>/dev/null
[ -e $K ] || exit 0

case ${1:-} in
start)
	echo scan > $K
	echo clear > $K
	;;
check)
	# kmemleak skips objects younger than 5 s, and an object counts as leaked
	# only when no scan finds a reference to it: wait, then scan twice.
	sleep 6
	echo scan > $K
	echo scan > $K
	if [ -s $K ]; then
		echo "kmemleak: suspected leaks:"
		cat $K
		exit 1
	fi
	echo "kmemleak: no leaks"
	;;
*)
	echo "usage: $0 start|check" >&2
	exit 2
	;;
esac
