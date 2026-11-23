# Build tcm_fcsim out of tree.
#   make            build src/tcm_fcsim.ko for the development kernel (KDIR)
#   make test       run all tests inside virtme-ng guests, one guest per test
#                   (a regression may crash the kernel); output and guest
#                   dmesg go to .test-out/
#   make KVER=<release> kver
#                   build build/<release>/tcm_fcsim.ko for another kernel,
#                   using /lib/modules/<release>/build (or KVER_KDIR)
#   make el9 / make test-el9
#                   the same for the installed AlmaLinux 9 kernel, and run
#                   all tests on it (needs kernel-core/-modules[-core],
#                   kernel-devel and busybox of that release)
#   make wsl / make test-wsl
#                   the same for the WSL2 kernel this host runs, against the
#                   tree built by scripts/build-wsl-kernel.sh; the tests boot
#                   that tree's kernel in virtme-ng
#   make rpm        DKMS RPM for AlmaLinux 9 in rpmbuild/ (from the working
#                   tree, minus .gitignore'd files; needs rpm-build)
#   make test-rpm   install that RPM in an AlmaLinux 9 kernel guest (overlay,
#                   the host stays untouched) and check dkms + tools
#   make clean      also removes rpmbuild/ and .test-out/; works without KDIR
KDIR ?= $(HOME)/build/linux-6.18
VERSION := $(shell sed -n 's/^\#define FCSIM_VERSION[[:space:]]*"\(.*\)"/\1/p' src/fcsim.h)

# The newest installed EL9 kernel: version order (5.14.0-503 after 5.14.0-70).
EL9_KVER ?= $(shell ls -d /lib/modules/*.el9*.x86_64 2>/dev/null | sort -V | tail -1 | xargs -r basename)
KVER_KDIR ?= /lib/modules/$(KVER)/build
WSL_KVER ?= $(shell uname -r)
WSL_KDIR ?= $(HOME)/build/wsl2-$(firstword $(subst -, ,$(WSL_KVER)))

all:
	$(MAKE) -C $(KDIR) M=$(CURDIR)/src W=1 modules

clean:
	if [ -e $(KDIR)/Makefile ]; then $(MAKE) -C $(KDIR) M=$(CURDIR)/src clean; fi
	rm -rf build rpmbuild .test-out

# A copy of src/ per kernel, so builds for different kernels do not mix objects.
kver:
	@test -n "$(KVER)" || { echo "KVER=<kernel release> required"; exit 1; }
	@test -e $(KVER_KDIR)/Makefile || { echo "no kernel build tree at $(KVER_KDIR) (install kernel-devel-$(KVER) or set KVER_KDIR)"; exit 1; }
	mkdir -p build/$(KVER)
	cp -p src/*.c src/*.h src/Kbuild build/$(KVER)/
	$(MAKE) -C $(KVER_KDIR) M=$(CURDIR)/build/$(KVER) W=1 modules

el9:
	@test -n "$(EL9_KVER)" || { echo "no AlmaLinux 9 kernel in /lib/modules"; exit 1; }
	$(MAKE) kver KVER=$(EL9_KVER)

wsl:
	@test -e $(WSL_KDIR)/Module.symvers || { echo "build the WSL2 kernel tree first: scripts/build-wsl-kernel.sh"; exit 1; }
	$(MAKE) kver KVER=$(WSL_KVER) KVER_KDIR=$(WSL_KDIR)

TESTS = \
	"smoke tests/smoke-fcsim.sh" \
	"smoke-targetcli tests/smoke-fcsim-targetcli.sh" \
	"race-abort tests/race-fcsim.sh abort" \
	"race-close tests/race-fcsim.sh close" \
	"race-deliver tests/race-fcsim.sh deliver" \
	"race-write-pending tests/race-fcsim.sh write-pending" \
	"fault tests/fault-fcsim.sh" \
	"held tests/held-fcsim.sh" \
	"devloss tests/devloss-fcsim.sh" \
	"stress tests/stress-fcsim.sh" \
	"hang tests/hang-fcsim.sh" \
	"multipath tests/multipath-fcsim.sh" \
	"multipathd tests/multipathd-fcsim.sh" \
	"misc tests/misc-fcsim.sh" \
	"cli tests/cli-fcsim.sh" \
	"zone tests/zone-fcsim.sh" \
	"fpin tests/fpin-fcsim.sh" \
	"eh tests/eh-fcsim.sh" \
	"scsi tests/scsi-fcsim.sh"

run-tests = @rc=0; for t in $(TESTS); do scripts/run-guest-test.sh $$t || rc=1; done; exit $$rc

test: all
	$(run-tests)

test-el9: export KIMG = /lib/modules/$(EL9_KVER)/vmlinuz
test-el9: export TEST_TAG = el9
test-el9: el9
	$(run-tests)

test-wsl: export KDIR = $(WSL_KDIR)
test-wsl: export TEST_TAG = wsl
test-wsl: TESTS += "wsl-try tests/wsl-try-guest.sh"	# needs the WSL2 kernel
test-wsl: wsl
	$(run-tests)

rpm:
	mkdir -p rpmbuild/SOURCES
	git ls-files -z --cached --others --exclude-standard | \
		tar --null -T - --transform 's|^|tcm_fcsim-$(VERSION)/|' \
		-czf rpmbuild/SOURCES/tcm_fcsim-$(VERSION).tar.gz
	rpmbuild -ba --define "_topdir $(CURDIR)/rpmbuild" \
		--define "fcsim_version $(VERSION)" packaging/tcm_fcsim.spec

test-rpm: export KIMG = /lib/modules/$(EL9_KVER)/vmlinuz
test-rpm: export TEST_TAG = el9
test-rpm: rpm
	@test -n "$(EL9_KVER)" || { echo "no AlmaLinux 9 kernel in /lib/modules"; exit 1; }
	scripts/run-guest-test.sh package tests/package-el9.sh $(VERSION)

.PHONY: all clean kver el9 wsl rpm test test-el9 test-wsl test-rpm
