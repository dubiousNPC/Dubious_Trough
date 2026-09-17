"""Write SD_Scarves_abilities.esp -- the 10 ability records the module needs.

The shipped SD_Scarves.esp is the CAKE item plugin: 320 MISC records and no
SPEL records at all, so every `core.magic.spells.records[id]` lookup missed and
neither bonus could ever apply.

Effect ids are not guessed. They were confirmed by parsing Sun's Dusk's own
plugin: sd_feather_f1..f8 use effect 8 (Feather) and sd_hearthfire_1..4 use
effect 79 with attribute 2, which is Fortify Attribute on Willpower. 79 lines up
with the standard TES3 effect table, and 95 in that same table is Resist Blight
Disease.
"""
import struct, sys, os

FORTIFY_ATTRIBUTE     = 79
RESIST_BLIGHT_DISEASE = 95
WILLPOWER             = 2
SPELL_TYPE_ABILITY    = 1


def zstring(s):
    return s.encode('cp1252') + b'\x00'


def sub(tag, data):
    return tag.encode('ascii') + struct.pack('<I', len(data)) + data


def record(tag, subrecords):
    body = b''.join(subrecords)
    # 4-byte tag, 4-byte size, then two 4-byte fields the engine ignores on
    # load (a legacy header and the record flags), then the body.
    return tag.encode('ascii') + struct.pack('<III', len(body), 0, 0) + body


def spell(rec_id, name, effect_id, magnitude, attribute=-1, skill=-1):
    enam = struct.pack('<hbbiiiii',
                       effect_id,
                       skill,
                       attribute,
                       0,          # range: Self
                       0,          # area
                       0,          # duration (abilities are permanent)
                       magnitude,  # min
                       magnitude)  # max
    return record('SPEL', [
        sub('NAME', zstring(rec_id)),
        sub('FNAM', zstring(name)),
        sub('SPDT', struct.pack('<III', SPELL_TYPE_ABILITY, 0, 0)),
        sub('ENAM', enam),
    ])


def header(num_records, description, masters):
    hedr = struct.pack('<fI', 1.3, 0)                    # version, file type (0 = esp)
    hedr += b'Scarves'.ljust(32, b'\x00')                # author
    hedr += description.encode('cp1252').ljust(256, b'\x00')
    hedr += struct.pack('<I', num_records)
    parts = [sub('HEDR', hedr)]
    for name, size in masters:
        parts.append(sub('MAST', zstring(name)))
        parts.append(sub('DATA', struct.pack('<Q', size)))
    return record('TES3', parts)


def build():
    recs = []

    # Warmth, binary-encoded over five records: 1+2+4+8+16 expresses any value
    # 0-31, and only the changed bits are added or removed at runtime. Mirrors
    # sd_hearthfire's effect exactly, so a scarf warms by the same mechanism a
    # fire does.
    for i, magnitude in enumerate([1, 2, 4, 8, 16], start=1):
        recs.append(spell('sd_scarf_w%d' % i, 'Scarf Warmth',
                          FORTIFY_ATTRIBUTE, magnitude, attribute=WILLPOWER))

    # Blight resistance, one record per 10% step.
    for percent in (10, 20, 30, 40, 50):
        recs.append(spell('sd_mask_blight_%d' % percent, 'Mask: Blight Resistance',
                          RESIST_BLIGHT_DISEASE, percent))

    masters = [('Morrowind.esm', 79837557)]
    data = header(len(recs), "Sun's Dusk :: Scarves and Masks -- ability records.",
                  masters) + b''.join(recs)
    return data, len(recs)


if __name__ == '__main__':
    out = sys.argv[1] if len(sys.argv) > 1 else 'SD_Scarves_abilities.esp'
    data, n = build()
    open(out, 'wb').write(data)
    print('wrote %s: %d SPEL records, %d bytes' % (out, n, len(data)))
