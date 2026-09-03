"""Emit cake_shared.lua from the CAKE plugins themselves.

Supersedes gen_shared.py, which built the registry from OMWFW's record id
tables. Those ids turned out to describe different content entirely: not one
of the 50 ids in globalcake.lua exists in CAKE.esp/CAKE34.esp. The authority
is the plugin, so the plugin is what gets read.
"""
import json, io, re, collections

recs = json.load(open('cake_records.json'))
assign = json.load(open('cake_assign.json'))

# Bones confirmed present in meshes/dbs/xbase_anim_dbs.nif.
DBS_BONES = ['Bip01 beltDBS', 'Bip01 R hipDBS', 'Bip01 L hipDBS', 'Bip01 chestDBS',
             'Bip01 backpackDBS', 'Bip01 capeDBS', 'Bip01 mouthDBS', 'Bip01 eyesDBS',
             'Bip01 earsDBS', 'Bip01 hornsDBS', 'Bip01 scarfDBS', 'Bip01 pendantDBS']

CATEGORIES = collections.OrderedDict([
    ('lanterns', ('Bip01 L hipDBS',  'Bip01 Pelvis')),
    ('eyewear',  ('Bip01 eyesDBS',   'head')),
    ('masks',    ('Bip01 mouthDBS',  'head')),
    ('scarves',  ('Bip01 scarfDBS',  'Bip01 Neck')),
    ('belts',    ('Bip01 beltDBS',   'Bip01 Pelvis')),
    ('bags',     ('Bip01 beltDBS',   'Bip01 Pelvis')),
    ('smokes',   ('Bip01 mouthDBS',  'head')),
    ('ears',     ('Bip01 earsDBS',   'head')),
])

CONFLICTS = {'masks': ['smokes'], 'smokes': ['masks']}

# Tails are deliberately excluded. They belong on the beast skeleton
# (xbase_animkna), and CAKE ships only xbase_anim_dbs.nif, which has no tail
# bone -- confirmed by reading all 123 nodes. Rather than point 33 items at a
# bone that does not exist, as playergear.lua did, they are left out of the
# registry entirely until a kna variant exists.
EXCLUDED = {'tails'}

items = {}
excluded_count = 0
for eqid, a in assign.items():
    if a['category'] in EXCLUDED:
        excluded_count += 1
        continue
    base = eqid[:-3]
    if base not in recs:
        continue
    items[base] = {
        'eq': eqid,
        'category': a['category'],
        'model': recs[eqid].get('model') or recs[base].get('model') or '',
        'name': recs[eqid].get('name') or recs[base].get('name') or '',
    }

out = io.StringIO()
W = out.write

W('''---@omw-context shared
--[[
    cake_shared.lua -- single source of truth for CAKE

    Generated from the corrected CAKE402 plugin and from the node names in
    meshes/dbs/xbase_anim_dbs.nif. Nothing in this file is typed by hand, so
    the registry cannot drift from the plugins and skeleton it describes.

    RECORD SCHEME
    -------------
    Every wearable is a types.Miscellaneous pair:

        dbs_<thing>        the item that sits in the inventory
        dbs_<thing>_eq     the item that replaces it while worn

    Using the base record destroys it and creates the _eq record; using the
    _eq record converts it back. This is Sun's Dusk's backpack mechanism, and
    it is what makes CAKE non-invasive: a Miscellaneous item occupies no
    equipment slot at all, so unlike the OMWFW approach nothing has to be
    blocked from equipping and no helmet or pauldron is displaced. It also
    means the worn state is visible in the inventory as a distinct item with
    its own icon, rather than living only in script state.

    BOTH halves of the pair carry the same model. The _eq record's model is
    what gets attached as a VFX.

    BONES
    -----
    The DBS bones below are the twelve confirmed present in
    xbase_anim_dbs.nif. Each category also names a vanilla `fallback` bone
    for players running without that skeleton, because attaching to a missing
    bone is a silent no-show rather than an error.

    NO TAILS
    --------
    The plugins define 33 tail pairs and playergear.lua pointed all of them at
    `Bip01 tailsDBS`. That bone does not exist -- all 123 nodes of
    xbase_anim_dbs.nif were read and none is a tail -- so every tail failed
    hasBone and rendered nothing.

    Tails belong on the beast skeleton (xbase_animkna), which CAKE does not
    ship. They are therefore excluded from this registry rather than pointed
    at a substitute: a wrong bone is worse than an absent entry, because it
    looks like a working feature that silently does nothing. Re-add them by
    dropping the `tails` entry from EXCLUDED in tools/gen_cake_shared.py once
    a kna skeleton with a tail bone is in the package.
]]

local M = {}

M.version = 2

-- Suffix appended to a base record id to get its worn counterpart.
M.EQ_SUFFIX = '_eq'

-- ---------------------------------------------------------------------------
-- SKELETON
-- ---------------------------------------------------------------------------

-- Node names read directly out of meshes/dbs/xbase_anim_dbs.nif.
M.DBS_BONES = {
''')
for b in DBS_BONES:
    W("    ['%s'] = true,\n" % b)
W('''}

M.SKELETON = {
    auto    = { label = 'Auto-detect', probe = true },
    dbs     = { label = 'xbase_anim_dbs.nif', probe = false, bones = M.DBS_BONES },
    vanilla = { label = 'Vanilla skeleton only', probe = false, bones = {} },
}

M.DEFAULT_SKELETON = 'auto'

-- ---------------------------------------------------------------------------
-- CATEGORIES
-- ---------------------------------------------------------------------------
-- One vfxId per category, so categories sharing a bone do not evict each
-- other. `conflicts` names categories that cannot be worn together.

M.CATEGORIES = {
''')
# A category with no items is dead weight, and worse than dead: cake_anim.lua
# validates its group keys against CATEGORIES and errors on an unknown one, so
# an empty category left behind by a reclassification is a load failure waiting
# to happen. Drop them here rather than remembering to prune by hand.
EMPTY = [c for c in CATEGORIES if not any(v['category'] == c for v in items.values())]
for c in EMPTY:
    del CATEGORIES[c]
if EMPTY:
    print('dropped empty categories: %s' % ', '.join(EMPTY))

for cat, (bone, fb) in CATEGORIES.items():
    n = sum(1 for v in items.values() if v['category'] == cat)
    W("    %-9s = {\n" % cat)
    W("        label        = '%s',\n" % cat.capitalize())
    W("        vfxId        = 'cake_%s',\n" % cat)
    assert bone in DBS_BONES, 'category %s points at non-existent bone %s' % (cat, bone)
    W("        bone         = '%s',\n" % bone)
    W("        boneFallback = '%s',\n" % fb)
    W("        conflicts    = { %s },\n" % ', '.join("'%s'" % c for c in CONFLICTS.get(cat, [])))
    W("        count        = %d,\n" % n)
    W("    },\n")

W('''}

-- ---------------------------------------------------------------------------
-- ITEMS
-- ---------------------------------------------------------------------------
-- Keyed by the BASE record id (lowercase, because OpenMW compares record ids
-- lowercase). `eq` is the worn record. `model` is reproduced verbatim from the
-- record, case and separators untouched: most of these meshes are supplied by
-- other mods and the path belongs to them.

M.ITEMS = {
''')
for cat in CATEGORIES:
    sel = sorted(k for k, v in items.items() if v['category'] == cat)
    W("    -- %s (%d)\n" % (cat, len(sel)))
    for k in sel:
        v = items[k]
        # Model path is emitted EXACTLY as the record states it -- original
        # case, original backslashes. Most of these meshes ship with other
        # mods (Tamriel_Data, OAAB, Project Cyrodiil and others), so the path
        # is their property, not ours to normalise. Lua needs the backslash
        # escaped in a quoted string; that is the only change made.
        model = v['model'].replace('\\', '\\\\')
        W("    ['%s']%s= { eq = '%s', category = '%s', model = '%s' },\n"
          % (k.lower(), ' ' * max(1, 26 - len(k)), v['eq'].lower(), cat, model))
    W("\n")

W('''}

-- ---------------------------------------------------------------------------
-- DERIVED
-- ---------------------------------------------------------------------------

-- Reverse index: worn record id -> base record id.
M.EQ_TO_BASE = {}
for baseId, entry in pairs(M.ITEMS) do
    M.EQ_TO_BASE[entry.eq] = baseId
end

M.allBones = {}
for _, cat in pairs(M.CATEGORIES) do
    if cat.bone then M.allBones[cat.bone] = true end
    M.allBones[cat.boneFallback] = true
end

-- ---------------------------------------------------------------------------
-- HELPERS
-- ---------------------------------------------------------------------------

---Entry for a base record id.
function M.get(recordId)
    if type(recordId) ~= 'string' then return nil end
    return M.ITEMS[recordId:lower()]
end

---Base record id for a worn record id, or nil if this is not a worn CAKE item.
---Uses the reverse index rather than string surgery: the old code did
---`id:sub(1, -4)`, which silently produced a non-existent id for anything
---whose naming did not match its assumption.
function M.baseOf(equippedId)
    if type(equippedId) ~= 'string' then return nil end
    return M.EQ_TO_BASE[equippedId:lower()]
end

---Worn record id for a base record id.
function M.eqOf(baseId)
    local entry = M.get(baseId)
    return entry and entry.eq or nil
end

function M.isBaseItem(recordId) return M.get(recordId) ~= nil end
function M.isWornItem(recordId) return M.baseOf(recordId) ~= nil end

---Category definition for either half of a pair.
function M.categoryOf(recordId)
    local entry = M.get(recordId) or M.get(M.baseOf(recordId))
    return entry and M.CATEGORIES[entry.category] or nil
end

return M
''')

open('out/cake_shared.lua', 'w').write(out.getvalue())
print('items: %d pairs (%d excluded: %s)' % (len(items), excluded_count, ', '.join(sorted(EXCLUDED))))
for c in CATEGORIES:
    print('  %-9s %3d' % (c, sum(1 for v in items.values() if v['category'] == c)))
