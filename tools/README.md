# Tools

License: MIT (see `../LICENSES/MIT.txt`). Some docstrings are still in
Spanish; usage below.

| tool | usage |
|---|---|
| `decode_aiqb.py` | `./decode_aiqb.py OV5693_MSHW0220_TGL.aiqb` — decode the Intel CPFF/.aiqb OEM tuning: per-illuminant sensor white point (→ AWB gains), CCT (McCamy from CIE xy) and 3x3 CCMs, as JSON. Works where Intel's own `libia_cmc_parser` segfaults. |
| `patch_aiqb_blc.py` | `./patch_aiqb_blc.py in.aiqb out.aiqb` — rescale the OEM black level /4 (12-bit-aligned → LSB-aligned RAW10) and fix both header checksums; required before feeding the .aiqb to the HAL on mainline kernels (else: global green cast). |
| `patch_aiqb_nr.py` | `./patch_aiqb_nr.py in.aiqb out.aiqb FACTOR` — rescale the bayer-NR thresholds at the high-gain nodes (LISP stream 60001, algo uuid 28866). Kept for reference: measured x1.5 has no effect, x3.0 destroys the image (see REBUILD §10.5). |
| `lisp_explore.py` | `./lisp_explore.py file.aiqb` — walk/dump the LISP/DFLT parameter streams of an .aiqb (gain-axed sub-records). |
| `extract_tables.py` | `./extract_tables.py ov5693.sys` — dump the sensor register/value tables from a Windows camera driver's `.rdata` section (source of the binned-mode registers). |
| `gen_autoconf.py` | `sudo python3 gen_autoconf.py /usr/src/linux-headers-$(uname -r)/include/config/auto.conf /usr/src/linux-headers-$(uname -r)/include/generated/autoconf.h` — regenerate the `autoconf.h` that `linux-headers-surface` does not ship; without it no DKMS module builds. Run after every kernel update, then `sudo touch .../include/generated/rustc_cfg && sudo dkms autoinstall`. |
| `camtest.sh` | `sudo ./camtest.sh [ov5693\|ov8865\|ov7251] [W H]` — raw Bayer/Y10 capture straight from a sensor through the IPU6 ISYS, bypassing libcamera and the HAL (5 frames to `/tmp/<sensor>.raw`). |
| `psys-test.sh` | `sudo ./psys-test.sh [loopback]` — run the front camera's PSYS pipeline by hand with visible logs (A/B against the production bridge); restores production services on exit. |
