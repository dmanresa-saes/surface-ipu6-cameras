# Bridges: what serves /dev/video80-82

Everything here installs to `/usr/local/bin` (scripts), `/etc/systemd/system`
(units) and `/etc/udev/rules.d` (rule). License: MIT.

**All three cameras are served by on-demand bridges**: nothing streams until
an application opens the loopback device, and the sensor is powered down a
few seconds after the last client leaves. They share one mechanism — the
loopback's `V4L2_EVENT_PRI_CLIENT_USAGE` event, a 2-3 s grace period
(players open, probe, close and reopen), and shutdown by SIGINT, never
SIGKILL. This matters more than tidiness: the IR illuminator stays lit for
as long as the sensor streams, and a SIGKILL'd producer wedges the IPU6
ISYS firmware until reboot.

| piece | role |
|---|---|
| `surface-camera-loopbacks` | creates the three labelled v4l2loopback devices at boot (`/dev/video80` front, `81` IR, `82` rear). Labels with spaces cannot be set via module parameters, hence runtime `v4l2loopback-ctl add`. Deliberately does NOT pin formats (`set-caps` would make the node advertise CAPTURE to everyone, and then no producer could open it for output). |
| `surface-psys-bridge` | **front camera (OV5693), production path**: owns `/dev/video80`, waits for the client-usage event, runs `icamerasrc` (Intel HAL → ISYS + **PSYS hardware ISP**) as a subprocess and relays YUY2 1280x720\@30. Retries the HAL's known intermittent stuck start (first-frame watchdog + `ov5693` driver recycle, max 3), and never lets systemd SIGKILL a streaming `icamerasrc` — SIGINT only, with patience. |
| `surface-rear-bridge` | **rear camera (OV8865), production path since 2026-08-30**: same shape as the PSYS bridge, but the producer is `gst-launch-1.0` running libcamera's software ISP (`libcamerasrc` → 1596x896 RGB → 2 px crop → 1280x720 YUY2 → `fdsink`). The daemon owns the loopback producer fd, sets the format **once, before any client exists** (a loopback a client has already negotiated answers EBUSY for ever), feeds black splash frames until the first real one, and stops the child with SIGINT. Idle cost measured 2026-08-30: 0.000% CPU, ~15 MB RSS, sensor `suspended`; with a client, ~30 fps and 0.31 s to the first real frame. |
| `surface-ir-bridge` | **IR camera (OV7251)**: raw Y10 from the ISYS → 8-bit → YUYV, with its own exposure loop (the IPU6 hands out nothing but Y10 and no consumer understands it). Rebuilds the media graph every session (the libcamera relays sever its link), reads the exposure range and nominal frame period off the driver at start-up (so it works with or without `vts_boost`, see `../config/modprobe.d/ov7251-surface.conf`), and **detects and restarts wedged sensor sessions** — see below. |
| `surface-camera-relayd` | **SUPERSEDED DESIGN, kept for reference and manual fallback.** The old always-on `v4l2-relayd` bridge for the colour cameras (libcamera → `v4l2-relayd` → loopback). Not used by either camera since 2026-08-30 and no instance is enabled. The gst element chain of its `rear` branch is reused verbatim inside `surface-rear-bridge`. |
| `systemd/*.service` | the five units. `KillMode=mixed` + `TimeoutStopSec=30` + the `Conflicts=` lines are all load-bearing (two producers must never share one loopback, and the gst/icamerasrc child must die by SIGINT). |
| `udev/90-dma-heap.rules` | gives group `video` access to `/dev/dma_heap/system` (libcamera's software ISP needs it). |

Enable:

```sh
systemctl enable --now surface-camera-loopbacks surface-psys-bridge \
    surface-rear-bridge surface-ir-bridge
```

No `surface-camera-relayd@` instance is enabled: `@front` belongs to the
PSYS bridge and `@rear` to `surface-rear-bridge`, and both units carry the
matching `Conflicts=` so that starting the relay by hand cannot inject a
second producer into the same loopback.

## Why the always-on relay was replaced (don't "restore" it)

`v4l2-relayd` runs its splash pipeline (`videotestsrc`) permanently, whether
or not anybody has the device open. Measured 2026-08-29 on this machine: 7 h
of *idle* cost ~20% of a CPU and **3.3 GB RSS**, with the sensor SUSPENDED
the whole time — the entire bill was a test source feeding a loopback nobody
read, with buffers piling up inside the relay. The on-demand rear bridge
costs 0.000% CPU and ~15 MB idle and gives the same picture.

## The rear bridge's gst chain is not a style choice

Every element fixes a measured defect (full detail in
`../docs/REBUILD.es.md` §4/§6):

- **render 1596x896**: the software ISP emits black frames when asked for
  less than ~1296 px wide off a full-resolution readout, and the GPU
  resampler lays magenta rows / a dark column at 1600 and 1920 wide. 1596 is
  the width with none of that.
- **`videocrop` 2 px all round**: the debayer's border rows/columns carry an
  incomplete Bayer phase and come out magenta after the CCM.
- **`videorate skip-to-first=true`**: without it the first frame is repeated
  for every "missing" slot since the pipeline clock started — a picture
  frozen for seconds ("camera frozen" bug).
- the loopback is written by **this process**, never by a `v4l2sink`.

## The IR bridge's wedge detect-and-restart — DO NOT remove it

A share of IR sensor sessions comes up broken: nearly every row pinned at
1023, sometimes with absurd frame pacing (127-443 fps). It looks exactly
like a sensor or exposure bug and it is **not**: the root cause is the
**IPU6's CSI-2 D-PHY losing sync at stream start** (only wedged sessions
emit `csi2-5 error: DPHY fatal error / SOT sync error / Frame sync error`,
from the very first frame; the "1023" rows contain values >1023, impossible
in real Y10). The correct fix belongs in the receiver driver; from userspace
the only cure is to restart the session, which is what this does:

- after STREAMON, inspect `WEDGE_PROBE_FRAMES = 3` frames (they are
  forwarded afterwards, so a clean start pays nothing for the check);
- a frame is wedged when **more than 50% of its rows have a row *minimum*
  ≥ 1020** (`WEDGE_ROW_LEVEL`/`WEDGE_ROW_FRAC`). This is calibrated, not
  guessed: measured wedged frames have ≥435 of 480 rows pinned, and a
  legitimately bright frame with 74% of its *pixels* saturated still has 0,
  because the illuminator's falloff always leaves low row minima;
- or when ≥2 gaps between kernel capture timestamps are under 0.4x the
  nominal frame period (`WEDGE_FAST_DT`) — the garbage-timing flavour of the
  same failure;
- recovery is STREAMOFF + close + reopen + rebuild the media graph, with a
  0.3 s pause because wedges come in streaks (7 of 10 attempts right after a
  wedge were wedged again, vs ~1 in 3 overall);
- after `WEDGE_RETRIES = 8` attempts it falls back to the **stock 30 fps
  vertical blanking** for the rest of the session (wedge rate there ~3%): a
  dimmer working session beats saturated frames. Only if even that stays
  wedged does it serve the frames as they are.

Validated over 20/20 good sessions, 6 of them recovered. The rate drifts
with the time of day (~3% morning, 25-35% afternoon, ~50% night) and is
independent of VTS, so a short test can easily "prove" the logic is
unnecessary.
