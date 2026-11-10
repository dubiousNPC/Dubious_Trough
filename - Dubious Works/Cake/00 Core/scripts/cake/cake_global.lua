---@omw-context global
--[[
    cake_global.lua -- wearing and taking off, and which NPCs show anything

    WEARING. Every accessory is a pair of Miscellaneous records, `dbs_<thing>`
    in the bag and `dbs_<thing>_eq` while worn (Sun's Dusk's backpack pattern).
    Using one swaps it for the other. Nothing occupies an equipment slot.

    The player script owns the worn state; it is told about every change here,
    including categories that were cleared to make room, so state and the bag
    never disagree.

    NPCS. An NPC wears what it carries in `_eq` form. Instead of a local script
    on every NPC, this script looks at each actor as it becomes active and
    attaches cake_npc.lua only to the ones carrying something, with the list of
    what to draw. An NPC carrying nothing costs one inventory read here.
]]

local I     = require('openmw.interfaces')
local types = require('openmw.types')
local world = require('openmw.world')
local util  = require('openmw.util')

local CAKE = require('scripts.cake.cake_shared')

local NPC_SCRIPT = 'scripts/cake/cake_npc.lua'

local showNpcs = true

-- ---------------------------------------------------------------------------
-- WEARING
-- ---------------------------------------------------------------------------

local function consumeOne(item)
    if item.count > 1 then item:split(1):remove() else item:remove() end
end

---Convert every worn record of the given categories back to its bag form.
---Every one, not the first found: a second `_eq` of the same category (looted,
---or left by an older version) would otherwise survive the swap.
local function clearCategories(inv, categories)
    for _, item in ipairs(inv:getAll(types.Miscellaneous)) do
        local base = CAKE.baseOf(item.recordId)
        if base and categories[CAKE.ITEMS[base].category] then
            local count = item.count
            item:remove()
            world.createObject(base, count):moveInto(inv)
        end
    end
end

local function onUse(item, actor)
    if not types.Player.objectIsInstance(actor) then return end
    local inv = types.Actor.inventory(actor)

    local wornBase = CAKE.baseOf(item.recordId)
    if wornBase then
        -- Using a worn record takes it off.
        consumeOne(item)
        world.createObject(wornBase, 1):moveInto(inv)
        actor:sendEvent('Cake_Changed', { cleared = { CAKE.ITEMS[wornBase].category } })
        return false
    end

    local entry = CAKE.get(item.recordId)
    if not entry then return end

    local clear = { [entry.category] = true }
    local cleared = { entry.category }
    for _, other in ipairs(CAKE.CATEGORIES[entry.category].conflicts) do
        clear[other] = true
        cleared[#cleared + 1] = other
    end
    clearCategories(inv, clear)

    consumeOne(item)
    world.createObject(entry.eq, 1):moveInto(inv)
    actor:sendEvent('Cake_Changed', { cleared = cleared, category = entry.category,
                                      base = item.recordId:lower() })
    return false
end

-- ---------------------------------------------------------------------------
-- LOOSE WORN RECORDS
-- ---------------------------------------------------------------------------
-- Converts `_eq` records lying in the player's cell, or in its containers, back
-- to their bag form. Requested by the player script only when a worn record has
-- left its inventory, which is the only way one can end up loose.

local function convertLooseInCell(player)
    if not player:isValid() or not player.cell then return end
    local cell = player.cell
    for _, obj in ipairs(cell:getAll(types.Miscellaneous)) do
        local base = CAKE.baseOf(obj.recordId)
        if base then
            local count, rot = obj.count, obj.rotation
            local box = obj:getBoundingBox()
            local pos = util.vector3(box.center.x, box.center.y, box.center.z - box.halfSize.z * 0.9)
            obj:remove()
            world.createObject(base, count):teleport(cell, pos, { rotation = rot })
        end
    end
    for _, container in ipairs(cell:getAll(types.Container)) do
        local inv = types.Container.inventory(container)
        if inv:isResolved() then
            for _, item in ipairs(inv:getAll(types.Miscellaneous)) do
                local base = CAKE.baseOf(item.recordId)
                if base then
                    local count = item.count
                    item:remove()
                    world.createObject(base, count):moveInto(inv)
                end
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- NPCS
-- ---------------------------------------------------------------------------

---What an NPC should show: one entry per category, from its `_eq` records.
---@return table[]|nil nil when it carries nothing worn
local function wornBy(actor)
    local list, seen = nil, nil
    for _, item in ipairs(types.Actor.inventory(actor):getAll(types.Miscellaneous)) do
        local base = CAKE.baseOf(item.recordId)
        if base then
            local entry = CAKE.ITEMS[base]
            seen = seen or {}
            if not seen[entry.category] then
                seen[entry.category] = true
                local cat = CAKE.CATEGORIES[entry.category]
                list = list or {}
                list[#list + 1] = { vfxId = cat.vfxId, bone = cat.bone, fallback = cat.fallback,
                                    model = types.Miscellaneous.record(entry.eq).model }
            end
        end
    end
    return list
end

local EMPTY = {}

local function syncNpc(actor)
    local list = showNpcs and wornBy(actor) or nil
    if actor:hasScript(NPC_SCRIPT) then
        -- An empty list makes the script clear what it drew and ask to be removed
        -- (Cake_NpcIdle); removing it here would drop the event undelivered.
        actor:sendEvent('Cake_Show', list or EMPTY)
    elseif list then
        actor:addScript(NPC_SCRIPT, list)
    end
end

local function onActorActive(actor)
    if types.NPC.objectIsInstance(actor) and not types.Player.objectIsInstance(actor) then
        syncNpc(actor)
    end
end

local function setShowNpcs(data)
    local value = data.value ~= false
    if value == showNpcs then return end
    showNpcs = value
    for _, actor in ipairs(world.activeActors) do onActorActive(actor) end
end

I.ItemUsage.addHandlerForType(types.Miscellaneous, onUse)

return {
    engineHandlers = {
        onActorActive = onActorActive,
        onSave = function() return { showNpcs = showNpcs } end,
        onLoad = function(data) if data then showNpcs = data.showNpcs ~= false end end,
    },
    eventHandlers = {
        Cake_ConvertInCell = convertLooseInCell,
        Cake_SetShowNpcs   = setShowNpcs,
        -- Another mod changed an NPC's CAKE items: { actor = <GameObject> }.
        Cake_RefreshNpc    = function(data) onActorActive(data.actor) end,
        Cake_NpcIdle       = function(actor)
            if actor:isValid() and actor:hasScript(NPC_SCRIPT) then actor:removeScript(NPC_SCRIPT) end
        end,
    },
}
