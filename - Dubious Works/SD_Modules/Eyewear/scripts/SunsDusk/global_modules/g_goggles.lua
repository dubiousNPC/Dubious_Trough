---@omw-context global
--[[
    Sun's Dusk addon module. NOT registered in an .omwscripts of its own --
    sd_g.lua walks its directory with vfs.pathsWithPrefix and require()s every file
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
	g_goggles.lua -- Glasses, Goggles & Eyepatches, the equip swap

	A straight copy of g_backpacks.lua's mechanism, by way of g_scarves.lua: a
	Miscellaneous item and an `_eq` twin, swapped by an ItemUsage handler.
	Nothing here occupies an equipment slot, so eyewear costs you no helmet.

	ONE category, unlike Scarves. All twenty records share CAKE's `eyewear`
	category and its single bone, so wearing a second pair replaces the first
	rather than stacking -- which is also the only sane reading of two pairs of
	goggles on one face.

	The `_eq` twin is what "worn" MEANS to the display layer, but NOT what it
	means to the bonus layer: p_goggles.lua keeps explicit saved state set by
	activation, so looting a loose `_eq` record does not silently equip it.
	That distinction is deliberate and is the one CAKE had to learn.
]]

-- Base ids, from CAKE's eyewear category. The `_eq` twin of each is the base
-- id plus "_eq", which is CAKE's own convention and is asserted below rather
-- than assumed.
local EYEWEAR_IDS = {
	"dbs_rv_blindfold1_h",
	"dbs_rv_eyepatch1l_h",
	"dbs_rv_eyepatch1r_h",
	"dbs_rv_glasses1_h",
	"dbs_rv_glasses1s_h",
	"dbs_rv_glasses2_h",
	"dbs_rv_glasses2s_h",
	"dbs_rv_glasses3_h",
	"dbs_rv_glasses4_h",
	"dbs_rv_glasses4s_h",
	"dbs_rv_goggles1_h",
	"dbs_rv_goggles2_h",
	"dbs_rv_goggles3_h",
	"dbs_rv_goggles4_h",
	"dbs_rv_goggles5_h",
	"dbs_rv_goggles6_h",
	"dbs_rv_goggles7_h",
	"dbs_rv_goggles8_h",
	"dbs_rv_lenses1_h",
	"dbs_rv_lenses2_h",
}

local CATEGORY_OF = {}
local BASE_OF_EQ  = {}
-- Both directions indexed. The base -> _eq direction used to be answered by
-- walking EYEWEAR_IDS on every Miscellaneous use.
local EQ_OF_BASE  = {}
for _, base in ipairs(EYEWEAR_IDS) do
	CATEGORY_OF[base .. "_eq"] = "eyewear"
	BASE_OF_EQ[base .. "_eq"]  = base
	EQ_OF_BASE[base]           = base .. "_eq"
end

local function consumeOne(item)
	item:remove(1)
end

-- Takes off whatever is already worn in this category, returning its base id
-- to the inventory. One category, so this is at most one item.
local function unwearCategory(inv, category)
	for _, item in ipairs(inv:getAll(types.Miscellaneous)) do
		local base = BASE_OF_EQ[item.recordId]
		if base and CATEGORY_OF[item.recordId] == category then
			consumeOne(item)
			world.createObject(base, 1):moveInto(inv)
			return base
		end
	end
	return nil
end

-- LOAD BEACON. Sun's Dusk finds this file by scanning the VFS prefix
-- "scripts/SunsDusk/global_modules/", so it only loads if THIS module folder is
-- its own data= entry. Point data= at the parent folder instead and the prefix
-- never matches, nothing here runs, the ItemUsage handler is never registered,
-- and using an item does nothing -- with no error, because no code ran.
--
-- One line at load turns that silence into evidence: no line in the log means
-- the module is not installed, not that it is broken.
log(2, "[SD Eyewear] module loaded; ItemUsage handler registering")

I.ItemUsage.addHandlerForType(types.Miscellaneous, function(item, actor)
	local id = item.recordId

	-- Taking a worn pair off: swap the _eq twin back for the base item.
	local base = BASE_OF_EQ[id]
	if base then
		local inv = types.Actor.inventory(actor)
		consumeOne(item)
		world.createObject(base, 1):moveInto(inv)
		actor:sendEvent("SunsDuskGoggles_equipped", { category = "eyewear", equippedId = nil })
		return false
	end

	-- Putting a pair on: swap the base item for its _eq twin, after taking off
	-- anything already worn.
	-- Hash lookup, not a linear scan. This handler runs on EVERY Miscellaneous
	-- item use in the game, so walking a 20-entry list to answer a question a
	-- table answers in one step is work done on every potion and every key.
	local eqId = EQ_OF_BASE[id]
	if not eqId then return true end

	local inv = types.Actor.inventory(actor)
	unwearCategory(inv, "eyewear")
	consumeOne(item)
	world.createObject(eqId, 1):moveInto(inv)
	actor:sendEvent("SunsDuskGoggles_equipped", { category = "eyewear", equippedId = eqId })
	return false
end)

-- A worn record that leaves the player's inventory -- dropped, sold, put in a
-- container -- has to become its base form again, or picking it up again reads
-- as wearing it.
--
-- This is the expensive operation in the module, so it is NOT called on equip
-- or unequip: p_goggles.lua asks for it only when its own reconcile finds a
-- worn record has actually gone missing, which is the only way one can become
-- loose. Sun's Dusk's backpack module triggers its equivalent the same way.
local function convertWornInCell(player)
	if not player or not player:isValid() then return end
	local cell = player.cell
	if not cell then return end

	local function sweep(list)
		for _, obj in ipairs(list) do
			local base = BASE_OF_EQ[obj.recordId]
			if base then
				local pos, rot = obj.position, obj.rotation
				local count = obj.count
				obj:remove()
				world.createObject(base, count):teleport(cell, pos, rot)
			end
		end
	end

	sweep(cell:getAll(types.Miscellaneous))

	local function sweepInventory(inv)
		for _, item in ipairs(inv:getAll(types.Miscellaneous)) do
			local base = BASE_OF_EQ[item.recordId]
			if base then
				local count = item.count
				item:remove(count)
				world.createObject(base, count):moveInto(inv)
			end
		end
	end

	for _, container in ipairs(cell:getAll(types.Container)) do
		sweepInventory(types.Container.content(container))
	end
end

G_eventHandlers.SunsDuskGoggles_convertInCell = convertWornInCell
