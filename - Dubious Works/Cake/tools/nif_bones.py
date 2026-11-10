#!/usr/bin/env python3
"""nif_bones.py NIF... -- list the custom bones a skeleton-extension file adds.

OpenMW grafts every node carrying a `BONE` NiStringExtraData onto the actor's
skeleton, under the node with the same name as its parent in this file
(Animation::injectCustomBones / loadBonesFromFile). A parent the actor's
skeleton does not have means the bone is silently not added.

Blocks are found by their type-name strings (NIF 4.0.0.2 has no block index),
and only NiNode and NiStringExtraData are decoded.
"""
import re, struct, sys

VANILLA = {'bip01', 'bip01 pelvis', 'bip01 spine', 'bip01 spine1', 'bip01 spine2', 'bip01 neck',
           'bip01 head', 'head', 'bip01 l clavicle', 'bip01 r clavicle', 'bip01 l upperarm',
           'bip01 r upperarm', 'bip01 l forearm', 'bip01 r forearm', 'bip01 l hand', 'bip01 r hand',
           'bip01 l thigh', 'bip01 r thigh', 'bip01 l calf', 'bip01 r calf', 'bip01 l foot',
           'bip01 r foot', 'weapon bone', 'shield bone', 'groin', 'chest', 'neck',
           'bip01 tail', 'bip01 tail1', 'bip01 tail2'}


def blocks(data):
    out = []
    for m in re.finditer(rb'(?s)(.{4})(Ni[A-Za-z]{2,40}|RootCollisionNode|AvoidNode)', data):
        n = struct.unpack('<I', m.group(1))[0]
        if n == len(m.group(2)):
            out.append((m.start(), m.group(2).decode()))
    return out


def sstr(d, o):
    n = struct.unpack_from('<I', d, o)[0]
    return d[o + 4:o + 4 + n].decode('latin1'), o + 4 + n


def parse(path):
    d = open(path, 'rb').read()
    bl = blocks(d)
    nodes, extra = {}, {}
    for idx, (start, typ) in enumerate(bl):
        o = start + 4 + len(typ)
        if typ == 'NiStringExtraData':
            o += 4 + 4          # next extra data ref, bytes remaining
            extra[idx], _ = sstr(d, o)
        elif typ == 'NiNode':
            name, o = sstr(d, o)
            ed, ctrl = struct.unpack_from('<ii', d, o); o += 8
            o += 2 + 12 + 36 + 4 + 12
            np_ = struct.unpack_from('<I', d, o)[0]; o += 4 + 4 * np_
            hasbb = struct.unpack_from('<I', d, o)[0]; o += 4
            if hasbb:
                o += 4 + 12 + 36 + 12
            nc = struct.unpack_from('<I', d, o)[0]; o += 4
            kids = list(struct.unpack_from('<%di' % nc, d, o))
            nodes[idx] = {'name': name, 'extra': ed, 'kids': kids}
    parent = {}
    for idx, n in nodes.items():
        for k in n['kids']:
            parent[k] = idx
    rows = []
    for idx, n in nodes.items():
        tags, e = [], n['extra']
        if e in extra:
            tags.append(extra[e])
        if 'BONE' in tags:
            p = nodes.get(parent.get(idx), {}).get('name', '?')
            rows.append((n['name'], p))
    return rows


if __name__ == '__main__':
    for f in sys.argv[1:]:
        print(f)
        for name, p in parse(f):
            ok = p.lower() in VANILLA
            print('  %-22s parent %-18s %s' % (name, p, 'ok' if ok else 'NOT ON THE VANILLA SKELETON: never added'))
