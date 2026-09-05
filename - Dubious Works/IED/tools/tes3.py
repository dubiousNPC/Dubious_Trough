"""Minimal TES3 (Morrowind esp/esm/omwaddon) reader.

Only what is needed here: walk top-level records, pull subrecords, and decode
CLOT / ARMO / BODY entries so each item's real slot comes from the plugin
rather than from guessing at its record id.
"""
import struct, sys, os, json

CLOTHING_TYPE = {
    0: 'Pants', 1: 'Shoes', 2: 'Shirt', 3: 'Belt', 4: 'Robe',
    5: 'RightGlove', 6: 'LeftGlove', 7: 'Skirt', 8: 'Ring', 9: 'Amulet',
}
ARMOR_TYPE = {
    0: 'Helmet', 1: 'Cuirass', 2: 'LeftPauldron', 3: 'RightPauldron',
    4: 'Greaves', 5: 'Boots', 6: 'LeftGauntlet', 7: 'RightGauntlet',
    8: 'Shield', 9: 'LeftBracer', 10: 'RightBracer',
}
# INDX byte -> body part slot the biped object occupies
BIPED_PART = {
    0: 'Head', 1: 'Hair', 2: 'Neck', 3: 'Chest', 4: 'Groin', 5: 'Skirt',
    6: 'RightHand', 7: 'LeftHand', 8: 'RightWrist', 9: 'LeftWrist',
    10: 'Shield', 11: 'RightForearm', 12: 'LeftForearm', 13: 'RightUpperArm',
    14: 'LeftUpperArm', 15: 'RightFoot', 16: 'LeftFoot', 17: 'RightAnkle',
    18: 'LeftAnkle', 19: 'RightKnee', 20: 'LeftKnee', 21: 'RightUpperLeg',
    22: 'LeftUpperLeg', 23: 'RightPauldron', 24: 'LeftPauldron',
    25: 'Weapon', 26: 'Tail',
}


def subrecords(blob):
    off = 0
    n = len(blob)
    while off + 8 <= n:
        tag = blob[off:off + 4].decode('ascii', 'replace')
        size = struct.unpack_from('<I', blob, off + 4)[0]
        off += 8
        yield tag, blob[off:off + size]
        off += size


def records(path):
    data = open(path, 'rb').read()
    off = 0
    n = len(data)
    while off + 16 <= n:
        tag = data[off:off + 4].decode('ascii', 'replace')
        size = struct.unpack_from('<I', data, off + 4)[0]
        off += 16
        yield tag, data[off:off + size]
        off += size


def zstr(b):
    return b.split(b'\x00', 1)[0].decode('cp1252', 'replace')


def parse(path):
    out = []
    for tag, blob in records(path):
        if tag not in ('CLOT', 'ARMO'):
            continue
        item = {'type': tag, 'id': None, 'name': None, 'model': None,
                'slot': None, 'parts': [], 'value': None, 'weight': None}
        pending_idx = None
        for st, sb in subrecords(blob):
            if st == 'NAME':
                item['id'] = zstr(sb)
            elif st == 'FNAM':
                item['name'] = zstr(sb)
            elif st == 'MODL':
                item['model'] = zstr(sb)
            elif st == 'CTDT' and len(sb) >= 12:
                t, w, v = struct.unpack_from('<ifH', sb, 0)
                item['slot'] = CLOTHING_TYPE.get(t, 'Unknown%d' % t)
                item['weight'], item['value'] = round(w, 2), v
            elif st == 'AODT' and len(sb) >= 24:
                t, w, v = struct.unpack_from('<ifi', sb, 0)
                item['slot'] = ARMOR_TYPE.get(t, 'Unknown%d' % t)
                item['weight'], item['value'] = round(w, 2), v
            elif st == 'INDX' and len(sb) >= 1:
                pending_idx = sb[0]
            elif st in ('BNAM', 'CNAM'):
                item['parts'].append({
                    'index': BIPED_PART.get(pending_idx, pending_idx),
                    'sex': 'male' if st == 'BNAM' else 'female',
                    'part': zstr(sb),
                })
        if item['id']:
            out.append(item)
    return out


if __name__ == '__main__':
    allitems = {}
    for p in sys.argv[1:]:
        items = parse(p)
        print('=== %s : %d wearables' % (os.path.basename(p), len(items)))
        for it in items:
            allitems[it['id'].lower()] = it
    json.dump(allitems, open('/home/claude/work/items.json', 'w'), indent=1)
    print('total unique:', len(allitems))
