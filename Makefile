# Build tcm_fcsim out of tree against the development kernel.
#   make            build src/tcm_fcsim.ko
#   make clean
#   make test       run all tests inside virtme-ng guests, one guest per test
#                   (a regression may crash the kernel); output and guest
#                   dmesg go to .test-out/
KDIR ?= $(HOME)/build/linux-6.18

all:
	$(MAKE) -C $(KDIR) M=$(CURDIR)/src W=1 modules

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR)/src clean

TESTS = \
	"smoke tests/smoke-fcsim.sh" \
	"smoke-targetcli tests/smoke-fcsim-targetcli.sh" \
	"race-abort tests/race-fcsim.sh abort" \
	"race-close tests/race-fcsim.sh close" \
	"fault tests/fault-fcsim.sh" \
	"hang tests/hang-fcsim.sh" \
	"multipath tests/multipath-fcsim.sh"

test: all
	@rc=0; for t in $(TESTS); do scripts/run-guest-test.sh $$t || rc=1; done; exit $$rc

.PHONY: all clean test
