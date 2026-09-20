# Module build for the TC-EB5 board helpers.
#
# Derived from Evsio0n/tc-eb5-oot v0.2.1 (modules/Makefile):
#   https://github.com/evsio0n/tc-eb5-oot
# Adapted so KSRC and KDIR can be separate (split source / output tree) and so
# it works with this repo's CI. See CREDITS.md.
#
# NOTE: upstream also builds tc-eb5-qmp-pcie.ko (an out-of-tree QMP PCIe PHY).
# This repo deliberately does not: the in-tree phy-qcom-qmp-pcie driver brings
# the link up correctly on this board, so the external PHY is unnecessary.

ifneq ($(KERNELRELEASE),)

obj-m += tc-eb5-pcie-helper.o
tc-eb5-pcie-helper-y := eb5-board.o eb5-bind-gate.o

else

# Out-of-tree build against a prepared kernel output tree.
#
#   make -C <ksrc> O=<kdir> M=$PWD ARCH=arm64 modules
#
KDIR ?= /lib/modules/$(shell uname -r)/build
KSRC ?= $(KDIR)

.PHONY: default clean

default:
	$(MAKE) -C $(KSRC) O=$(KDIR) M=$(CURDIR) ARCH=arm64 modules

clean:
	$(MAKE) -C $(KSRC) O=$(KDIR) M=$(CURDIR) ARCH=arm64 clean

endif
