#!/usr/bin/env python3
"""fix_textkeys.py -- rename an animation group's text keys inside a .kf.

    fix_textkeys.py OLD NEW file.kf [file.kf ...]

Rewrites every NiTextKeyExtraData key line "OLD: <key>" to "NEW: <key>" in
place (a .bak is kept). NIF 4.0.0.2 stores no block offsets or sizes, so a
length-prefixed string may change length safely; the result is re-read and
the block count checked before the original is replaced.

Written for xGondola1*.kf, whose loop keys were authored as "godola1":
OpenMW groups text keys by the name before the colon, so "gondola1" had only
a stop key and "godola1" had no stop -- neither group could play its loop.
"""
import os
import shutil
import struct
import sys

TAG = b'NiTextKeyExtraData'


def block_count(d):
    return struct.unpack_from('<I', d, d.find(b'\n') + 1 + 4)[0]


def rewrite(d, old, new):
    out, changed, pos = bytearray(), 0, 0
    marker = struct.pack('<I', len(TAG)) + TAG
    i = d.find(marker)
    while i >= 0:
        p = i + len(marker) + 8                 # next-extra ref + bytesRemaining
        n, = struct.unpack_from('<I', d, p); p += 4
        out += d[pos:p]
        for _ in range(n):
            out += d[p:p + 4]; p += 4            # time
            ln, = struct.unpack_from('<I', d, p); p += 4
            text = d[p:p + ln].decode('latin1'); p += ln
            lines = text.split('\r\n')
            fixed = [new + l[len(old):] if l.lower().startswith(old.lower() + ':') else l for l in lines]
            if fixed != lines:
                changed += sum(1 for a, b in zip(lines, fixed) if a != b)
            enc = '\r\n'.join(fixed).encode('latin1')
            out += struct.pack('<I', len(enc)) + enc
        pos = p
        i = d.find(marker, p)
    out += d[pos:]
    return bytes(out), changed


def main():
    old, new, files = sys.argv[1], sys.argv[2], sys.argv[3:]
    for path in files:
        d = open(path, 'rb').read()
        fixed, changed = rewrite(d, old, new)
        if not changed:
            print('  unchanged  %s' % path)
            continue
        if block_count(fixed) != block_count(d) or fixed.count(TAG) != d.count(TAG):
            raise SystemExit('structure changed in %s; not written' % path)
        shutil.copy2(path, path + '.bak')
        open(path, 'wb').write(fixed)
        print('  %d key(s)  %s' % (changed, path))


if __name__ == '__main__':
    main()
