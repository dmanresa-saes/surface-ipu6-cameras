#!/bin/bash
# Raw V4L2 capture straight from one of the Surface Pro 7+ sensors, bypassing
# libcamera. Usage: camtest.sh [ov5693|ov8865|ov7251] [WIDTH HEIGHT]
SENSOR="${1:-ov5693}"
W="$2"; H="$3"

SD=""
for v in /sys/class/video4linux/v4l-subdev*; do
    case "$(cat "$v/name")" in "$SENSOR "*) SD="/dev/$(basename "$v")"; ENTITY="$(cat "$v/name")";; esac
done
if [ -z "$SD" ]; then
    echo "no v4l2 subdev for $SENSOR -- driver did not bind"
    echo "sensors:"; for d in INT33BE:00 INT347A:00 INT347E:00; do
        printf '  %-12s -> %s\n' "$d" "$(basename "$(readlink /sys/bus/i2c/devices/i2c-$d/driver 2>/dev/null)" 2>/dev/null || echo NONE)"
    done
    exit 1
fi

# Which CSI-2 receiver is this sensor wired to, and hence which capture node.
# Walk the graph: sensor -> CSI-2 receiver -> first capture entity on pad 1.
# The capture entity's number is not simply port*8, so resolve it by name.
GRAPH=$(media-ctl -d /dev/media0 -p 2>/dev/null)
CSI=$(echo "$GRAPH" | awk -v e="\"$ENTITY\":0" '
    /entity .*CSI2/ { csi=$0; sub(/.*entity [0-9]+: /,"",csi); sub(/ \(.*/,"",csi) }
    index($0, e) && /ENABLED/ { print csi; exit }')
[ -z "$CSI" ] && { echo "no CSI-2 receiver linked to $ENTITY"; exit 1; }

CAP=$(echo "$GRAPH" | awk -v c="entity .*: $CSI \\(" '
    $0 ~ c { inside=1; next }
    inside && /^- entity/ { exit }
    inside && /pad1: Source/ { want=1; next }
    inside && want && /-> "Intel IPU6 ISYS Capture/ {
        line=$0; sub(/.*-> "/,"",line); sub(/":.*/,"",line); print line; exit }')
[ -z "$CAP" ] && { echo "no capture entity on ${CSI} pad1"; exit 1; }

NODE=""
for v in /sys/class/video4linux/video*; do
    [ "$(cat "$v/name")" = "$CAP" ] && NODE=${v##*/video}
done
[ -z "$NODE" ] && { echo "no /dev/video node named '$CAP'"; exit 1; }

# Native format and size of the sensor.
FMT=$(v4l2-ctl -d "$SD" --get-subdev-fmt 0 2>/dev/null)
if [ -z "$W" ]; then
    WH=$(echo "$FMT" | awk '/Width\/Height/{print $NF}')
    W=${WH%%/*}; H=${WH##*/}
fi
MBUS=$(echo "$FMT" | awk '/Mediabus/{print $NF}' | tr -d '()')
case "$MBUS" in
    MEDIA_BUS_FMT_Y10_1X10)     PIX='Y10 '; MB=Y10_1X10 ;;
    MEDIA_BUS_FMT_SBGGR10_1X10) PIX=BG10; MB=SBGGR10_1X10 ;;
    MEDIA_BUS_FMT_SGRBG10_1X10) PIX=BA10; MB=SGRBG10_1X10 ;;
    *) echo "unhandled mbus code $MBUS"; exit 1 ;;
esac

echo "sensor  : $ENTITY ($SD)"
echo "receiver: $CSI -> $CAP (/dev/video$NODE)"
echo "format  : ${W}x${H} $MBUS -> $PIX"

media-ctl -d /dev/media0 -l "\"$CSI\":1 -> \"$CAP\":0 [1]"
media-ctl -d /dev/media0 -V "\"$ENTITY\":0 [fmt:$MB/${W}x${H}]"
media-ctl -d /dev/media0 -V "\"$CSI\":0 [fmt:$MB/${W}x${H}]"
media-ctl -d /dev/media0 -V "\"$CSI\":1 [fmt:$MB/${W}x${H}]"

OUT=/tmp/${SENSOR}.raw
rm -f "$OUT"
timeout 25 v4l2-ctl -d "/dev/video$NODE" \
    "--set-fmt-video=width=$W,height=$H,pixelformat=$PIX" \
    --stream-mmap=6 --stream-count=5 --stream-to="$OUT"
echo "captured: $(stat -c%s "$OUT" 2>/dev/null || echo 0) bytes into $OUT (5 frames expected)"
