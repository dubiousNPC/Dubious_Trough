--[[
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

-- sd_g.lua auto-requires everything under scripts/SunsDusk/settings/, but only
-- in GLOBAL context -- where `world` is set and the file takes its
-- registerGroup branch. Registering the PAGE needs a non-global context, and
-- sd_p.lua only requires `sd_settings` by name, so a third-party module has to
-- require its own. This is the same line sd_p.lua:381 uses, and it also
-- guarantees SCARVES_WARMTH and friends exist before the code below reads them.
require('scripts.SunsDusk.settings.scarves_settings')

local VFX_SCARF = "SD_scarfVfx"
local VFX_MASK  = "SD_maskVfx"

local SCARF_BONE     = "Bip01 scarfDBS"
local SCARF_FALLBACK = "Bip01 Neck"
local MASK_BONE     = "Bip01 mouthDBS"
local MASK_FALLBACK = "head"

local CATEGORY_OF = {
	["dbs_rv_scarf_01_eq"] = "scarves",
	["dbs_rv_scarf_02_eq"] = "scarves",
	["dbs_rv_scarf_03_eq"] = "scarves",
	["dbs_rv_scarf_04_eq"] = "scarves",
	["dbs_rv_scarf_05_eq"] = "scarves",
	["dbs_rv_scarf_06_eq"] = "scarves",
	["dbs_rv_scarf_07_eq"] = "scarves",
	["dbs_rv_scarf_08_eq"] = "scarves",
	["dbs_rv_scarf_09_eq"] = "scarves",
	["dbs_rv_scarf_10_eq"] = "scarves",
	["dbs_rv_scarf_11_eq"] = "scarves",
	["dbs_rv_scarf_12_eq"] = "scarves",
	["dbs_rv_scarf_13_eq"] = "scarves",
	["dbs_rv_scarf_14_eq"] = "scarves",
	["dbs_rv_scarf_15_eq"] = "scarves",
	["dbs_rv_scarf_16_eq"] = "scarves",
	["dbs_rv_ashmask1_h_eq"] = "masks",
	["dbs_rv_ashmask2_h_eq"] = "masks",
	["dbs_rv_ashmask3_h_eq"] = "masks",
	["dbs_rv_daedramask1_h_eq"] = "masks",
	["dbs_rv_daedramask2_h_eq"] = "masks",
	["dbs_rv_daedramask3_h_eq"] = "masks",
	["dbs_rv_daedramask4_h_eq"] = "masks",
	["dbs_rv_facewrap1_h_eq"] = "masks",
	["dbs_rv_facewrap2_h_eq"] = "masks",
	["dbs_rv_facewrap3_h_eq"] = "masks",
	["dbs_rv_facewrap4_h_eq"] = "masks",
	["dbs_rv_facewrap5_h_eq"] = "masks",
	["dbs_rv_facewrap6_h_eq"] = "masks",
	["dbs_rv_facewrap7_h_eq"] = "masks",
	["dbs_rv_facewrap8_h_eq"] = "masks",
	["dbs_rv_orcishmask1_h_eq"] = "masks",
	["dbs_rv_orcishmask2_h_eq"] = "masks",
}

local VFX_OF = { scarves = VFX_SCARF, masks = VFX_MASK }
local BONE_OF = {
	scarves = { SCARF_BONE, SCARF_FALLBACK },
	masks   = { MASK_BONE,  MASK_FALLBACK },
}

-- Binary-encoded ability ids, as sd_feather_f1..f8 are for backpacks.
-- Five records span 0-31, which covers the 0-20 the setting allows.
-- Backpacks uses eight for feather because it needs 0-255.
local WARMTH_BITS = { 1, 2, 4, 8, 16 }

local function abilityId(prefix, i) return prefix .. i end

-- Adds and removes only the bits that changed, so a magnitude tweak is one or
-- two spell operations rather than a full teardown.
local function updateBinaryAbility(prefix, currentKey, target)
	local current = saveData[currentKey] or 0
	target = math.max(0, math.min(31, math.floor(target or 0)))
	if current == target then return end

	for i, bit in ipairs(WARMTH_BITS) do
		local had = (current % (bit * 2)) >= bit
		local needs = (target % (bit * 2)) >= bit
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
