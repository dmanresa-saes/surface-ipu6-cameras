#!/usr/bin/env python3
"""Explore/patch gain-axed params in LISP/DFLT stream 60001 of the aiqb."""
import struct, sys

SECTION_TAGS = {b'CPFF', b'LCMC', b'LAIQ', b'LISP', b'LTHR',
                b'DFLT', b'ULL3', b'LMOD', b'AIQB'}

def walk_sections(d):
    p, path = 0x18, []
    while p + 16 <= len(d):
        tag = d[p:p + 4]
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
            yield '/'.join(t for t, _ in path), p + 0x18, end
            p = end
        else:
            path.append((name, end))
            p += 16

def walk_chain(d, start, end):
    off = start
    while off + 8 <= end:
        size, fmt, key, nid = struct.unpack_from('<IBBH', d, off)
        if size < 8 or off + size > end:
            return
        yield off, size, fmt, key, nid
        off += size

def gain_params(d, stream=60001, section='LISP/DFLT'):
    """Yield (abs_payload_off, uuid, param_idx, axes, values) for sub-records
    whose node axis is an analog-gain axis (starts 1.0, ends >10)."""
    for path, start, end in walk_sections(d):
        if path != section:
            continue
        for off, size, fmt, key, nid in walk_chain(d, start, end):
            if nid != stream:
                continue
            p = off + 8
            idx = 0
            while p + 28 <= off + size:
                ssz, tag, flags, uuid, ver = struct.unpack_from('<IHHII', d, p)
                if ssz < 16 or p + ssz > off + size:
                    break
                nn, unk, npts = struct.unpack_from('<III', d, p + 16)
                if 2 <= nn <= 8 and 28 + 4*nn <= ssz:
                    axes = struct.unpack_from(f'<{nn}f', d, p + 28)
                    if abs(axes[0] - 1.0) < 0.01 and axes[-1] > 10:
                        po = p + 28 + 4*nn
                        nv = (ssz - (28 + 4*nn)) // 4
                        vals = struct.unpack_from(f'<{nv}f', d, po)
                        yield po, uuid, idx, axes, vals
                idx += 1
                p += ssz

if __name__ == '__main__':
    d = open(sys.argv[1], 'rb').read()
    for po, uuid, idx, axes, vals in gain_params(d):
        n = len(axes)
        per = len(vals) // n if n and len(vals) % n == 0 else 0
        mono = ''
        if per == 1:
            v = vals
            if all(v[i] <= v[i+1] for i in range(n-1)) and v[0] < v[-1]:
                mono = ' MONO-UP'
            elif all(v[i] >= v[i+1] for i in range(n-1)) and v[0] > v[-1]:
                mono = ' MONO-DOWN'
        print(f'{po:#07x} uuid={uuid:5d} idx={idx:2d} nvals={len(vals):3d} '
              f'per_node={per}{mono} vals={[round(x,4) for x in vals]}')
