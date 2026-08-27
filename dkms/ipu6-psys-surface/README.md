# ipu6-psys-surface — the IPU6 hardware ISP (PSYS) as a DKMS module

The mainline `intel-ipu6` driver (Linux >= 6.10) handles only the capture
side (ISYS) and creates an orphan auxiliary device `intel_ipu6.psys.40`.
Intel's out-of-tree repo carries a PSYS module prepared to bind to exactly
that device, on top of the mainline driver — it replaces nothing.

This directory does **not** vendor Intel's sources. To build:

```sh
git clone --depth 1 https://github.com/intel/ipu6-drivers.git
sudo ./dkms_install.sh
```

What the installer assembles into `/usr/src/ipu6-psys-surface-1.0/`:

- `drivers/media/pci/intel/ipu6/psys/` and the headers of its two parent
  directories plus `include/`, from the `ipu6-drivers` clone (GPL-2.0).
  Validated against commit `71bddb5` of that repo.
- `mainline-ipu6-headers/` (included here, GPL-2.0): the ~16 private
  headers of `drivers/media/pci/intel/ipu6/` from Linux v6.19, which the
  `linux-headers` packages do not ship, plus `uapi/linux/ipu-psys.h` from
  Intel's repo. To regenerate them for another kernel version, copy
  `drivers/media/pci/intel/ipu6/*.h` from the corresponding kernel tag.

The wrapper `Makefile` matters: the `-I` order puts `ml-hdrs` first so the
mainline headers shadow Intel's same-named ones, and `dkms.conf` delegates
to it because dkms.conf's parser cannot carry quoted `KCPPFLAGS`.

Verify after boot: `/dev/ipu-psys0` exists and `dmesg | grep psys` shows
`pkg_dir entry count:8` (the `ipu6_fw.bin` shipped in linux-firmware already
contains the PSYS packages — do not install Intel's firmware over it).
