---@omw-context local
--[[
    cake_npc.lua -- worn items on other actors

    Same rule as the player: an actor wears an item exactly when the `_eq`
    record is in its inventory. No polling -- an NPC's inventory does not
    change while you are looking at it, so onActive plus explicit refresh
    events is enough. One inventory walk covers every category.
]]

local self    = require('openmw.self')
local types   = require('openmw.types')
local anim    = require('openmw.animation')
local storage = require('openmw.storage')

local CAKE = require('scripts.cake.cake_shared')

-- Read-only here; the global script owns this section. Absent means "not
-- seeded yet", which should behave as enabled rather than as disabled.
local globalState = storage.globalSection('Cake_global')

local boneCache = nil

local function probeBone(bone)
    if boneCache == nil then boneCache = {} end
    if boneCache[bone] == nil then
        local ok, has = pcall(anim.hasBone, self, bone)
        boneCache[bone] = (ok and has) or false
    end
    return boneCache[bone]
end

local function resolveBone(cat)
    if cat.bone and probeBone(cat.bone) then return cat.bone end
    if probeBone(cat.boneFallback) then return cat.boneFallback end
    return nil
end

local function rescan()
    for _, cat in pairs(CAKE.CATEGORIES) do pcall(anim.removeVfx, self, cat.vfxId) end
    boneCache = nil

    -- Detaching first and returning means turning the setting off strips what
    -- is already showing, rather than freezing it in place.
    if globalState:get('showNpcs') == false then return end

    local seen = {}
    for _, item in ipairs(types.Actor.inventory(self):getAll(types.Miscellaneous)) do
        local baseId = CAKE.baseOf(item.recordId)
        local entry  = baseId and CAKE.get(baseId) or nil
        if entry and not seen[entry.category] then
            seen[entry.category] = true
            local cat  = CAKE.CATEGORIES[entry.category]
            local bone = resolveBone(cat)
            if bone then
                pcall(anim.addVfx, self, entry.model, {
                    vfxId           = cat.vfxId,
                    boneName        = bone,
                    loop            = true,
                    useAmbientLight = false,
                })
            end
        end
    end
end

return {
    engineHandlers = {
        onActive   = rescan,
        onInactive = function() boneCache = nil end,
    },
    eventHandlers = {
        Cake_Refresh = rescan,
        vfxRemoveAll = rescan,
        equipped     = rescan,
        unequipped   = rescan,
    },
}
