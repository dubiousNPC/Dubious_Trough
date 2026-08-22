"""Validate fixed/CAKE402.json and rebuild the registry inputs from it.

Checks the exact faults the audit found, so a regression shows up here rather
than in game, then emits cake_records.json / cake_assign.json for
gen_cake_shared.py.
"""
import json, re, collections, sys

fails = []
def check(name, cond, extra=''):
    if cond:
        print('  ok   %s' % name)
    else:
        fails.append(name)
        print('  FAIL %s %s' % (name, extra))

out = json.load(open('fixed/CAKE402.json'))
recs = [r for r in out if r['type'] == 'MiscItem']
base = [r for r in recs if not r['id'].endswith('_eq')]
worn = [r for r in recs if r['id'].endswith('_eq')]
ids = [r['id'] for r in recs]

print('validating fixed/CAKE402.json')
check('320 records', len(recs) == 320, len(recs))
check('160 base + 160 worn', len(base) == 160 and len(worn) == 160,
      '%d/%d' % (len(base), len(worn)))

dupes = [i for i, c in collections.Counter(i.lower() for i in ids).items() if c > 1]
check('no duplicate ids (this was the original fault)', not dupes, dupes[:5])

low = {i.lower() for i in ids}
unpaired = [b['id'] for b in base if (b['id'] + '_eq').lower() not in low]
check('every base has an _eq partner', not unpaired, unpaired[:5])
orphan = [w['id'] for w in worn if w['id'][:-3].lower() not in low]
check('every _eq has a base partner', not orphan, orphan[:5])

check('every id carries the dbs_ prefix',
      all(i.lower().startswith('dbs_') for i in ids),
      [i for i in ids if not i.lower().startswith('dbs_')][:5])

noname = [r['id'] for r in recs if not (r.get('name') or '').strip()]
check('no record has an empty display name', not noname, noname[:5])

eqname = [r['id'] for r in recs if (r.get('name') or '').endswith('_eq')]
check('_eq never leaks into a display name', not eqname, eqname[:5])

pairbad = [b['id'] for b in base
           if b['name'] != next(w['name'] for w in worn if w['id'] == b['id'] + '_eq')]
check('base and worn share a display name', not pairbad, pairbad[:5])

names = collections.Counter(b['name'] for b in base)
check('display names are unique among base records',
      all(v == 1 for v in names.values()),
      [k for k, v in names.items() if v > 1][:5])

# The collision the dbs_ prefix was meant to resolve.
bodyparts = {r['id'].lower() for r in json.load(open('/mnt/user-data/uploads/CAKE3npcCont.json'))
             if r.get('type') == 'Bodypart'}
collide = [i for i in ids if i.lower() in bodyparts]
check('no id shadows a Bodypart id', not collide, collide[:5])

nomesh = [r['id'] for r in recs if not r.get('mesh')]
check('every record has a mesh', not nomesh, nomesh[:5])

withicon = sum(1 for r in base if r.get('icon'))
print('  --   icons present on %d / %d base records' % (withicon, len(base)))

# --------------------------------------------------------------- references
fixed3 = json.load(open('fixed/CAKE3npcCont.json'))
defined = {r['id'].lower() for r in fixed3 if r.get('type') in ('Armor', 'MiscItem', 'Static')}
defined |= low
NOT_CAKE = re.compile(r'^(sc_|expensive_|extravagant_)')
unres = collections.Counter()
for r in fixed3:
    if r.get('type') in ('Container', 'Npc'):
        for _, iid in r.get('inventory') or []:
            if iid.lower() not in defined and not NOT_CAKE.match(iid):
                unres[iid] += 1
tails_only = all('tail' in k.lower() or 'domina' in k.lower() for k in unres)
check('every unresolved container ref is a tail (tails are excluded by design)',
      tails_only, list(unres)[:5])
print('  --   unresolved refs: %d, all tails' % len(unres))

stocked = set()
for r in fixed3:
    if r.get('type') in ('Container', 'Npc'):
        for _, iid in r.get('inventory') or []:
            if iid.lower() in low:
                stocked.add(iid.lower())
print('  --   CAKE items now stocked somewhere: %d / 160' % len(stocked))

# ------------------------------------------------------------ registry feed
records = {r['id']: {'type': 'MISC', 'id': r['id'], 'name': r.get('name'),
                     'model': (r.get('mesh') or '').replace('\\', '/')}
           for r in recs}
json.dump(records, open('cake_records.json', 'w'), indent=1)

PATS = [
    (r'ashmask|daedramask|orcishmask|facewrap|mask', 'masks'),
    (r'cigar', 'smokes'),
    (r'blindfold|eyepatch|glasses|goggle|lenses', 'eyewear'),
    (r'scarf', 'scarves'),
    (r'tail|domina|bear|darkbro|helseth|nordtail|orctail|gold', 'tails'),
    (r'lantern|lantn|lan\d|colov|indoril|glantern|cave|wood|orclan|pap|ash\d', 'lanterns'),
    (r'belt', 'belts'),
    (r'fannypack|waistbag|thighbag|fpktbg|fpkpch|satchel|ubelt', 'bags'),
]
assign, unclassified = {}, []
for r in worn:
    hay = (r['id'] + ' ' + (r.get('mesh') or '') + ' ' + (r.get('name') or '')).lower()
    for pat, cat in PATS:
        if re.search(pat, hay):
            assign[r['id']] = {'category': cat, 'bone': None}
            break
    else:
        unclassified.append(r['id'])
check('every worn record classifies into a category', not unclassified, unclassified[:8])
json.dump(assign, open('cake_assign.json', 'w'), indent=1)

print('\n%s' % ('ALL PASS' if not fails else '%d FAILURES' % len(fails)))
sys.exit(1 if fails else 0)
