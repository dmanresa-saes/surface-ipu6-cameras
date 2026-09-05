# Patches

All patches apply with `patch -p1` (or `git apply`) from the root of the
tree they target. Baselines they were generated and verified against:

| patch | target tree | baseline | license |
|---|---|---|---|
| `ov5693-surface-ipu6.patch` | linux (`drivers/media/i2c/ov5693.c`) | v6.19 **+ the "media: i2c: Surface Pro 7+ camera flip fixes" v2 series** (msgid `20260729-sp7plus-ov-flips-v2-0-91884b81a8f5@berg.pm`, patchwork linux-media series 28516) | GPL-2.0 |
| `ov5693-binned-no-mipictrl.patch` | linux (`drivers/media/i2c/ov5693.c`) | **mainline master + Fernando Rimoli's "media: Enable the OV5693 front camera on IPU6 Surface devices" v5, patches 1/7 (OVTI5693 HID) and 4/7 (MIPI_CTRL00 clock-lane gate)** (msgid `20260902142322.73523-1-fernandorimoli11@gmail.com`) | GPL-2.0 |
| `ov7251-surface-ir.patch` | linux (`drivers/media/i2c/ov7251.c`) | v6.19 | GPL-2.0 |
| `int3472-surface-sensors.patch` | linux (`drivers/platform/x86/intel/int3472/discrete.c`) | v6.19 | GPL-2.0 |
| `libcamera-local.patch` | [libcamera](https://git.libcamera.org/libcamera/libcamera.git) | commit `35c137c` | LGPL-2.1+ |
| `ipu6-camera-hal-bggr-support.patch` | [intel/ipu6-camera-hal](https://github.com/intel/ipu6-camera-hal) | commit `6fefa86` (master) | Apache-2.0 |
| `v4l2-relayd-client-usage.patch` | [9elements/v4l2-relayd](https://github.com/9elements/v4l2-relayd) | commit `f14d6d4` (main) | GPL-2.0 (upstream's license) |

`ov5693-surface-ipu6.patch` now PRESUPPOSES Jakob Berg Jespersen's flip-fix
series above applied first: it inherits the inverted-HFLIP polarity (HFLIP=0
= un-mirrored) and rebases the binned mode on top of it (binned ISP window X
offset stays 8 in both flip states — the binned readout's Bayer phase does
not move with the mirror, unlike full resolution). The HAL sensor profile
that pairs with it must therefore use `hflip=0 vflip=1` (it used `hflip=1`
before the series).

`ov5693-binned-no-mipictrl.patch` is the binned-mode half of the patch
above, re-done as a standalone `git format-patch` commit for testers whose
tree already carries Rimoli's v5 series (Surface Go 4 / ADL-N, Pro 8, Pro 9,
Pro 7+ on linux-surface once the series lands): mode-dependent PLL/analogue
registers, the vendor window geometry (full-array crop binned to 1312x978,
ISP offsets X=8, Y=`binned_y_offset`, default 2 = BGGR, 3 = GRBG for the
PSYS stack), sensor-bit-only VFLIP in binned mode, the 30 fps VTS cap and the
BLC comment. It contains NO MIPI_CTRL00 (0x4800) code -- the v5 4/7 gate
provides that -- and it does NOT depend on Jakob's withdrawn ov5693 flip
patch: upstream HFLIP polarity is left untouched and the binned X offset is a
constant 8 in both flip states (measured: the mirror does not move the binned
Bayer phase), so the variant is flip-polarity agnostic. With upstream
polarity the un-mirrored image is `hflip=1` (the HAL profile that pairs with
`ov5693-surface-ipu6.patch` uses `hflip=0`). Verified with `git apply --check`
(zero fuzz) on master + v5 1/7 + 4/7 and clean under `checkpatch.pl --strict`;
not yet tested on hardware in that configuration.

The kernel patches are also shipped pre-applied as complete files under
`../dkms/`, which is the recommended way to install them (no kernel tree
needed). What each one does — and why every hunk exists — is documented in
`../docs/REBUILD.es.md` and summarised in the top-level README.
