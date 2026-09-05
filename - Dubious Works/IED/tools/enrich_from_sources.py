"""Enrich the CAKE Miscellaneous records from their source mods.

Every CAKE wearable is a Miscellaneous stand-in for an ARMO record in one of
the mods that supplied its mesh. Those ARMO records carry the authored name,
the icon path, and a weight and value the author chose. The CAKE records
carried none of that: a placeholder name, a uniform 0.5/2 for everything, and
no icon on 61 of 160.

The link is the bodypart. An ARMO's biped_objects[].male_bodypart names the
same record the CAKE item was derived from, so:

    _RV_Ashmask_1 (Armor)  --biped_object-->  _RV_Ashmask1_H (Bodypart)
                                                     |
                                       dbs_RV_Ashmask1_H (CAKE MiscItem)

158 of 160 resolve this way. Names, icons and values are taken from the source
rather than invented, which is the point: "Dunmer Ashmask" is what the author
called it, and no amount of guessing gets there from "Ashmask 1".

Mesh paths are NEVER touched. They point at assets these mods ship, and the
CAKE record's mesh is the worn variant while the ARMO's is a _GND ground mesh
-- taking the ARMO's would be actively wrong.
"""
import json, glob, os, collections, re, sys

UP = '/mnt/user-data/uploads'
MWSE = 'new/MWSEoriginals'


def source_index():
    """bodypart id (lowercase) -> (source file, armor record)."""
    idx = {}
    for path in sorted(glob.glob(os.path.join(MWSE, '*.json'))):
        name = os.path.basename(path)
        for rec in json.load(open(path)):
            if rec.get('type') != 'Armor':
                continue
            for bip in rec.get('biped_objects') or []:
                for key in ('male_bodypart', 'female_bodypart'):
                    if bip.get(key):
                        idx.setdefault(bip[key].lower(), (name, rec))
    return idx


def lookup(idx, cake_id):
    """dbs_ strips the leading underscore some ids carry, so try both."""
    stem = cake_id[4:] if cake_id.lower().startswith('dbs_') else cake_id
    for cand in (stem.lower(), ('_' + stem).lower()):
        if cand in idx:
            return idx[cand]
    return None, None


# Cosmetics carry no armour rating and should not be worth what an enchanted
# helmet is worth, but a 46-item lantern set all priced identically is no
# better. Scale the source value down and keep the relative ordering the
# author chose.
VALUE_SCALE = 0.25
MIN_VALUE = 1


def enrich(records, idx):
    stats = collections.Counter()
    unsourced = []
    # Base and worn halves must stay identical apart from the id.
    by_base = {}
    for rec in records:
        if not rec['id'].lower().endswith('_eq'):
            by_base[rec['id'].lower()] = rec

    for rec in records:
        rid = rec['id']
        base_id = rid[:-3] if rid.lower().endswith('_eq') else rid
        src_file, src = lookup(idx, base_id)
        if not src:
            unsourced.append(rid)
            stats['unsourced'] += 1
            continue

        if src.get('name'):
            rec['name'] = src['name']
            stats['name'] += 1
        if src.get('icon'):
            rec['icon'] = src['icon']
            stats['icon'] += 1

        d = src.get('data') or {}
        if 'weight' in d:
            rec.setdefault('data', {})['weight'] = round(float(d['weight']), 2)
            stats['weight'] += 1
        if 'value' in d:
            rec.setdefault('data', {})['value'] = max(MIN_VALUE,
                                                      int(round(d['value'] * VALUE_SCALE)))
            stats['value'] += 1
        rec['_source'] = src_file
    return stats, unsourced


def dedupe_names(records):
    """Number names that repeat, so a bag of sixteen scarves is navigable.

    Only base records are counted; the worn half then copies its partner, so a
    pair never disagrees.
    """
    base = [r for r in records if not r['id'].lower().endswith('_eq')]
    counts = collections.Counter(r.get('name') or '' for r in base)
    seen = collections.Counter()
    final = {}
    for r in base:
        n = r.get('name') or ''
        if counts[n] > 1:
            seen[n] += 1
            n = '%s %d' % (n, seen[n])
        r['name'] = n
        final[r['id'].lower()] = n
    for r in records:
        if r['id'].lower().endswith('_eq'):
            r['name'] = final.get(r['id'][:-3].lower(), r.get('name'))
    return records


def armor_to_cake(idx, cake_ids):
    """Source ARMO record id -> CAKE MiscItem id.

    The container and vendor inventories were authored against the source
    mods' ARMO ids (`adamantium_tail`, `_RV_Ashmask_1`). Each of those names a
    bodypart, and that bodypart names the CAKE record. So the source mods are
    the mapping authority -- no alias table needed, and no guessing.
    """
    lower = {c.lower(): c for c in cake_ids}
    out = {}
    for bodypart, (_f, armo) in idx.items():
        for cand in ('dbs_' + bodypart.lstrip('_'), 'dbs_' + bodypart):
            if cand.lower() in lower:
                out[armo['id'].lower()] = lower[cand.lower()]
                break
    return out


def remap_npc(mapping, cake_ids):
    data = json.load(open(os.path.join(UP, 'CAKE_npc.json')))
    # Records defined in this file, plus every CAKE record, since the wearables
    # live in the other plugin and a ref to one is perfectly valid.
    defined = {r['id'].lower() for r in data if r.get('type') in ('Armor', 'MiscItem', 'Static')}
    defined |= {c.lower() for c in cake_ids}
    NOT_CAKE = re.compile(r'^(sc_|expensive_|extravagant_)')
    stats = collections.Counter()
    unresolved = collections.Counter()
    for rec in data:
        if rec.get('type') not in ('Container', 'Npc'):
            continue
        # A reference to a record no plugin defines is a load warning and an
        # item that can never appear, so drop it rather than carry it.
        kept = []
        for entry in rec.get('inventory') or []:
            iid = entry[1]
            if NOT_CAKE.match(iid):
                stats['vanilla'] += 1
            elif iid.lower() in defined:
                stats['already valid'] += 1
            elif iid.lower() in mapping:
                entry[1] = mapping[iid.lower()]
                stats['remapped via source mod'] += 1
            else:
                stats['dropped (no such record)'] += 1
                unresolved[iid] += 1
                continue
            kept.append(entry)
        if rec.get('inventory') is not None:
            rec['inventory'] = kept
    return data, stats, unresolved


if __name__ == '__main__':
    idx = source_index()
    print('bodyparts indexed from source mods: %d' % len(idx))

    data = json.load(open(os.path.join(UP, 'CAKEv4_2.json')))
    recs = [r for r in data if r['type'] == 'MiscItem']
    meshes_before = {r['id']: r.get('mesh') for r in recs}

    stats, unsourced = enrich(recs, idx)
    dedupe_names(recs)

    # Mesh paths must be untouched: they belong to the mods that ship them.
    altered = [i for i, m in meshes_before.items()
               if next(r for r in recs if r['id'] == i).get('mesh') != m]
    assert not altered, 'mesh paths altered: %s' % altered[:5]

    for r in recs:
        r.pop('_source', None)

    json.dump(data, open('fixed/CAKEv4_2.json', 'w'), indent=1)

    print('enriched from source: %s' % dict(stats))
    print('unsourced records: %d %s' % (len(unsourced), unsourced))
    noicon = [r['id'] for r in recs if not r.get('icon')]
    print('still without an icon: %d %s' % (len(noicon), noicon))
    print('mesh paths altered: 0')

    mapping = armor_to_cake(idx, {r['id'] for r in recs})
    print('\nsource ARMO id -> CAKE id mappings derived: %d' % len(mapping))
    npc, stats2, unresolved2 = remap_npc(mapping, {r['id'] for r in recs})
    json.dump(npc, open('fixed/CAKE_npc.json', 'w'), indent=1)
    print('CAKE_npc inventory refs: %s' % dict(stats2))
    if unresolved2:
        print('  unresolved: %d %s' % (len(unresolved2), list(unresolved2)[:20]))
