"""Rewrite CAKE402.json and CAKE3npcCont.json onto the dbs_ scheme.

Three faults are corrected, in this order:

  1. The `_eq` suffix was applied to FNAM (display name) instead of NAME
     (record id), so the second block of 160 records overwrote the first and
     no worn variant existed. The suffix is moved onto the id and the display
     names are restored.

  2. Ids gain the `dbs_` prefix. This is not a new convention: `dbs_` + the id
     with its leading underscore stripped reproduces the ids already in
     CAKE.esp/CAKE34.esp for 159 of 160 records, and all 160 `_eq` partners
     already exist there. It also resolves the bodypart collision, since
     `dbs_RV_Ashmask1_H` no longer shadows the `_RV_Ashmask1_H` bodypart.

  3. Icons are attached by matching each record's mesh to a shipped icon file,
     falling back to the icon the equivalent ARMO record already uses.

Container and vendor inventories in CAKE3npcCont are remapped to the new ids so
the items are actually obtainable.
"""
import json, os, re, collections, difflib

UP = '/mnt/user-data/uploads'
ICON_ROOT = 'ref/CAKE/CAKE/icons'

# ---------------------------------------------------------------- id scheme

def dbs_id(raw):
    """`_RV_Ashmask1_H` -> `dbs_RV_Ashmask1_H`; `1adamantail` -> `dbs_1adamantail`."""
    return 'dbs_' + raw.lstrip('_')


# ------------------------------------------------------------- name repairs

# Names that describe the wrong object entirely. Verified against the mesh.
NAME_FIX = {
    '_RV_Ashmask3_H':   'Ashmask',      # was "tail armor"
    '_RV_Blindfold1_H': 'Blindfold',    # was "Ashmask"
    'hfirebelt':        'Heartfire Belt',  # was "lantern"
}

# The five records with no FNAM at all, which render as a blank inventory row.
NAME_MISSING = {
    '_RV_Goggles5_H':    'Goggles',
    '_RV_Goggles6_H':    'Goggles',
    '_RV_Goggles7_H':    'Goggles',
    '_RV_Goggles8_H':    'Goggles',
    '_RV_Orcishmask1_H': 'Orcish Mask',
}


def base_name(rec):
    n = rec.get('name') or ''
    n = re.sub(r'_eq$', '', n)              # undo the misplaced suffix
    n = NAME_FIX.get(rec['id'], n)
    if not n:
        n = NAME_MISSING.get(rec['id'], '')
    return n


def dedupe_names(records):
    """Number repeated display names so a player can tell 16 scarves apart.

    Only touches names that actually repeat; unique names are left alone.
    """
    counts = collections.Counter(r['_name'] for r in records)
    seen = collections.Counter()
    for r in records:
        n = r['_name']
        if counts[n] > 1:
            seen[n] += 1
            r['_name'] = '%s %d' % (n, seen[n])
    return records


# -------------------------------------------------------------------- icons

def icon_index():
    idx = {}
    for root, _, files in os.walk(ICON_ROOT):
        for f in files:
            rel = os.path.relpath(os.path.join(root, f), ICON_ROOT).replace('/', '\\')
            idx[os.path.splitext(f)[0].lower()] = rel
    return idx


def armo_icons():
    """Icon each ARMO record uses, keyed by its bodypart id."""
    out = {}
    for r in json.load(open(os.path.join(UP, 'CAKE3npcCont.json'))):
        if r.get('type') != 'Armor' or not r.get('icon'):
            continue
        for b in r.get('biped_objects') or []:
            for k in ('male_bodypart', 'female_bodypart'):
                if b.get(k):
                    out[b[k].lower()] = r['icon']
    return out


# Icon lookup by id pattern. The mesh stem and the icon stem were named by
# different hands (`light_de_lantern_02` vs nothing at all), so a stem match
# alone covers barely a fifth of the set.
ICON_RULES = [
    # RV facewear: icon stems carry an underscore the ids do not.
    (r'^_RV_Ashmask(\d)_H$',      r'RV\\ashmask\1.tga'),
    (r'^_RV_Facewrap(\d)_H$',     r'RV\\facewrap\1.tga'),
    (r'^_RV_Daedramask(\d)_H$',   r'RV\\Daedramask\1.tga'),
    (r'^_RV_Orcishmask(\d)_H$',   r'RV\\Orcishmask\1.tga'),
    (r'^_RV_Goggles(\d)_H$',      r'RV\\Goggles_\1.tga'),
    (r'^_RV_Glasses(\d)_H$',      r'RV\\Glasses_\1.tga'),
    (r'^_RV_Glasses(\d)s_H$',     r'RV\\Glasses_\1s.tga'),
    (r'^_RV_Lenses(\d)_H$',       r'RV\\Lenses_\1.tga'),
    (r'^_RV_Blindfold1_H$',       r'RV\\Blindfold_1.tga'),
    (r'^_RV_Eyepatch1([LR])_H$',  r'RV\\Eyepatch1\1.tga'),
    # Scarves: ids are zero-padded, icons are not.
    (r'^_RV_Scarf_0?(\d+)$',      r'RV\\scarf\1.tga'),
    # Ashlander lanterns are the only lanterns with icons.
    (r'^ash(\d)$',                r'lanterns\\ash\1.dds'),
    # Bags share five icons across fourteen records.
    (r'^aa_fannypack',            r'frummyonda\\fy_fannypack.dds'),
    (r'^aa_waistbag',             r'frummyonda\\fy_fannypack.dds'),
    (r'^aa_fpk',                  r'frummyonda\\fy_fpktbg.dds'),
    (r'^aa_satchel',              r'frummyonda\\fy_satchel.dds'),
    (r'^aa_thighbag',             r'frummyonda\\fy_thighbag.dds'),
    (r'^aa_ubelt$',               r'frummyonda\\fy_ubelt.dds'),
]

# Tails are excluded from the Lua registry but still get icons, so the records
# are complete if a beast skeleton is added later.
TAIL_ICON = re.compile(r'^ArmoredTails[\\/](\w+?)\.nif$', re.I)


def pick_icon(rec, idx, from_armo):
    rid = rec['id']

    # An ARMO already dressed this exact bodypart: reuse its icon verbatim.
    hit = from_armo.get(rid.lower())
    if hit:
        return hit, 'armo'

    for pat, repl in ICON_RULES:
        m = re.match(pat, rid, re.I)
        if m:
            # expand(), not re.sub(): the prefix rules are anchored but not
            # anchored at the end, so sub() would leave the unmatched tail
            # glued onto the icon path ("fy_fannypack.dds_l").
            path = m.expand(repl)
            if os.path.exists(os.path.join(ICON_ROOT, path.replace('\\', '/'))):
                return path, 'rule'

    mesh = (rec.get('mesh') or '').replace('/', '\\')
    m = TAIL_ICON.match(mesh)
    if m:
        stem = m.group(1).lower()
        for cand in (stem, stem.replace('tail', '')):
            if cand in idx and idx[cand].lower().startswith('a\\armoredtails'):
                return idx[cand], 'tail'

    stem = re.split(r'[\\/]', mesh)[-1].rsplit('.', 1)[0].lower()
    if stem in idx:
        return idx[stem], 'mesh'

    return None, 'none'


# ------------------------------------------------------------------ rewrite

def rewrite_402():
    data = json.load(open(os.path.join(UP, 'CAKE402.json')))
    header = [r for r in data if r['type'] == 'Header']
    misc = [r for r in data if r['type'] == 'MiscItem']
    assert len(misc) == 320, len(misc)
    A, B = misc[:160], misc[160:]
    assert [a['id'] for a in A] == [b['id'] for b in B], 'blocks are not parallel'

    idx, from_armo = icon_index(), armo_icons()

    for a in A:
        a['_name'] = base_name(a)
    dedupe_names(A)

    stats = collections.Counter()
    out, mapping = list(header), {}

    for a, b in zip(A, B):
        raw = a['id']
        base, worn = dbs_id(raw), dbs_id(raw) + '_eq'
        mapping[raw] = base

        icon, how = pick_icon(a, idx, from_armo)
        stats[how] += 1

        for newid, src in ((base, a), (worn, b)):
            rec = dict(src)
            rec.pop('_name', None)
            rec['id'] = newid
            # Both halves keep the same display name. The worn state is visible
            # from the icon and from the item having moved, and encoding it in
            # the name is what broke this file in the first place.
            rec['name'] = a['_name']
            if icon:
                rec['icon'] = icon
            out.append(rec)

    return out, mapping, stats


# Old container ids to CAKE402 ids. Curated, not fuzzy-matched: difflib
# happily mapped `LanternPapery1` onto `LanternPap1`, which is a different
# lantern and already claimed by `LanternPaper1`. Every entry below was
# checked against the target record's mesh path.
ALIAS = {
    # abbreviations
    'GlassLantern2': 'GLantern2',   'GlassLantern6': 'GLantern6',
    'GlassLanterngrn': 'GLanterngrn', 'GlassLanternred': 'GLanternred',
    'GlassLanternyel': 'GLanternyel',
    'LanternDwem': 'Lantern0AABDwrn',
    'TravelLantern1': 'TravLantern1', 'TravelLantern2': 'TravLantern2',
    'cavernlant': 'cavelant', 'woodlantern': 'woodlan',
    'orclantern1': 'orclan1', 'orclantern2': 'orclan2',
    'colovianlant2': 'colov2', 'colovianlant3': 'colov3',
    'colovianlant4': 'colov4', 'colovianlant5': 'colov5',
    'ashl1': 'ash1', 'ashl2': 'ash2', 'ashl3': 'ash3', 'ashl4': 'ash4',
    'ashl5': 'ash5', 'ashl6': 'ash6', 'ashl7': 'ash7',
    # LanternPaper<colour><n> -> LanternPap<colour><n>; note prp -> pur and
    # y -> yel, which is why this cannot be a prefix rule.
    'LanternPaper1': 'LanternPap1',   'LanternPaper5': 'LanternPap5',
    'LanternPaper7': 'LanternPap7',   'LanternPaper10': 'LanternPap10',
    'LanternPaper11': 'LanternPap11', 'LanternPaper14': 'LanternPap14',
    'LanternPaperblue1': 'LanternPapblu1', 'LanternPaperblue4': 'LanternPapblu4',
    'LanternPapergrn1': 'LanternPapgrn1', 'LanternPapergrn4': 'LanternPapgrn4',
    'LanternPaperprp1': 'LanternPappur1', 'LanternPaperprp4': 'LanternPappur4',
    'LanternPapery1': 'LanternPapyel1',   'LanternPapery4': 'LanternPapyel4',
    # Tamriel_Data Indoril hanging lanterns
    'Indoril1': 'TRIndorilLan1', 'Indoril2': 'TRIndorilLan2', 'Indoril3': 'TRIndorilLan3',
    'IndorilGreen1': 'TRIndorilGRLan1', 'IndorilGreen2': 'TRIndorilGRLan2',
    'IndorilGreen3': 'TRIndorilGRLan3',
    'IndorilPur1': 'TRIndorilPurLan1', 'IndorilPur2': 'TRIndorilPurLan2',
    'IndorilPur3': 'TRIndorilPurLan3',
    # belts
    'commonbelt1': 'cbelt1', 'commonbelt2': 'cbelt2', 'commonbelt3': 'cbelt3',
    'commonbelt4': 'cbelt4', 'commonbelt5': 'cbelt5',
    'expensivebelt1': 'expbelt1', 'expensivebelt2': 'expbelt2',
    'expensivebelt3': 'expbelt3',
    'extravagantbelt1': 'extravbelt1', 'extravagantbelt2': 'extravbelt2',
    'exquistebelt': 'exqbelt', 'heartfire': 'hfirebelt', 'Erabenimsun': 'erabinbelt',
    # frummyonda bags: fy_ prefix became aa_
    'fy_fannypack_b': 'aa_fannypack', 'fy_waistbag_b': 'aa_waistbag',
    'fy_fpkpch': 'aa_fpkpch', 'fy_fpktbg_l': 'aa_fpktbg_l',
    'fy_thighbag_l': 'aa_thighbag_l', 'fy_ubelt': 'aa_ubelt',
    'fy_satchel': 'aa_satchel_m',
}

# Items the vendor legitimately carries that are not CAKE content and must be
# left exactly as they are.
NOT_CAKE = re.compile(r'^(sc_|expensive_|extravagant_)')


def rewrite_npccont(mapping):
    data = json.load(open(os.path.join(UP, 'CAKE3npcCont.json')))
    defined = {r['id'].lower() for r in data if r.get('type') in ('Armor', 'MiscItem', 'Static')}
    lower = {k.lower(): v for k, v in mapping.items()}

    def denum(x):
        return re.sub(r'0+(\d)', r'\1', re.sub(r'[^a-z0-9]', '', x.lower()))

    # Normalised index over the pre-rename ids, so `_RV_Ashmask_1` finds
    # `_RV_Ashmask1_H` without needing an explicit alias for all 33 of them.
    norm = {}
    for old_id in mapping:
        for variant in (old_id, old_id.replace('_H', '')):
            norm.setdefault(denum(variant), old_id)

    def resolve(iid):
        if NOT_CAKE.match(iid):
            return iid, 'vanilla'
        if iid.lower() in defined:
            return iid, 'kept'
        target = ALIAS.get(iid)
        if target and target in mapping:
            return mapping[target], 'alias'
        if iid.lower() in lower:
            return lower[iid.lower()], 'direct'
        hit = norm.get(denum(iid))
        if hit:
            return mapping[hit], 'normalised'
        return iid, 'unresolved'

    stats = collections.Counter()
    unresolved = collections.Counter()
    claimed = collections.Counter()
    for r in data:
        if r.get('type') not in ('Container', 'Npc'):
            continue
        for e in r.get('inventory') or []:
            new, how = resolve(e[1])
            stats[how] += 1
            if how in ('alias', 'direct', 'normalised'):
                e[1] = new
                claimed[new] += 1
            elif how == 'unresolved':
                unresolved[e[1]] += 1

    # Two different old ids collapsing onto one record means an alias is wrong.
    dupes = {k: v for k, v in claimed.items() if v > 2}
    return data, stats, unresolved, dupes


if __name__ == '__main__':
    os.makedirs('fixed', exist_ok=True)

    out402, mapping, icon_stats = rewrite_402()
    json.dump(out402, open('fixed/CAKE402.json', 'w'), indent=1)
    print('CAKE402: %d records out (%d pairs)' % (len(out402) - 1, (len(out402) - 1) // 2))
    print('  icons: %s' % dict(icon_stats))
    if icon_stats['none']:
        missing = [a['id'] for a in json.load(open('fixed/CAKE402.json'))[1:]
                   if not a.get('icon')]
        print('  records still without an icon: %d' % len(set(missing)))

    out3, ref_stats, unresolved, dupes = rewrite_npccont(mapping)
    json.dump(out3, open('fixed/CAKE3npcCont.json', 'w'), indent=1)
    print('CAKE3npcCont inventory refs: %s' % dict(ref_stats))
    if dupes:
        print('  !! ids claimed by more than one source ref: %s' % dupes)
    if unresolved:
        print('  still unresolved (%d distinct):' % len(unresolved))
        for k, v in unresolved.most_common(40):
            print('     %-26s x%d' % (k, v))
