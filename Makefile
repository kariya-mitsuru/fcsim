# Build tcm_fcsim out of tree against the development kernel.
#   make            build src/tcm_fcsim.ko
#   make clean
#   make test       run the smoke and race tests inside virtme-ng guests
#                   (one guest per test: a regression may crash the kernel)
KDIR ?= $(HOME)/build/linux-6.18

all:
	$(MAKE) -C $(KDIR) M=$(CURDIR)/src W=1 modules

clean:
	$(MAKE) -C $(KDIR) M=$(CURDIR)/src clean

test: all
	scripts/vng-run.sh -- tests/smoke-fcsim.sh
	scripts/vng-run.sh -- tests/smoke-fcsim-targetcli.sh
	scripts/vng-run.sh -- tests/race-fcsim.sh abort
	scripts/vng-run.sh -- tests/race-fcsim.sh close

.PHONY: all clean test
