#!/usr/bin/env python3
"""Derive WhyWalk Caravans' in-place silt strider from Immersive Travel's assets.

    python3 tools/build_inplace_strider.py "<Immersive Travel - Assets>/Meshes"

Writes, under this module's meshes/whywalk/caravans/:

    siltstrider.nif     IT's r/siltstrider.nif, byte for byte
    xsiltstrider.nif    IT's r/xsiltstrider.nif, byte for byte
    xsiltstrider.kf     IT's r/xsiltstrider.kf with ONE change: the X and Y of
                        every "Root Bone" translation key are zeroed

WHY. IT's kf moves its accumulation root ("Root Bone") 800 units along +Y per
loop of RunForward and WalkForward. For an ACTOR the engine strips that and
turns it into movement; for an ACTIVATOR -- which is what Caravans spawns -- it
does not, so the body walks up to 1100 units ahead of its origin and snaps back
every loop. With the root's horizontal travel removed the gait plays on the
spot and all travel comes from the route. Z, every rotation, every other bone
and every text key are untouched, so the gait itself is the same.

The copies live under their own path so nothing of IT's is replaced: an
installation without them simply falls back to IT's mesh (caravans_global,
INPLACE).

Morrowind NIF 4.0.0.2 only. The script checks every assumption it makes and
stops rather than writing a file it is not sure of.
"""
import pathlib
import re
import shutil
import struct
import sys

ROOT = 'Root Bone'
KNOWN = re.compile(rb'^(Ni[A-Za-z]+|RootCollisionNode|AvoidNode|BSFurnitureMarker)$')


def block_starts(d):
    """(offset, type) of each block. 4.0.0.2 has no block index, so each block is
    found by its length-prefixed type name, and the count must match the header."""
    assert d.startswith(b'NetImmerse File Format, Version 4.0.0.2'), 'not a 4.0.0.2 file'
    i = d.find(b'\n') + 1
    assert struct.unpack_from('<I', d, i)[0] == 0x04000002, 'unexpected version'
    i += 4
    count = struct.unpack_from('<I', d, i)[0]
    i += 4
    starts, j = [], i
    while j < len(d) - 8 and len(starts) < count:
        n = struct.unpack_from('<I', d, j)[0]
        if 4 <= n <= 40 and KNOWN.match(d[j + 4:j + 4 + n]) and (j == i or starts):
            starts.append((j, d[j + 4:j + 4 + n].decode()))
            j += 4 + n
            continue
        j += 1
    assert len(starts) == count, f'found {len(starts)} blocks, header says {count}'
    return starts


class Reader:
    def __init__(self, d, p):
        self.d, self.p = d, p

    def get(self, fmt):
        v = struct.unpack_from('<' + fmt, self.d, self.p)
        self.p += struct.calcsize('<' + fmt)
        return v

    def u32(self):
        return self.get('I')[0]

    def i32(self):
        return self.get('i')[0]

    def string(self):
        n = self.u32()
        s = self.d[self.p:self.p + n].decode('latin-1')
        self.p += n
        return s


def root_keyframe_data(d, starts):
    """Offset of the NiKeyframeData driving ROOT, via the sequence helper's
    controller chain and its parallel chain of NiStringExtraData target names."""
    by_index = {k: (off, typ) for k, (off, typ) in enumerate(starts)}
    helpers = [k for k, (_, t) in by_index.items() if t == 'NiSequenceStreamHelper']
    assert len(helpers) == 1, 'expected one NiSequenceStreamHelper'
    off, typ = by_index[helpers[0]]
    r = Reader(d, off + 4 + len(typ))
    r.string()
    extra, ctrl = r.i32(), r.i32()

    names = []
    while extra >= 0:
        off, typ = by_index[extra]
        r = Reader(d, off + 4 + len(typ))
        nxt = r.i32()
        r.u32()                                   # bytes remaining
        if typ == 'NiStringExtraData':
            names.append(r.string())
        extra = nxt

    datas = []
    while ctrl >= 0:
        off, typ = by_index[ctrl]
        assert typ == 'NiKeyframeController', f'unexpected controller {typ}'
        r = Reader(d, off + 4 + len(typ))
        nxt = r.i32()
        r.get('H'); r.get('4f'); r.i32()           # flags, freq/phase/start/stop, target
        datas.append(r.i32())
        ctrl = nxt
    assert len(names) == len(datas), f'{len(names)} target names, {len(datas)} controllers'

    hits = [datas[k] for k, n in enumerate(names) if n.lower() == ROOT.lower()]
    assert len(hits) == 1, f'expected one {ROOT!r} track, found {len(hits)}'
    off, typ = by_index[hits[0]]
    assert typ == 'NiKeyframeData'
    return off + 4 + len(typ)


def zero_root_xy(d):
    d = bytearray(d)
    p = root_keyframe_data(bytes(d), block_starts(bytes(d)))
    nrot = struct.unpack_from('<I', d, p)[0]; p += 4
    if nrot:
        kt = struct.unpack_from('<I', d, p)[0]; p += 4
        assert kt in (1, 2, 3), f'unsupported rotation key type {kt}'
        p += nrot * (4 + 16 + (12 if kt == 3 else 0))
    ntr = struct.unpack_from('<I', d, p)[0]; p += 4
    assert ntr > 0, f'{ROOT} has no translation keys; nothing to do'
    kt = struct.unpack_from('<I', d, p)[0]; p += 4
    assert kt in (1, 2, 3), f'unsupported translation key type {kt}'
    span = []
    for _ in range(ntr):
        p += 4                                      # time
        for _vec in range(3 if kt == 2 else 1):     # value (+ two tangents if quadratic)
            x, y, z = struct.unpack_from('<3f', d, p)
            span.append(y)
            struct.pack_into('<3f', d, p, 0.0, 0.0, z)
            p += 12
        if kt == 3:
            p += 12                                 # tension/bias/continuity
    return bytes(d), ntr, min(span), max(span)


def main():
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    src = pathlib.Path(sys.argv[1])
    files = {n: src / 'r' / n for n in ('siltstrider.nif', 'xsiltstrider.nif', 'xsiltstrider.kf')}
    for n, f in files.items():
        if not f.is_file():
            # The asset pack's own capitalisation varies; find it case-insensitively.
            cand = [c for c in (src / 'r').iterdir() if c.name.lower() == n] if (src / 'r').is_dir() else []
            if not cand:
                raise SystemExit(f'missing {f}')
            files[n] = cand[0]

    out = pathlib.Path(__file__).resolve().parent.parent / 'meshes' / 'whywalk' / 'caravans'
    out.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(files['siltstrider.nif'], out / 'siltstrider.nif')
    shutil.copyfile(files['xsiltstrider.nif'], out / 'xsiltstrider.nif')
    kf, n, y0, y1 = zero_root_xy(files['xsiltstrider.kf'].read_bytes())
    (out / 'xsiltstrider.kf').write_bytes(kf)

    # Re-read what was written: the root must now be still, and nothing else moved.
    a = files['xsiltstrider.kf'].read_bytes()
    assert len(a) == len(kf), 'size changed'
    diff = sum(1 for i in range(len(a)) if a[i] != kf[i])
    _, n2, z0, z1 = zero_root_xy(kf)
    assert (z0, z1) == (0.0, 0.0), 'root still travels after patching'
    print(f'{ROOT}: {n} translation keys, travel along Y was {y0:.0f}..{y1:.0f}, now 0')
    print(f'{diff} bytes changed in {len(a)}; written to {out}')


if __name__ == '__main__':
    main()
