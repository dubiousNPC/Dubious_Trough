---@omw-context global
--[[
    cake_global.lua -- the equip/unequip swap

    Sun's Dusk's backpack mechanism, generalised. Using a base record destroys
    it and creates the paired `_eq` record; using an `_eq` record converts it
    back. Because both records are types.Miscellaneous, nothing occupies an
    equipment slot and there is no equip to block.

    WHAT WAS WRONG WITH globalcake.lua
    ----------------------------------
    * Its BACKPACK_IDS table listed 50 ids -- fy_fannypack_b, indoril_tail,
      LanternDwem and so on. NONE of the 50 exist in CAKE.esp or CAKE34.esp.
      The list came from a different content set, so no item could ever be
      equipped. The registry is now generated from the plugins.
    * It computed the worn id as `itemId .. "_eq"` and the base id as
      `equippedId:sub(1, -4)`. The plugins name the pair `dbs_<thing>` and
      `dbs_<thing>_eq`, so that arithmetic is right only if the id list already
      carries the `dbs_` prefix -- which it did not. Both directions now go
      through an explicit reverse index instead of string surgery, so a naming
      change breaks loudly at generation time rather than silently at runtime.
    * Record ids compare lowercase in OpenMW. Half the old table's keys were
      capitalised (LanternDwem, GlassLantern2, _RV_Scarf01), so even a correct
      list would have missed them. Everything here is lowercased on the way in.
    * BACKPACK_Z_OFFSETS was referenced but never defined, so the drop handler
      raised an error the moment it ran.
    * getBaseId was defined twice.
    * The script had no `require` statements at all and referenced I, types,
      world, G_eventHandlers and friends from Sun's Dusk's shared environment.
      Dropped into a standalone mod it cannot load. CAKE also ships no
      .omwscripts file, so nothing was registering these scripts at all.
]]

local I       = require('openmw.interfaces')
local types   = require('openmw.types')
local world   = require('openmw.world')
local util    = require('openmw.util')
local storage = require('openmw.storage')

local CAKE = require('scripts.cake.cake_shared')

-- NPC local scripts cannot read a player settings section, so the settings
-- they need are mirrored here, in a section only global scripts may write.
local globalState = storage.globalSection('Cake_global')

---Remove one from a stack, or the whole object if it is the last.
local function consumeOne(item)
    if item.count > 1 then item:split(1):remove() else item:remove() end
end

---Find whatever CAKE item is currently worn in `category`, if any.
local function findWorn(inv, category)
    for _, item in ipairs(inv:getAll(types.Miscellaneous)) do
        local baseId = CAKE.baseOf(item.recordId)
        if baseId then
            local entry = CAKE.get(baseId)
            if entry and (category == nil or entry.category == category) then
                return item, baseId, entry
            end
        end
    end
    return nil
end

---Convert a worn item back to its inventory form.
local function unwear(inv, item, baseId)
    consumeOne(item)
    world.createObject(baseId, 1):moveInto(inv)
end

local function onUse(item, actor)
    if not types.Player.objectIsInstance(actor) then return end

    local inv = types.Actor.inventory(actor)

    -- Case 1: they used something already worn. Take it off.
    local wornBase = CAKE.baseOf(item.recordId)
    if wornBase then
        unwear(inv, item, wornBase)
        actor:sendEvent('Cake_Changed', { category = CAKE.get(wornBase).category })
        return false
    end

    -- Case 2: they used a wearable from the inventory. Put it on.
    local entry = CAKE.get(item.recordId)
    if not entry then return end

    -- Take off whatever occupies the same category, plus anything that
    -- conflicts with it, before putting the new one on.
    local cat = CAKE.CATEGORIES[entry.category]
    local toClear = { entry.category }
    for _, other in ipairs(cat.conflicts) do toClear[#toClear + 1] = other end
    for _, categoryName in ipairs(toClear) do
        local oldItem, oldBase = findWorn(inv, categoryName)
        if oldItem then unwear(inv, oldItem, oldBase) end
    end

    consumeOne(item)
    world.createObject(entry.eq, 1):moveInto(inv)

    actor:sendEvent('Cake_Changed', { category = entry.category, equipped = entry.eq })
    return false
end

---Convert loose `_eq` records in the cell back to their base form.
---
---This used to be load-bearing: worn state was inferred from inventory
---presence, so an `_eq` record in a chest was an item you put on by looting
---it, and this sweep was the only thing preventing that. cake_player now keeps
---explicit activation-set state, so looting one does nothing and using one
---converts it back on its own. The sweep is world hygiene now, not correctness.
---
---It is still the most expensive operation in the mod -- every Miscellaneous
---object in the cell, plus a getAll on every container -- so it is called only
---when cake_player's reconcile finds a worn record has actually gone missing.
---Sun's Dusk triggers its equivalent the same way.
local function convertLooseInCell(player)
    if not player or not player:isValid() then return end
    local cell = player.cell
    if not cell then return end

    for _, obj in ipairs(cell:getAll(types.Miscellaneous)) do
        local baseId = CAKE.baseOf(obj.recordId)
        if baseId then
            local count, pos, rot = obj.count, obj.position, obj.rotation
            -- Sit the replacement on the ground rather than at the mesh origin.
            -- The old code read a BACKPACK_Z_OFFSETS table that was never
            -- defined; the bounding box is always available and needs no table.
            local ok, bbox = pcall(obj.getBoundingBox, obj)
            if ok and bbox then
                pos = util.vector3(bbox.center.x, bbox.center.y,
                                   bbox.center.z - bbox.halfSize.z * 0.9)
            end
            obj:remove()
            world.createObject(baseId, count):teleport(cell, pos, rot)
        end
    end

    for _, container in ipairs(cell:getAll(types.Container)) do
        local inv = types.Container.content(container)
        for _, item in ipairs(inv:getAll(types.Miscellaneous)) do
            local baseId = CAKE.baseOf(item.recordId)
            if baseId then
                local count = item.count
                item:remove()
                world.createObject(baseId, count):moveInto(inv)
            end
        end
    end
end

local registered = false
local function register()
    if registered then return end
    if not I.ItemUsage then
        print('[CAKE] ItemUsage unavailable; items cannot be worn')
        return
    end
    registered = true
    I.ItemUsage.addHandlerForType(types.Miscellaneous, onUse)
    if globalState:get('showNpcs') == nil then globalState:set('showNpcs', true) end
end

return {
    engineHandlers = {
        onInit = register,
        onLoad = register,
    },
    eventHandlers = {
        Cake_ConvertInCell = convertLooseInCell,
        Cake_SetShowNpcs   = function(data)
            globalState:set('showNpcs', data and data.value ~= false)
        end,
    },
}
