#!/usr/bin/env python3
"""fix_textkeys.py -- rename an animation group's text keys inside a .kf.

    fix_textkeys.py OLD NEW file.kf [file.kf ...]
    fix_textkeys.py OLD NEW --from 13.7 --to 16.4 file.kf [file.kf ...]

Rewrites every NiTextKeyExtraData key line "OLD: <key>" to "NEW: <key>" in
place (a .bak is kept). NIF 4.0.0.2 stores no block offsets or sizes, so a
length-prefixed string may change length safely; the result is re-read and
the block count checked before the original is replaced.

Written for xGondola1*.kf, whose loop keys were authored as "godola1":
OpenMW groups text keys by the name before the colon, so "gondola1" had only
a stop key and "godola1" had no stop -- neither group could play its loop.

--from / --to RESTRICT THE RENAME TO A TIME WINDOW, and that exists because
the whole-file form cannot fix the other way this goes wrong. xRowing1.kf
declares five sequential segments of which TWO were both named "rowingr":
10.833-13.700 and 13.733-16.333. A group cannot have two start keys and play
both, so the second segment -- the left-turn stroke -- was unreachable.
Renaming every "rowingr" would just move the collision. The window picks one
segment out of a clip whose groups are laid end to end, which is how an
animator exports them.

Bounds are inclusive and compared against each key's own time, so a window
has to cover a whole start..stop cycle to leave a playable group behind. The
tool prints the keys it changed with their times so that is checkable.
"""
import os
import shutil
import struct
import sys

TAG = b'NiTextKeyExtraData'


def block_count(d):
    return struct.unpack_from('<I', d, d.find(b'\n') + 1 + 4)[0]


def rewrite(d, old, new, lo=None, hi=None):
    out, changed, pos = bytearray(), 0, 0
    touched = []
    marker = struct.pack('<I', len(TAG)) + TAG
    i = d.find(marker)
    while i >= 0:
        p = i + len(marker) + 8                 # next-extra ref + bytesRemaining
        n, = struct.unpack_from('<I', d, p); p += 4
        out += d[pos:p]
        for _ in range(n):
            t, = struct.unpack_from('<f', d, p)
            out += d[p:p + 4]; p += 4            # time
            ln, = struct.unpack_from('<I', d, p); p += 4
            text = d[p:p + ln].decode('latin1'); p += ln
            lines = text.split('\r\n')
            # The time window is checked per KEY, not per block: one
            # NiTextKeyExtraData holds every key in the clip.
            in_window = (lo is None or t >= lo) and (hi is None or t <= hi)
            if in_window:
                fixed = [new + l[len(old):]
                         if l.lower().startswith(old.lower() + ':') else l
                         for l in lines]
            else:
                fixed = lines
            if fixed != lines:
                changed += sum(1 for a, b in zip(lines, fixed) if a != b)
                touched += [(t, b) for a, b in zip(lines, fixed) if a != b]
            enc = '\r\n'.join(fixed).encode('latin1')
            out += struct.pack('<I', len(enc)) + enc
        pos = p
        i = d.find(marker, p)
    out += d[pos:]
    return bytes(out), changed, touched


def main():
    argv = sys.argv[1:]
    old, new = argv[0], argv[1]
    lo = hi = None
    files, i = [], 2
    while i < len(argv):
        if argv[i] == '--from':
            lo = float(argv[i + 1]); i += 2
        elif argv[i] == '--to':
            hi = float(argv[i + 1]); i += 2
        else:
            files.append(argv[i]); i += 1

    for path in files:
        d = open(path, 'rb').read()
        fixed, changed, touched = rewrite(d, old, new, lo, hi)
        if not changed:
            print('  unchanged  %s' % path)
            continue
        if block_count(fixed) != block_count(d) or fixed.count(TAG) != d.count(TAG):
            raise SystemExit('structure changed in %s; not written' % path)
        shutil.copy2(path, path + '.bak')
        open(path, 'wb').write(fixed)
        print('  %d key(s)  %s' % (changed, path))
        for t, line in touched:
            print('      %8.3f  %s' % (t, line))


if __name__ == '__main__':
    main()
