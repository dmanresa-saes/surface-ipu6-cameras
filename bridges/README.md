# Bridges: what serves /dev/video80-82

Everything here installs to `/usr/local/bin` (scripts), `/etc/systemd/system`
(units) and `/etc/udev/rules.d` (rule). License: MIT.

| piece | role |
|---|---|
| `surface-camera-loopbacks` | creates the three labelled v4l2loopback devices at boot (`/dev/video80` front, `81` IR, `82` rear). Labels with spaces cannot be set via module parameters, hence runtime `v4l2loopback-ctl add`. Deliberately does NOT pin formats (`set-caps` would break the producers). |
| `surface-psys-bridge` | **front camera, production path**: on-demand daemon that owns `/dev/video80`, waits for v4l2loopback's client-usage event, runs `icamerasrc` (Intel HAL → ISYS+PSYS) as a subprocess and relays YUY2 1280x720\@30. Retries the HAL's known intermittent stuck start (first-frame watchdog + `ov5693` driver recycle, max 3), and never lets systemd SIGKILL a streaming `icamerasrc` (that wedges the ISYS firmware until reboot) — SIGINT only, with patience. |
| `surface-camera-relayd` | colour-camera softISP bridge (libcamera → `v4l2-relayd` → loopback). In production only for the **rear** camera (`surface-camera-relayd@rear`); the `front` instance is kept for falling back to the software ISP (needs `modprobe ov5693 binned_y_offset=2`, see the README). |
| `surface-ir-bridge` | IR camera: raw Y10 from the ISYS → 8-bit → YUYV, with its own exposure loop (the IPU6 hands out nothing but Y10 and no consumer understands it). Streams only while a client holds the device — which is also what turns the IR illuminator off. Rebuilds the media graph every session (the libcamera relays sever its link). |
| `systemd/*.service` | the four units. Note `surface-psys-bridge.service`: `KillMode=mixed` + `TimeoutStopSec=30` + `Conflicts=surface-camera-relayd@front.service` are all load-bearing. |
| `udev/90-dma-heap.rules` | gives group `video` access to `/dev/dma_heap/system` (libcamera's software ISP needs it). |

Enable:

```sh
systemctl enable --now surface-camera-loopbacks surface-psys-bridge \
    surface-camera-relayd@rear surface-ir-bridge
```

(`surface-camera-relayd@front` stays disabled: the front camera is served by
the PSYS bridge, and two producers must never share one loopback.)
