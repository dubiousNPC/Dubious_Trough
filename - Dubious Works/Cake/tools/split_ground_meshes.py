"""Give each base record its ground mesh, leaving the worn mesh on the _eq half.

WHY
---
Bardcraft attaches a mesh from a parallel tree (`meshes/bardcraft/vfx/sheathe/`)
rather than the item's own model, and says why outright: a mesh attached as VFX
stops being interactable until the game restarts. Sun's Dusk reaches the same
place by a different route -- every one of its backpack pairs uses a `_g` ground
mesh on the base record and the worn mesh on the `_eq` record, so the model
passed to addVfx is never the model a world object uses.

CAKE currently has all 160 pairs sharing one mesh. That is a regression against
both predecessors, and it also means a dropped item renders with its worn mesh,
which for something authored to hang off a bone usually looks wrong.

WHAT IS SAFE TO CHANGE
----------------------
Only the base half, and only when the source ARMO's model is unambiguously a
ground mesh: `_GND.nif`, `_g.nif`, or `<name> gnd.nif` (Fashionwind's scarves
use a space). Anything else is left alone.

`dbs_RV_Eyepatch1L_H` is the reason for the strictness: its source ARMO points
at `RV\\blindfold1.nif`, a different item entirely. Taking "the source mesh"
uncritically would have swapped an eyepatch for a blindfold on the ground.
"""
import json, glob, os, re, collections

MWSE = 'new/MWSEoriginals'
GROUND_PAT = re.compile(r'(_gnd|_g|\sgnd)\.nif$', re.I)


def source_index():
    idx = {}
    for path in sorted(glob.glob(os.path.join(MWSE, '*.json'))):
        for rec in json.load(open(path)):
            if rec.get('type') != 'Armor':
                continue
            for bip in rec.get('biped_objects') or []:
                for key in ('male_bodypart', 'female_bodypart'):
                    if bip.get(key):
                        idx.setdefault(bip[key].lower(), rec)
    return idx


def ground_for(idx, base_id, worn_mesh):
    stem = base_id[4:] if base_id.lower().startswith('dbs_') else base_id
    src = idx.get(stem.lower()) or idx.get(('_' + stem).lower())
    if not src:
        return None, 'no source'
    mesh = src.get('mesh') or ''
    if not mesh:
        return None, 'no source mesh'
    if mesh == worn_mesh:
        return None, 'source has no separate ground mesh'
    if not GROUND_PAT.search(mesh):
        # Differs, but nothing marks it as a ground mesh -- could be a wholly
        # different item. Not worth the risk for a cosmetic improvement.
        return None, 'differs but unlabelled, skipped'
    return mesh, 'split'


if __name__ == '__main__':
    idx = source_index()
    data = json.load(open('fixed/CAKEv4_2.json'))
    recs = [r for r in data if r['type'] == 'MiscItem']
    by_id = {r['id']: r for r in recs}

    stats = collections.Counter()
    changed = []
    for rec in recs:
        if rec['id'].lower().endswith('_eq'):
            continue
        worn = rec.get('mesh') or ''
        ground, why = ground_for(idx, rec['id'], worn)
        stats[why] += 1
        if ground:
            rec['mesh'] = ground
            changed.append((rec['id'], worn, ground))

    # The worn half must keep the worn mesh; assert rather than trust.
    for base_id, worn, _g in changed:
        eq = by_id.get(base_id + '_eq')
        assert eq and eq['mesh'] == worn, 'worn mesh disturbed on %s' % base_id

    json.dump(data, open('fixed/CAKEv4_2.json', 'w'), indent=1)

    for why, n in stats.most_common():
        print('  %-38s %d' % (why, n))
    print('\nbase records now using a ground mesh: %d' % len(changed))
    for c in changed[:6]:
        print('   %-24s %-30s -> %s' % c)

    still = sum(1 for r in recs
                if not r['id'].endswith('_eq')
                and by_id.get(r['id'] + '_eq', {}).get('mesh') == r.get('mesh'))
    print('\npairs still sharing one mesh: %d (need ground meshes authored)' % still)
