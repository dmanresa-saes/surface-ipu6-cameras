# Patches

All patches apply with `patch -p1` (or `git apply`) from the root of the
tree they target. Baselines they were generated and verified against:

| patch | target tree | baseline | license |
|---|---|---|---|
| `ov5693-surface-ipu6.patch` | linux (`drivers/media/i2c/ov5693.c`) | v6.19 | GPL-2.0 |
| `ov7251-surface-ir.patch` | linux (`drivers/media/i2c/ov7251.c`) | v6.19 | GPL-2.0 |
| `int3472-surface-sensors.patch` | linux (`drivers/platform/x86/intel/int3472/discrete.c`) | v6.19 | GPL-2.0 |
| `libcamera-local.patch` | [libcamera](https://git.libcamera.org/libcamera/libcamera.git) | commit `35c137c` | LGPL-2.1+ |
| `ipu6-camera-hal-bggr-support.patch` | [intel/ipu6-camera-hal](https://github.com/intel/ipu6-camera-hal) | commit `6fefa86` (master) | Apache-2.0 |
| `v4l2-relayd-client-usage.patch` | [9elements/v4l2-relayd](https://github.com/9elements/v4l2-relayd) | commit `f14d6d4` (main) | GPL-2.0 (upstream's license) |

The kernel patches are also shipped pre-applied as complete files under
`../dkms/`, which is the recommended way to install them (no kernel tree
needed). What each one does — and why every hunk exists — is documented in
`../docs/REBUILD.es.md` and summarised in the top-level README.
