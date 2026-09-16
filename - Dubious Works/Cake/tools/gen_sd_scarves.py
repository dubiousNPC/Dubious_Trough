"""Emit the Sun's Dusk `Scarves` module from CAKE's masks and scarves.

Item ids, bones and meshes come from cake_shared.lua; nothing is typed by hand,
so the module cannot drift from the plugin CAKE ships.
"""
import re, os, io, json

SRC = 'out/pkg/CAKE/scripts/cake/cake_shared.lua'
OUT = 'sd_scarves/Scarves'

shared = open(SRC, encoding='utf-8').read()

ROW = re.compile(
    r"\['([\w_]+)'\]\s*= \{ eq = '([\w_]+)', category = '(\w+)', model = '([^']*)' \}")

items = {'masks': [], 'scarves': []}
for base, eq, cat, model in ROW.findall(shared):
    if cat in items:
        # cake_shared escapes the backslash for Lua; unescape for JSON output.
        items[cat].append((base, eq, model.replace('\\\\', '\\')))
for k in items:
    items[k].sort()

# Bones as CAKE resolves them, with a vanilla fallback for a skeleton without
# the DBS rig.
BONES = {
    'scarves': ('Bip01 scarfDBS', 'Bip01 Neck'),
    'masks':   ('Bip01 mouthDBS', 'head'),
}

# Warmth is granted in binary-encoded steps, exactly as backpacks does feather:
# eight ability records with magnitudes 1,2,4..128 sum to any value 0-255.
WARMTH_BITS = [1, 2, 4, 8, 16, 32, 64, 128]

os.makedirs(OUT + '/scripts/SunsDuskScarves', exist_ok=True)
os.makedirs(OUT + '/l10n', exist_ok=True)


def lua_id_table(rows, indent='\t'):
    return '\n'.join("%s%s = true," % (indent, base) for base, _e, _m in rows)


# ---------------------------------------------------------------- global -----
g = io.StringIO()
g.write('''--[[
	g_scarves.lua -- Scarves & Masks, the equip swap

	A straight copy of g_backpacks.lua's mechanism: a Miscellaneous item and an
	`_eq` twin, swapped by an ItemUsage handler. Nothing here occupies an
	equipment slot, so a scarf costs you no helmet and no pauldron.

	Two differences from backpacks, both deliberate:

	  * TWO categories, not one. A scarf and a mask sit on different bones and
	    can be worn together, so the "take off whatever is already worn" step
	    is per category rather than global. Wearing a second scarf replaces the
	    first; wearing a mask does not disturb it.

	  * getBaseId does a REVERSE LOOKUP, not string surgery. g_backpacks.lua
	    derives the base id with `equippedId:sub(1, -4)`, which is right only
	    while every id ends in exactly "_eq" and the base exists. An explicit
	    table cannot silently produce an id that was never defined -- and it
	    also defines the module's whole vocabulary in one place.

	Ids, bones and meshes are generated from CAKE's cake_shared.lua.
]]

''')

for cat in ('scarves', 'masks'):
    g.write('local %s_IDS = {\n%s\n}\n\n' % (cat.upper(), lua_id_table(items[cat])))

g.write('''-- base id -> category, and equipped id -> base id. Built once at load.
local CATEGORY_OF = {}
local BASE_OF_EQ  = {}
for id in pairs(SCARVES_IDS) do
	CATEGORY_OF[id] = "scarves"
	BASE_OF_EQ[id .. "_eq"] = id
end
for id in pairs(MASKS_IDS) do
	CATEGORY_OF[id] = "masks"
	BASE_OF_EQ[id .. "_eq"] = id
end

local function consumeOne(item)
	if item.count > 1 then item:split(1):remove() else item:remove() end
end

-- Take off whatever is worn in `category`, returning it to the inventory.
local function unwearCategory(inv, category)
	for _, invItem in ipairs(inv:getAll(types.Miscellaneous)) do
		local baseId = BASE_OF_EQ[invItem.recordId]
		if baseId and CATEGORY_OF[baseId] == category then
			consumeOne(invItem)
			world.createObject(baseId, 1):moveInto(inv)
			return baseId
		end
	end
	return nil
end

I.ItemUsage.addHandlerForType(types.Miscellaneous, function(item, actor)
	if not types.Player.objectIsInstance(actor) then return end

	local itemId = item.recordId
	local inv = types.Actor.inventory(actor)

	-- Used something already worn: take it off.
	local wornBase = BASE_OF_EQ[itemId]
	if wornBase then
		consumeOne(item)
		world.createObject(wornBase, 1):moveInto(inv)
		actor:sendEvent("SunsDusk_playSound", "Item Clothes Up")
		actor:sendEvent("SunsDuskScarves_equipped",
			{ category = CATEGORY_OF[wornBase], equippedId = nil })
		return
	end

	local category = CATEGORY_OF[itemId]
	if not category then return end

	-- Replace only what shares this category.
	unwearCategory(inv, category)

	consumeOne(item)
	local newEquippedId = itemId .. "_eq"
	world.createObject(newEquippedId, 1):moveInto(inv)

	actor:sendEvent("SunsDusk_playSound", "Item Clothes Up")
	actor:sendEvent("SunsDuskScarves_equipped",
		{ category = category, equippedId = newEquippedId })
end)

-- A worn record that leaves the player's inventory -- dropped, sold, put in a
-- container, pickpocketed -- has to become its base form again, or the world
-- fills with items stuck in their "currently worn" state. Same sweep as
-- backpacks, over the same four places.
local function convertWornInCell(player)
	if not player or not player:isValid() then return end
	local cell = player.cell
	if not cell then return end

	for _, obj in ipairs(cell:getAll(types.Miscellaneous)) do
		local baseId = BASE_OF_EQ[obj.recordId]
		if baseId then
			local count, rot = obj.count, obj.rotation
			-- Bounding box rather than a hardcoded offset table: every one of
			-- these is a small head or neck mesh, and the box is always there.
			local bbox = obj:getBoundingBox()
			local pos = util.vector3(bbox.center.x, bbox.center.y,
				bbox.center.z - bbox.halfSize.z * 0.9)
			obj:remove()
			world.createObject(baseId, count):teleport(cell, pos, rot)
		end
	end

	local function sweepInventory(inv)
		for _, item in ipairs(inv:getAll(types.Miscellaneous)) do
			local baseId = BASE_OF_EQ[item.recordId]
			if baseId then
				local count = item.count
				item:remove()
				world.createObject(baseId, count):moveInto(inv)
			end
		end
	end

	for _, container in ipairs(cell:getAll(types.Container)) do
		sweepInventory(types.Container.content(container))
	end
	for _, actor in ipairs(cell:getAll(types.NPC)) do
		if not types.Player.objectIsInstance(actor) then
			sweepInventory(types.Actor.inventory(actor))
		end
	end
	for _, actor in ipairs(cell:getAll(types.Creature)) do
		sweepInventory(types.Actor.inventory(actor))
	end
end

G_eventHandlers.SunsDuskScarves_convertInCell = convertWornInCell
''')
open(OUT + '/scripts/SunsDuskScarves/g_scarves.lua', 'w').write(g.getvalue())

# ---------------------------------------------------------------- player -----
p = io.StringIO()
p.write('''--[[
	p_scarves.lua -- Scarves & Masks, worn state and bonuses

	Mirrors p_backpacks.lua. Where that grants a carry-weight feather scaled to
	the camping gear you are hauling, this grants:

	  SCARVES  warmth, through Sun's Dusk's temperature system
	  MASKS    blight resistance

	Both magnitudes come from settings and both are granted as ABILITY RECORDS,
	which is the only way an addon can feed the temperature system: p_temp
	scans equipped armour and clothing for its material modifiers, and a CAKE
	scarf is a Miscellaneous item that occupies no slot, so it is invisible to
	that scan. I.SunsDusk's temperature functions return display STRINGS, not
	numbers, so there is nothing to add to there either. An ability is what
	`sd_hearthfire_1..4` already are, so warmth from a scarf reaches the player
	by exactly the route warmth from a fire does.

	WARMTH IS BINARY-ENCODED, exactly as backpacks encodes feather: eight
	ability records with magnitudes 1, 2, 4 ... 128 sum to any value from 0 to
	255, and only the bits that changed are added or removed. It costs eight
	records to make one configurable number.

	Every ability is applied only `if core.magic.spells.records[id]` -- so a
	missing record degrades to no bonus rather than to an error, and the module
	still works if you strip the ability records from the plugin.
]]

local VFX_SCARF = "SD_scarfVfx"
local VFX_MASK  = "SD_maskVfx"

''')

for cat in ('scarves', 'masks'):
    bone, fallback = BONES[cat]
    p.write('local %s_BONE     = "%s"\n' % (cat.upper()[:-1] if cat == 'masks' else 'SCARF', bone))
    p.write('local %s_FALLBACK = "%s"\n' % (cat.upper()[:-1] if cat == 'masks' else 'SCARF', fallback))
p.write('\n')

p.write('local CATEGORY_OF = {\n')
for cat in ('scarves', 'masks'):
    for base, eq, _m in items[cat]:
        p.write('\t["%s"] = "%s",\n' % (eq, cat))
p.write('}\n\n')

p.write('''local VFX_OF = { scarves = VFX_SCARF, masks = VFX_MASK }
local BONE_OF = {
	scarves = { SCARF_BONE, SCARF_FALLBACK },
	masks   = { MASK_BONE,  MASK_FALLBACK },
}

-- Binary-encoded ability ids, as sd_feather_f1..f8 are for backpacks.
local WARMTH_BITS = { %s }

local function abilityId(prefix, i) return prefix .. i end

-- Adds and removes only the bits that changed, so a magnitude tweak is one or
-- two spell operations rather than a full teardown.
local function updateBinaryAbility(prefix, currentKey, target)
	local current = saveData[currentKey] or 0
	target = math.max(0, math.min(255, math.floor(target or 0)))
	if current == target then return end

	for i, bit in ipairs(WARMTH_BITS) do
		local had = (current %% (bit * 2)) >= bit
		local needs = (target %% (bit * 2)) >= bit
		local id = abilityId(prefix, i)
		if had and not needs then
			if core.magic.spells.records[id] then typesActorSpellsSelf:remove(id) end
		elseif needs and not had then
			if core.magic.spells.records[id] then typesActorSpellsSelf:add(id) end
		end
	end
	saveData[currentKey] = target
end

local function refreshWarmth()
	local target = 0
	if saveData.sdScarfId and SCARVES_ENABLED ~= false then
		target = SCARVES_WARMTH or 0
	end
	updateBinaryAbility("sd_scarf_w", "sdScarfWarmth", target)
end

-- Blight resistance is a single ability rather than a binary encoding: it is a
-- percentage the player picks once, and eight records to express one of a few
-- values would be waste. The plugin defines one record per step.
local BLIGHT_STEPS = { 10, 20, 30, 40, 50 }

local function nearestBlightStep(percent)
	local best, bestDiff = nil, math.huge
	for _, step in ipairs(BLIGHT_STEPS) do
		local diff = math.abs(step - (percent or 0))
		if diff < bestDiff then best, bestDiff = step, diff end
	end
	return best
end

local function refreshBlight()
	local wanted = nil
	if saveData.sdMaskId and MASKS_ENABLED ~= false and (MASKS_BLIGHT_RES or 0) > 0 then
		wanted = "sd_mask_blight_" .. nearestBlightStep(MASKS_BLIGHT_RES)
	end
	if saveData.sdMaskBlightAbility == wanted then return end

	if saveData.sdMaskBlightAbility
	   and core.magic.spells.records[saveData.sdMaskBlightAbility] then
		typesActorSpellsSelf:remove(saveData.sdMaskBlightAbility)
	end
	if wanted and core.magic.spells.records[wanted] then
		typesActorSpellsSelf:add(wanted)
	end
	saveData.sdMaskBlightAbility = wanted
end

local function wornId(category)
	return category == "scarves" and saveData.sdScarfId or saveData.sdMaskId
end

local function setWornId(category, id)
	if category == "scarves" then saveData.sdScarfId = id
	else saveData.sdMaskId = id end
end

-- Straight from p_backpacks.refreshVfx: remove, verify the bone, retry ONCE on
-- a 0.1s timer. The retry matters because the animation object is still being
-- rebuilt for a moment after a perspective change, and attaching to a bone
-- that is not ready yet attaches nothing at all -- silently.
local function refreshVfx(category, retries)
	animation.removeVfx(self, VFX_OF[category])

	local id = wornId(category)
	if not id then return end

	local bone = nil
	for _, candidate in ipairs(BONE_OF[category]) do
		if animation.hasBone(self, candidate) then bone = candidate; break end
	end
	if not bone then
		log(3, "[SD Scarves] no usable bone for", category)
		if not retries then
			async:newUnsavableSimulationTimer(0.1, function()
				refreshVfx(category, 1)
			end)
		end
		return
	end

	local record = types.Miscellaneous.record(id)
	if not record then
		log(3, "[SD Scarves] no record for", id)
		return
	end

	-- record.model, NOT a path from a table. The record's model is a VFS path;
	-- a plugin's raw MODL string is not, and attaches nothing.
	animation.addVfx(self, record.model, {
		vfxId = VFX_OF[category],
		boneName = bone,
		loop = true,
		useAmbientLight = false,
	})
end

local function refreshAllVfx()
	refreshVfx("scarves")
	refreshVfx("masks")
end

local function onEquipped(data)
	local category = data.category
	if not category then return end

	setWornId(category, data.equippedId)

	if category == "scarves" then refreshWarmth() else refreshBlight() end
	refreshVfx(category)
end

G_eventHandlers.SunsDuskScarves_equipped = onEquipped

-- Sluggish list, not per-frame: this is Sun's Dusk's own throttle, and it is
-- where p_backpacks puts the identical check.
local function onSluggishFrame()
	if not saveData.sdScarfId and not saveData.sdMaskId then return end

	for _, category in ipairs({ "scarves", "masks" }) do
		local id = wornId(category)
		if id and not typesActorInventorySelf:find(id) then
			-- It left the inventory. Ask the global script to convert any loose
			-- copies back, drop the bonus, and stop drawing it.
			core.sendGlobalEvent("SunsDuskScarves_convertInCell", self)
			setWornId(category, nil)
			if category == "scarves" then refreshWarmth() else refreshBlight() end
			refreshVfx(category)
		end
	end
end

table.insert(G_onFrameJobsSluggish, onSluggishFrame)

local function onLoad()
	for _, category in ipairs({ "scarves", "masks" }) do
		local id = wornId(category)
		if id then
			if not types.Miscellaneous.records[id]
			   or not typesActorInventorySelf:find(id) then
				-- Record gone from the load order, or item gone from the bag.
				setWornId(category, nil)
			end
		end
	end
	refreshWarmth()
	refreshBlight()

	if saveData.sdScarfId or saveData.sdMaskId then
		G_onFrameJobs["refreshScarfVfx"] = function()
			G_onFrameJobs["refreshScarfVfx"] = nil
			refreshAllVfx()
		end
	end
end

table.insert(G_onLoadJobs, onLoad)

-- Rest and Travel rebuild the player model and drop attached VFX.
table.insert(G_UiModeChangedJobs, function(data)
	if data.oldMode == "Rest" or data.oldMode == "Travel" then
		refreshAllVfx()
	end
end)

-- A settings change alters the magnitude, not the worn item, so only the
-- abilities need revisiting.
G_settingsChangedJobs = G_settingsChangedJobs or {}
G_settingsChangedJobs.sdScarves = function(_section, setting)
	if setting == "SCARVES_WARMTH" or setting == "SCARVES_ENABLED" then
		refreshWarmth()
	elseif setting == "MASKS_BLIGHT_RES" or setting == "MASKS_ENABLED" then
		refreshBlight()
	end
end
''' % ', '.join(str(b) for b in WARMTH_BITS))
open(OUT + '/scripts/SunsDuskScarves/p_scarves.lua', 'w').write(p.getvalue())

print('scarves: %d, masks: %d' % (len(items['scarves']), len(items['masks'])))
json.dump(items, open('sd_scarves_items.json', 'w'), indent=1)
