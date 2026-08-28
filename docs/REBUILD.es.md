# REPRODUCIR.md — Cámaras Surface Pro 7+ en Linux, de cero
> **Para quien lee esto (humano o IA):** este fichero es la única fuente necesaria
> para dejar funcionando las cámaras de un Surface Pro 7+ (front OV5693, trasera
> OV8865, IR OV7251, IPU6 Tiger Lake PCI 8086:9a19) en una instalación limpia de
> Ubuntu (validado en 24.04 con kernel linux-surface 6.19.8; diseñado para
> migrar a 26.04). Contiene TODO: parches embebidos, scripts completos, tuning
> calibrado, URLs públicas de lo que hay que descargar, y las trampas conocidas.
> Ejecutar en orden. Cada sección dice cómo verificarse.
>
> Último estado (2026-08-27): frontal PERFECTA (color calibrado contra el tuning
> OEM de Microsoft, 1280x720@30 binned, verificada en Teams/Chrome), trasera e IR
> funcionales sin calibrar color, ISP hardware (PSYS) en exploración (sección 10).

## 0. Requisitos y mapa

- Kernel **linux-surface** (https://github.com/linux-surface/linux-surface).
  Las cámaras NO funcionan con el kernel Ubuntu genérico (falta soporte y los
  sensores enumeran por ACPI como OVTI5693/INT347A/INT347E).
- Paquetes: `dkms linux-headers-surface gstreamer1.0-plugins-{base,good,bad}
  build-essential meson ninja-build python3-yaml python3-ply python3-jinja2
  libgnutls28-dev libyaml-dev pkg-config libglib2.0-dev libgstreamer1.0-dev
  libgstreamer-plugins-base1.0-dev libevent-dev v4l-utils`
- Arquitectura final:
  ```
  FRONTAL (ISP hardware, sección 10):
  ov5693 -> IPU6 ISYS (kernel mainline) -> HAL Intel + PSYS (DKMS) ->
        icamerasrc -> surface-psys-bridge -> v4l2loopback /dev/video80
  TRASERA (softISP):
  ov8865 -> IPU6 ISYS -> libcamera (softISP, parcheado) -> libcamerasrc
        -> v4l2-relayd -> v4l2loopback /dev/video82
  IR: ov7251 -> ISYS -> surface-ir-bridge -> /dev/video81
  ```
- ACPI: frontal `\_SB_.PC00.I2C2.CAMF` (OV5693), trasera `\_SB_.PC00.I2C3.CAMR`
  (OV8865), IR `\_SB_.PC00.I2C2.CAMI` (OV7251, media graph aparte).
- **Trampa global**: los WebRTC de apps de escritorio solo sondean
  /dev/video0-63 (linux-surface issue #2242). Con loopbacks en 80-82 solo va
  el navegador. Si se quiere Teams/Zoom nativos: usar números <64.

## 1. linux-headers-surface no trae autoconf.h

`linux-headers-surface` no incluye `include/generated/autoconf.h`; sin él DKMS
no compila nada. Regenerarlo tras CADA kernel nuevo:

```python
# gen_autoconf.py — ejecutar: python3 gen_autoconf.py (como root)
import sys,re
src=sys.argv[1]; dst=sys.argv[2]
out=["/*","  * Automatically generated file; DO NOT EDIT.","  */","#define __KCONFIG_H__ 1",""]
out=["/* Automatically generated - do not edit */"]
for line in open(src):
    line=line.strip()
    if not line or line.startswith('#'): continue
    if '=' not in line: continue
    k,v=line.split('=',1)
    if not k.startswith('CONFIG_'): continue
    if v=='y': out.append(f"#define {k} 1")
    elif v=='m': out.append(f"#define {k}_MODULE 1")
    elif v.startswith('"'): out.append(f"#define {k} {v}")
    elif v=="": out.append(f"#define {k} \"\"")
    else: out.append(f"#define {k} {v}")
open(dst,'w').write("\n".join(out)+"\n")
print("wrote",dst,len(out),"lines")
```

## 2. Driver del sensor frontal OV5693 (DKMS) — LA PIEZA CLAVE

Partir del `drivers/media/i2c/ov5693.c` de mainline v6.19 y aplicar el diff
embebido abajo. Qué hace y POR QUÉ (todo descubierto a base de sangre):

- **HID ACPI**: mainline solo matchea INT33BE; el Surface enumera OVTI5693.
- **0x4800=0x2d (MIPI_CTRL00)** en stream-on: sin él, la CSI-2 no engancha
  nunca (línea en negro). Es el fix del PR linux-surface #2171.
- **Modo binned 1296x972** (el que usa Windows para 720p/1080p): 2x2 binning =
  4x luz por píxel (2 stops). Sin esto la imagen tiene un ruido brutal
  (ganancia analógica 127 vs 15). Requiere TODO esto a la vez:
  * PLL MIPI por modo: 0x30b3=0x70 binned / 0x83 full. Solo cambiar el PLL
    pasa el error de "Transfer FIFO overflow" a "Frame sync error" pero sigue
    negro.
  * **Geometría**: el crop exacto sin margen ROMPE el ISP del sensor (Frame
    sync error perpetuo). Solución: crop de array completo (0,0)-(2623,1955) +
    offsets de ventana ISP X=8, **Y=2**. El offset Y tiene que ser PAR: impar
    invierte la fase Bayer (imagen magenta/verde). Windows usa Y=3 pero su
    pipeline lee otra fase.
  * Registros analógicos por modo (3600/3620/21/22, 3708/09, 371f): valores
    extraídos del driver de Windows (ov5693.sys del MSI de Surface, tablas con
    windows-driver/extract_tables.py del repo ~/camara si está disponible).
  * VTS: cap a 30fps en binned (VTS 60fps=1038 no cabe con el PLL binned).
  * **Flip vertical**: en binned solo el bit SENSOR (0x3820 bit1); los dos bits
    a la vez rompen el framing CSI-2, y solo el bit ISP escupe imagen SIN
    voltear (te ves boca abajo).
- HTS 2688, VTS base 1984 (matcha Windows binned).

```diff
--- /tmp/claude-1000/ov5693-mainline.c	2026-08-27 00:05:02.151496465 +0200
+++ ov5693-fix/ov5693.c	2026-08-26 19:49:11.546795874 +0200
@@ -110,6 +110,10 @@
 #define OV5693_MIN_CROP_WIDTH			2
 #define OV5693_MIN_CROP_HEIGHT			2
 
+/* MIPI control */
+#define OV5693_MIPI_CTRL00_REG			CCI_REG8(0x4800)
+#define OV5693_MIPI_CTRL00_IPU6			0x2d
+
 /* Test Pattern */
 #define OV5693_TEST_PATTERN_REG			CCI_REG8(0x5e00)
 #define OV5693_TEST_PATTERN_ENABLE		BIT(7)
@@ -353,15 +357,36 @@
 
 /* V4L2 Controls Functions */
 
+/*
+ * Which FORMAT1 bits express a vertical flip depends on the readout mode.
+ *
+ * At full resolution both the sensor-side and the ISP-side bit are used, as
+ * the datasheet describes. With 2x2 binning, setting both corrupts the CSI-2
+ * framing: an IPU6 receiver reports "Frame sync error" on every frame and no
+ * data arrives at all. The ISP bit alone streams cleanly but does not
+ * actually flip the picture, so the sensor-side bit alone is the one that
+ * both streams and flips. It also inverts the vertical Bayer phase, which
+ * the even ISP window offset in ov5693_mode_configure() keeps in place --
+ * measured on a Surface Pro 7+ against the full-resolution orientation.
+ */
+static u8 ov5693_flip_vert_bits(struct ov5693_device *ov5693)
+{
+	if (ov5693->mode.binning_y)
+		return OV5693_FORMAT1_FLIP_VERT_SENSOR_EN;
+
+	return OV5693_FORMAT1_FLIP_VERT_ISP_EN |
+	       OV5693_FORMAT1_FLIP_VERT_SENSOR_EN;
+}
+
 static int ov5693_flip_vert_configure(struct ov5693_device *ov5693,
 				      bool enable)
 {
-	u8 bits = OV5693_FORMAT1_FLIP_VERT_ISP_EN |
+	u8 mask = OV5693_FORMAT1_FLIP_VERT_ISP_EN |
 		  OV5693_FORMAT1_FLIP_VERT_SENSOR_EN;
 	int ret;
 
-	ret = cci_update_bits(ov5693->regmap, OV5693_FORMAT1_REG, bits,
-			      enable ? bits : 0, NULL);
+	ret = cci_update_bits(ov5693->regmap, OV5693_FORMAT1_REG, mask,
+			      enable ? ov5693_flip_vert_bits(ov5693) : 0, NULL);
 	if (ret)
 		return ret;
 
@@ -549,17 +574,73 @@
 
 /* System Control Functions */
 
+/*
+ * Registers the vendor (Windows) driver programs differently for the full
+ * resolution and the 2x2 binned readout, taken from the mode tables in
+ * ov5693.sys.
+ *
+ * The mainline driver writes only the full-resolution values, once, from
+ * ov5693_global_regs, and never revisits them. Selecting the binned mode
+ * therefore leaves the sensor with a MIPI PLL multiplier (0x30b3) and
+ * analogue readout timing meant for twice the line length. On an IPU6 the
+ * receiver then reports "Transfer FIFO overflow" and every frame arrives
+ * empty, which is why the binned mode has been unusable -- and why the
+ * sensor has had to be read at full resolution and downscaled, costing two
+ * stops of light and forcing the AGC to its maximum analogue gain.
+ */
+static const struct cci_reg_sequence ov5693_mode_full_regs[] = {
+	{CCI_REG8(0x30b3), 0x83},	/* MIPI PLL multiplier */
+	{CCI_REG8(0x3620), 0x54},
+	{CCI_REG8(0x3621), 0xc7},
+	{CCI_REG8(0x3622), 0x0f},
+	{CCI_REG8(0x3708), 0xe2},
+	{CCI_REG8(0x3709), 0xc3},
+	{CCI_REG8(0x371f), 0x0c},
+};
+
+static const struct cci_reg_sequence ov5693_mode_binned_regs[] = {
+	{CCI_REG8(0x30b3), 0x70},	/* MIPI PLL multiplier */
+	{CCI_REG8(0x3600), 0xbc},	/* analogue, vendor sets it binned-only */
+	{CCI_REG8(0x3620), 0x44},
+	{CCI_REG8(0x3621), 0xb5},
+	{CCI_REG8(0x3622), 0x0c},
+	{CCI_REG8(0x3708), 0xe6},
+	{CCI_REG8(0x3709), 0xc7},
+	{CCI_REG8(0x371f), 0x1f},
+};
+
 static int ov5693_mode_configure(struct ov5693_device *ov5693)
 {
 	const struct ov5693_mode *mode = &ov5693->mode;
+	bool binned = mode->binning_x || mode->binning_y;
 	int ret = 0;
 
+	/*
+	 * Readout geometry. At full resolution this is the crop rectangle
+	 * selected over the media API, with the sensor-ISP window offsets at
+	 * zero.
+	 *
+	 * The binned mode instead copies the vendor driver: read the whole
+	 * pixel array (0..2623 x 0..1955), bin it to 1312x978, and let the
+	 * ISP window offsets place the 1296x972 output inside that. The
+	 * vertical offset is 2 rather than the vendor's 3: an odd offset
+	 * shifts the Bayer phase by one row (everything decodes magenta and
+	 * green); the vendor ISP knows the resulting phase, a V4L2 receiver
+	 * assumes it unchanged. The
+	 * obvious alternative -- keeping the 2592x1944 crop so the binned
+	 * readout exactly equals the output size with zero offset -- leaves
+	 * the sensor ISP without spare pixels around the window, and the
+	 * frames it emits then fail CSI-2 framing ("Frame sync error" on the
+	 * IPU6, no frame ever completes).
+	 */
+
 	/* Crop Start X */
-	cci_write(ov5693->regmap, OV5693_CROP_START_X_REG, mode->crop.left,
-		  &ret);
+	cci_write(ov5693->regmap, OV5693_CROP_START_X_REG,
+		  binned ? 0 : mode->crop.left, &ret);
 
 	/* Offset X */
-	cci_write(ov5693->regmap, OV5693_OFFSET_START_X_REG, 0, &ret);
+	cci_write(ov5693->regmap, OV5693_OFFSET_START_X_REG,
+		  binned ? 8 : 0, &ret);
 
 	/* Output Size X */
 	cci_write(ov5693->regmap, OV5693_OUTPUT_SIZE_X_REG, mode->format.width,
@@ -567,18 +648,20 @@
 
 	/* Crop End X */
 	cci_write(ov5693->regmap, OV5693_CROP_END_X_REG,
-		  mode->crop.left + mode->crop.width, &ret);
+		  binned ? OV5693_NATIVE_WIDTH - 1 :
+			   mode->crop.left + mode->crop.width, &ret);
 
 	/* Horizontal Total Size */
 	cci_write(ov5693->regmap, OV5693_TIMING_HTS_REG, OV5693_FIXED_PPL,
 		  &ret);
 
 	/* Crop Start Y */
-	cci_write(ov5693->regmap, OV5693_CROP_START_Y_REG, mode->crop.top,
-		  &ret);
+	cci_write(ov5693->regmap, OV5693_CROP_START_Y_REG,
+		  binned ? 0 : mode->crop.top, &ret);
 
 	/* Offset Y */
-	cci_write(ov5693->regmap, OV5693_OFFSET_START_Y_REG, 0, &ret);
+	cci_write(ov5693->regmap, OV5693_OFFSET_START_Y_REG,
+		  binned ? 2 : 0, &ret);
 
 	/* Output Size Y */
 	cci_write(ov5693->regmap, OV5693_OUTPUT_SIZE_Y_REG, mode->format.height,
@@ -586,7 +669,8 @@
 
 	/* Crop End Y */
 	cci_write(ov5693->regmap, OV5693_CROP_END_Y_REG,
-		  mode->crop.top + mode->crop.height, &ret);
+		  binned ? OV5693_NATIVE_HEIGHT - 1 :
+			   mode->crop.top + mode->crop.height, &ret);
 
 	/* Subsample X increase */
 	cci_write(ov5693->regmap, OV5693_SUB_INC_X_REG,
@@ -604,6 +688,24 @@
 			OV5693_FORMAT2_HBIN_EN,
 			mode->binning_x ? OV5693_FORMAT2_HBIN_EN : 0, &ret);
 
+	/*
+	 * The set of FORMAT1 bits that means "vertical flip" changes with the
+	 * readout mode, so re-apply the control now that binning is known.
+	 */
+	if (ov5693->ctrls.vflip && ov5693->ctrls.vflip->val)
+		cci_update_bits(ov5693->regmap, OV5693_FORMAT1_REG,
+				OV5693_FORMAT1_FLIP_VERT_ISP_EN |
+				OV5693_FORMAT1_FLIP_VERT_SENSOR_EN,
+				ov5693_flip_vert_bits(ov5693), &ret);
+
+	/* PLL and analogue readout timing follow the readout mode. */
+	if (mode->binning_x || mode->binning_y)
+		cci_multi_reg_write(ov5693->regmap, ov5693_mode_binned_regs,
+				    ARRAY_SIZE(ov5693_mode_binned_regs), &ret);
+	else
+		cci_multi_reg_write(ov5693->regmap, ov5693_mode_full_regs,
+				    ARRAY_SIZE(ov5693_mode_full_regs), &ret);
+
 	return ret;
 }
 
@@ -611,6 +713,18 @@
 {
 	int ret = 0;
 
+	/*
+	 * Program MIPI_CTRL00 (CSI-2 clock-lane control) before starting the
+	 * stream. The 0x00 power-on default is accepted by the IPU3 ISP but
+	 * leaves the IPU6 D-PHY (Surface Pro 7+/8/9) unable to lock onto the
+	 * link: the sensor streams yet the receiver gets no CSI-2 data and
+	 * capture times out. 0x2d matches the value the vendor (Windows)
+	 * driver writes and lets the IPU6 receive frames.
+	 */
+	if (enable)
+		cci_write(ov5693->regmap, OV5693_MIPI_CTRL00_REG,
+			  OV5693_MIPI_CTRL00_IPU6, &ret);
+
 	cci_write(ov5693->regmap, OV5693_SW_STREAM_REG,
 		  enable ? OV5693_START_STREAMING : OV5693_STOP_STREAMING,
 		  &ret);
@@ -762,6 +876,16 @@
 
 	tgt_fps = rounddown(OV5693_PIXEL_RATE / OV5693_FIXED_PPL / height, 30);
 
+	/*
+	 * Cap at 30fps. Left alone this picks 60fps for the 2x2 binned mode,
+	 * which halves VTS to 1038 -- and the binned readout runs off a slower
+	 * MIPI PLL (0x30b3), so the link cannot carry twice the frame rate:
+	 * the IPU6 reports "Frame sync error" and no frame ever completes. The
+	 * vendor driver runs the same mode at VTS 1984. Staying at 30fps also
+	 * keeps the exposure ceiling, which is VTS bound, where it was.
+	 */
+	tgt_fps = min(tgt_fps, 30U);
+
 	return ALIGN_DOWN(OV5693_PIXEL_RATE / OV5693_FIXED_PPL / tgt_fps, 2);
 }
 
```

dkms.conf (paquete ov5693-surface/1.0):
```
PACKAGE_NAME="ov5693-surface"
PACKAGE_VERSION="1.0"
BUILT_MODULE_NAME[0]="ov5693"
DEST_MODULE_LOCATION[0]="/updates"
AUTOINSTALL="yes"
BUILD_DIR="${dkms_tree}/${PACKAGE_NAME}/${PACKAGE_VERSION}/build"
MAKE[0]="make -C ${kernel_source_dir} M=${BUILD_DIR} modules"
CLEAN="make -C ${kernel_source_dir} M=${BUILD_DIR} clean"
```

Instalar: copiar ov5693.c+Makefile+dkms.conf a /usr/src/ov5693-surface-1.0/,
`dkms add/build/install ov5693-surface/1.0`. Makefile mínimo:
`obj-m += ov5693.o`.
Verificar: `sudo dmesg | grep ov5693` → probe sin errores; el ov5693 mainline
queda sustituido por el de /updates.

## 3. Drivers IR (OV7251) e int3472 (DKMS)

**OV7251** (cámara IR, para Howdy o visor): mismo esquema DKMS
(ov7251-surface). Diff vs mainline v6.19:

```diff
--- /tmp/claude-1000/ov7251-mainline.c	2026-08-27 00:06:13.388214366 +0200
+++ ov7251-fix/ov7251.c	2026-08-26 00:36:54.851075642 +0200
@@ -23,6 +23,30 @@
 #include <media/v4l2-fwnode.h>
 #include <media/v4l2-subdev.h>
 
+/*
+ * The Windows-Hello IR illuminator hangs off the sensor's strobe output.
+ * Nothing in ACPI describes it -- the INT3472 for this camera declares only a
+ * power-enable and a reset GPIO -- so without programming it here the sensor
+ * sees a completely black scene: the module sits behind an IR-pass filter and
+ * room lighting emits next to nothing in the infrared.
+ *
+ * Two registers matter, both read out of the mode tables in the vendor's
+ * ov7251.sys:
+ *
+ *   0x3005  pad output value; 0x08 routes the strobe to the illuminator.
+ *   0x3b81  strobe pattern, one bit per frame. The vendor writes 0xff for its
+ *           illuminated modes and 0xa5 for the rest. 0xa5 is 10100101, so the
+ *           illuminator fires on half the frames: the LED blinks visibly and
+ *           every second frame comes out black. This driver's global init
+ *           programs 0xa5, hence the need to override it.
+ */
+#define OV7251_PAD_OUT1			0x3005
+#define OV7251_PAD_OUT1_IR_LED		0x08
+#define OV7251_STROBE_PATTERN		0x3b81
+#define OV7251_STROBE_EVERY_FRAME	0xff
+#define OV7251_STROBE_HALF_FRAMES	0xa5
+
+
 #define OV7251_SC_MODE_SELECT		0x0100
 #define OV7251_SC_MODE_SELECT_SW_STANDBY	0x0
 #define OV7251_SC_MODE_SELECT_STREAMING		0x1
@@ -1053,7 +1077,7 @@
 	case V4L2_CID_EXPOSURE:
 		ret = ov7251_set_exposure(ov7251, ctrl->val);
 		break;
-	case V4L2_CID_GAIN:
+	case V4L2_CID_ANALOGUE_GAIN:
 		ret = ov7251_set_gain(ov7251, ctrl->val);
 		break;
 	case V4L2_CID_TEST_PATTERN:
@@ -1334,6 +1358,36 @@
 	return 0;
 }
 
+static int ir_led = -1;
+module_param(ir_led, int, 0644);
+MODULE_PARM_DESC(ir_led,
+		 "IR illuminator while streaming: -1 auto (on for ACPI INT347E), 0 off, 1 on");
+
+static bool ov7251_has_ir_led(struct ov7251 *ov7251)
+{
+	if (ir_led >= 0)
+		return ir_led;
+
+	return acpi_dev_hid_uid_match(ACPI_COMPANION(ov7251->dev), "INT347E", NULL);
+}
+
+static int ov7251_ir_led_set(struct ov7251 *ov7251, bool on)
+{
+	int ret;
+
+	if (!ov7251_has_ir_led(ov7251))
+		return 0;
+
+	ret = ov7251_write_reg(ov7251, OV7251_PAD_OUT1,
+			       on ? OV7251_PAD_OUT1_IR_LED : 0);
+	if (ret)
+		return ret;
+
+	return ov7251_write_reg(ov7251, OV7251_STROBE_PATTERN,
+				on ? OV7251_STROBE_EVERY_FRAME :
+				     OV7251_STROBE_HALF_FRAMES);
+}
+
 static int ov7251_s_stream(struct v4l2_subdev *subdev, int enable)
 {
 	struct ov7251 *ov7251 = to_ov7251(subdev);
@@ -1372,7 +1426,13 @@
 				       OV7251_SC_MODE_SELECT_STREAMING);
 		if (ret)
 			goto err_power_down;
+
+		ret = ov7251_ir_led_set(ov7251, true);
+		if (ret)
+			goto err_power_down;
 	} else {
+		ov7251_ir_led_set(ov7251, false);
+
 		ret = ov7251_write_reg(ov7251, OV7251_SC_MODE_SELECT,
 				       OV7251_SC_MODE_SELECT_SW_STANDBY);
 		pm_runtime_put(ov7251->dev);
@@ -1579,7 +1639,7 @@
 	ov7251->exposure = v4l2_ctrl_new_std(&ov7251->ctrls, &ov7251_ctrl_ops,
 					     V4L2_CID_EXPOSURE, 1, 32, 1, 32);
 	ov7251->gain = v4l2_ctrl_new_std(&ov7251->ctrls, &ov7251_ctrl_ops,
-					 V4L2_CID_GAIN, 16, 1023, 1, 16);
+					 V4L2_CID_ANALOGUE_GAIN, 16, 1023, 1, 16);
 	v4l2_ctrl_new_std_menu_items(&ov7251->ctrls, &ov7251_ctrl_ops,
 				     V4L2_CID_TEST_PATTERN,
 				     ARRAY_SIZE(ov7251_test_pattern_menu) - 1,
```

**int3472** (el glue ACPI de alimentación de los sensores): parche necesario
para que la trasera OV8865 y la IR OV7251 reciban sus reguladores. El enfoque
para la OV8865 es ahora el del parche upstream de Jakob Berg Jespersen
"[PATCH v2] platform/x86: int3472: support the POWER1 GPIO type"
(msgid `20260729-sp7plus-int3472-v2-1-cdfaf97ac3ad@berg.pm`, enviado a
platform-driver-x86, Suggested-by: Sakari Ailus): define los tipos de GPIO
POWER0 (0x07) y POWER1 (0x08) y mapea POWER1 a un regulador con con_id
"dvdd" GENÉRICAMENTE (sin quirk por HID); es lo que previsiblemente acabará
en mainline. Encima conservamos NUESTRA parte para la IR (INT347E →
power-enable con con_id "vdda"), que su parche no cubre, y el parámetro de
módulo `ov8865_pwr1_con_id` como override opcional del con_id de POWER1
(default "dvdd", compatible con lo documentado antes). Trampa descubierta:
`GPIO_SUPPLY_NAME_LENGTH` = 5 (4 chars máx): "dovdd" NO cabe, por eso
POWER1 mapea a "dvdd". El int3472 solo enumera su sensor EN EL ARRANQUE:
cada prueba = reiniciar. Diff vs mainline v6.19
(drivers/platform/x86/intel/int3472/; también en
publish/surface-ipu6-cameras/patches/int3472-surface-sensors.patch):

```diff
--- a/drivers/platform/x86/intel/int3472/discrete.c
+++ b/drivers/platform/x86/intel/int3472/discrete.c
@@ -157,6 +157,20 @@
 		.type_to = INT3472_GPIO_TYPE_RESET,
 		.con_id = "enable",
 	},
+	{	/*
+		 * Surface Pro 7+ (and other IPU6 designs) wire the OV7251's
+		 * single gated rail to the INT3472 power-enable GPIO, but the
+		 * ov7251 driver / DT-bindings name their supplies vdda, vddd
+		 * and vdddo. Without this the regulator is registered as
+		 * "avdd", the driver finds no supply at all, and the sensor is
+		 * never powered: probe dies on the first I2C write with -121.
+		 */
+		.hid = "INT347E",
+		.type_from = INT3472_GPIO_TYPE_POWER_ENABLE,
+		.type_to = INT3472_GPIO_TYPE_POWER_ENABLE,
+		.con_id = "vdda",
+		.enable_time_us = GPIO_REGULATOR_ENABLE_TIME,
+	},
 	{	/* ov08x40's handshake pin needs a 45 ms delay on some HP laptops */
 		.hid = "OVTI08F4",
 		.type_from = INT3472_GPIO_TYPE_HANDSHAKE,
@@ -166,6 +180,40 @@
 	},
 };
 
+/*
+ * POWER0 (0x07) / POWER1 (0x08) GPIO types. Not yet defined in the v6.19
+ * header (include/linux/platform_data/x86/int3472.h); POWER1 describes a
+ * second sensor power rail, mapped generically to a regulator with con_id
+ * "dvdd" (the supply the in-tree ov8865 driver requests). On the Surface
+ * Pro 7+ the rear camera's INT3472 (INT347A, ov8865) has such a pin;
+ * without it "dvdd" resolves to a dummy regulator, the first I2C write
+ * dies with -121 and the sensor never probes. POWER0 is defined but left
+ * unmapped, as no device that uses it is known.
+ *
+ * Based on Jakob Berg Jespersen's upstream patch
+ * "[PATCH v2] platform/x86: int3472: support the POWER1 GPIO type"
+ * <20260729-sp7plus-int3472-v2-1-cdfaf97ac3ad@berg.pm>
+ * (Suggested-by: Sakari Ailus).
+ */
+#ifndef INT3472_GPIO_TYPE_POWER0
+#define INT3472_GPIO_TYPE_POWER0				0x07
+#endif
+#ifndef INT3472_GPIO_TYPE_POWER1
+#define INT3472_GPIO_TYPE_POWER1				0x08
+#endif
+
+/*
+ * Optional override kept for compatibility with earlier revisions of this
+ * DKMS package, which mapped the OV8865's POWER1 pin per-HID with a
+ * settable supply name. The default follows Jespersen's generic mapping
+ * ("dvdd"). Note that GPIO_SUPPLY_NAME_LENGTH is 5, so "dovdd" -- the
+ * other candidate -- does not even fit.
+ */
+static char *ov8865_pwr1_con_id = "dvdd";
+module_param(ov8865_pwr1_con_id, charp, 0644);
+MODULE_PARM_DESC(ov8865_pwr1_con_id,
+		 "supply name for the POWER1 (type 0x08) GPIO regulator (default: dvdd)");
+
 static void int3472_get_con_id_and_polarity(struct int3472_discrete_device *int3472, u8 *type,
 					    const char **con_id, unsigned long *gpio_flags,
 					    unsigned int *enable_time_us)
@@ -223,6 +271,10 @@
 		*con_id = "avdd";
 		*gpio_flags = GPIO_ACTIVE_HIGH;
 		break;
+	case INT3472_GPIO_TYPE_POWER1:
+		*con_id = ov8865_pwr1_con_id;
+		*gpio_flags = GPIO_ACTIVE_HIGH;
+		break;
 	case INT3472_GPIO_TYPE_HANDSHAKE:
 		*con_id = "dvdd";
 		*gpio_flags = GPIO_ACTIVE_HIGH;
@@ -248,6 +300,8 @@
  *
  * 0x00 Reset
  * 0x01 Power down
+ * 0x07 Power 0
+ * 0x08 Power 1
  * 0x0b Power enable
  * 0x0c Clock enable
  * 0x0d Privacy LED
@@ -332,6 +386,7 @@
 	case INT3472_GPIO_TYPE_CLK_ENABLE:
 	case INT3472_GPIO_TYPE_PRIVACY_LED:
 	case INT3472_GPIO_TYPE_POWER_ENABLE:
+	case INT3472_GPIO_TYPE_POWER1:
 	case INT3472_GPIO_TYPE_HANDSHAKE:
 		gpio = skl_int3472_gpiod_get_from_temp_lookup(int3472, agpio, con_id, gpio_flags);
 		if (IS_ERR(gpio)) {
@@ -356,6 +411,7 @@
 		case INT3472_GPIO_TYPE_POWER_ENABLE:
 			second_sensor = int3472->quirks.avdd_second_sensor;
 			fallthrough;
+		case INT3472_GPIO_TYPE_POWER1:
 		case INT3472_GPIO_TYPE_HANDSHAKE:
 			ret = skl_int3472_register_regulator(int3472, gpio, enable_time_us,
 							     con_id, second_sensor);
```

El OV8865 usa el driver mainline SIN tocar.

## 4. v4l2loopback y v4l2-relayd

- **v4l2loopback**: el de Ubuntu no compila con kernel 6.19 → usar master de
  https://github.com/umlaeute/v4l2loopback (DKMS, v0.15.4+ vale).
  `/etc/modules-load.d/v4l2loopback-surface.conf` → `v4l2loopback`
  `/etc/modprobe.d/` → `options v4l2loopback max_buffers=4`
- **v4l2-relayd**: https://github.com/9elements/v4l2-relayd + este parche
  (el publicado escucha el evento equivocado: V4L2_EVENT_PRIVATE_START en vez
  de 0x10E00001):

```diff
diff --git a/src/v4l2-relayd.c b/src/v4l2-relayd.c
index a3b1a1d..9c3d1f2 100644
--- a/src/v4l2-relayd.c
+++ b/src/v4l2-relayd.c
@@ -28,7 +28,8 @@
 #include <gst/app/gstappsrc.h>
 #include <gst/video/video-info.h>
 
-#define V4L2_EVENT_PRI_CLIENT_USAGE  V4L2_EVENT_PRIVATE_START
+#define V4L2LOOPBACK_EVENT_OFFSET    0x08E00000
+#define V4L2_EVENT_PRI_CLIENT_USAGE  (V4L2_EVENT_PRIVATE_START + V4L2LOOPBACK_EVENT_OFFSET + 1)
 
 struct v4l2_event_client_usage {
   __u32 count;
```

Compilar (autotools) e instalar en /usr/local/bin/v4l2-relayd.

**Trampas de loopback (NO repetir):**
- NO usar `v4l2loopback-ctl set-caps`: el device pasa a anunciar CAPTURE a
  todos y el productor ya no puede abrirlo.
- NO hacer S_FMT en el loopback cuando el cliente ya negoció: EBUSY en bucle.
- El splash por defecto de v4l2-relayd (PNG 16x16 con imagefreeze
  num-buffers=2) SE AGOTA y el appsrc compartido no se recupera (pantalla
  negra para siempre) → splash vivo con videotestsrc (ver script sección 6).

## 5. libcamera con parches locales

Clonar https://git.libcamera.org/libcamera/libcamera.git y aplicar el parche
embebido (2 cambios, AMBOS imprescindibles, candidatos a upstream):

1. **awb.h — quitar el clamp de ganancia >=1.0**: los ISP hardware no atenúan
   y libcamera hereda ese suelo, pero el softISP multiplica en shader y este
   módulo NECESITA ganancia de rojo <1 en tungsteno (el tuning OEM de
   Microsoft lo confirma: r_gain=0.87 @2592K). Con el clamp todo sale verde.
2. **softisp agc — parámetro de tuning `exposureOptimal`**: el AGC del softISP
   (algoritmo MSV) lleva el objetivo 2.5 cableado; recorta paredes a 255 y las
   estadísticas recortadas envenenan el AWB. Con el parámetro se baja a 2.1.

```diff
diff --git a/src/ipa/libipa/awb.h b/src/ipa/libipa/awb.h
index d35a851..74411dc 100644
--- a/src/ipa/libipa/awb.h
+++ b/src/ipa/libipa/awb.h
@@ -117,7 +117,18 @@ public:
 	{
 		AwbAlgorithmBase::init(tuningData);
 
-		gainMin_ = std::max(Q::TraitsType::min, 1.0f);
+		/*
+		 * Hardware ISPs generally cannot attenuate a channel, hence
+		 * the historical floor of 1.0 -- but the software ISP
+		 * multiplies in a shader and attenuates just fine, and some
+		 * modules genuinely need it: the Surface Pro 7+ OV5693 sees
+		 * ~68% more red relative to green than its lens-shading
+		 * siblings, so a correct white balance needs a red gain well
+		 * below 1.0 at every daylight temperature. With the floor in
+		 * place every scene rendered green. Trust the numeric range
+		 * of the gain type instead, with a small safety floor.
+		 */
+		gainMin_ = std::max(Q::TraitsType::min, 1.0f / 16);
 		gainMax_ = Q::TraitsType::max;
 
 		controls_[&controls::ColourGains] =
diff --git a/src/ipa/softisp/algorithms/agc.cpp b/src/ipa/softisp/algorithms/agc.cpp
index 63b4154..d1b6a68 100644
--- a/src/ipa/softisp/algorithms/agc.cpp
+++ b/src/ipa/softisp/algorithms/agc.cpp
@@ -65,12 +65,27 @@ Agc::Agc()
 {
 }
 
+int Agc::init([[maybe_unused]] IPAContext &context, const ValueNode &tuningData)
+{
+	/*
+	 * The MSV the loop drives towards. The 2.5 default centres the
+	 * histogram, which on a scene with a bright background behind a dark
+	 * foreground (a person in front of a lit wall -- this camera's usual
+	 * view) runs hot enough to clip the background, and clipped highlights
+	 * also poison the AWB statistics. Tuning files can lower it.
+	 */
+	exposureOptimal_ =
+		tuningData["exposureOptimal"].get<double>(kExposureOptimal);
+
+	return 0;
+}
+
 void Agc::updateExposure(IPAContext &context, IPAFrameContext &frameContext, double exposureMSV)
 {
 	int32_t &exposure = frameContext.sensor.exposure;
 	double &again = frameContext.sensor.gain;
 
-	double error = kExposureOptimal - exposureMSV;
+	double error = exposureOptimal_ - exposureMSV;
 
 	if (std::abs(error) <= kExposureSatisfactory)
 		return;
diff --git a/src/ipa/softisp/algorithms/agc.h b/src/ipa/softisp/algorithms/agc.h
index 3694461..8cf35b5 100644
--- a/src/ipa/softisp/algorithms/agc.h
+++ b/src/ipa/softisp/algorithms/agc.h
@@ -19,6 +19,7 @@ public:
 	Agc();
 	~Agc() = default;
 
+	int init(IPAContext &context, const ValueNode &tuningData) override;
 	void process(IPAContext &context, const uint32_t frame,
 		     IPAFrameContext &frameContext,
 		     const SwIspStats *stats,
@@ -26,6 +27,8 @@ public:
 
 private:
 	void updateExposure(IPAContext &context, IPAFrameContext &frameContext, double exposureMSV);
+
+	float exposureOptimal_;
 };
 
 } /* namespace ipa::softisp::algorithms */
```

Compilar: `meson setup build && ninja -C build && sudo ninja -C build install`
(instala en /usr/local). **Si se recompila/actualiza libcamera, reaplicar
estos parches** — sin ellos el color se rompe en silencio.

Detalles del softISP que condicionan todo (aprendidos a golpes):
- El pipeline "simple" NO implementa SensorConfiguration: la propiedad
  sensor-config de libcamerasrc es un NO-OP. El modo del sensor se elige por
  el TAMAÑO pedido: pedir <=1292 de ancho → modo binned 1296 (el debayer roba
  un borde de 2px por lado).
- El softISP a 1920 de ancho mete una columna oscura en x=1211 (bug
  determinista). El mismo resampler GPU mete FILAS magenta de 1px en
  posiciones que dependen del ANCHO del render (1600 → filas 371 y 771;
  1568 → 483 y 875; independientes de la altura); con el CCM calibrado se
  ven rojas. A 1596 de ancho no hay ninguna → la trasera renderiza
  1596x896. Además la fila 0 y la columna 0 del debayer salen magenta
  (fase Bayer incompleta): se recortan 2px por lado con videocrop
  (post-debayer, no afecta a la calibración).
- AWB bayes exige en el yaml: colourGains {ct,gains}, priors, y AwbMode como
  DICCIONARIO (clave = nombre del control, singular) incluyendo AwbAuto.

## 6. El tuning de color (ov5693.yaml) — CALIBRADO, copiar tal cual

Instalar en `/usr/local/share/libcamera/ipa/softisp/ov5693.yaml`. Procedencia:
curva AWB y CCMs del **tuning OEM de Microsoft** (sección 9), anclado a la
unidad física contra el render de W11 de la misma escena (pared blanca G/R
0.965 G/B 1.006; saturación de cortina 0.639). Métricas finales conseguidas:
pared 0.976/1.007, saturación 0.648.

```yaml
# SPDX-License-Identifier: CC0-1.0
#
# Colour tuning for the OV5693 as wired on the Surface Pro 7+.
#
# The colour correction matrices are Raspberry Pi's measured OV5647 set
# (libcamera src/ipa/rpi/vc4/data/ov5647.json). The OV5647 is not this
# sensor, but it is the closest thing anyone has published: same vendor,
# same 5 MP generation, same 2592x1944 Bayer array. Borrowing its CCMs is
# an approximation -- the colour filter dyes and the module's IR-cut filter
# are not identical -- but it is a far better starting point than what
# libcamera falls back to without a tuning file, which is no colour
# correction at all.
#
# Awb has no colourGains curve here on purpose. The grey-world algorithm
# estimates the colour temperature straight from the frame
# (AwbGrey::estimateCCT), which is what the Ccm interpolation needs; the
# curve only feeds the manual-colour-temperature control, and a curve
# borrowed from a different sensor would make that worse, not better.
%YAML 1.1
---
version: 1
algorithms:
  - BlackLevel:
  # Bayesian AWB instead of the grey-world default. Grey world assumes the
  # scene averages to neutral, which this camera's usual scene (a person, a
  # wall, one dominant colour) rarely does -- a red curtain filling half the
  # frame pushed everything cyan/green. The bayes search constrains the gains
  # to the colour-temperature curve below.
  #
  # colourGains: derived from THIS module's OEM tuning. Microsoft ships the
  # Intel .aiqb calibration (OV5693_MSHW0220_TGL.aiqb) inside the public
  # Surface Pro 7+ driver MSI; the advanced-color-matrix record stores, per
  # illuminant (A/F4/F11/F2/D50/D65/D75), the sensor white point as R/G,B/G
  # chromaticity. Gains are the reciprocals; CT comes from the record's CIE
  # coordinates (McCamy). See w11-ref/aiqb-real/decode_aiqb.py.
  # The whole curve is then scaled per-channel (r x1.20, b x1.08 net) to this
  # PHYSICAL unit, anchored on a white wall under the room's ceiling light,
  # matched to how the Windows stack renders the same wall (G/R=0.965,
  # G/B=1.006). Note the tungsten red gain sits below 1.0 -- that is why the
  # gainMin_ patch in libcamera's src/ipa/libipa/awb.h is required.
  - Awb:
      algorithm: bayes
      colourGains:
        - ct: 2592
          gains: [ 1.037, 2.790 ]
        - ct: 2773
          gains: [ 1.237, 2.689 ]
        - ct: 3716
          gains: [ 1.590, 2.192 ]
        - ct: 3763
          gains: [ 1.645, 2.171 ]
        - ct: 4877
          gains: [ 1.727, 1.740 ]
        - ct: 5894
          gains: [ 1.960, 1.573 ]
        - ct: 6905
          gains: [ 2.151, 1.452 ]
      transversePos: 0.03
      transverseNeg: 0.03
      priors:
        - lux: 0
          ct: [ 2000, 13000 ]
          probability: [ 1.0, 1.0 ]
      # CT search ranges per V4L2 AWB mode; bayes refuses to start without
      # them (the tuning key is the control name "AwbMode"), and AwbAuto is the default the wrapper registers. Bounds stay
      # inside the colourGains span (2500..8625) so every mode lands on the
      # measured part of the curve.
      AwbMode:
        AwbAuto:
          lo: 2592
          hi: 6905
        AwbIncandescent:
          lo: 2500
          hi: 3000
        AwbTungsten:
          lo: 3000
          hi: 3500
        AwbFluorescent:
          lo: 4000
          hi: 4700
        AwbDaylight:
          lo: 5500
          hi: 6500
        AwbCloudy:
          lo: 7000
          hi: 8500
  # CCMs: the OEM 'traditional' matrices from the same .aiqb record, one per
  # illuminant, then globally strengthened x1.28 toward saturation (extrapolated
  # blend M'=K*M+(1-K)*I, rows still sum to 1) because the Windows pipeline adds
  # saturation preference on top of the accurate matrices: with the plain OEM
  # CCMs the red curtain measured HSV-sat 0.45 where the W11 capture of the same
  # scene under the same light measures 0.64. Final: 0.654.
  - Ccm:
      ccms:
        - ct: 2592
          ccm: [  1.9808, -0.4749, -0.5056,
                 -0.6684,  2.1544, -0.4860,
                 -0.5242, -1.8228,  3.3471 ]
        - ct: 2773
          ccm: [  2.1986, -0.9864, -0.2122,
                 -0.7359,  2.1626, -0.4264,
                 -0.2464, -1.4841,  2.7305 ]
        - ct: 3716
          ccm: [  2.2949, -1.1377, -0.1572,
                 -0.5846,  2.0326, -0.4481,
                 -0.1379, -1.0260,  2.1638 ]
        - ct: 3763
          ccm: [  2.2515, -1.0836, -0.1676,
                 -0.5637,  2.1049, -0.5412,
                 -0.0962, -1.2263,  2.3225 ]
        - ct: 4877
          ccm: [  2.0780, -0.8023, -0.2755,
                 -0.4319,  1.9676, -0.5358,
                 -0.1268, -0.9285,  2.0556 ]
        - ct: 5894
          ccm: [  2.0637, -0.8381, -0.2258,
                 -0.4043,  2.1383, -0.7340,
                 -0.1010, -0.9164,  2.0173 ]
        - ct: 6905
          ccm: [  2.1656, -0.9687, -0.1969,
                 -0.3738,  2.1203, -0.7465,
                 -0.0803, -0.8685,  1.9489 ]
  - Adjust:
  # 0.12 rather than the 0.16 default: this camera's usual scene (a lit wall
  # behind a dark foreground) runs the default hot enough to clip the wall --
  # the vendor stack exposes the same scene around 115/255. Clipped highlights
  # also poison the AWB statistics, which then mis-estimate the illuminant.
  - Agc:
      # MSV target (default 2.5 centres the histogram). Lowered so the lit
      # wall behind a dark foreground stays below clipping -- the vendor
      # stack exposes this scene around 115/255, the 2.5 default ran it at
      # ~147 with the wall solid 255, and clipped highlights also poison the
      # AWB statistics.
      exposureOptimal: 2.1
```

**Método de calibración** (si hay que recalibrar en otra unidad):
1. Calibrar SIEMPRE contra las estadísticas del softISP
   (`LIBCAMERA_LOG_LEVELS=Awb:DEBUG`, línea "Means Vector"), NUNCA contra el
   raw decodificado a mano: la fase Bayer que cuenta es la de las stats.
2. Iluminante improvisado: pantalla en blanco a fullscreen
   (`ffplay -fs -f lavfi -i color=white`) ≈6500K.
3. Medir por regiones robustas a encuadre: pared = luminancia 80-235 y
   saturación <0.25; objeto saturado = píxeles R>1.3*G.
4. El fit bayes SE DESLIZA por la curva al reescalarla: cada cambio nominal
   solo se materializa ~la mitad; iterar 3-4 veces.
5. Variación módulo a módulo real: ~9% (esta unidad necesitó r x1.20 b x1.08
   netos sobre las cromaticidades OEM).

### 6.1 El tuning de color de la trasera (ov8865.yaml) — CALIBRADO 2026-08-28

Instalar `tuning/libcamera/ov8865.yaml` en
`/usr/local/share/libcamera/ipa/softisp/ov8865.yaml` (fuente = copia
autoritativa; la cabecera del fichero documenta procedencia y estado).
Curva AWB bayes + CCMs del OEM `OV8865_MSHW0221_TGL.aiqb` (sección 9),
CCMs x1.28 como la frontal.

**Anclaje final: r x1.07 / b x1.083 netos** sobre las ganancias OEM (misma
banda de variación módulo a módulo que la frontal, x1.20/x1.08). Medido en
zona neutra del render (pared/colcha blancas, ~70% del encuadre, LED ~4600K
estable): OEM puro daba R/G 0.959 / B/G 0.954; final **R/G 1.002, B/G 1.008**
(criterio 1.00±0.03), AWB clavado en 4605±2K durante 11 s (gains 1.93/1.83
variando en la 4ª decimal). Convergió en 3 iteraciones con luz estable
(1.05/1.06 → 0.979/0.980; 1.09/1.11 → 1.020/1.024; interpolando → final).

**El bug que había que arreglar NO era el anclaje sino el black level.** El
OV8865 es tan poco sensible (ver abajo) que el raw típico queda al 2-5% del
fondo de escala INCLUSO con AGC a tope; el pedestal (16/1023, coincide con el
64/4095 que calibra su .aiqb) es entonces comparable a la señal:
- el default del softISP asume black level 16/**255** (4x el real), y
- el auto-ajuste por histograma tiene granularidad 4/255 = 16/1023, con lo
  que aquí cae a 0 (bin 0),
y en ambos casos el AWB calcula R/G y B/G con pedestal dentro → ratios ~0.9
(falso neutro), el bayes elige ~4600K y el render sale MAGENTA (fue el
síntoma inicial). Fix en el yaml: `BlackLevel: { blackLevel: 1024 }` (clave
de 16 bits, el softISP usa valor>>8 → nivel 4/255 = 16/1023 exacto).

Trampas nuevas de esta calibración (además de las de la frontal):
- El CCM OEM de la trasera amplifica ~3x los errores de azul en el render
  (fila B = [-0.09, -1.93, +3.02]): un 5% de déficit de azul post-AWB sale
  como ~15% en el render. Con el deslizamiento del fit por la curva, cada
  cambio nominal de b materializa solo ~1/4-1/2.
- Calibrar SOLO con iluminante estable: una primera pasada al atardecer,
  con la componente de luz de día muriendo, medía residuos que perseguían la
  deriva (CT aparente 4000→6300K en 10 min), no el módulo — llegó a "pedir"
  b x1.5. Descartada entera; con el LED de techo estable convergió en 3
  iteraciones a r x1.07 / b x1.083.
- Con el canal B a <1 LSB neto las stats son ruido rectificado y el fit se
  vuelve caos (Means Vector saltando, B clavado en 1e-05): NO iterar así.

**Sensibilidad (limitación, no bug de color)**: el modo 1632x1224 corre a
~120 fps (VTS 1246, línea 6,68 µs, pixel rate 288 MHz) → exposición máx
8,3 ms, y la ganancia analógica solo llega a x16. Verificado por raw directo:
subir `vertical_blanking` a 2500 (VTS 3724, ~40 fps) hace que el driver
amplíe la exposición a 3716 líneas (24,8 ms) y da x3 de señal (raw real,
probado con camtest.sh + v4l2-ctl), pero el pipeline softISP no lo digiere
bien (stats a ~2,5 fps, AGC sin converger en 10 s) y vblank=3769 (33 ms)
directamente rompe el sensor (frames planos). Queda como pendiente (sección
11); el tuning de color es independiente de esto.

## 7. El puente: scripts y unidades systemd

`/usr/local/bin/surface-camera-loopbacks`:
```bash
#!/bin/bash
# Create the two loopback devices the Surface camera bridges feed.
#
# The module's card_label parameter cannot express two labels containing
# spaces, so the devices are added at runtime instead. Do NOT pin the format
# with set-caps: with exclusive_caps=1 a pinned device advertises CAPTURE to
# everyone, and then the producers (v4l2sink, the IR bridge) can no longer
# open it for output. Each producer marks itself by writing a frame instead.
set -e
modprobe v4l2loopback
add() {  # nr label
    [ -e "/dev/video$1" ] && return 0
    /usr/local/bin/v4l2loopback-ctl add --exclusive-caps 1 --name "$2" "/dev/video$1" >/dev/null
}
add 80 "Surface Front Camera"
add 81 "Surface IR Camera"
add 82 "Surface Rear Camera"
```

`/usr/local/bin/surface-camera-relayd` (SOLO rear desde 2026-08-27: la
frontal pasó al ISP hardware con `surface-psys-bridge`, sección 10; el script
conserva el caso front por si hay que volver al softISP a mano — requiere
recargar ov5693 con binned_y_offset=2, ver sección 10):
```bash
#!/bin/bash
# On-demand bridge: a Surface Pro 7+ colour camera -> v4l2loopback, via
# libcamera's software ISP. v4l2-relayd only runs the pipeline while an
# application has the loopback device open.
#
# Usage: surface-camera-relayd front|rear
set -e

# BINNED=1 asks libcamera for the output size directly, with no oversized
# render pass. The simple pipeline picks the sensor mode from the requested
# output size (its debayer keeps a 2-pixel border, so a 1296-wide binned
# readout can serve at most 1292): asking for 1280x720 is what selects the
# OV5693's 2x2-binned mode, which gathers 4x the light per pixel and is the
# difference between the AGC running at analogue gain ~15 and it being pinned
# at the 127 ceiling. The rear OV8865 has no working binned mode, so it keeps
# the render-large-and-downscale path.
case "${1:-front}" in
  front) CAM_ID='\\_SB_.PC00.I2C2.CAMF'; LABEL="Surface Front Camera"
         BINNED=1 ;;
  rear)  CAM_ID='\\_SB_.PC00.I2C3.CAMR'; LABEL="Surface Rear Camera"
         BINNED=0 ;;
  *)     echo "usage: $0 front|rear" >&2; exit 2 ;;
esac

OUT_W="${OUT_W:-1280}"
OUT_H="${OUT_H:-720}"
OUT_FPS="${OUT_FPS:-30/1}"

export GST_PLUGIN_PATH=/usr/local/lib/x86_64-linux-gnu/gstreamer-1.0

DEVICE=$(grep -l -m1 -F -x "$LABEL" /sys/devices/virtual/video4linux/*/name | cut -d/ -f6)
if [ -z "$DEVICE" ]; then
    echo "no v4l2loopback device labelled '$LABEL'" >&2
    exit 1
fi

# camera-name: the libcamera id is an ACPI path starting with a backslash.
# gst_parse_launch() eats one level of backslash, hence the doubling.
#
# Note there is no sensor-config here: the "simple" pipeline handler never
# implemented SensorConfiguration, so that property was always a no-op. The
# sensor mode is steered entirely by the requested output size.
INPUT="libcamerasrc camera-name=$CAM_ID"
if [ "$BINNED" = 1 ]; then
    INPUT+=" ! video/x-raw,width=$OUT_W,height=$OUT_H"
    INPUT+=" ! videorate skip-to-first=true"
    INPUT+=" ! video/x-raw,framerate=$OUT_FPS"
else
    # Render larger than the output: the software ISP emits black frames when
    # asked for less than ~1296 px wide from a full-resolution readout.
    #
    # 1596x896 rather than the obvious 1920x1080: at exactly 1920 wide the
    # software ISP lays a dark column down 63% of the frame -- reproducible to
    # the same pixel (x=1211), about 23% below its neighbours, and absent from
    # the raw Bayer. The same GPU resampler also lays 1-px magenta ROWS at
    # width-dependent positions (1600 wide -> rows 371 and 771, 1568 wide ->
    # rows 483 and 875, regardless of height); with the calibrated CCM they
    # glow red. At 1596 wide there are none: the worst interior row/column is
    # <1% off and lands somewhere different every frame, which is just noise.
    INPUT+=" ! video/x-raw,width=1596,height=896"
    # The debayer's first row and first column carry an incomplete Bayer
    # phase and come out magenta (~+60 R-G vs neighbours after the CCM).
    # Crop 2 px all round (post-debayer RGB, so the Bayer phase and the
    # colour calibration are untouched) before scaling.
    INPUT+=" ! videocrop top=2 left=2 right=2 bottom=2"
    # skip-to-first: v4l2-relayd keeps one clock for the splash and the
    # camera, so by the time a client shows up the pipeline's running time is
    # however long the daemon has been idle. Without this, videorate treats
    # that as a gap to fill and repeats the first frame for every missing
    # slot -- a picture frozen for as long as the relay had been waiting.
    INPUT+=" ! videoscale ! videorate skip-to-first=true"
    INPUT+=" ! video/x-raw,width=$OUT_W,height=$OUT_H,framerate=$OUT_FPS"
fi
# End on a real element: v4l2-relayd links its appsink (which carries the
# YUY2 output caps) to the last unlinked src pad, and videoconvert is what
# turns libcamera's ABGR into YUY2.
INPUT+=" ! videoconvert"

OUTPUT="appsrc name=appsrc caps=video/x-raw,format=YUY2,width=$OUT_W,height=$OUT_H,framerate=$OUT_FPS"
# sync=false: libcamerasrc timestamps its buffers off the sensor clock, which
# does not line up with the running time of the pipeline v4l2-relayd builds
# around its appsrc. Left to synchronise, v4l2sink sits on every frame waiting
# for a deadline that never matches and the device trickles out ~1 fps, which
# looks exactly like a frozen picture. There is nothing to sync to here anyway:
# the loopback just wants frames as they arrive.
OUTPUT+=" ! videoconvert ! v4l2sink name=v4l2sink sync=false device=/dev/$DEVICE"

# v4l2-relayd's built-in splash is a 16x16 black PNG behind "imagefreeze
# num-buffers=2", which runs dry after two buffers. Once it has, the shared
# appsrc never recovers when the camera pipeline takes over: the loopback
# keeps handing out black frames at a few fps for as long as the client is
# open. A live source of the right size and rate keeps the appsrc fed until
# libcamera has its first frame ready.
SPLASH="videotestsrc pattern=black is-live=true"
SPLASH+=" ! video/x-raw,width=$OUT_W,height=$OUT_H,framerate=$OUT_FPS"
SPLASH+=" ! videoconvert"

exec /usr/local/bin/v4l2-relayd -i "$INPUT" -o "$OUTPUT" -s "$SPLASH"
```

Claves no obvias de ese script:
- `videorate skip-to-first=true`: sin él, al quedar el daemon idle, videorate
  rellena duplicando el primer frame → "cámara congelada".
- `v4l2sink sync=false`: los timestamps de libcamerasrc van en reloj de sensor;
  con sync=true el appsrc estrangula a ~1fps.
- Front pide 1280x720 directo (fuerza modo binned, ver sección 5); rear
  renderiza 1596x896, recorta 2px por lado (bordes magenta del debayer) y
  escala (1596 de ancho evita la columna oscura de 1920 y las filas magenta
  interiores de 1600/1568).

`/usr/local/bin/surface-ir-bridge` (completo, python):
```python
#!/usr/bin/env python3
"""Surface Pro 7+ IR camera (OV7251 + Intel IPU6) -> v4l2loopback.

The IPU6 ISYS hands out the sensor's raw Y10 (10 bits in a 16-bit word) and
nothing else: 'GREY', 'Y16 ' and the packed variants are all rejected by the
driver, and libcamera's software ISP only knows how to debayer colour sensors,
so it exposes this camera as raw-only too. Face-recognition tools (howdy) want
an ordinary 8-bit greyscale device, so convert here.

Streaming is started only while an application has the loopback device open,
which matters more than usual: the IR illuminator is lit for as long as the
sensor streams.
"""

import ctypes
import fcntl
import signal
import mmap
import os
import select
import struct
import subprocess
import sys
import time

import numpy as np

IR_W, IR_H = 640, 480
TARGET_MEAN = 110          # 8-bit target for the exposure loop
EXPOSURE_MIN, EXPOSURE_MAX = 2, 1704   # in lines
GAIN_MIN, GAIN_MAX = 16, 1023
DIGITAL_MAX = 6.0          # last resort once the sensor is maxed out

LOOPBACK_LABEL = "Surface IR Camera"

# --- v4l2 ioctls -----------------------------------------------------------
VIDIOC_S_FMT = 0xC0D05605
VIDIOC_REQBUFS = 0xC0145608
VIDIOC_QUERYBUF = 0xC0585609
VIDIOC_QBUF = 0xC058560F
VIDIOC_DQBUF = 0xC0585611
VIDIOC_STREAMON = 0x40045612
VIDIOC_STREAMOFF = 0x40045613
VIDIOC_SUBSCRIBE_EVENT = 0x4020565A
# _IOR('V', 89, struct v4l2_event); the struct is 136 bytes, and encoding
# the wrong size here makes the ioctl fail with ENOTTY, which used to be
# swallowed as "no event" -- so a client letting go was never noticed and
# the IR illuminator stayed lit.
VIDIOC_DQEVENT = 0x80885659

BUF_TYPE_CAPTURE = 1
BUF_TYPE_OUTPUT = 2
MEMORY_MMAP = 1

FMT_Y10 = 0x20303159    # 'Y10 '
FMT_YUYV = 0x56595559   # 'YUYV' -- browsers do not accept plain 'GREY'

# v4l2loopback signals this when the number of capturing clients changes.
V4L2_EVENT_PRI_CLIENT_USAGE = 0x08000000 + 0x08E00000 + 1

# How long every client has to be gone before the sensor is powered down.
CLIENT_GRACE = 2.0


def find_loopback(label):
    for name in sorted(os.listdir("/sys/devices/virtual/video4linux")):
        path = f"/sys/devices/virtual/video4linux/{name}/name"
        try:
            if open(path).read().strip() == label:
                return "/dev/" + name
        except OSError:
            pass
    return None


def find_subdev(sensor):
    for name in sorted(os.listdir("/sys/class/video4linux")):
        if not name.startswith("v4l-subdev"):
            continue
        entity = open(f"/sys/class/video4linux/{name}/name").read().strip()
        if entity.startswith(sensor + " "):
            return "/dev/" + name, entity
    return None, None


def media_ctl(*args):
    subprocess.run(["media-ctl", "-d", "/dev/media0", *args],
                   check=False, capture_output=True)


def setup_graph(entity):
    """Point the sensor's CSI-2 receiver at its capture node and agree on Y10.

    Has to be redone before every session, not once at start-up: the libcamera
    relays for the colour cameras reconfigure the same media device, and that
    severs this link (STREAMON then fails with ENOLINK).
    """
    out = subprocess.run(["media-ctl", "-d", "/dev/media0", "-p"],
                         capture_output=True, text=True).stdout

    csi = None
    current = None
    for line in out.splitlines():
        if "entity " in line and "CSI2" in line:
            current = line.split(": ", 1)[1].split(" (")[0]
        if f'"{entity}":0' in line and "ENABLED" in line and current:
            csi = current
            break
    if not csi:
        raise RuntimeError(f"no CSI-2 receiver linked to {entity}")

    # The capture entity's number is not port * 8, so read it off the graph
    # and then map that name to a /dev/video node.
    cap = None
    inside = want = False
    for line in out.splitlines():
        if line.startswith("- entity"):
            inside = f": {csi} (" in line
            want = False
            continue
        if not inside:
            continue
        if "pad1: Source" in line:
            want = True
        elif want and '-> "Intel IPU6 ISYS Capture' in line:
            cap = line.split('-> "', 1)[1].split('"', 1)[0]
            break
    if not cap:
        raise RuntimeError(f"no capture entity on {csi} pad1")

    node = None
    for name in sorted(os.listdir("/sys/class/video4linux")):
        if not name.startswith("video"):
            continue
        if open(f"/sys/class/video4linux/{name}/name").read().strip() == cap:
            node = "/dev/" + name
    if not node:
        raise RuntimeError(f"no /dev/video node named {cap!r}")

    fmt = f"[fmt:Y10_1X10/{IR_W}x{IR_H}]"
    media_ctl("-l", f'"{csi}":1 -> "{cap}":0 [1]')
    media_ctl("-V", f'"{entity}":0 {fmt}')
    media_ctl("-V", f'"{csi}":0 {fmt}')
    media_ctl("-V", f'"{csi}":1 {fmt}')
    return node, csi


DEBUG = os.environ.get("IR_BRIDGE_DEBUG")


def set_ctrls(subdev, exposure, gain):
    r = subprocess.run(["v4l2-ctl", "-d", subdev, "--set-ctrl",
                        f"exposure={exposure},analogue_gain={gain}"],
                       check=False, capture_output=True, text=True)
    if DEBUG:
        print(f"  set exposure={exposure} gain={gain} rc={r.returncode} "
              f"{r.stderr.strip()}{r.stdout.strip()}", flush=True)


def s_fmt(fd, buf_type, pixfmt, width, height):
    fmt = bytearray(204)
    struct.pack_into("I", fmt, 0, buf_type)
    struct.pack_into("IIII", fmt, 8, width, height, pixfmt, 1)
    fcntl.ioctl(fd, VIDIOC_S_FMT, fmt)
    bytesperline = struct.unpack_from("I", fmt, 8 + 16)[0]
    sizeimage = struct.unpack_from("I", fmt, 8 + 20)[0]
    return bytesperline, sizeimage


def buffer_struct(index, buf_type):
    b = bytearray(88)
    struct.pack_into("I", b, 0, index)
    struct.pack_into("I", b, 4, buf_type)
    struct.pack_into("I", b, 60, MEMORY_MMAP)
    return b


class Capture:
    """mmap capture from the IPU6 ISYS node."""

    def __init__(self, node, nbufs=6):
        self.fd = os.open(node, os.O_RDWR)
        self.maps = []
        try:
            self._setup(nbufs)
        except BaseException:
            # Leaking the fd here would make every later session fail with
            # EBUSY on this node, forever.
            self.close()
            raise

    def _setup(self, nbufs):
        self.bpl, _ = s_fmt(self.fd, BUF_TYPE_CAPTURE, FMT_Y10, IR_W, IR_H)
        self.stride = self.bpl // 2

        rb = bytearray(20)
        struct.pack_into("IIII", rb, 0, nbufs, BUF_TYPE_CAPTURE, MEMORY_MMAP, 0)
        fcntl.ioctl(self.fd, VIDIOC_REQBUFS, rb)
        self.count = struct.unpack_from("I", rb, 0)[0]

        for i in range(self.count):
            b = buffer_struct(i, BUF_TYPE_CAPTURE)
            fcntl.ioctl(self.fd, VIDIOC_QUERYBUF, b)
            length = struct.unpack_from("I", b, 72)[0]
            offset = struct.unpack_from("I", b, 64)[0]
            self.maps.append(mmap.mmap(self.fd, length, mmap.MAP_SHARED,
                                       mmap.PROT_READ, offset=offset))
            fcntl.ioctl(self.fd, VIDIOC_QBUF, buffer_struct(i, BUF_TYPE_CAPTURE))

        fcntl.ioctl(self.fd, VIDIOC_STREAMON, struct.pack("I", BUF_TYPE_CAPTURE))

    def frame(self, timeout=2.0):
        r, _, _ = select.select([self.fd], [], [], timeout)
        if not r:
            return None
        b = bytearray(88)
        struct.pack_into("I", b, 4, BUF_TYPE_CAPTURE)
        struct.pack_into("I", b, 60, MEMORY_MMAP)
        fcntl.ioctl(self.fd, VIDIOC_DQBUF, b)
        idx = struct.unpack_from("I", b, 0)[0]
        raw = np.frombuffer(self.maps[idx], dtype="<u2",
                            count=self.stride * IR_H)
        img = raw.reshape(IR_H, self.stride)[:, :IR_W].copy()
        fcntl.ioctl(self.fd, VIDIOC_QBUF, b)
        return img

    def close(self):
        if self.fd is None:
            return
        try:
            fcntl.ioctl(self.fd, VIDIOC_STREAMOFF,
                        struct.pack("I", BUF_TYPE_CAPTURE))
        except OSError:
            pass
        for m in self.maps:
            m.close()
        self.maps = []
        os.close(self.fd)
        self.fd = None


def run_session(entity, subdev, out_fd):
    """Pump frames until every client has let go of the loopback."""
    # The media graph has to be rebuilt every session, not once at start-up:
    # the libcamera relays for the colour cameras reconfigure the same media
    # device and sever this link. Do NOT re-run S_FMT on the loopback here --
    # once a reader has the format negotiated it answers EBUSY.
    node, _ = setup_graph(entity)
    exposure, gain, digital = 800, 256, 1.0
    gone_since = None
    set_ctrls(subdev, exposure, gain)
    cap = Capture(node)
    yuyv = np.empty((IR_H, IR_W, 2), dtype=np.uint8)
    yuyv[..., 1] = 128
    try:
        last_ae = 0.0
        while True:
            img = cap.frame()
            if img is None:
                break

            # 10 bits -> 8, with a digital top-up for when the sensor has
            # already run out of exposure and analogue gain (which it does
            # indoors: the illuminator only lights what is close to it).
            if digital == 1.0:
                out = (img >> 2).astype(np.uint8)
            else:
                out = np.clip(img.astype(np.float32) * (digital / 4.0),
                              0, 255).astype(np.uint8)
            mean = float(out.mean())

            # Grey -> YUYV with neutral chroma. Browsers and most apps refuse
            # a plain 8-bit greyscale device, so hand them a packed 4:2:2 one.
            yuyv[..., 0] = out
            try:
                os.write(out_fd, yuyv.tobytes())
            except BrokenPipeError:
                break

            now = time.monotonic()
            if now - last_ae > 0.25:
                last_ae = now
                if DEBUG:
                    print(f"  mean={mean:.1f} exposure={exposure} "
                          f"gain={gain} digital={digital:.2f}", flush=True)
                if not TARGET_MEAN * 0.75 <= mean <= TARGET_MEAN * 1.3:
                    factor = min(max(TARGET_MEAN / max(mean, 1.0), 0.4), 2.0)

                    # Spend the correction on the cheapest knob first:
                    # digital gain is given back before touching the sensor,
                    # then exposure time, then analogue gain (noisiest).
                    prev = (exposure, gain)
                    if factor < 1 and digital > 1.0:
                        digital = max(digital * factor, 1.0)
                    elif factor < 1 and gain > GAIN_MIN:
                        gain = max(int(gain * factor), GAIN_MIN)
                    elif factor < 1:
                        exposure = max(int(exposure * factor), EXPOSURE_MIN)
                    elif exposure < EXPOSURE_MAX:
                        exposure = min(int(exposure * factor), EXPOSURE_MAX)
                    elif gain < GAIN_MAX:
                        gain = min(int(gain * factor), GAIN_MAX)
                    else:
                        digital = min(digital * factor, DIGITAL_MAX)
                    if (exposure, gain) != prev:
                        set_ctrls(subdev, exposure, gain)

            # Players open the device, probe it, close it and open it again
            # before settling. Quitting on the first count=0 would end the
            # session during that probe, so let the gap play out first.
            count = poll_client_count(out_fd)
            if count is not None:
                gone_since = None if count else time.monotonic()
            if gone_since and time.monotonic() - gone_since > CLIENT_GRACE:
                break
    finally:
        cap.close()


def poll_client_count(fd):
    """Newest client count the loopback has reported, or None if unchanged.

    V4L2 signals these on the exceptional set (POLLPRI), which is the third
    list select() returns -- reading the first one instead always yields the
    empty read set, so a client letting go is never noticed and the sensor
    (with it the IR illuminator) stays lit.
    """
    count = None
    while True:
        _, _, x = select.select([], [], [fd], 0)
        if not x:
            return count
        ev = bytearray(136)
        try:
            fcntl.ioctl(fd, VIDIOC_DQEVENT, ev)
        except OSError:
            return count
        # The payload union starts at offset 8, after `type` and its padding.
        if struct.unpack_from("I", ev, 0)[0] == V4L2_EVENT_PRI_CLIENT_USAGE:
            count = struct.unpack_from("I", ev, 8)[0]


def _terminate(signum, frame):
    """Turn a signal into an exception so the streaming teardown still runs.

    systemd sends SIGTERM on stop and restart. Dying on the default handler
    skips the `finally` that issues STREAMOFF, which leaves the sensor
    streaming -- and therefore the IR illuminator lit -- until the next boot.
    """
    raise KeyboardInterrupt(f"signal {signum}")


def main():
    signal.signal(signal.SIGTERM, _terminate)
    signal.signal(signal.SIGINT, _terminate)

    loopback = find_loopback(LOOPBACK_LABEL)
    if not loopback:
        sys.exit(f"no v4l2loopback device labelled {LOOPBACK_LABEL!r}")
    subdev, entity = find_subdev("ov7251")
    if not subdev:
        sys.exit("ov7251 has no v4l2 subdev -- driver did not bind")
    node, csi = setup_graph(entity)
    print(f"{entity} ({subdev}) via {csi} -> {node} -> {loopback}", flush=True)

    out_fd = os.open(loopback, os.O_RDWR)
    s_fmt(out_fd, BUF_TYPE_OUTPUT, FMT_YUYV, IR_W, IR_H)

    # v4l2loopback only starts advertising CAPTURE to other openers once a
    # producer has actually written something, so push one black frame now.
    # Otherwise nothing could ever open the device and the client-usage event
    # this loop waits for would never fire.
    os.write(out_fd, bytes(IR_W * IR_H * 2))

    sub = bytearray(32)
    struct.pack_into("I", sub, 0, V4L2_EVENT_PRI_CLIENT_USAGE)
    fcntl.ioctl(out_fd, VIDIOC_SUBSCRIBE_EVENT, sub)

    try:
        serve(entity, subdev, out_fd)
    except KeyboardInterrupt as exc:
        print(f"stopping: {exc}", flush=True)


def serve(entity, subdev, out_fd):
    while True:
        select.select([], [], [out_fd])
        if poll_client_count(out_fd):
            print("client opened, streaming (IR illuminator on)", flush=True)
            try:
                run_session(entity, subdev, out_fd)
            except (OSError, RuntimeError) as exc:
                # Usually ENOLINK: a libcamera relay reconfigured the media
                # device underneath us. Give up on this session, keep serving,
                # but back off -- the client is still holding the loopback, so
                # retrying immediately just spins.
                if DEBUG:
                    import traceback; traceback.print_exc()
                print(f"session failed: {exc}", flush=True)
                time.sleep(2)
            print("idle", flush=True)


if __name__ == "__main__":
    main()
```

Sus fixes críticos, por si hay que tocarlo:
- El media graph de /dev/media0 hay que RECONSTRUIRLO en cada sesión (los
  relays de libcamera lo reconfiguran y cortan el enlace, ENOLINK).
- Contar clientes del loopback: V4L2_EVENT_PRI_CLIENT_USAGE=0x08E00001,
  VIDIOC_DQEVENT=0x80885659 (struct de 136 bytes, payload en offset 8), y el
  POLLPRI llega por la TERCERA lista de select(). Gracia de 2s antes de cerrar
  sesión (los players abren/sondean/cierran/reabren).
- Precalentar SOLO el IR con `v4l2-ctl --stream-mmap --stream-count=30`;
  precalentar las de color tira libcamera abajo (~115 frames congelados).

Unidades systemd (`/etc/systemd/system/`):
```ini
# surface-camera-loopbacks.service
[Unit]
Description=Create v4l2loopback devices for the Surface cameras
After=systemd-modules-load.service
Before=v4l2-relayd.service surface-ir-bridge.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/surface-camera-loopbacks

[Install]
WantedBy=multi-user.target

# surface-camera-relayd@.service  (instancia en uso: rear; front existe pero
# esta deshabilitada desde que la frontal va por surface-psys-bridge, s.10)
[Unit]
Description=Surface %i camera relay (libcamera -> v4l2loopback)
Requires=surface-camera-loopbacks.service
After=surface-camera-loopbacks.service

[Service]
Type=simple
ExecStart=/usr/local/bin/surface-camera-relayd %i
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target

# surface-ir-bridge.service
[Unit]
Description=Surface IR camera bridge (OV7251 -> v4l2loopback)
Requires=surface-camera-loopbacks.service
After=surface-camera-loopbacks.service

[Service]
Type=simple
Environment=IR_BRIDGE_DEBUG=
ExecStart=/usr/local/bin/surface-ir-bridge
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
```

Habilitar: `systemctl enable --now surface-camera-loopbacks
surface-camera-relayd@rear surface-ir-bridge surface-psys-bridge`
(la unidad `surface-psys-bridge` está en la sección 10;
`surface-camera-relayd@front` queda DESHABILITADA — la frontal es del puente
PSYS, y su unit lleva `Conflicts=surface-camera-relayd@front.service`).

## 8. Verificación

- `gst-launch-1.0 v4l2src device=/dev/video80 num-buffers=60 ! fakesink` y
  para ver: cualquier visor sobre /dev/video80 (front), 81 (IR), 82 (rear).
- En Chrome: las tres aparecen como "Surface Front/IR/Rear Camera".
- **Medir movimiento con HASHES de frames, no con estadísticas**: una imagen
  congelada tiene stats normales (error cometido una vez).
- `ffmpeg` sin `-input_format`/`-video_size` se atraganta sondeando estos
  loopbacks; para medir usar `v4l2-ctl --stream-mmap`.
- Errores csi2 "Frame sync/FIFO overflow" en dmesg: OJO con el rate-limiting
  del kernel ("callbacks suppressed") — no fiarse de ventanas cortas al contar.

## 9. Tuning OEM de Microsoft (.aiqb) — de dónde sale y cómo leerlo

El MSI público de drivers del Surface Pro 7+ contiene la calibración de color
OEM de las tres cámaras (formato Intel CPFF/.aiqb):

- URL (Legacy Update archiva las de Microsoft):
  `https://download.microsoft.com/download/0195da46-88f9-4f56-8046-babe15cafe2e/SurfacePro7+_Win11_22621_25.084.40018.0.msi` (~957MB)
- `msiextract`; los ficheros están en `SurfaceUpdate/Surface*extension/`:
  OV5693_MSHW0220_TGL.aiqb (front), OV8865_MSHW0221_TGL.aiqb (rear),
  OV7251_MSHW0222_TGL.aiqb (IR); y en `SurfaceUpdate/ov5693/` los
  graph_settings XML (la variante _BIN_ es el modo binned) y el ov5693.sys
  (tablas de registros del sensor).

Decoder (funciona; el parser oficial de Intel libia_cmc_parser SEGFAULTEA
incluso con sus propios ficheros, no perder tiempo ahí):

```python
#!/usr/bin/env python3
"""Decode Intel CPFF/.aiqb OEM camera tuning (Surface Pro 7+ modules).

The CMC record chain starts at file offset 0x50 (right after the CPFF header
block). Records: size(u32), data_format_id(u8), key_id(u8), name_id(u16).
name_id 25 = advanced color matrices: per light source a 20-byte info
(src_type u32, chromaticity R/G,B/G float, CIE x,y float) followed by a
'traditional' 3x3 float CCM (rows sum to 1) and sector_count hue-sector CCMs.

The chromaticity IS the sensor white point per illuminant: AWB gains = 1/chroma.
CCT is not stored; derive it from CIE xy (McCamy). Usage:
    ./decode_aiqb.py OV5693_MSHW0220_TGL.aiqb
"""
import json
import struct
import sys

LS = {0: 'none', 1: 'A/tungsten', 2: 'B', 3: 'C', 4: 'D50', 5: 'D55',
      6: 'D65', 7: 'D75', 8: 'E', 9: 'F1', 10: 'F2/coolwhite', 11: 'F3',
      12: 'F4/warmwhite', 13: 'F5', 14: 'F6', 15: 'F7/D65sim', 16: 'F8',
      17: 'F9', 18: 'F10', 19: 'F11/TL84', 20: 'F12'}


def mccamy_cct(x, y):
    n = (x - 0.3320) / (0.1858 - y)
    return 449 * n**3 + 3525 * n**2 + 6823.3 * n + 5520.33


def walk_records(d, start=0x50):
    off = start
    while off + 8 <= len(d):
        size, fmt, key, nid = struct.unpack_from('<IBBH', d, off)
        if size < 8 or off + size > len(d) or nid > 200:
            return
        yield off, size, fmt, key, nid
        off += size


def decode_advanced_ccm(d, off):
    body = off + 8
    nls, nsec = struct.unpack_from('<HH', d, body)
    p = body + 4 + nsec * 4  # skip hue_of_sectors
    out = []
    for _ in range(nls):
        src, = struct.unpack_from('<I', d, p)
        rg, bg, cx, cy = struct.unpack_from('<4f', d, p + 4)
        trad = struct.unpack_from('<9f', d, p + 20)
        out.append({'src': LS.get(src, str(src)),
                    'cct': round(mccamy_cct(cx, cy)),
                    'rpg': round(rg, 4), 'bpg': round(bg, 4),
                    'awb_gains': [round(1 / rg, 4), round(1 / bg, 4)],
                    'ccm': [round(v, 4) for v in trad]})
        p += 20 + 36 + nsec * 36
    return sorted(out, key=lambda e: e['cct'])


def main():
    d = open(sys.argv[1], 'rb').read()
    assert d[:4] == b'CPFF', 'not a CPFF file'
    for off, size, fmt, key, nid in walk_records(d):
        if nid == 25:
            res = decode_advanced_ccm(d, off)
            json.dump(res, sys.stdout, indent=1)
            print()
            return
    print('no advanced-CCM record (name_id 25) found', file=sys.stderr)
    sys.exit(1)


if __name__ == '__main__':
    main()
```

Estructura descubierta: cadena de records desde offset 0x50; header
size(u32)+fmt(u8)+key(u8)+name_id(u16); fmt puede ser >100 (no filtrar);
name_id 25 = advanced color matrices SIN comprimir: por iluminante, punto
blanco del sensor (cromaticidad R/G,B/G → ganancias AWB = recíproco) + CIE xy
(→ CCT por McCamy) + CCM "traditional" 9xfloat con filas que suman 1.
El decoder ya saca JSON listo. La trasera OV8865 decodifica igual (6
iluminantes) — ÚSALO para calibrar la trasera, que quedó pendiente.

## 10. ISP HARDWARE (IPU6 PSYS) — PRODUCCIÓN de la frontal desde 2026-08-27

Lo que le falta al softISP vs Windows: denoise, lens shading y sharpening.
Son hardware en el IPU6 (PSYS); en software cargarían la CPU (rechazado).
El pipeline entero (icamerasrc → HAL Intel → ISYS+PSYS) está VALIDADO y es
el camino de producción de la frontal: /dev/video80 lo sirve
`surface-psys-bridge.service` (ver 10.3). La trasera sigue en softISP
(sección 7) y la IR en su bridge. Hechos base:

- El intel-ipu6 mainline de 6.19 ya crea el auxiliary device
  `intel_ipu6.psys.40`, huérfano.
- El módulo psys de https://github.com/intel/ipu6-drivers (rama master,
  drivers/media/pci/intel/ipu6/psys/) está preparado para kernel >=6.10 SOBRE
  el ipu6 mainline (no sustituye el ISYS). Compila limpio contra 6.19 así:
  1. Bajar los headers mainline de drivers/media/pci/intel/ipu6/ (v6.19,
     ~16 ficheros .h; el paquete linux-headers no los trae) a un dir ml-hdrs/,
     y copiar include/uapi/linux/ipu-psys.h del repo a ml-hdrs/uapi/linux/.
  2. `make -C /lib/modules/$(uname -r)/build M=<repo>/drivers/media/pci/intel/ipu6/psys \
      KCPPFLAGS="-I<ml-hdrs> -I<repo>/include -I<repo>/drivers/media/pci/intel -I<repo>/drivers/media/pci/intel/ipu6" \
      CONFIG_VIDEO_INTEL_IPU6=m modules`
- `modprobe intel-ipu6-psys` → `/dev/ipu-psys0` aparece, "pkg_dir entry
  count:8" (el ipu6_fw.bin de linux-firmware YA trae los paquetes psys),
  probe limpio, el resto de cámaras sigue funcionando.

### 10.1 Módulo psys como DKMS (`ipu6-psys-surface/1.0`)

Instalador y fuentes en `ipu6-userspace/dkms/` (dkms.conf + Makefile
envoltorio + dkms_install.sh); el repo de Intel clonado en
`ipu6-userspace/ipu6-drivers/` y los headers mainline en
`ipu6-userspace/mainline-ipu6-headers/`. Instalar:

    cd camara/ipu6-userspace/dkms && sudo ./dkms_install.sh

El script monta `/usr/src/ipu6-psys-surface-1.0/` con: `psys/` (fuentes) bajo
`drivers/media/pci/intel/ipu6/`, los `.h` de sus dos directorios padre,
`include/` del repo y `ml-hdrs/`; añade
`/etc/modules-load.d/intel-ipu6-psys.conf`. La carga en boot va doble:
alias `auxiliary:intel_ipu6.psys` (autocarga al crearse el aux device) +
modules-load.d. Prerequisito por kernel: `include/generated/autoconf.h`
(gen_autoconf.py, sección 1). Verificado: `srcversion` del .ko DKMS idéntico
al .ko validado a mano (mismas fuentes, commit 71bddb5 del repo).

`ipu6-userspace/dkms/dkms.conf`:
```
PACKAGE_NAME="ipu6-psys-surface"
PACKAGE_VERSION="1.0"
BUILT_MODULE_NAME[0]="intel-ipu6-psys"
BUILT_MODULE_LOCATION[0]="drivers/media/pci/intel/ipu6/psys"
DEST_MODULE_LOCATION[0]="/updates"
AUTOINSTALL="yes"
BUILD_DIR="${dkms_tree}/${PACKAGE_NAME}/${PACKAGE_VERSION}/build"
# El modulo psys de intel/ipu6-drivers compila SOBRE el intel-ipu6 mainline
# (>=6.10). Los KCPPFLAGS (con sus comillas) no caben en MAKE[0] -- el parser
# de dkms.conf se atraganta con comillas escapadas -- asi que delega en el
# Makefile envoltorio del propio arbol fuente.
MAKE[0]="make -C ${BUILD_DIR} KDIR=${kernel_source_dir} modules"
CLEAN="make -C ${BUILD_DIR} KDIR=${kernel_source_dir} clean"
```

`ipu6-userspace/dkms/Makefile` (envoltorio; el orden de los -I IMPORTA:
ml-hdrs primero para tapar los headers homónimos del árbol de Intel):
```make
KDIR ?= /lib/modules/$(shell uname -r)/build
M := $(CURDIR)
PSYS := $(M)/drivers/media/pci/intel/ipu6/psys
KCPP := -I$(M)/ml-hdrs -I$(M)/include -I$(M)/drivers/media/pci/intel -I$(M)/drivers/media/pci/intel/ipu6

modules:
	$(MAKE) -C $(KDIR) M=$(PSYS) KCPPFLAGS="$(KCPP)" CONFIG_VIDEO_INTEL_IPU6=m modules

clean:
	$(MAKE) -C $(KDIR) M=$(PSYS) clean
```

`ipu6-userspace/dkms/dkms_install.sh` (completo):
```bash
#!/bin/bash
# Instala el modulo PSYS del IPU6 como paquete DKMS "ipu6-psys-surface/1.0".
#
# Fuentes:
#  - github.com/intel/ipu6-drivers (solo drivers/media/pci/intel/ipu6/psys/
#    mas los headers de sus padres e include/): el modulo esta preparado para
#    kernel >=6.10 SOBRE el intel-ipu6 mainline (no sustituye al ISYS).
#  - mainline-ipu6-headers/: los ~16 .h de drivers/media/pci/intel/ipu6/ del
#    kernel (el paquete linux-headers no los incluye) + uapi/linux/ipu-psys.h
#    del propio repo de Intel.
#
# Prerequisito (una vez por kernel): linux-headers-surface no trae
# include/generated/autoconf.h; generarlo con ov5693-fix/gen_autoconf.py
# (ver ov5693-fix/README.md).
set -e
HERE=$(dirname "$(readlink -f "$0")")
REPO=${REPO:-$HERE/../ipu6-drivers}
ML=${ML:-$HERE/../mainline-ipu6-headers}
SRC=/usr/src/ipu6-psys-surface-1.0

[ -d "$REPO/drivers/media/pci/intel/ipu6/psys" ] || {
    echo "no encuentro el repo intel/ipu6-drivers en $REPO" >&2
    echo "  git clone --depth 1 https://github.com/intel/ipu6-drivers.git $REPO" >&2
    exit 1
}
KVER=$(uname -r)
[ -e "/usr/src/linux-headers-$KVER/include/generated/autoconf.h" ] || {
    echo "falta include/generated/autoconf.h en los headers de $KVER;" >&2
    echo "generarlo primero: sudo python3 ov5693-fix/gen_autoconf.py \\" >&2
    echo "  /boot/config-$KVER /usr/src/linux-headers-$KVER/include/generated/autoconf.h" >&2
    exit 1
}

rm -rf "$SRC"
mkdir -p "$SRC/drivers/media/pci/intel/ipu6"
cp "$HERE/dkms.conf" "$HERE/Makefile" "$SRC/"
cp -r "$ML" "$SRC/ml-hdrs"
cp -r "$REPO/include" "$SRC/include"
cp "$REPO"/drivers/media/pci/intel/*.h "$SRC/drivers/media/pci/intel/"
cp "$REPO"/drivers/media/pci/intel/ipu6/*.h "$SRC/drivers/media/pci/intel/ipu6/"
cp -r "$REPO/drivers/media/pci/intel/ipu6/psys" "$SRC/drivers/media/pci/intel/ipu6/"
# por si el repo tiene restos de una compilacion manual
find "$SRC" -name '*.o' -o -name '*.ko' -o -name '*.mod*' -o -name '.*.cmd' \
    -o -name 'Module.symvers' -o -name 'modules.order' | xargs -r rm -f

dkms remove ipu6-psys-surface/1.0 --all 2>/dev/null || true
dkms add -m ipu6-psys-surface -v 1.0
dkms build -m ipu6-psys-surface -v 1.0
dkms install -m ipu6-psys-surface -v 1.0 --force
dkms status

# Carga en el arranque: el alias auxiliary:intel_ipu6.psys ya autocarga el
# modulo cuando intel-ipu6 crea el device, pero el modules-load.d no estorba
# y cubre el caso de que el aux device aparezca antes que el depmod.
echo intel-ipu6-psys > /etc/modules-load.d/intel-ipu6-psys.conf
echo "OK: modulo instalado; cargara en el arranque (alias auxiliary + modules-load.d)"
```

### 10.2 Offset del driver en el arranque (modprobe.d)

`/etc/modprobe.d/ov5693-surface.conf`:
```
# La frontal en produccion va por el ISP hardware (PSYS): fase GRBG =
# offset Y binned IMPAR (1), casada con vflip=1+hflip=1 del perfil HAL.
# El softISP/libcamera de la frontal esperaba offset 2 (BGGR): con este
# default, usar la frontal por libcamera sale magenta -- la frontal es
# PSYS-only desde 2026-08-27. La trasera (ov8865) no usa este parametro.
options ov5693 binned_y_offset=1
```

CONSECUENCIA: la frontal es PSYS-only. Cualquier uso de la frontal vía
libcamera (cam/qcam/libcamerasrc, o rehabilitar surface-camera-relayd@front)
saldrá MAGENTA con este default (libcamera cree BGGR, la fase real con
offset 1 es GRBG); para volver al softISP a mano: parar surface-psys-bridge,
`modprobe -r ov5693; modprobe ov5693 binned_y_offset=2` y arrancar
relayd@front. `ver.sh frontal` NO se ve afectado (lee /dev/video80, que ahora
alimenta el puente PSYS con las mismas caps YUY2 1280x720@30).

### 10.3 El puente de producción: surface-psys-bridge

Diseño (opción "servicio propio", NO v4l2-relayd, decisión 2026-08-27):
v4l2-relayd corre su pipeline gst EN PROCESO, así que no puede ni vigilar
"cero frames" ni reciclar el driver entre intentos, y si el pipeline
icamerasrc se atasca al parar (gst_cam_base_src_set_playing) systemd
escalaría a SIGKILL del cgroup entero = kill -9 a un icamerasrc vivo =
firmware ISYS atascado hasta reiniciar. El puente propio lanza gst-launch
como SUBPROCESO y usa exactamente la mecánica validada de psys-test.sh:
SIGINT (repetido) y ciclo de ov5693.

- Daemon: `/usr/local/bin/surface-psys-bridge` (python, fuente en
  `camara/bridge/surface-psys-bridge`, embebido abajo). Es el ÚNICO productor
  del loopback: mantiene abierto /dev/video80 (S_FMT OUTPUT YUYV 1280x720 +
  S_PARM 30fps + un frame negro para que anuncie CAPTURE), espera el evento
  client-usage de v4l2loopback (POLLPRI, tercera lista de select), y por
  sesión lanza `gst-launch-1.0 -q icamerasrc device-name=0 !
  NV12,1280x720 ! videoconvert ! YUY2 ! fdsink fd=1` y copia los frames del
  pipe al loopback. Así las caps de cara a Chrome NO cambian respecto al
  relayd antiguo (YUY2 1280x720@30) y gst nunca toca el device.
- Reintento del arranque atascado (el ISYS a veces no entrega nada: "Poll:
  Device node fd NN poll timeout"): si en 10 s no llega el primer frame →
  SIGINT al gst (un stream SIN frames sí muere), `modprobe -r ov5693;
  modprobe ov5693` (modprobe.d ya pone offset 1) y relanzar; máx 3 intentos.
  Mientras espera el primer frame alimenta splash negro a 30fps (el cliente
  no se atasca en la negociación).
- Fin de sesión: clientes a 0 + 2 s de gracia → SIGINT al gst y esperar
  (presupuesto 20 s, SIGINT repetido cada 4 s). Si gst no muere con SIGINT el
  daemon SALE sin tocar el driver (recargar bajo stream vivo atasca el ISYS;
  única cura reiniciar) — nunca escala a TERM/KILL.
- Solo una instancia icamerasrc: si detecta otra (psys-test.sh) se niega a
  arrancar la sesión y reintenta a los 5 s.
- Si el productor muere solo con clientes aún conectados, rearranca la
  sesión (no llega ningún evento nuevo de client-usage en ese caso).
- Latencias medidas (2026-08-27, 10 sesiones de demanda + 1 restart bajo
  stream): primer frame real 0.27-0.33 s desde el open() del cliente (sin
  reintento; el arranque atascado no apareció en las pruebas). Con un
  reintento el peor caso teórico es ~10 s (timeout) + ~2 s (ciclo driver)
  + ~0.3 s.
- LECCIÓN del shutdown (2026-08-27): la primera versión salía al recibir
  SIGTERM sin parar al hijo, y systemd REMATABA el gst vivo con SIGKILL
  (gst en estado D + ráfaga de errores CSI2; el ISYS sobrevivió de milagro).
  El daemon ahora para SIEMPRE el productor (SIGINT + espera, señales
  ignoradas durante el teardown) antes de salir; verificado con
  `systemctl restart` en pleno streaming: parada limpia en <0.3 s.

`/etc/systemd/system/surface-psys-bridge.service`:
```ini
[Unit]
Description=Surface front camera bridge (IPU6 hardware ISP -> v4l2loopback)
Requires=surface-camera-loopbacks.service
After=surface-camera-loopbacks.service
# La frontal es de este puente; el relayd softISP de la frontal no debe
# arrancar a la vez (dos productores sobre /dev/video80).
Conflicts=surface-camera-relayd@front.service

[Service]
Type=simple
Environment=PSYS_BRIDGE_DEBUG=
ExecStart=/usr/local/bin/surface-psys-bridge
Restart=always
RestartSec=2
# SIGTERM solo al daemon: el hijo gst-launch (icamerasrc) NUNCA debe recibir
# TERM/KILL con frames fluyendo (atasca el firmware ISYS hasta reiniciar);
# el daemon lo para con SIGINT y espera. El presupuesto de parada del daemon
# es de 20 s, deja margen antes del KILL final.
KillMode=mixed
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
```

`/usr/local/bin/surface-psys-bridge` (completo, python):
```python
#!/usr/bin/env python3
"""Surface Pro 7+ front camera -> v4l2loopback, via the IPU6 hardware ISP.

Producer pipeline (root): icamerasrc (Intel HAL -> ISYS -> PSYS) -> NV12
1280x720@30 -> videoconvert -> YUY2 -> this daemon -> /dev/video80. The
gst pipeline writes raw frames to a pipe (fdsink); the daemon owns the
loopback producer fd, so the device's caps never change for clients
(YUY2 1280x720, same as the old v4l2-relayd front bridge).

Why not v4l2-relayd (design decision, 2026-08-27):
 - The HAL start is INTERMITTENT: sometimes the ISYS never delivers a frame
   ("Poll: Device node fd NN poll timeout"). The proven recovery is SIGINT
   to the gst process, recycle the ov5693 driver, relaunch -- v4l2-relayd
   runs its pipeline in-process and has neither a no-frames watchdog nor a
   way to reload a kernel module between attempts.
 - Stopping a stuck icamerasrc pipeline in-process can hang in
   gst_cam_base_src_set_playing; if that hangs v4l2-relayd, systemd's stop
   escalates to SIGKILL of the whole cgroup -- and kill -9 on a streaming
   icamerasrc wedges the ISYS firmware until reboot. Here the daemon stays
   responsive and only ever SIGINTs its child.

Hard rules honoured here (see REPRODUCIR.md section 10):
 - only ONE icamerasrc instance at a time (the HAL rejects a second);
 - NEVER kill -9 / SIGTERM a gst with frames flowing; SIGINT, repeated;
 - a stream with NO frames does die on SIGINT (poll timeouts unblock it).
"""

import fcntl
import os
import select
import signal
import struct
import subprocess
import sys
import time

W, H, FPS = 1280, 720, 30
FRAME_SIZE = W * H * 2
LOOPBACK_LABEL = "Surface Front Camera"

GST_CMD = [
    "gst-launch-1.0", "-q",
    "icamerasrc", "device-name=0", "!",
    f"video/x-raw,format=NV12,width={W},height={H}", "!",
    "videoconvert", "!",
    f"video/x-raw,format=YUY2,width={W},height={H}", "!",
    "fdsink", "fd=1",
]

# How long to wait for the FIRST frame before declaring the HAL start stuck
# and recycling the sensor driver. A good start delivers in ~2-4 s; the
# stuck starts deliver nothing at all, so 10 s separates them cleanly.
FIRST_FRAME_TIMEOUT = 10.0
MAX_ATTEMPTS = 3
# How long every client has to be gone before the camera is shut down.
CLIENT_GRACE = 2.0
# SIGINT-and-wait budget for the gst child (repeat the SIGINT: historically
# one is sometimes ignored).
STOP_BUDGET = 20.0

# --- v4l2 ioctls (same layouts as surface-ir-bridge) ------------------------
VIDIOC_S_FMT = 0xC0D05605
VIDIOC_S_PARM = 0xC0CC5616
VIDIOC_SUBSCRIBE_EVENT = 0x4020565A
VIDIOC_DQEVENT = 0x80885659  # struct v4l2_event is 136 bytes; wrong size => ENOTTY
BUF_TYPE_OUTPUT = 2
FMT_YUYV = 0x56595559
# v4l2loopback signals this when the number of capturing clients changes.
V4L2_EVENT_PRI_CLIENT_USAGE = 0x08000000 + 0x08E00000 + 1

DEBUG = os.environ.get("PSYS_BRIDGE_DEBUG")


def log(msg):
    print(f"[{time.monotonic():.3f}] {msg}", flush=True)


def find_loopback(label):
    for name in sorted(os.listdir("/sys/devices/virtual/video4linux")):
        try:
            path = f"/sys/devices/virtual/video4linux/{name}/name"
            if open(path).read().strip() == label:
                return "/dev/" + name
        except OSError:
            pass
    return None


def s_fmt_output(fd):
    fmt = bytearray(204)
    struct.pack_into("I", fmt, 0, BUF_TYPE_OUTPUT)
    struct.pack_into("IIII", fmt, 8, W, H, FMT_YUYV, 1)
    fcntl.ioctl(fd, VIDIOC_S_FMT, fmt)


def s_parm_output(fd):
    """Advertise 30 fps (v4l2_outputparm.timeperframe = 1/30)."""
    parm = bytearray(204)
    struct.pack_into("I", parm, 0, BUF_TYPE_OUTPUT)
    struct.pack_into("II", parm, 4, 0x1000, 0)   # capability=TIMEPERFRAME, outputmode
    struct.pack_into("II", parm, 12, 1, FPS)     # timeperframe num/den
    try:
        fcntl.ioctl(fd, VIDIOC_S_PARM, parm)
    except OSError as exc:
        log(f"S_PARM failed ({exc}); fps stays at the loopback default")


def poll_client_count(fd):
    """Newest capture-client count, or None if unchanged. POLLPRI = the
    THIRD list select() returns; reading the first one misses every event."""
    count = None
    while True:
        _, _, x = select.select([], [], [fd], 0)
        if not x:
            return count
        ev = bytearray(136)
        try:
            fcntl.ioctl(fd, VIDIOC_DQEVENT, ev)
        except OSError:
            return count
        if struct.unpack_from("I", ev, 0)[0] == V4L2_EVENT_PRI_CLIENT_USAGE:
            count = struct.unpack_from("I", ev, 8)[0]


# Black in YUY2: Y=16, U=V=128 (video range; Y=0 also works but this is
# what videotestsrc pattern=black emits).
BLACK_FRAME = bytes([16, 128]) * (W * H)


def recycle_sensor():
    """Reload ov5693. /etc/modprobe.d supplies binned_y_offset=1, so a bare
    modprobe restores the production (PSYS/GRBG) phase."""
    log("recycling ov5693 driver")
    subprocess.run(["modprobe", "-r", "ov5693"], check=False)
    subprocess.run(["modprobe", "ov5693"], check=False)
    time.sleep(1.0)


def stop_gst(proc):
    """SIGINT the gst child (never SIGTERM/SIGKILL: a streaming icamerasrc
    must shut down its pipeline or the ISYS firmware wedges until reboot).
    Returns True once it is gone."""
    if proc.poll() is not None:
        return True
    deadline = time.monotonic() + STOP_BUDGET
    proc.send_signal(signal.SIGINT)
    next_int = time.monotonic() + 4.0
    while time.monotonic() < deadline:
        if proc.poll() is not None:
            return True
        if time.monotonic() >= next_int:
            try:
                proc.send_signal(signal.SIGINT)
            except ProcessLookupError:
                return True
            next_int = time.monotonic() + 4.0
        time.sleep(0.2)
    return proc.poll() is not None


def other_icamerasrc_running():
    """Pids of real gst-launch processes with icamerasrc among their argv.

    NOT pgrep -f "gst-launch.*icamerasrc": that also matches any shell whose
    command STRING happens to contain both words (a test harness, a grep, a
    copy-pasted psys-test line), and a false positive here kills the session.
    """
    pids = []
    for entry in os.listdir("/proc"):
        if not entry.isdigit() or int(entry) == os.getpid():
            continue
        try:
            argv = open(f"/proc/{entry}/cmdline", "rb").read().split(b"\0")
        except OSError:
            continue
        if argv and os.path.basename(argv[0]).startswith(b"gst-launch") \
                and any(a.startswith(b"icamerasrc") for a in argv[1:]):
            pids.append(int(entry))
    return pids


class SessionOver(Exception):
    pass


# The live producer, if any, so the shutdown path can stop it. A SIGTERM
# (systemd stop/restart) raises KeyboardInterrupt ANYWHERE, including inside
# run_session -- if the daemon then exits with the child alive, systemd
# SIGKILLs the leftover gst mid-stream, which is exactly the forbidden case
# (observed 2026-08-27: "Killing process ... with signal SIGKILL", gst in
# D-state, CSI2 error burst; the ISYS survived that once, do not bet on it).
CURRENT_PROC = [None]


def run_session(out_fd, client_open_t):
    """Serve one demand session: spawn the producer, relay frames, retry a
    stuck start with a driver recycle, stop when every client lets go."""
    others = other_icamerasrc_running()
    if others:
        log(f"REFUSING to start: another icamerasrc is running (pid {others});"
            " close it (psys-test.sh?) -- retrying in 5 s")
        time.sleep(5.0)
        # keep retrying while a client is still waiting on the loopback
        count = poll_client_count(out_fd)
        return count is None or count > 0

    for attempt in range(1, MAX_ATTEMPTS + 1):
        log(f"starting producer (attempt {attempt}/{MAX_ATTEMPTS})")
        proc = subprocess.Popen(GST_CMD, stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL)
        CURRENT_PROC[0] = proc
        pipe = proc.stdout.fileno()
        os.set_blocking(pipe, False)
        try:
            fcntl.fcntl(pipe, 1031, 1 << 20)  # F_SETPIPE_SZ, 1 MiB
        except OSError:
            pass

        buf = bytearray()
        first_frame_t = None
        gone_since = None
        spawn_t = time.monotonic()
        next_splash = 0.0
        try:
            while True:
                now = time.monotonic()

                # Watchdog: no first frame in time = the known stuck start.
                if first_frame_t is None and now - spawn_t > FIRST_FRAME_TIMEOUT:
                    log("no frames from the HAL (stuck start)")
                    break

                # Splash: keep the waiting client fed with black frames so
                # its negotiation/first read does not stall.
                if first_frame_t is None and now >= next_splash:
                    try:
                        os.write(out_fd, BLACK_FRAME)
                    except OSError:
                        pass
                    next_splash = now + 1.0 / FPS

                r, _, x = select.select([pipe], [], [out_fd], 0.02)

                if r:
                    try:
                        chunk = os.read(pipe, 1 << 20)
                    except BlockingIOError:
                        chunk = b""
                    if chunk == b"" and proc.poll() is not None:
                        if first_frame_t is None:
                            log("producer exited before the first frame")
                            break
                        raise SessionOver("producer exited")
                    buf += chunk
                    while len(buf) >= FRAME_SIZE:
                        frame = bytes(buf[:FRAME_SIZE])
                        del buf[:FRAME_SIZE]
                        if first_frame_t is None:
                            first_frame_t = time.monotonic()
                            log(f"first frame: {first_frame_t - spawn_t:.2f} s"
                                f" after spawn, {first_frame_t - client_open_t:.2f} s"
                                f" after client open (attempt {attempt})")
                        try:
                            os.write(out_fd, frame)
                        except OSError as exc:
                            raise SessionOver(f"loopback write failed: {exc}")

                count = poll_client_count(out_fd)
                if count is not None:
                    gone_since = None if count else time.monotonic()
                    if DEBUG:
                        log(f"clients: {count}")
                if gone_since and time.monotonic() - gone_since > CLIENT_GRACE:
                    raise SessionOver("all clients gone")

        except SessionOver as exc:
            log(f"session over: {exc}")
            if not stop_gst(proc):
                log("FATAL: gst will not die on SIGINT; NOT touching the "
                    "driver (reload under a live stream wedges the ISYS). "
                    "A reboot is the only cure. Exiting.")
                sys.exit(1)
            # If the producer died on its own while clients are still
            # attached, no new client-usage event will fire -- ask the
            # serve loop to start a fresh session for them.
            if str(exc) == "producer exited" and gone_since is None:
                time.sleep(1.0)
                return True
            return False

        # Stuck start: SIGINT (a frameless stream does die on it), recycle
        # the sensor, try again.
        if not stop_gst(proc):
            log("FATAL: stuck gst will not die on SIGINT; exiting (reboot needed)")
            sys.exit(1)
        if attempt < MAX_ATTEMPTS:
            recycle_sensor()

    log(f"giving up after {MAX_ATTEMPTS} attempts (HAL never delivered)")
    time.sleep(2.0)
    return False


def _terminate(signum, frame):
    raise KeyboardInterrupt(f"signal {signum}")


def main():
    signal.signal(signal.SIGTERM, _terminate)
    signal.signal(signal.SIGINT, _terminate)

    loopback = find_loopback(LOOPBACK_LABEL)
    if not loopback:
        sys.exit(f"no v4l2loopback device labelled {LOOPBACK_LABEL!r}")
    if not os.path.exists("/dev/ipu-psys0"):
        sys.exit("/dev/ipu-psys0 missing -- intel-ipu6-psys not loaded (DKMS?)")

    out_fd = os.open(loopback, os.O_RDWR)
    s_fmt_output(out_fd)
    s_parm_output(out_fd)
    # v4l2loopback only advertises CAPTURE once a producer has written
    # something; without this nothing could open the device and the
    # client-usage event below would never fire.
    os.write(out_fd, BLACK_FRAME)

    sub = bytearray(32)
    struct.pack_into("I", sub, 0, V4L2_EVENT_PRI_CLIENT_USAGE)
    fcntl.ioctl(out_fd, VIDIOC_SUBSCRIBE_EVENT, sub)

    log(f"serving {loopback} (front camera via IPU6 PSYS), waiting for clients")
    try:
        while True:
            select.select([], [], [out_fd])
            if poll_client_count(out_fd):
                t = time.monotonic()
                log("client opened")
                while run_session(out_fd, t):
                    t = time.monotonic()
                log("idle")
    except KeyboardInterrupt as exc:
        log(f"stopping: {exc}")
    finally:
        # Never leave the producer to systemd's final SIGKILL: stop it here,
        # with SIGINT and patience, before the main process exits. A second
        # SIGTERM must not abort this teardown, so ignore signals from now on.
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        proc = CURRENT_PROC[0]
        if proc is not None and proc.poll() is None:
            log("shutting down producer (SIGINT)")
            if not stop_gst(proc):
                log("FATAL: producer ignored SIGINT during shutdown; "
                    "a reboot may be needed (do NOT kill -9 it)")


if __name__ == "__main__":
    main()
```

### 10.4 Recetas del userspace (HAL, icamerasrc, config) — sin cambios
- USERSPACE MONTADO Y FUNCIONANDO (2026-08-27) hasta imagen real por PSYS.
  Receta completa:
  1. **ipu6-camera-bins** (clonar github.com/intel/ipu6-camera-bins): crear
     symlinks .so, copiar lib/ a /usr/lib, include/ a /usr/include, pkgconfig.
     NO copiar su firmware: el ipu6_fw.bin de linux-firmware ya vale.
  2. **ipu6-camera-hal** (github.com/intel/ipu6-camera-hal, cmake):
     `-DIPU_VERSIONS="ipu6" -DBUILD_CAMHAL_ADAPTOR=ON -DBUILD_CAMHAL_PLUGIN=ON
     -DUSE_PG_LITE_PIPE=ON`. HACEN FALTA 3 PARCHES (sensor BGGR inedito para
     este HAL, Intel solo prueba GRBG):
     * PGUtils.cpp getStride(): añadir BAYER_BGGR/RGGB/GBRG al case de GRBG
       (ALIGN_64(width*2)); sin esto el firmware del ISP aborta con assert
       `stride % 64 == 0` en dma_nci_io.
     * Utils.cpp getBpl(): añadir fourcc 'BG10'/'RG10'/'GB10' junto a 'GR10'
       (bpl=width*2); sin esto imagen en tiras verticales.
     * PipeLiteExecutor.cpp isSameStreamConfig(): en el WA GRBG-interno vs
       RGGB-externo, aceptar tambien SBGGR10/12 (nuestro driver siempre
       etiqueta SBGGR10); sin esto "Failed to bind input ports".
     OJO: `make install` MACHACA /etc/camera/ipu6/libcamhal_profile.xml:
     re-añadir "ov5693-uf-4," a availableSensors tras cada install.
  3. **icamerasrc** (rama icamerasrc_slim_api): `export CHROME_SLIM_CAMHAL=ON;
     ./autogen.sh; ./configure --prefix=/usr; make; make install`. Instala el
     plugin en /usr/lib/gstreamer-1.0: symlink a
     /usr/lib/x86_64-linux-gnu/gstreamer-1.0/ o gst no lo ve.
  4. **Config del ov5693** (ficheros en reproducir-src/ y aiqb-real/ del repo):
     * /etc/camera/ipu6/sensors/ov5693-uf.xml (perfil mediaCfg=1; el de
       reproducir-src incluye ya los controles de flip y NV12).
     * /etc/camera/ipu6/OV5693_MSHW0220_TGL.aiqb: el del MSI pero con el
       black level reescalado a 10 bits (aiqb-real/patch_aiqb_blc.py, o
       copiar aiqb-real/OV5693_MSHW0220_TGL_bl10.aiqb); el original tal
       cual da dominante verde (ver "COLOR ... CAUSA Y FIX" abajo).
     * /etc/camera/ipu6/gcss/graph_settings_ov5693.xml = el
       graph_settings_ov5693_13P2BA540_BIN_TGL.xml del MSI TAL CUAL (en GRBG;
       NO cambiar a BGGR: la fase real de nuestros datos ES GRBG, medido en
       raw: verdes en diagonal p00/p11 con consistencia 0.0%).
     * "-uf-4" = el ov5693 cuelga de "Intel IPU6 CSI2 4" (la 1 es del IR).
  5. Detectar sensor: `gst-inspect-1.0 icamerasrc` (como root) debe listar
     ov5693-uf. Probar:
     `gst-launch-1.0 icamerasrc device-name=0 ! video/x-raw,format=NV12,width=1280,height=720 ! ...`
     (NV12: es lo que sale del PG; pSysFormat=NV12 en el perfil).
  6. Logs: `export cameraDebug=0xff` (a stdout). El error "Malformed ET range"
     es de perfiles ajenos (ar0234), ignorar.
- ESTADO al cierre: pipeline entero funciona (sensor->ISYS->PSYS->NV12 30fps,
  CPU ~7%, AE converge, AWB corre con el .aiqb OEM cargado, nitidez
  visiblemente mejor que softISP). COLOR RESUELTO (2026-08-27), ver abajo.
- COLOR (dominante verde + rojos a purpura) — CAUSA Y FIX (2026-08-27):
  * Diagnostico: las stats RGBS NO estaban cruzadas (el AWB reportaba white
    point r/g=0.632 b/g=0.560 vs pared medida en raw 0.65-0.69/0.59-0.65,
    mismo orden y ballpark) y la CCM era la interpolacion correcta de las
    OEM del .aiqb para su CCT. PERO el render real no casaba con el modelo
    ganancias+CCM: la pared salia VERDE cuando el modelo predecia magenta
    suave. Ajustando el modelo por parches (claros y oscuros), la salida
    solo casa si el PG resta un nivel de negro de ~64 LSB10 cuando el negro
    real de nuestros datos es ~16 LSB10 (resta constante que deprime R/G y
    B/G tanto mas cuanto mas oscuro: verde global, esquinas/sombras peor).
  * Causa raiz: el .aiqb OEM calibra black level = 64.9 (CMC records 3 y 31)
    porque el ISYS de WINDOWS entrega el RAW10 alineado a 12 bits (16.2<<2).
    El ISYS mainline lo entrega alineado a LSB (pedestal real ~16 a todas
    las ganancias analogicas, medido a oscuras; los registros BLC del sensor
    son identicos a los de Windows, 0x4009=0x10). El AIC aplica el 64.9 tal
    cual sobre datos 4x mas pequenos.
  * FIX: reescalar el black level del .aiqb /4 (64.9 -> 16.2) con
    w11-ref/aiqb-real/patch_aiqb_blc.py (parcha records 3 y 31 y recalcula
    los DOS checksums de cabecera: 0x4c = suma u32 auto-excluyente de la
    seccion AIQB [0x38,0x38+size@0x3c), y despues 0x14 = suma u32
    auto-excluyente del fichero entero; sin ellos el CCA rechaza el fichero:
    "initIntelCcaHandle, init IntelCca fails"). Instalado:
    /etc/camera/ipu6/OV5693_MSHW0220_TGL.aiqb = version parcheada
    (OV5693_MSHW0220_TGL_bl10.aiqb; original en .aiqb.orig y en aiqb-real/).
  * Resultado: AWB estima CCT 4784 y white point (0.649,0.623) = D50 del
    .aiqb, coherente con la luz real; pared neutra en la salida (R/G
    1.03-1.11, B/G 0.93-0.97, misma calidez que el softISP calibrado),
    naranjas/rojos correctos, sin dominante verde. Borrar
    /run/camera/ov5693-uf_VIDEO.aiqd al cambiar el .aiqb.
  * OJO trasera: el OV8865_MSHW0221_TGL.aiqb tendra el mismo desajuste;
    aplicar el mismo reescalado /4 cuando se monte su pipeline PSYS (validar
    antes su pedestal real con capturas a oscuras).
- ORIENTACION PSYS (RESUELTA 2026-08-27): combinacion ganadora
  **vflip=1 + hflip=1 en el perfil HAL + binned_y_offset=1 en el driver**
  -> imagen derecha, mismo espejo que el softISP, fase GRBG intacta (sin
  magenta). Hallazgos empiricos que matizan el algebra de fase:
  * En binned el vflip (solo bit SENSOR de 0x3820) NO conmuta la fase de
    fila: v1+o2 dio la misma fase BGGR que v0+o2 (magenta bajo el HAL GRBG).
    La paridad del offset sigue mandando: impar = GRBG tambien con vflip=1.
  * v1+o3 NO vale: el sensor emite frames rotos (csi2-4 "Transfer FIFO
    overflow" / paquetes descartados en dmesg, ningun frame completa).
    Con vflip la ventana ISP se referencia del otro borde y offset 3 se
    sale; offset 1 funciona (tras 1-2 frames iniciales con error CSI2
    transitorio al arrancar, el stream queda limpio).
- Probar a mano (A/B, saltándose el puente): `sudo ./psys-test.sh` (ventana)
  o `sudo ./psys-test.sh loopback` (alimenta /dev/video80). Para los puentes
  al entrar y al salir (Ctrl+C) RESTAURA producción (recarga ov5693 con el
  default de modprobe.d y arranca surface-psys-bridge + relayd@rear + ir).
- Diseño del modo ventana (2026-08-27): el pipeline de root alimenta
  /dev/video80 (idéntico al loopback) y el VISOR es un ffplay que corre COMO
  EL USUARIO en su sesión Wayland (`sudo -u usuario env XDG_RUNTIME_DIR=...
  ffplay /dev/video80`); root no toca el display. El antiguo
  `icamerasrc ! xvimagesink` como root se retiró: cuando el HAL se atascaba
  al arrancar (ver abajo) daba VENTANA NEGRA sin diagnóstico y encima el
  shutdown se colgaba en `gst_cam_base_src_set_playing` ignorando SIGINT.
- El arranque del HAL es INTERMITENTE: a veces el ISYS no entrega ningún
  frame ("CamHAL[ERR] Poll: Device node fd NN poll timeout", 0% CPU en todos
  los hilos, el loopback nunca fija formato). Lo tratan igual psys-test.sh
  (gate: formato en /sys/devices/virtual/video4linux/video80/format) y el
  puente de producción (gate: primer frame por el pipe, timeout 10 s):
  SIGINT + ciclo de driver (modprobe -r/modprobe) + relanzar; el segundo
  intento históricamente arranca. Un stream atascado así (sin frames) SÍ
  muere con SIGINT (los poll timeout desbloquean el shutdown) — el SIGTERM
  sólo como último recurso.
- IMPORTANTE driver: para PSYS el offset Y binned debe ser 1 (impar = fase
  GRBG, compatible con vflip=1); para el softISP/libcamera debe ser 2 (fase
  BGGR). Es PARAMETRO del modulo, fijado a 1 en producción por
  /etc/modprobe.d/ov5693-surface.conf (ver 10.2; el default compilado del
  driver sigue siendo 2). El valor 3 solo vale con vflip=0 (imagen invertida).
- TRAMPAS operativas (aprendidas a base de dolor):
  - Solo UNA instancia de icamerasrc a la vez: el HAL rechaza la segunda con
    "device has been opened in another process" y gst-launch da el criptico
    "Failed to set pipeline to PAUSED". psys-test.sh ya aborta si detecta otra.
  - NUNCA `kill -9` a un pipeline en pleno streaming: el firmware del ISYS
    queda atascado ("stream stop time out" en dmesg; despues TODO da poll
    timeout, hasta captura raw por media-ctl). Recargar modulos no lo cura.
  - NO intentar curar el atasco con remove/rescan PCI de 0000:00:05.0:
    ipu_bridge filtra sus software nodes (bug kernel: quedan en
    /sys/kernel/software_nodes/ apuntando a rodata del modulo descargado) y
    el re-probe muere con -EEXIST "IPU6 bridge init failed"; los sensores
    fallan luego con "no supported link freq found". Unica cura: REINICIAR
    (no queda nada persistente, arranque limpio restaura todo).
  - Si un gst-launch con icamerasrc no muere con SIGINT: reiniciar la
    maquina directamente, no escalar a -9.

### 10.5 Grano en poca luz: palancas probadas y POR QUÉ no hay fix (2026-08-27)

Objetivo: menos grano que produce el pipeline PSYS en poca luz vs W11.
Protocolo: escena fija, parche plano oscuro 32x32 (x=1232,y=672), sigma
temporal DETRENDED (se resta la media del parche por frame: la deriva de luz
contamina sigma_t si no) + sigma espacial + Y + ag del log (cameraDebug=0xff).
Evidencia: scratchpad noise-levers/ (jpgs+logs). Resumen de medidas (30
frames, misma escena, la luz derivó entre runs — comparar por ag):

    config                       sigma_t  sigma_s   Y    ag     t(ms)
    base30 (producción)            3.60     3.96   22.9  1.44   30.4
    caps 15fps (sin más)           3.57     3.87   23.7  1.88   30.5
    15fps+perfil 66ms+driver       2.43     2.77   21.1  1.50   30.4  <- AE ni caso
    exp-priority=iso, ev=3 (dark)  6.99     7.69   20.6  3.0    30.6  <- idem
    MANUAL 30ms ag1.44             1.89     2.20   16.1  1.44   30.0  } mismo tet,
    MANUAL 60ms ag1.0              1.20     1.40   18.1  1.0    60.0  } A/B limpio
    aiqb NR x1.5 (man ag4)         1.07     1.37   23.4  4.0    30.0  vs 1.06 orig
    aiqb NR x3.0 (man ag4)         imagen destrozada (posterización, púrpura)

- PALANCA 1 (bajar fps para exponer más): el mecanismo se destapó entero.
  (1) el perfil `supportedAeExposureTimeRange` NO parsea bajo locale es_ES
  ("Malformed ET range": el HAL usa strtof y la coma decimal se come el
  separador; bajo systemd/C locale sí parsea); (2) el HAL lee el rango de
  exposición del sensor UNA vez al arrancar (getExposureRange = VTS default
  del driver - 8 = 2070 líneas = 33.2ms) y lo usa de techo del AE toda la
  sesión (probado: subir el VTS default del driver a 15fps reporta 4150 y el
  AE lo ve); (3) PERO aunque se levanten techo del sensor Y del perfil
  (66666us) y se pida framerate=15/1, el AE de ia_aiq NUNCA pasa de
  ~30.6ms: la DISTRIBUCIÓN de exposición del tuning OEM (LAIQ) capa el
  tiempo ahí y mete el resto en ganancia analógica. exp-priority=iso
  (Distribution Priority 2) tampoco lo mueve con tet alto. Y OJO: W11 hace
  LO MISMO (EXIF de foto nocturna W11: 30ms ISO374). El "15fps en poca luz"
  de la app de W11 no es integración de 66ms del pipe de vídeo.
  En MANUAL sí se puede (ae-mode=manual exposure-time=60000 gain=0: el HAL
  escribe VBLANK+exposure por frame y el driver ensancha el rango): con el
  MISMO tet, 60ms/ag1 da sigma_t 1.20 vs 1.89 de 30ms/ag1.44 (-36%). La
  física está, el tuning no la deja usar en AUTO. Sin tocar el binario de
  ia_aiq o el record AE del aiqb (nid 258, 16KB opacos), NO acotado.
  Driver y perfil RESTAURADOS byte a byte (ningún cambio en producción).
- PALANCA 2 (NR por el HAL): este build de icamerasrc (slim_api) NO expone
  nr-mode/nr-level (gst-inspect: no hay propiedad NR; el HAL sí tiene
  setNrMode/setNrLevel pero no hay camino desde gst-launch).
- PALANCA 3 (subir fuerza NR en el .aiqb): estructura LISP descifrada del
  todo (ver aiqb-structure-notes.md y w11-ref/aiqb-real/lisp_explore.py):
  sub-records {n1,n2,npts, eje1 f32*n1, eje2 f32*n2, valores i32*n1*n2*npts};
  el algoritmo uuid 28866 (stream 60001) es el NR bayer funcional: sus
  umbrales suben monótonos con el eje de ganancia [1,2,4,8,15.88]
  (425->981, 551->1979, 64->141). patch_aiqb_nr.py los reescala en los
  nodos g>=4 recalculando el checksum de la sección LISP (hdr+0x14) y el
  del fichero (0x14). Resultado A/B a ag=4.0 fijo: x1.5 NO mejora sigma_t
  (1.07 vs 1.06; el parche oscuro lo domina el TNR) y x3.0 DESTROZA la
  imagen. Margen nulo entre "sin efecto" y "artefactos": aiqb RESTAURADO
  (md5 = OV5693_MSHW0220_TGL_bl10.aiqb).

CONCLUSIÓN: producción queda EXACTAMENTE igual (ningún fichero cambiado).
El grano en poca luz es la ganancia analógica que el tuning OEM elige
(igual que W11 foto); la ventaja visible de la app de W11 es el apilado
multi-frame ULL, que este HAL no tiene montado (configStreams ULL -38,
ver 10.x/notas). Vías futuras NO acotadas: (a) descifrar el record AE nid
258 del LAIQ para subir el techo de 30.6ms; (b) montar el pipe ULL.

## 11. Pendientes conocidos

- (HECHO 2026-08-28) Calibrar color de la trasera (sección 6.1: curva OEM
  anclada r x1.07 / b x1.083 + blackLevel 16/1023 explícito).
- Trasera más brillante: subir vertical_blanking (2500 → 24,8 ms de
  exposición, x3 de señal verificado en raw) requiere que el softISP/AGC lo
  digiera; hoy desestabiliza el pipeline (ver sección 6.1). Alternativa: el
  camino PSYS de abajo.
- IR más brillante: portar PLL (30b0-30b5, 3098-309b) y VTS (522 vs 1724) del
  ov7251.sys de Windows.
- Publicar todo en GitHub (borradores primero; cuenta dmanresa-saes).
- (HECHO 2026-08-27) Userspace PSYS: en producción para la frontal
  (sección 10: DKMS + modprobe.d + surface-psys-bridge).
- PSYS para la trasera (OV8865): mismo camino, pendiente perfil HAL propio y
  reescalado /4 del black level de su .aiqb (ver nota en sección 10).
