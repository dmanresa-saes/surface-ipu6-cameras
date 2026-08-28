#!/bin/bash
# A/B test tool: run the front camera's PSYS pipeline BY HAND, bypassing the
# production bridge (surface-psys-bridge), and look at it live.
#
#   sudo ./psys-test.sh            # window with the live PSYS image (Ctrl+C to stop)
#   sudo ./psys-test.sh loopback   # feed /dev/video80 instead (view with: ffplay /dev/video80)
#
# Since 2026-08-27 the PSYS path IS production for the front camera
# (surface-psys-bridge.service serves /dev/video80 on demand); this script
# remains as a debugging/A-B tool that runs the same gst pipeline in the
# foreground with visible logs. On exit it restores production: driver
# reloaded (modprobe.d already sets binned_y_offset=1) and the bridge
# services restarted.
set -e
[ "$(id -u)" = 0 ] || { echo "run with sudo"; exit 1; }

MODE="${1:-window}"

# Only one icamerasrc client can own the camera: a second instance fails with
# "failed to open libcamhal device" (HAL: device has been opened in another
# process) and, worse, its restore trap reloads ov5693 UNDER the live stream
# of the first instance, which wedges the ISYS firmware ("stream stop time
# out" in dmesg; only a reboot recovers). Refuse to start in that case.
OTHER=$(pgrep -f "gst-launch-1\.0.*icamerasrc" || true)
if [ -n "$OTHER" ]; then
    echo "[psys-test] ERROR: ya hay una instancia usando icamerasrc (PID $OTHER)."
    echo "            Ciérrala con Ctrl+C en su terminal (o: kill -INT $OTHER) y reintenta."
    exit 1
fi

GST_PID=""
VIEWER_PID=""

# Parar el gst-launch en background SOLO con SIGINT (nunca -9: atasca el
# firmware ISYS) y esperar a que muera. Devuelve 1 si sobrevive.
stop_gst() {
    [ -n "$GST_PID" ] || return 0
    if kill -0 "$GST_PID" 2>/dev/null; then
        kill -INT "$GST_PID" 2>/dev/null || true
        for i in $(seq 1 15); do
            kill -0 "$GST_PID" 2>/dev/null || break
            sleep 1
            # historico: a veces hace falta repetir el SIGINT
            [ $((i % 4)) = 0 ] && kill -INT "$GST_PID" 2>/dev/null || true
        done
        kill -0 "$GST_PID" 2>/dev/null && return 1
    fi
    wait "$GST_PID" 2>/dev/null || true
    GST_PID=""
    return 0
}

restore() {
    echo; echo "[psys-test] restaurando produccion (surface-psys-bridge)..."
    # el visor (proceso del usuario) puede recibir TERM sin peligro
    [ -n "$VIEWER_PID" ] && kill -TERM "$VIEWER_PID" 2>/dev/null || true
    # esperar a que gst muera ANTES de recargar ov5693 -- recargar el driver
    # bajo un stream vivo es lo que cuelga el ISYS
    if ! stop_gst; then
        echo "[psys-test] AVISO: gst-launch (PID $GST_PID) no muere con SIGINT;"
        echo "            NO se recarga el driver ni se arrancan los servicios."
        echo "            Mátalo a mano (kill -TERM $GST_PID) y luego:"
        echo "            modprobe -r ov5693; modprobe ov5693"
        echo "            systemctl start surface-psys-bridge surface-camera-relayd@rear surface-ir-bridge"
        return
    fi
    wait 2>/dev/null || true
    if ! modprobe -r ov5693 2>/dev/null; then
        echo "[psys-test] AVISO: ov5693 sigue en uso, no se pudo recargar."
    fi
    # sin parametro: /etc/modprobe.d/ov5693-surface.conf ya fija offset 1
    modprobe ov5693
    systemctl start surface-psys-bridge surface-camera-relayd@rear surface-ir-bridge
    echo "[psys-test] listo: /dev/video80 vuelve al puente de produccion"
}
trap restore EXIT
trap 'exit 130' INT TERM

echo "[psys-test] parando puentes y recargando driver..."
systemctl stop surface-psys-bridge surface-camera-relayd@rear surface-ir-bridge
modprobe -r ov5693
# offset 1 (impar = GRBG) + vflip=1/hflip=0 en el perfil HAL (hflip=0 desde la serie flip-fixes) = imagen derecha;
# lo fija /etc/modprobe.d/ov5693-surface.conf (produccion). NO usar offset 3
# con vflip=1: el sensor emite frames rotos (CSI2 FIFO overflow).
modprobe ov5693
# modulo psys: instalado por DKMS (ipu6-psys-surface/1.0), autocarga en boot
[ -e /dev/ipu-psys0 ] || modprobe intel-ipu6-psys 2>/dev/null || true
[ -e /dev/ipu-psys0 ] || { echo "no /dev/ipu-psys0 -- modulo psys no carga (dkms status?)"; exit 1; }
sleep 1

SRC="icamerasrc device-name=0 ! video/x-raw,format=NV12,width=1280,height=720"
# Unico camino verificado: PSYS -> /dev/video80 (caps explicitas tras
# videoconvert: fijar YUY2 1280x720 evita renegociaciones raras con el
# loopback). El antiguo modo ventana directo (icamerasrc ! xvimagesink) se
# retiro: cuando el HAL se atascaba al arrancar daba VENTANA NEGRA sin
# diagnostico y el shutdown se quedaba colgado en gst_cam_base_src_set_playing
# (SIGINT no bastaba); con el visor separado el fallo se detecta y reintenta.
if [ "$MODE" = loopback ]; then
    echo "[psys-test] alimentando /dev/video80 -- mira con: ffplay /dev/video80"
    gst-launch-1.0 $SRC ! videoconvert \
        ! video/x-raw,format=YUY2,width=1280,height=720 \
        ! v4l2sink device=/dev/video80 sync=false
else
    echo "[psys-test] modo ventana: PSYS -> /dev/video80 + visor del usuario (Ctrl+C para salir)"
    # El arranque del HAL a veces se atasca (el ISYS no entrega nada:
    # "Poll: Device node fd NN poll timeout" en el log, ventana negra si no
    # se detecta). Se detecta esperando a que el productor fije formato en el
    # loopback (= primer frame en camino) y se reintenta UNA vez con ciclo de
    # driver; el segundo intento historicamente arranca.
    ATTEMPT=1
    while :; do
        gst-launch-1.0 $SRC ! videoconvert \
            ! video/x-raw,format=YUY2,width=1280,height=720 \
            ! v4l2sink device=/dev/video80 sync=false &
        GST_PID=$!
        FMT=""
        for i in $(seq 1 40); do
            FMT=$(cat /sys/devices/virtual/video4linux/video80/format 2>/dev/null)
            [ -n "$FMT" ] && break
            kill -0 "$GST_PID" 2>/dev/null || break
            sleep 0.5
        done
        [ -n "$FMT" ] && break
        stop_gst || { echo "[psys-test] ERROR: gst atascado no muere; abortando."; exit 1; }
        if [ "$ATTEMPT" -ge 2 ]; then
            echo "[psys-test] ERROR: el HAL no entrega frames tras 2 intentos; reintenta mas tarde."
            exit 1
        fi
        ATTEMPT=$((ATTEMPT + 1))
        echo "[psys-test] HAL atascado (sin frames); reintento $ATTEMPT con ciclo de driver..."
        modprobe -r ov5693 2>/dev/null || true
        modprobe ov5693
        sleep 1
    done
    echo "[psys-test] frames fluyendo ($FMT), abriendo visor como usuario..."
    # el VISOR corre COMO EL USUARIO en su propia sesion (root no toca el
    # display): ffplay via XWayland/Wayland con el entorno del usuario.
    VUSER="${SUDO_USER:-usuario}"
    VUID=$(id -u "$VUSER")
    XAUTH=$(ls /run/user/$VUID/.mutter-Xwaylandauth.* 2>/dev/null | head -n1)
    sudo -u "$VUSER" env XDG_RUNTIME_DIR=/run/user/$VUID WAYLAND_DISPLAY=wayland-0 \
        DISPLAY=:0 ${XAUTH:+XAUTHORITY=$XAUTH} \
        ffplay -loglevel warning -window_title "PSYS front (/dev/video80)" \
        /dev/video80 >/tmp/psys-viewer.log 2>&1 &
    VIEWER_PID=$!
    wait $GST_PID
fi
