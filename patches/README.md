# Patches

All patches apply with `patch -p1` (or `git apply`) from the root of the
tree they target. Baselines they were generated and verified against:

| patch | target tree | baseline | license |
|---|---|---|---|
| `ov5693-surface-ipu6.patch` | linux (`drivers/media/i2c/ov5693.c`) | v6.19 **+ the "media: i2c: Surface Pro 7+ camera flip fixes" v2 series** (msgid `20260729-sp7plus-ov-flips-v2-0-91884b81a8f5@berg.pm`, patchwork linux-media series 28516) | GPL-2.0 |
| `ov5693-binned-no-mipictrl.patch` | linux (`drivers/media/i2c/ov5693.c`) | **mainline master + Fernando Rimoli's "media: Enable the OV5693 front camera on IPU6 Surface devices" v5, patches 1/7 (OVTI5693 HID) and 4/7 (MIPI_CTRL00 clock-lane gate)** (msgid `20260902142322.73523-1-fernandorimoli11@gmail.com`) | GPL-2.0 |
| `ov7251-surface-ir.patch` | linux (`drivers/media/i2c/ov7251.c`) | v6.19 | GPL-2.0 |
| `ipu-bridge-selfcontained-swnodes.patch` | linux (`drivers/media/pci/intel/ipu-bridge.c`, `include/media/ipu-bridge.h`) | torvalds/master snapshot of 2026-08-31 (~v7.3-rc); also applied and run on 6.19 and on top of Fernando Rimoli's OV5693 v5 series | GPL-2.0 |
| `ipu-bridge-reuse-on-rebind.patch` | linux (`drivers/media/pci/intel/ipu-bridge.c`) | the patch above | GPL-2.0 |
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

`ov7251-surface-ir.patch` is a plain diff of mainline v6.19's
`drivers/media/i2c/ov7251.c` against the driver shipped in
`../dkms/ov7251-surface/ov7251.c`; applying it to a clean v6.19 file
reproduces that driver byte for byte (verified). Besides the IR illuminator
strobe programming and the `V4L2_CID_GAIN` -> `V4L2_CID_ANALOGUE_GAIN`
rename (libcamera refuses to enumerate the sensor without the latter; the
rename is Dan Scally's 2023 patch, never mainlined), it now carries the two
module parameters and the reset settle described in the top-level README:

- `vts_boost` — overrides the default 640x480 mode's VTS (1724 = 30 fps).
  Production uses 3448: 15 fps, exposure ceiling 3192 lines, **1.78x
  measured IR brightness**. See `../config/modprobe.d/ov7251-surface.conf`.
  The bridge reads the resulting control ranges at runtime, so nothing else
  needs changing. A longer integration window also needs a bigger safety
  margin to VTS (`OV7251_BOOST_INTEGRATION_MARGIN`, 256 lines): starting a
  stream with exposure within ~250 lines of VTS intermittently wedges the
  exposure engine.
- `win_timing` — the Windows Hello mode timing read out of the vendor
  `ov7251.sys` (VTS 522, 638.4 Mbps link, ~132 fps). Kept for the record
  only: **do not use it**, it is 2.4x darker at equal gain, because the
  brightness lever is the length of the integration window, not the PLL.
- a 5 ms settle after the global init's software reset, before `s_stream`
  starts writing PLL/mode registers.

## The `ipu-bridge` rebind patches (sent upstream, NOT applied yet)

`ipu-bridge` registers software nodes for the camera sensors it finds in
ACPI and deliberately never unregisters them. Two bugs follow from that,
both reproducible on this machine and both fatal in practice:

1. **Properties dangling into unloaded module rodata**
   (`ipu-bridge-selfcontained-swnodes.patch`). The values of the
   `link-frequencies` property point into the `const
   ipu_supported_sensors[]` table, and the *name* of the `lens-focus`
   property is a string literal — both in module rodata. Unload
   `ipu-bridge` and the registered nodes keep serving those pointers, so a
   re-probing sensor driver reads poison (`ov8865: failed to find 360000000
   clk rate in endpoint link-frequencies`, `ov5693: supported link freq
   419200000 not found`) or faults. The patch copies both into the never
   freed `struct ipu_bridge`, next to the data-lanes array that is already
   kept there for exactly this reason.
2. **`-EEXIST` on PCI remove/rescan** (`ipu-bridge-reuse-on-rebind.patch`).
   `device_del()` clears the ACPI fwnode's `->secondary`, so on the next
   probe the fwnode-graph shortcut finds no endpoints and the bridge tries
   to register the IPU HID software node again: `sysfs: cannot create
   duplicate filename '/kernel/software_nodes/INT343E'`, `probe ... failed
   with error -17`, cameras dead until reboot. The patch adds the missing
   reuse path (`software_node_find_by_name()` + point the secondary fwnode
   at it).

Tested here on 6.19 (linux-surface 6.19.8) and later on top of Fernando
Rimoli's "media: Enable the OV5693 front camera on IPU6 Surface devices" v5
series, whose 5/7 restructures `ipu-bridge` and conflicts textually with
1/2 (the link-frequencies block); rebasing is on our side. With the series,
the sequence that is fatal today

```sh
echo 1 > /sys/bus/pci/devices/0000:00:05.0/remove
modprobe -r intel_ipu6_isys intel_ipu6
echo 1 > /sys/bus/pci/rescan
modprobe intel_ipu6
```

completes cleanly, twice in a row, with all three cameras streaming after
each rebind.

**Upstream state: sent, reviewed, not applied.** Posted to linux-media on
2026-08-31 as `[PATCH v2 1/2]` and `[PATCH v2 2/2]` (Message-IDs
`20260831140304.45940-2@gmail.com` and `20260831140304.45940-3@gmail.com`),
after Sakari Ailus's review of v1; both were still in patchwork state
*new* on 2026-09-22. **Without them, never try to revive a wedged IPU6 by
PCI remove/rescan — only a reboot recovers.** Anyone is welcome to pick the
series up; the author no longer has the hardware.

There is a **third** literal of the same class: Rimoli's v5 adds a
`clock-noncontinuous` property whose name is another rodata string. That
one is fixed by his follow-up patch *"media: ipu-bridge: Keep the
clock-noncontinuous property name out of rodata"*, which carries a
`Reported-by` for this work; 1/2 above remains the fix for the other two
literals.

The kernel patches are also shipped pre-applied as complete files under
`../dkms/`, which is the recommended way to install them (no kernel tree
needed). What each one does — and why every hunk exists — is documented in
`../docs/REBUILD.es.md` and summarised in the top-level README.
