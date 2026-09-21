# Configuration files

| file | installs to | what |
|---|---|---|
| `ov5693-uf.xml` | `/etc/camera/ipu6/sensors/ov5693-uf.xml` | HAL sensor profile for the front OV5693 on the **mainline** ISYS driver (`mediaCfg=1`), binned 1296x972 SBGGR10, NV12 out, `vflip=1 hflip=0` — hflip=0 since the flip-fixes series inverted HFLIP polarity — (matched with the driver's `binned_y_offset=1`). Own work, MIT. |
| `tuning/libcamera/ov5693.yaml` | `/usr/local/share/libcamera/ipa/softisp/ov5693.yaml` | calibrated libcamera softISP colour tuning (bayes AWB curve + CCMs derived from the decoded OEM `.aiqb`, re-anchored to a physical unit). CC0-1.0, as libcamera tuning files are. Used by the softISP path (rear camera today; front fallback). |
| `tuning/libcamera/ov8865.yaml` | `/usr/local/share/libcamera/ipa/softisp/ov8865.yaml` | calibrated libcamera softISP colour tuning for the **rear** camera, derived the same way from the decoded OEM `.aiqb` and anchored on this physical unit (r x1.07 / b x1.083). Note the explicit `BlackLevel: { blackLevel: 1024 }` (16-bit scale, i.e. pedestal 16 at 10 bits): this key is load-bearing — with the softISP default the pedestal is swallowed and the picture renders magenta. CC0-1.0. |
| `modprobe.d/ov7251-surface.conf` | `/etc/modprobe.d/` | `vts_boost=3448`: the brighter IR mode (VTS 3448 -> 15 fps, exposure ceiling 3192 lines, **1.78x measured brightness**). Optional — remove the line for stock 30 fps; `surface-ir-bridge` reads the ranges off the driver at runtime. Read the caveat comments in the file: a share of stream starts comes up wedged, and that is the IPU6 D-PHY, not the sensor. |
| `modprobe.d/ov5693-surface.conf` | `/etc/modprobe.d/` | `binned_y_offset=1`: odd offset = GRBG Bayer phase for the PSYS/HAL path. **Consequence: the front camera becomes PSYS-only** — with this default, libcamera (which believes the driver's advertised BGGR) renders it magenta. For the softISP fallback use `binned_y_offset=2`. |
| `modprobe.d/v4l2loopback-surface.conf`, `modules-load.d/*` | `/etc/modprobe.d/`, `/etc/modules-load.d/` | loopback module options and boot-time loading (v4l2loopback, intel-ipu6-psys). |

## HAL files you must extract yourself (not redistributable)

The Intel HAL additionally needs, in `/etc/camera/ipu6/`:

- `OV5693_MSHW0220_TGL.aiqb` — the OEM colour calibration, **patched /4**
  with `tools/patch_aiqb_blc.py` (see README: black-level alignment).
- `gcss/graph_settings_ov5693.xml` — Microsoft's
  `graph_settings_ov5693_13P2BA540_BIN_TGL.xml`, verbatim (keep it GRBG).

Both come out of the public Surface Pro 7+ driver MSI (see the top-level
README for the URL and `msiextract` instructions). They are Microsoft/Intel
material and are therefore **not** included in this repository.

## libcamhal_profile.xml

`make install` of `ipu6-camera-hal` overwrites
`/etc/camera/ipu6/libcamhal_profile.xml`. That file is Intel's; the only
edit needed is adding this sensor to `availableSensors` in the `<Common>`
section (re-do it after every `make install`):

```xml
<availableSensors value="ov5693-uf-4,..."/>
```

`-uf-4` because the OV5693 hangs off "Intel IPU6 CSI2 4" (port 1 belongs to
the IR camera).
