#!/usr/bin/env python3
"""Reescalar el black level del .aiqb OEM de 12 bits a 10 bits (dividir /4).

Por que: el .aiqb de Microsoft calibra el black level en ~64.9 LSB porque el
ISYS de Windows entrega el RAW10 del OV5693 alineado a 12 bits (16.2 <<2).
El ISYS mainline de Linux lo entrega alineado a LSB (10 bits, pedestal real
~16, medido con capturas a oscuras a todas las ganancias analogicas). El PG
del PSYS restaba 64.9 sobre datos 4x mas pequenos: cada canal perdia ~49
cuentas, lo que deprime R/G y B/G en proporcion inversa al nivel (verde
global, peor en sombras, rojos corridos a purpura). Verificado: el modelo
gains+CCM del AIQ solo casa con la salida real si se anade esa sobre-resta.

Que toca:
  - CMC record name_id=3  (black level, 25 LUTs x 4 canales u16 Q8.8)
  - CMC record name_id=31 (black level global, 25 LUTs x 16 float)
  - checksum de cabecera en 0x4c: suma u32 auto-excluyente de la seccion
    AIQB [0x38, 0x38+size) (size = u32 en 0x3c)
  - checksum de cabecera en 0x14: suma u32 auto-excluyente del fichero entero
    (recalcular DESPUES del de 0x4c)

Uso: ./patch_aiqb_blc.py OV5693_MSHW0220_TGL.aiqb OV5693_MSHW0220_TGL_bl10.aiqb
"""
import struct
import sys


def patch(src, dst):
    d = bytearray(open(src, 'rb').read())
    assert d[:4] == b'CPFF', 'no es un CPFF'

    n3 = n31 = 0
    off = 0x50
    while off + 8 <= len(d):
        size, fmt, key, nid = struct.unpack_from('<IBBH', d, off)
        if size < 8 or off + size > len(d) or nid > 200:
            break
        body = off + 8
        if nid == 3:  # cmc_black_level: u32 num, luts {u32 exp, u32 gain, 4x u16 Q8.8}
            num, = struct.unpack_from('<I', d, body)
            for i in range(num):
                p = body + 4 + 16 * i + 8
                for c in range(4):
                    v, = struct.unpack_from('<H', d, p + 2 * c)
                    assert 12000 < v < 20000, (i, c, v)  # ~64.9 en Q8.8
                    struct.pack_into('<H', d, p + 2 * c, round(v / 4))
                    n3 += 1
        if nid == 31:  # cmc_black_level_global: u32 num, 12 bytes, luts de 72
            num, = struct.unpack_from('<I', d, body)
            p = body + 16
            for i in range(num):
                e, = struct.unpack_from('<I', d, p)
                g, = struct.unpack_from('<f', d, p + 4)
                assert 0 < e < 200000 and 0 < g < 200, (i, e, g)
                for c in range(16):
                    v, = struct.unpack_from('<f', d, p + 8 + 4 * c)
                    assert v == 0 or 50 < v < 80, (i, c, v)
                    struct.pack_into('<f', d, p + 8 + 4 * c, v / 4.0)
                    n31 += 1
                p += 72
        off += size
    assert n3 == 100 and n31 == 400, (n3, n31)

    def selfsum(lo, hi, pos):
        t = 0
        for o in range(lo, hi, 4):
            if o != pos:
                t = (t + struct.unpack_from('<I', d, o)[0]) & 0xffffffff
        return t

    aiqb_size, = struct.unpack_from('<I', d, 0x3c)
    struct.pack_into('<I', d, 0x4c, selfsum(0x38, 0x38 + aiqb_size, 0x4c))
    struct.pack_into('<I', d, 0x14, selfsum(0, len(d), 0x14))

    open(dst, 'wb').write(bytes(d))
    print(f'ok: {n3} u16 + {n31} float /4, checksums recalculados -> {dst}')


if __name__ == '__main__':
    patch(sys.argv[1], sys.argv[2])
