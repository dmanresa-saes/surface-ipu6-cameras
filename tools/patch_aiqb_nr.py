#!/usr/bin/env python3
"""Subir la fuerza del NR bayer en poca luz (nodos de ganancia alta) del .aiqb.

Contexto (2026-08-27, experimento de ruido): el AE del tuning OEM clava la
exposicion a ~30.6ms y a partir de ahi solo mete ganancia analogica (igual
que W11: EXIF 30ms ISO374). El grano en poca luz es la ganancia; la unica
palanca acotada que queda es la fuerza del NR en los nodos de ganancia alta.

Que toca: en la seccion LISP/DFLT, stream 60001 (pipe de video), sub-records
del algoritmo uuid=28866 (candidato bnlm/NR bayer: sus params fuerza crecen
monotonos con el eje de ganancia analogica [1,2,4,8,15.88]). Se reescalan
x FACTOR los valores de los nodos con ganancia >= 4, SOLO en los params
monotonos crecientes con primer valor >= 2 (umbrales de ruido tipo
425->981, 551->1979, 64->141...). Se excluye el param identidad [1,2,4,8,15].

Sub-record: {size u32, 0x0064 u16, 0x8000 u16, uuid u32, ver u32,
             n1 u32, n2 u32, npts u32, eje1 n1*f32, eje2 n2*f32,
             valores n1*n2*npts u32 (enteros)}

Checksums recalculados: el de la seccion AIQB que contiene LISP/DFLT
(u32 auto-excluyente en hdr+0x14) y el del fichero entero (0x14), en ese
orden. Sin ellos el CCA rechaza el fichero.

Uso: ./patch_aiqb_nr.py IN.aiqb OUT.aiqb [factor]
     (IN debe ser el ya parcheado de BLC: OV5693_MSHW0220_TGL_bl10.aiqb)

RESULTADO (2026-08-27, A/B manual ag=4.0 t=30ms, parche 32x32 oscuro fijo):
  x1.5 -> sigma_t 1.06 vs 1.07 (SIN mejora medible; imagen visualmente OK)
  x3.0 -> imagen DESTROZADA: posterizacion, sombras purpura, textura perdida
El knob es real (el CCA acepta el fichero y los params SI alimentan el pipe:
x3 lo demuestra), pero el margen entre "sin efecto" y "artefactos" es
estrecho y no hay ganancia. NO INSTALADO en produccion; se restauro el
OV5693_MSHW0220_TGL_bl10.aiqb byte a byte. Queda como herramienta por si se
quiere reintentar con params/factores mas finos (ver lisp_explore.py).
"""
import struct
import sys

SECTION_TAGS = {b'CPFF', b'LCMC', b'LAIQ', b'LISP', b'LTHR',
                b'DFLT', b'ULL3', b'LMOD', b'AIQB'}
TARGET_UUID = 28866
STREAM = 60001
GAIN_MIN = 4.0          # nodos a reescalar: eje >= 4


def walk_sections(d):
    p, path = 0x18, []
    while p + 16 <= len(d):
        tag = bytes(d[p:p + 4])
        if tag not in SECTION_TAGS:
            break
        size, ver = struct.unpack_from('<II', d, p + 4)
        end = p + size
        while path and path[-1][1] <= p:
            path.pop()
        name = tag.decode()
        if tag in (b'LMOD', b'ULL3', b'DFLT'):
            name += str(ver) if tag == b'LMOD' else ''
        if tag == b'AIQB':
            yield '/'.join(t for t, _ in path), p, p + 0x18, end
            p = end
        else:
            path.append((name, end))
            p += 16


def patch(src, dst, factor):
    d = bytearray(open(src, 'rb').read())
    assert d[:4] == b'CPFF', 'no es un CPFF'

    patched = []
    lisp_hdr = None
    for path, hdr, start, end in walk_sections(d):
        if path != 'LISP/DFLT':
            continue
        lisp_hdr = (hdr, end)
        # cadena de records {size u32, fmt u8, key u8, nid u16}
        off = start
        while off + 8 <= end:
            rsize, fmt, key, nid = struct.unpack_from('<IBBH', d, off)
            if rsize < 8 or off + rsize > end:
                break
            if nid == STREAM:
                p = off + 8
                while p + 28 <= off + rsize:
                    ssz, tag, flags, uuid, ver = struct.unpack_from(
                        '<IHHII', d, p)
                    if ssz < 16 or p + ssz > off + rsize:
                        break
                    n1, n2, npts = struct.unpack_from('<III', d, p + 16)
                    if (uuid == TARGET_UUID and n1 >= 4 and n2 == 1
                            and npts == 1):
                        ax = struct.unpack_from(f'<{n1}f', d, p + 28)
                        vo = p + 28 + 4 * n1 + 4 * n2
                        if (abs(ax[0] - 1.0) < 0.01 and ax[-1] > 10
                                and vo + 4 * n1 <= p + ssz):
                            vals = list(struct.unpack_from(f'<{n1}i', d, vo))
                            mono_up = (all(vals[i] <= vals[i + 1]
                                           for i in range(n1 - 1))
                                       and vals[0] < vals[-1])
                            is_axis = all(abs(vals[i] - ax[i]) <= 1
                                          for i in range(n1))
                            # solo umbrales "grandes" (>=64): excluye params
                            # pequenos tipo radio/iteraciones (p.ej. 2..11)
                            if (mono_up and vals[0] >= 2 and not is_axis
                                    and max(vals) >= 64):
                                new = list(vals)
                                for i in range(n1):
                                    if ax[i] >= GAIN_MIN:
                                        new[i] = round(vals[i] * factor)
                                struct.pack_into(f'<{n1}i', d, vo, *new)
                                patched.append((p, vals, new))
                    p += ssz
            off += rsize
    assert patched, 'ningun parametro elegible encontrado'
    for p, old, new in patched:
        print(f'  {p:#07x}: {old} -> {new}')

    def selfsum(lo, hi, pos):
        t = 0
        for o in range(lo, hi, 4):
            if o != pos:
                t = (t + struct.unpack_from('<I', d, o)[0]) & 0xffffffff
        return t

    hdr, end = lisp_hdr
    struct.pack_into('<I', d, hdr + 0x14, selfsum(hdr, end, hdr + 0x14))
    struct.pack_into('<I', d, 0x14, selfsum(0, len(d), 0x14))
    open(dst, 'wb').write(bytes(d))
    print(f'ok: {len(patched)} params x{factor} en nodos g>={GAIN_MIN:g}, '
          f'checksums recalculados -> {dst}')


if __name__ == '__main__':
    f = float(sys.argv[3]) if len(sys.argv) > 3 else 1.5
    patch(sys.argv[1], sys.argv[2], f)
