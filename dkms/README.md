# DKMS packages

Four out-of-tree kernel modules, each in its own directory with sources,
`dkms.conf` and a `dkms_install.sh`. All GPL-2.0 (kernel-derived code).

| package | what it is |
|---|---|
| `ov5693-surface/` | front sensor driver: mainline v6.19 `ov5693.c` + the binned-mode / MIPI_CTRL00 / flip / `binned_y_offset` patch (`../patches/ov5693-surface-ipu6.patch` pre-applied) |
| `ov7251-surface/` | IR sensor driver: mainline v6.19 `ov7251.c` + IR-illuminator control (`../patches/ov7251-surface-ir.patch` pre-applied) |
| `int3472-surface/` | sensor power glue: mainline v6.19 `int3472/discrete.c` patched (`../patches/int3472-surface-sensors.patch`) + the unmodified sibling sources the module links against |
| `ipu6-psys-surface/` | the IPU6 hardware ISP (PSYS) module from `intel/ipu6-drivers`, built ON TOP of the mainline `intel-ipu6`. Intel's sources are NOT vendored — see its README for the two-line clone-and-install |

Prerequisite on linux-surface kernels (once per kernel update): the
`linux-headers-surface` package does not ship `include/generated/autoconf.h`,
and without it **no** DKMS module builds. Regenerate it:

```sh
sudo python3 ../tools/gen_autoconf.py \
  /usr/src/linux-headers-$(uname -r)/include/config/auto.conf \
  /usr/src/linux-headers-$(uname -r)/include/generated/autoconf.h
sudo touch /usr/src/linux-headers-$(uname -r)/include/generated/rustc_cfg
sudo dkms autoinstall
```

Install each package with `sudo ./dkms_install.sh` inside its directory.
`v4l2loopback` is also needed as DKMS: use master from
<https://github.com/umlaeute/v4l2loopback> (v0.15.4+; the Ubuntu package
does not build against 6.19).
