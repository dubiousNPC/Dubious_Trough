"""Write SD_Goggles_abilities.esp -- the one ability record the module needs.

The CAKE item plugin carries MISC records only -- no SPEL records -- so without
this file every `core.magic.spells.records[id]` lookup misses. p_goggles.lua
guards that lookup, which means the failure is SILENT: eyewear equips and draws
correctly and simply grants nothing. That is exactly how Scarves shipped a
release with no working bonuses, so the module now logs once when the record is
absent rather than staying quiet.

Effect id is not guessed. It is the same encoding make_abilities_esp.py writes
for sd_scarf_w1..w5, which was itself parsed out of Sun's Dusk's sd_hearthfire
records: effect 79, Fortify Attribute. Only the attribute byte differs --
LUCK (7) rather than WILLPOWER (2).
"""
import struct, sys, os

FORTIFY_ATTRIBUTE     = 79
RESIST_BLIGHT_DISEASE = 95
WILLPOWER             = 2
LUCK                  = 7
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
    hedr += b'Goggles'.ljust(32, b'\x00')                # author
    hedr += description.encode('cp1252').ljust(256, b'\x00')
    hedr += struct.pack('<I', num_records)
    parts = [sub('HEDR', hedr)]
    for name, size in masters:
        parts.append(sub('MAST', zstring(name)))
        parts.append(sub('DATA', struct.pack('<Q', size)))
    return record('TES3', parts)


def build():
    # ONE record. The boon is a flat 1 point of Luck, so there is nothing to
    # binary-encode -- Scarves needs five records only because its magnitude is
    # configurable 0-31. Do not generalise this into a bit set.
    recs = [spell('sd_goggles_luck1', 'Eyewear: Keen Eye',
                  FORTIFY_ATTRIBUTE, 1, attribute=LUCK)]

    masters = [('Morrowind.esm', 79837557)]
    data = header(len(recs), "Sun's Dusk :: Glasses, Goggles and Eyepatches -- ability record.",
                  masters) + b''.join(recs)
    return data, len(recs)


if __name__ == '__main__':
    out = sys.argv[1] if len(sys.argv) > 1 else 'SD_Goggles_abilities.esp'
    data, n = build()
    open(out, 'wb').write(data)
    print('wrote %s: %d SPEL records, %d bytes' % (out, n, len(data)))
