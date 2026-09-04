--[[
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

local SCARVES_IDS = {
	dbs_rv_scarf_01 = true,
	dbs_rv_scarf_02 = true,
	dbs_rv_scarf_03 = true,
	dbs_rv_scarf_04 = true,
	dbs_rv_scarf_05 = true,
	dbs_rv_scarf_06 = true,
	dbs_rv_scarf_07 = true,
	dbs_rv_scarf_08 = true,
	dbs_rv_scarf_09 = true,
	dbs_rv_scarf_10 = true,
	dbs_rv_scarf_11 = true,
	dbs_rv_scarf_12 = true,
	dbs_rv_scarf_13 = true,
	dbs_rv_scarf_14 = true,
	dbs_rv_scarf_15 = true,
	dbs_rv_scarf_16 = true,
}

local MASKS_IDS = {
	dbs_rv_ashmask1_h = true,
	dbs_rv_ashmask2_h = true,
	dbs_rv_ashmask3_h = true,
	dbs_rv_daedramask1_h = true,
	dbs_rv_daedramask2_h = true,
	dbs_rv_daedramask3_h = true,
	dbs_rv_daedramask4_h = true,
	dbs_rv_facewrap1_h = true,
	dbs_rv_facewrap2_h = true,
	dbs_rv_facewrap3_h = true,
	dbs_rv_facewrap4_h = true,
	dbs_rv_facewrap5_h = true,
	dbs_rv_facewrap6_h = true,
	dbs_rv_facewrap7_h = true,
	dbs_rv_facewrap8_h = true,
	dbs_rv_orcishmask1_h = true,
	dbs_rv_orcishmask2_h = true,
}

-- base id -> category, and equipped id -> base id. Built once at load.
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
