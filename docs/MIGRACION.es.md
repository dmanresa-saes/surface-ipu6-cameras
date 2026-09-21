# Instalación limpia: por dónde empezar

Este documento es el **punto de entrada** para quien (persona o IA) quiera
dejar funcionando las tres cámaras de un Microsoft Surface Pro 7+ en una
instalación limpia de Debian/Ubuntu. No hace falta acceso a la máquina en la
que se hizo el trabajo: todo lo necesario está en este repositorio.

Hardware de referencia: Surface Pro 7+ (Tiger Lake), Intel IPU6 `8086:9a19`,
sensores OV5693 (frontal), OV8865 (trasera), OV7251 (IR / Windows Hello).
Modelos cercanos (Pro 8, Pro 9, Go 4) comparten buena parte del problema;
donde se sabe que difieren, se dice.

> **Nota 2026-09-22**: la máquina en la que se hizo todo esto se dona, así que
> no habrá más pruebas sobre hardware IPU6 por nuestra parte. Lo que había
> pendiente de upstream queda descrito abajo con su estado real; cualquiera
> puede recogerlo. Todo lo medido está publicado aquí.

## Orden de lectura

1. [`../README.md`](../README.md) — qué hay montado y por qué (el *qué*), y el
   estado upstream resumido.
2. **Este fichero** — qué comprobar ANTES de aplicar nada, y las decisiones ya
   tomadas.
3. [`REBUILD.es.md`](REBUILD.es.md) — el playbook detallado y autocontenido,
   con los parches y los scripts embebidos y el POR QUÉ de cada pieza (el
   *cómo*). Es el documento largo.

## Qué hay en este repositorio

| ruta | contenido |
|---|---|
| `docs/REBUILD.es.md` | playbook completo: drivers, parches, tuning, puentes, systemd |
| `dkms/` | los cuatro paquetes DKMS (ov5693, ov7251, int3472 parcheados + el módulo PSYS) con las fuentes ya parcheadas |
| `patches/` | los mismos cambios como diffs limpios contra sus árboles base (kernel, libcamera, HAL de Intel, v4l2-relayd) |
| `bridges/` | los tres puentes bajo demanda + el relay antiguo (superado), unidades systemd y regla udev |
| `config/` | perfil del sensor para el HAL, tuning de color de libcamera, snippets de `modprobe.d` / `modules-load.d` |
| `tools/` | decodificador y parcheador del `.aiqb` OEM, extractor de tablas del driver de Windows, generador de `autoconf.h`, scripts de prueba |
| `docs/measurements/`, `docs/images/` | medidas de color y comparativas contra Windows 11 |

**Lo que NO está aquí, a propósito**: nada de Microsoft ni de Intel — ni
`.aiqb`, ni `graph_settings*.xml`, ni `.sys`, ni las librerías de
`ipu6-camera-bins`, ni el volcado DSDT de la máquina. El README dice de dónde
bajar el MSI público de drivers y cómo extraer lo que hace falta. Tampoco se
redistribuyen los parches de otras personas (ver la tabla siguiente): se
referencian por su publicación en la lista.

## ANTES DE APLICAR NADA: comprobar qué ya está upstream

Varias piezas se enviaron upstream entre agosto y septiembre de 2026 y
**pueden estar ya en tu kernel o en tu libcamera**. Aplicarlas a ciegas sobre
un árbol que ya las tiene rompe la compilación o duplica lógica. Comprobar una
por una (estado revisado el 2026-09-22):

| pieza | cómo comprobar | si YA está / estado |
|---|---|---|
| `ov5693` MIPI_CTRL00 (`0x4800`) para que el D-PHY del IPU6 engancha | `grep -i clock-noncontinuous drivers/media/pci/intel/ipu-bridge.c` | **SUPERADO UPSTREAM.** La serie v5 de Fernando Rimoli ("media: Enable the OV5693 front camera on IPU6 Surface devices") lo hace bien: propiedad `clock-noncontinuous` por PCI-ID en `ipu-bridge` + RMW del BIT(5) de MIPI_CTRL00 en el ov5693. Entró en la rama `next` de media-committers el **2026-09-11**. Si tu árbol la trae, **NO** uses nuestro `patches/ov5693-surface-ipu6.patch`: usa `patches/ov5693-binned-no-mipictrl.patch`, que es sólo la parte del modo binned, sin ningún `0x4800` (esa configuración se probó aquí el 2026-09-06 con módulos hechos a mano; el fichero de parche está verificado con `git apply --check` y `checkpatch --strict` pero no compilado en ese árbol exacto). Nuestro `0x2d` escribía cuatro bits (0, 2, 3, 5) de los cuales sólo el 5 hace algo — barrido de Fil Dunsky en una Pro 8, confirmado aquí porque la firma de errores CSI-2 es idéntica con `0x2d` y con bit-5-solo. |
| modo binned 2x2 del `ov5693` (1296x972) | `grep -n 'binning_x\|1296' drivers/media/i2c/ov5693.c` y ver si hay PLL por modo (`0x30b3`) | nadie lo ha llevado upstream: es la pieza que sigue siendo nuestra. Aplicar la variante que corresponda según la fila anterior. |
| `int3472` POWER1 (0x08) → `dvdd` | `grep -r POWER1 include/linux/platform_data/x86/int3472.h` | parche v3 de Jakob Berg Jespersen, con Reviewed-by de Hans de Goede; en patchwork como *handled-elsewhere* el 2026-09-22, **aún no en master**. Si ya está, no apliques ese hunk del nuestro; conserva sólo el mapeo `INT347E → vdda` de la IR. |
| `int3472` INT347E → `vdda` (cámara IR) | `grep -B2 -A3 vdda drivers/platform/x86/intel/int3472/discrete.c` | nuestro parche, enviado a platform-driver-x86 el 2026-08-30 (v2, con Reviewed-by y Tested-by); en patchwork como *handled-elsewhere*, **aún no en master**. Está en `patches/int3472-surface-sensors.patch`. Si ambos hunks ya están upstream, el DKMS `int3472-surface` sobra entero. |
| `ov8865` polaridad de HFLIP | ver si `ov8865.c` invierte los bits de `0x3821` respecto a v6.19 | parche de Jakob Berg Jespersen ([1/2] de la serie "Surface Pro 7+ camera flip fixes", patchwork linux-media 28516, con `Cc: stable`), confirmado aquí. **No lo redistribuimos**: bájalo de la lista. La trasera lo necesita para que la rotación de 180° que pide libcamera sea la de verdad y no un espejo horizontal; sin él la trasera funciona igual que siempre, sólo espejada. **Y si ya está**, revisa los offsets nuestros del `ov5693`, que están rebasados sobre esa serie. |
| `ov5693` fase Bayer con los flips (su [2/2]) | **fue RETIRADO** por su autor, no debería estar | lo retiró tras reproducir nuestra matriz de fases medida: su compensación acierta sólo en el estado VFLIP=1. Si aparece algo parecido, mide la fase antes de fiarte. |
| `ov7251` `V4L2_CID_ANALOGUE_GAIN` | `grep ANALOGUE_GAIN drivers/media/i2c/ov7251.c` | parche de Dan Scally de 2023 **nunca mainlineado** (redescubierto tres veces; está en el mbox de linux-surface). libcamera no enumera el sensor sin él, así que nuestro DKMS y `surface-ir-bridge` dependen de él. Si ya está, no apliques ese hunk. |
| `ipu-bridge`: rebind / `-EEXIST` y propiedades apuntando a rodata descargada | `grep -i reusing drivers/media/pci/intel/ipu-bridge.c` | nuestra serie de 2 parches, enviada a linux-media el 2026-08-31 (v2, revisada por Sakari Ailus), **en patchwork state *new*, sin aplicar**. Están aquí como `patches/ipu-bridge-selfcontained-swnodes.patch` y `patches/ipu-bridge-reuse-on-rebind.patch`. Si no están y no los aplicas: **no hagas remove/rescan PCI del IPU6**, deja la máquina rota hasta reiniciar. Un tercer literal del mismo tipo (`clock-noncontinuous`, que introduce la serie v5) lo arregla el parche de seguimiento de Fernando Rimoli "media: ipu-bridge: Keep the clock-noncontinuous property name out of rodata", con nosotros como `Reported-by`. |
| D-PHY del IPU6 desincronizado al stream-on (IR que arranca "en blanco") | no hay arreglo que buscar: mira si el ISYS reintenta al ver `DPHY fatal error` / `SOT sync error` | reportado a linux-media el 2026-08-29 con la evidencia (sección 11 de `REBUILD.es.md`). **Sin arreglo en el kernel.** Mientras no lo haya, `surface-ir-bridge` lo detecta y reinicia la sesión: no quites esa lógica. |
| libcamera: `gainMin` en el AWB | `grep gainMin src/ipa/libipa/awb.h` | RFC v2 enviado a libcamera-devel el 2026-08-29, **sin respuesta**. Si está, usa la clave oficial en `ov5693.yaml`; si no, el tuning funciona igual con el suelo por defecto (1.0), sólo pierde algo de margen en tungsteno. |
| libcamera: AGC, `exposureOptimal` → `relativeLuminanceTarget` | `grep -r relativeLuminanceTarget src/ipa/` | **cambió upstream** (commit `004fea17d`). Nuestros yaml no dependen ya de la clave vieja, pero si adaptas un tuning antiguo, la escala NO es la misma: hay que recalibrar. |

## Otras cosas que una instalación nueva obliga a mirar

1. **Módulos fuera de DKMS**: en la máquina de referencia acabaron tres
   módulos copiados a mano en `/lib/modules/<kernel>/updates/` (el `ov8865`
   con el parche de Jespersen, y `ipu-bridge` + `intel-ipu6` recompilados con
   la serie v5 de Rimoli más la nuestra). **Cualquier kernel nuevo los
   revierte en silencio.** En un sistema nuevo: primero comprueba la tabla de
   arriba; lo que no esté upstream, empaquétalo como DKMS igual que los otros
   cuatro, no lo copies a mano.
2. **Versiones**: el `v4l2loopback` de Ubuntu no compilaba con 6.19 (usar
   master); `linux-headers-surface` no trae
   `include/generated/autoconf.h` y hay que regenerarlo con
   `tools/gen_autoconf.py` tras cada kernel (ver `dkms/README.md`).
3. **Rutas de dispositivo**: los loopbacks están en `/dev/video80-82` porque
   los nodos bajos los ocupa el IPU6. Las apps nativas (Teams/Zoom) sólo
   sondean `video0-63`, así que con esa numeración sólo funcionan los
   navegadores; si te queda hueco por debajo de 64, merece la pena bajarlos.
4. **El `.aiqb` OEM se extrae, no se descarga de aquí**: el color de la
   frontal (ruta PSYS) y de la trasera (ruta softISP) sale de la calibración
   de Microsoft dentro del MSI público de drivers. El README tiene la URL y el
   procedimiento; `tools/decode_aiqb.py` lo lee y `tools/patch_aiqb_blc.py`
   corrige su black level.

## Decisiones ya tomadas (no re-litigar sin motivo)

- **La frontal va por el ISP hardware (PSYS)**, no por el softISP: ~7% de CPU
  contra un pipeline de GPU. Eso obliga al DKMS `ipu6-psys-surface`, al HAL de
  Intel y al perfil `/etc/camera/ipu6/sensors/ov5693-uf.xml`. Consecuencia: la
  frontal es **PSYS-only**; usarla por libcamera sale magenta por la fase
  Bayer del modo binned. Documentado en `REBUILD.es.md` §10.
- **El color sale del tuning OEM de Microsoft** (`.aiqb` del paquete público
  de drivers), decodificado con `tools/decode_aiqb.py`. No inventar curvas:
  los números buenos ya están medidos y validados contra Windows 11.
- **`blackLevel` explícito en los yaml** (1024 en escala de 16 bits, es decir
  pedestal 16 a 10 bits; no el default): el default se comía el pedestal y
  daba magenta en la trasera. Misma clase de bug que el del `.aiqb` en la ruta
  PSYS (black level ÷4).
- **Los tres puentes son bajo demanda**: nada corre mientras ninguna app tiene
  la cámara abierta. Importa de verdad en la IR (el iluminador infrarrojo se
  queda encendido si el puente muere sin hacer STREAMOFF) y en la trasera (el
  diseño viejo con `v4l2-relayd` siempre encendido llegó a 3,3 GB de RAM y 20%
  de CPU generando una imagen negra que nadie miraba). Medido tras el cambio:
  0,000% de CPU y 15 MB en reposo, 30 fps y primera imagen real a 0,3-0,4 s de
  abrir el dispositivo. Los tres comparten el mismo mecanismo: evento
  `V4L2_EVENT_PRI_CLIENT_USAGE` del loopback + gracia de 2-3 s (los
  reproductores abren, sondean, cierran y reabren) + apagado con SIGINT, nunca
  SIGKILL.
- **La IR usa `vts_boost=3448`** (15 fps, 1,78x más brillo medido). Es
  opcional: quitar el fichero de `modprobe.d` vuelve al modo stock sin tocar
  nada más, porque el puente lee los rangos del driver en runtime.

## Trampas que cuestan horas (lista corta; la larga está en REBUILD.es.md)

- **Nunca `kill -9`** a nada que tenga abierto el IPU6, y **nunca** un
  remove/rescan PCI mientras no esté la serie de `ipu-bridge`: deja la máquina
  rota hasta reiniciar.
- Recargar `ov7251` exige desvincular antes (el ISYS lo tiene en uso):
  `echo i2c-INT347E:00 | sudo tee /sys/bus/i2c/drivers/ov7251/unbind`, y luego
  `rmmod`/`modprobe` con los servicios de cámara parados.
- `int3472` sólo encuentra su sensor durante el arranque: **probarlo =
  reiniciar**.
- Para saber si un defecto es del sensor o del software: captura Bayer cruda
  con `tools/camtest.sh` y compara cada columna con sus vecinas **de la misma
  fase**. Mezclar fases lo enmascara todo.
- Al medir "congelado", compara **hashes** de frames: una imagen congelada
  tiene estadísticas perfectamente normales.
- El patrón de test del sensor se inyecta **después** de la etapa de flip y
  ventana: no sirve para diagnosticar fase ni espejo.
- La IR arranca colgada un % de las veces (D-PHY del IPU6, no el sensor): el
  puente lo detecta y reintenta. Si reescribes el puente, **no quites** esa
  lógica (está explicada en `bridges/README.md`).
