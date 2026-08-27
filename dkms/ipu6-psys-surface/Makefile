# Wrapper para DKMS: el dkms.conf no admite comillas dentro de MAKE[0], y
# KCPPFLAGS lleva varios -I. El orden IMPORTA: ml-hdrs (headers del ipu6
# mainline) primero, para tapar los headers homonimos del arbol de Intel.
KDIR ?= /lib/modules/$(shell uname -r)/build
M := $(CURDIR)
PSYS := $(M)/drivers/media/pci/intel/ipu6/psys
KCPP := -I$(M)/ml-hdrs -I$(M)/include -I$(M)/drivers/media/pci/intel -I$(M)/drivers/media/pci/intel/ipu6

modules:
	$(MAKE) -C $(KDIR) M=$(PSYS) KCPPFLAGS="$(KCPP)" CONFIG_VIDEO_INTEL_IPU6=m modules

clean:
	$(MAKE) -C $(KDIR) M=$(PSYS) clean
