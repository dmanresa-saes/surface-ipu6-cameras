#!/usr/bin/env python3
"""Volcar las tablas de registros de los drivers de camara de Windows.

Las entradas son de 16 bytes, {u32 flag=0, u32 tamaño, u32 registro, u32 valor},
en la seccion .rdata. Uso: extract_tables.py ov7251.sys
"""
import struct, sys

def sections(d):
    pe = struct.unpack_from('<I', d, 0x3c)[0]
    nsec = struct.unpack_from('<H', d, pe + 6)[0]
    opt = pe + 24
    magic = struct.unpack_from('<H', d, opt)[0]
    off = opt + (240 if magic == 0x20b else 224)
    out = {}
    for _ in range(nsec):
        name = d[off:off + 8].rstrip(b'\x00').decode('latin1')
        vsz, va, rsz, ra = struct.unpack_from('<IIII', d, off + 8)
        out[name] = (va, ra, rsz)
        off += 40
    return out

def main(path):
    d = open(path, 'rb').read()
    va0, raw, size = sections(d)['.rdata']

    def entry(p):
        if p < raw or p + 16 > raw + size:
            return None
        flag, sz, reg, val = struct.unpack_from('<IIII', d, p)
        if flag or sz not in (1, 2) or not 0x0100 <= reg < 0x6000 or val > 0xffff:
            return None
        return reg, val

    p = raw
    while p + 16 <= raw + size:
        if entry(p) and not entry(p - 16):
            regs, q = [], p
            while entry(q):
                regs.append(entry(q))
                q += 16
            if len(regs) >= 8:
                print(f"\n=== tabla @ va {0x140000000 + va0 + p - raw:#x} "
                      f"({len(regs)} registros) ===")
                items = [f"{r:04x}={v:02x}" for r, v in regs]
                for i in range(0, len(items), 10):
                    print('  ' + ' '.join(items[i:i + 10]))
            p = q
        else:
            p += 4

if __name__ == '__main__':
    main(sys.argv[1] if len(sys.argv) > 1 else 'ov7251.sys')
