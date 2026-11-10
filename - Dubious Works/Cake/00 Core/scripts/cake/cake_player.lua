---@omw-context player
--[[
    cake_player.lua -- what the player wears, and drawing it

    STATE. `worn` maps category -> base record id. It is written only by
    Cake_Changed, which cake_global sends when the player uses an item, so
    looting a worn record never puts it on. It is saved with the game, and
    audited against the bag whenever a menu closes or the model is rebuilt:
    an entry whose `_eq` record has left the bag is dropped.

    DRAWING. Through AnimRefresh v6, subscribed only while something is worn.
    The callback is the one place that attaches meshes, and it returns false
    while the model is not built yet, so AnimRefresh retries it rather than
    CAKE running its own timer. `verify = true` asks for the second delivery
    1.8 s after a perspective change: a rebuild that lands after the first
    delivery silently drops what was attached, and nothing can detect that.
    Joining delivers once on its own, so subscribing draws.
]]

local self    = require('openmw.self')
local types   = require('openmw.types')
local anim    = require('openmw.animation')
local camera  = require('openmw.camera')
local storage = require('openmw.storage')
local core    = require('openmw.core')
local async   = require('openmw.async')
local I       = require('openmw.interfaces')

local CAKE = require('scripts.cake.cake_shared')

local settings = storage.playerSection('Settings_cake_main')
local inv = types.Actor.inventory(self)

local worn = {}    -- category -> base record id
local drawn = {}   -- vfxId -> true

---Drop entries whose worn record has left the bag. True if any were dropped.
local function audit()
    local lost = false
    for category, base in pairs(worn) do
        local entry = CAKE.get(base)
        if not entry or inv:countOf(entry.eq) == 0 then
            worn[category] = nil
            lost = true
        end
    end
    if lost then core.sendGlobalEvent('Cake_ConvertInCell', self.object) end
    return lost
end

local function clear()
    for vfxId in pairs(drawn) do anim.removeVfx(self, vfxId) end
    drawn = {}
end

---Attach everything worn. Returns false when the model is not ready yet.
local function draw(mode)
    clear()
    if mode == camera.MODE.FirstPerson and not settings:get('SHOWFIRSTPERSON') then return true end
    for category, base in pairs(worn) do
        local cat = CAKE.CATEGORIES[category]
        local bone = anim.hasBone(self, cat.bone) and cat.bone
                     or anim.hasBone(self, cat.fallback) and cat.fallback or nil
        -- The fallbacks are vanilla bones every humanoid skeleton has. Neither
        -- answering means the model is mid-rebuild, not that the bone is absent.
        if not bone then clear(); return false end
        anim.addVfx(self, types.Miscellaneous.record(CAKE.get(base).eq).model,
                    { vfxId = cat.vfxId, boneName = bone, loop = true, useAmbientLight = false })
        drawn[cat.vfxId] = true
    end
    return true
end

local subscribed = false

local function onRefresh(mode)
    audit()
    return draw(mode)
end

---Bring the subscription and the drawing in line with `worn`.
local function sync()
    if next(worn) == nil then
        clear()
        if subscribed then I.AnimRefresh.unsubscribe('CAKE'); subscribed = false end
    elseif not subscribed then
        I.AnimRefresh.subscribe('CAKE', onRefresh, { verify = true })   -- the join draws
        subscribed = true
    else
        draw(camera.getMode())
    end
end

local function pushNpcSetting()
    core.sendGlobalEvent('Cake_SetShowNpcs', { value = settings:get('SHOWNPCS') ~= false })
end

settings:subscribe(async:callback(function(_, key)
    if key == 'SHOWNPCS' then pushNpcSetting() else sync() end
end))

return {
    interfaceName = 'CAKE',
    interface = {
        version = CAKE.version,
        ---category -> base record id of what the player wears (a copy).
        getWorn = function()
            local out = {}
            for k, v in pairs(worn) do out[k] = v end
            return out
        end,
        ---Redraw now, e.g. after another mod rebuilt the player model.
        refresh = function() sync() end,
    },
    engineHandlers = {
        onActive = function()
            audit()
            sync()
            pushNpcSetting()
        end,
        onSave = function() return { worn = worn } end,
        onLoad = function(data)
            worn = {}
            for category, base in pairs(data and data.worn or {}) do
                if CAKE.CATEGORIES[category] and CAKE.get(base) then worn[category] = base end
            end
        end,
    },
    eventHandlers = {
        -- From cake_global only: { cleared = { category, ... }, category, base }.
        Cake_Changed = function(data)
            for _, category in ipairs(data.cleared) do worn[category] = nil end
            if data.category then worn[data.category] = data.base end
            sync()
        end,
        -- A worn record can leave the bag in any menu that moves items.
        UiModeChanged = function(data)
            if data.newMode == nil and next(worn) ~= nil and audit() then sync() end
        end,
    },
}
