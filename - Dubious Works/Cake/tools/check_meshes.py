#!/usr/bin/env python3
"""check_meshes.py [DATA_DIR...] -- every registered item must have a model that
can be attached: present in a data directory (or a .bsa in one), and not skinned.

A worn model is attached with animation.addVfx under one bone. A missing model
draws the yellow error marker; a skinned one (NiSkinInstance) draws nothing
where it should. Neither raises an error in game, so both are checked here.

Run from the package root. With no arguments it checks `00 Core` plus the
vanilla archives named by $MW_DATA (the folder holding Morrowind.bsa).
Items whose model is supplied by another mod are listed, not failed.
"""
import os, re, struct, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def bsa_names(p):
    f = open(p, 'rb')
    _v, hoff, n = struct.unpack('<III', f.read(12))
    f.read(8 * n)
    offs = struct.unpack('<%dI' % n, f.read(4 * n))
    names = f.read(hoff - 12 * n)
    return {names[o:names.index(b'\0', o)].decode('latin1').lower().replace('\\', '/') for o in offs}


def index(dirs):
    loose, packed = {}, set()
    for d in dirs:
        for r, _ds, fs in os.walk(d):
            for f in fs:
                full = os.path.join(r, f)
                rel = os.path.relpath(full, d).lower().replace('\\', '/')
                if f.lower().endswith('.bsa'):
                    packed |= bsa_names(full)
                else:
                    loose[rel] = full
    return loose, packed


def main():
    dirs = sys.argv[1:] or [os.path.join(ROOT, '00 Core')]
    if not sys.argv[1:] and os.environ.get('MW_DATA'):
        dirs.append(os.environ['MW_DATA'])
    loose, packed = index(dirs)
    sys.path.insert(0, os.path.join(ROOT, 'tools'))
    import tes3
    models = {}
    for rel in ('00 Core/Cake_Gear.omwaddon', '01 Lanterns Belts Bags/cake_v4.2.esp'):
        for tag, blob in tes3.records(os.path.join(ROOT, rel)):
            if tag != 'MISC':
                continue
            rec = {st: tes3.zstr(b) for st, b in tes3.subrecords(blob) if st in ('NAME', 'MODL')}
            models[rec['NAME'].lower()] = rec.get('MODL', '')
    shared = open(os.path.join(ROOT, '00 Core/scripts/cake/cake_shared.lua')).read()
    worn = re.findall(r"eq = '([^']+)', category = '(\w+)'", shared)
    fail, external = 0, {}
    for eq, cat in worn:
        path = 'meshes/' + models[eq].lower().replace('\\', '/')
        if path in loose:
            if b'NiSkinInstance' in open(loose[path], 'rb').read():
                fail += 1
                print('  SKINNED  %-28s %s' % (eq, path))
        elif path not in packed:
            top = path.split('/')[1]
            external.setdefault(top, []).append(eq)
    print('%d worn models checked in %s' % (len(worn), ', '.join(os.path.basename(d) for d in dirs)))
    for top, ids in sorted(external.items()):
        print('  not shipped: %-12s %3d items  e.g. %s' % (top + '/', len(ids), ids[0]))
    print('%d skinned' % fail)
    sys.exit(1 if fail else 0)


main()
