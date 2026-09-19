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
