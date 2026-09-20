---@omw-context player
--[[
    Sun's Dusk addon module. NOT registered in an .omwscripts of its own --
    sd_p.lua walks its directory with vfs.pathsWithPrefix and require()s every file
    it finds, so this file runs inside that script's environment and inherits
    its context. Declaring it in a manifest as well is FATAL: OpenMW allows a
    script path exactly one set of flags, and a second declaration aborts the
    game before the main menu.

    That is also why the names below are read without ever being declared or
    required here. Sun's Dusk assigns them as GLOBALS on purpose (sd_p.lua
    lines 6-20), and `require` shares the requiring script's environment:

        core  types  util  world  I  animation  async  storage  MODNAME
        saveData  typesActorInventorySelf  typesActorSpellsSelf
        G_eventHandlers  G_onFrameJobs  G_onFrameJobsSluggish
        G_onLoadJobs  G_UiModeChangedJobs  G_settingsChangedJobs
        log                     -- a global function from constants.lua:124

    Every name was checked against sd_p.lua / sd_g.lua / constants.lua rather
    than assumed. Requiring them locally would work but would diverge from
    every other module in that directory, and the G_* job tables have no local
    equivalent at all -- they are the host's scheduler bus.

    Static checkers will report these as undeclared globals. That is correct
    and expected; pass the list above via --globals when sweeping this mod.
]]
--[[
	p_goggles.lua -- Glasses, Goggles & Eyepatches, worn state and boon

	Mirrors p_scarves.lua, which mirrors p_backpacks.lua. Where those grant
	warmth and carry weight, this grants one flat point of Luck.

	ONE ability record, not a binary-encoded set. Scarves needs five records to
	span a configurable 0-31 warmth; the boon here is always exactly 1, so one
	record covers it. Do not "generalise" this into a bit set -- there is no
	second value for it to encode.

	The ability is applied only `if core.magic.spells.records[id]`, so a missing
	record degrades to no boon rather than to an error, and the module still
	works if you strip the ability record from the plugin. That guard is also
	why Scarves' missing SPEL records went unnoticed for a release: it fails
	SILENTLY by design, so verify the plugin actually contains the record.

	WORN STATE IS SET BY ACTIVATION, NOT INFERRED FROM THE INVENTORY.
	`saveData.sdGogglesId` is written only when the ItemUsage handler reports a
	swap. Deriving it by scanning for an `_eq` record would make LOOTING one
	equal to wearing it, because presence would be the whole test. Explicit
	state is reconciled against the inventory rather than replaced by it.
]]

-- sd_p.lua only requires `sd_settings` by name, so a third-party module has to
-- require its own. This is the same line sd_p.lua:381 uses, and it also
-- guarantees GOGGLES_ENABLED exists before the code below reads it.
require('scripts.SunsDusk.settings.goggles_settings')

local VFX_EYEWEAR = "SD_gogglesVfx"

-- CAKE's eyewear category bone, read from its cake_shared.lua rather than
-- guessed: bone = 'Bip01 eyesDBS', boneFallback = 'head'.
local EYEWEAR_BONE     = "Bip01 eyesDBS"
local EYEWEAR_FALLBACK = "head"

local LUCK_ABILITY = "sd_goggles_luck1"

local CATEGORY_OF = {
	["dbs_rv_blindfold1_h_eq"] = "eyewear",
	["dbs_rv_eyepatch1l_h_eq"] = "eyewear",
	["dbs_rv_eyepatch1r_h_eq"] = "eyewear",
	["dbs_rv_glasses1_h_eq"] = "eyewear",
	["dbs_rv_glasses1s_h_eq"] = "eyewear",
	["dbs_rv_glasses2_h_eq"] = "eyewear",
	["dbs_rv_glasses2s_h_eq"] = "eyewear",
	["dbs_rv_glasses3_h_eq"] = "eyewear",
	["dbs_rv_glasses4_h_eq"] = "eyewear",
	["dbs_rv_glasses4s_h_eq"] = "eyewear",
	["dbs_rv_goggles1_h_eq"] = "eyewear",
	["dbs_rv_goggles2_h_eq"] = "eyewear",
	["dbs_rv_goggles3_h_eq"] = "eyewear",
	["dbs_rv_goggles4_h_eq"] = "eyewear",
	["dbs_rv_goggles5_h_eq"] = "eyewear",
	["dbs_rv_goggles6_h_eq"] = "eyewear",
	["dbs_rv_goggles7_h_eq"] = "eyewear",
	["dbs_rv_goggles8_h_eq"] = "eyewear",
	["dbs_rv_lenses1_h_eq"] = "eyewear",
	["dbs_rv_lenses2_h_eq"] = "eyewear",
}

local function wornId()
	return saveData.sdGogglesId
end

local function setWornId(id)
	saveData.sdGogglesId = id
end

-- ---------------------------------------------------------------------------
-- PUBLIC HOOK
-- ---------------------------------------------------------------------------
-- Other scripts ask here rather than scanning the inventory themselves. An
-- inventory scan would answer a different question -- "is an _eq record in the
-- bag" rather than "is a pair being worn" -- and would be wrong for a looted
-- one. It is also a getAll walk per caller per call.
--
-- Exposed as G_gogglesIsWorn(), the plain-global convention Sun's Dusk itself
-- uses for cross-module reads. Every other player module shares this
-- environment, so the global reaches all of them.
--
-- NOT exposed as I.SunsDuskGoggles. openmw.interfaces is a read-only userdata:
-- assigning a field to it raises "attempt to index global 'I' (a userdata
-- value)", and because this file is require()d at the top level of sd_p.lua
-- that error aborts sd_p.lua itself -- every Sun's Dusk player module dies with
-- it. An interface only exists when a registered script RETURNS interfaceName,
-- and a module is not a registered script; it cannot publish one.
--
-- Returns, so a caller can branch on which pair:
--   worn (boolean), base record id or nil, _eq record id or nil
local function isWorn()
	local eqId = wornId()
	if not eqId then return false, nil, nil end
	local baseId = eqId:gsub("_eq$", "")
	return true, baseId, eqId
end

G_gogglesIsWorn = isWorn

-- ---------------------------------------------------------------------------
-- BOON
-- ---------------------------------------------------------------------------
local function refreshLuck()
	local want = GOGGLES_ENABLED ~= false and wornId() ~= nil
	local has = saveData.sdGogglesLuck == true
	if want == has then return end

	if not core.magic.spells.records[LUCK_ABILITY] then
		-- Say so once rather than failing silently: a missing SPEL record is
		-- exactly the fault that shipped in Scarves unnoticed.
		if not saveData.sdGogglesWarned then
			saveData.sdGogglesWarned = true
			log(2, "[SD Goggles] ability record '" .. LUCK_ABILITY ..
			       "' not found -- enable SD_Goggles_abilities.esp. Eyewear is cosmetic only.")
		end
		return
	end

	if want then
		typesActorSpellsSelf:add(LUCK_ABILITY)
	else
		typesActorSpellsSelf:remove(LUCK_ABILITY)
	end
	saveData.sdGogglesLuck = want
end

-- ---------------------------------------------------------------------------
-- DISPLAY
-- ---------------------------------------------------------------------------
-- Straight from p_backpacks.refreshVfx: remove, verify the bone, retry ONCE on
-- a later frame if the skeleton is not ready. Never retry forever -- a missing
-- bone is a missing skeleton, not a race.
local function refreshVfx(retries)
	animation.removeVfx(self, VFX_EYEWEAR)

	local eqId = wornId()
	if not eqId then return end

	local rec = types.Miscellaneous.records[eqId]
	if not rec or not rec.model then return end

	local bone = EYEWEAR_BONE
	if not animation.hasBone(self, bone) then
		bone = EYEWEAR_FALLBACK
		if not animation.hasBone(self, bone) then
			if (retries or 0) < 1 then
				G_onFrameJobs["refreshGogglesVfx"] = function()
					G_onFrameJobs["refreshGogglesVfx"] = nil
					refreshVfx(1)
				end
			end
			return
		end
	end

	-- The mesh has to actually be in the VFS. addVfx on a path that is not
	-- there attaches nothing and says nothing: the item still swaps to its worn
	-- record and the ability still applies, so a user missing the eyewear mesh
	-- pack gets an item that equips, buffs and is invisible, with a clean log.
	-- Report it instead.
	if not vfs.fileExists(rec.model) then
		log(3, "[SD Goggles] mesh not in VFS, skipping:", rec.model,
		    "(eyewear meshes ship separately)")
		return
	end

	animation.addVfx(self, rec.model, {
		vfxId = VFX_EYEWEAR,
		boneName = bone,
		loop = true,
	})
end

-- ---------------------------------------------------------------------------
-- WIRING
-- ---------------------------------------------------------------------------
local function onEquipped(data)
	if CATEGORY_OF[data.equippedId or ""] == nil and data.equippedId ~= nil then return end
	setWornId(data.equippedId)
	refreshLuck()
	refreshVfx()
end

G_eventHandlers.SunsDuskGoggles_equipped = onEquipped

-- Sluggish list, not per-frame: this is Sun's Dusk's own throttle, and it is
-- where p_backpacks puts the identical check. State leads; the inventory
-- audits it.
local function onSluggishFrame()
	if not saveData.sdGogglesId then return end

	local id = wornId()
	if id and not typesActorInventorySelf:find(id) then
		-- It left the inventory. Ask the global script to convert any loose
		-- copies back, drop the boon, and stop drawing it.
		core.sendGlobalEvent("SunsDuskGoggles_convertInCell", self.object)
		setWornId(nil)
		refreshLuck()
		refreshVfx()
	end
end

table.insert(G_onFrameJobsSluggish, onSluggishFrame)

local function onLoad()
	local id = wornId()
	if id then
		if not types.Miscellaneous.records[id]
		   or not typesActorInventorySelf:find(id) then
			-- Record gone from the load order, or item gone from the bag.
			setWornId(nil)
		end
	end
	refreshLuck()

	if saveData.sdGogglesId then
		G_onFrameJobs["refreshGogglesVfx"] = function()
			G_onFrameJobs["refreshGogglesVfx"] = nil
			refreshVfx()
		end
	end
end

table.insert(G_onLoadJobs, onLoad)

-- Rest and Travel rebuild the player model and drop attached VFX.
table.insert(G_UiModeChangedJobs, function(data)
	if data.oldMode == "Rest" or data.oldMode == "Travel" then
		refreshVfx()
	end
end)

-- A settings change alters whether the boon applies, not the worn item.
-- table.insert, not a named key. Every Sun's Dusk module registers this way
-- (p_clean.lua:2499, p_temp.lua:3752, ...), and sd_p.lua:135 creates the table
-- before player_modules load -- so `= G_settingsChangedJobs or {}` reassigns a
-- table the host owns on an ordering assumption never checked.
table.insert(G_settingsChangedJobs, function(_section, setting)
	if setting == "GOGGLES_ENABLED" then
		refreshLuck()
	end
end)
