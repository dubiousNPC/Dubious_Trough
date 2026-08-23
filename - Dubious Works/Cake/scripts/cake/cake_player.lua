---@omw-context player
--[[
    cake_player.lua -- attaching worn items to the player

    WORN STATE IS SET BY ACTIVATION, NOT INFERRED FROM THE INVENTORY
    ----------------------------------------------------------------
    `worn` below is explicit saved state: category -> base record id, written
    only when I.ItemUsage reports the player actually used the item. This is
    Sun's Dusk's model (`saveData.backpackId` in p_backpacks.lua), and the
    distinction is not academic.

    An earlier version derived worn state by scanning the inventory for `_eq`
    records. That inverts the intent: it makes LOOTING an `_eq` record equal
    to wearing it, because presence was the whole test. Activation stopped
    being what put something on -- it was merely one of the ways an `_eq`
    record could end up in your bag. Everything downstream then had to defend
    that inference, which is what the cell-wide sweep was really propping up.

    Explicit state alone can drift, so it is reconciled the way Sun's Dusk
    reconciles its own: if the `_eq` record backing an entry is no longer in
    the inventory, the entry is dropped. State leads, the inventory audits.

    WHAT WAS WRONG WITH playergear.lua
    ----------------------------------
    * `Bip01 tailsDBS` does not exist. 32 tails were assigned to it; every one
      failed hasBone and rendered nothing. See cake_shared.lua.
    * DEFAULT_BONE was a TABLE (with `fallback`, `uiModes` and `vfxItem` keys)
      but was used as `BACKPACK_BONES[id] or DEFAULT_BONE` and then handed to
      animation.hasBone, which wants a string. Any item missing from the bones
      table hit that path.
    * BACKPACK_FEATHER_PERCENT was referenced by refreshFeatherMagnitude but
      never defined in the file, so the function raised on first call.
    * The bones table mixed three naming conventions at once --
      `dbs_indoril_tail_eq`, `LanternDwem_eq`, `_RV_Scarf01` -- and none of the
      three matched the `dbs_<thing>_eq` records the plugins actually define.
    * A single VFX_ID meant one worn item across all categories; a lantern and
      a mask could not coexist. Each category now has its own vfxId.
    * The Sun's Dusk feather/ability system was carried over wholesale,
      including `sd_feather_f1..f8` and `SunsDusk_playSound`. Those are Sun's
      Dusk records. Cosmetics do not need an encumbrance system, so it is gone
      rather than reimplemented; if a category ever wants a buff it should get
      its own records.

    NO POLLING
    ----------
    Sun's Dusk polls camera mode and inventory presence on its sluggish frame
    list because it predates AnimRefresh. Perspective changes arrive here
    through AnimRefresh instead, subscribed only while something is worn.
    Inventory changes arrive through the equip event and the UI-mode handler.
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

local Actor    = types.Actor
local settings = storage.playerSection('Settings_cake_main')

local FIRST_PERSON = camera.MODE.FirstPerson

-- Retry once after this long if the bone is missing. Straight from Sun's Dusk:
-- right after a perspective switch the rebuilt skeleton may not be ready yet,
-- and attaching to it then is a silent no-show.
local BONE_RETRY_DELAY = 0.1

local boneCache = nil

-- category -> base record id. Written only by activation (Cake_Changed),
-- persisted across saves, audited against the inventory on load and on
-- becoming active.
local worn = {}

---Drop any entry whose backing `_eq` record has left the inventory -- dropped,
---sold, stolen. Mirrors Sun's Dusk's `if not inventory:find(backpackId)` check.
---@return boolean lost true if anything was reconciled away
local function reconcile()
    local inv  = Actor.inventory(self)
    local lost = false
    for category, baseId in pairs(worn) do
        local entry = CAKE.get(baseId)
        local ok, count = pcall(function() return inv:countOf(entry and entry.eq or '') end)
        if not entry or not ok or (count or 0) < 1 then
            worn[category] = nil
            lost = true
        end
    end
    return lost
end

-- ---------------------------------------------------------------------------
-- BONES
-- ---------------------------------------------------------------------------

local function probeBones()
    local found = {}
    for bone in pairs(CAKE.allBones) do
        local ok, has = pcall(anim.hasBone, self, bone)
        found[bone] = (ok and has) or false
    end
    boneCache = found
    return found
end

---Bone a category should attach to, honouring the skeleton setting.
---@return string|nil bone, boolean missingPrimary
local function resolveBone(cat)
    local profile = CAKE.SKELETON[settings:get('SKELETON') or CAKE.DEFAULT_SKELETON]
                    or CAKE.SKELETON.auto

    if not profile.probe then
        if cat.bone and profile.bones[cat.bone] then return cat.bone, false end
        return cat.boneFallback, cat.bone ~= nil
    end

    local bones = boneCache or probeBones()
    if cat.bone and bones[cat.bone] then return cat.bone, false end
    if bones[cat.boneFallback] then return cat.boneFallback, cat.bone ~= nil end
    return nil, true
end

-- ---------------------------------------------------------------------------
-- ATTACHMENT
-- ---------------------------------------------------------------------------

local function detachAll()
    for _, cat in pairs(CAKE.CATEGORIES) do
        pcall(anim.removeVfx, self, cat.vfxId)
    end
end

---Everything currently worn, as category -> entry.
---A table read, not an inventory walk: `worn` is authoritative and one
---category can only ever hold one entry, so no first-one-wins tie-break is
---needed and no duplicated pair can stack two meshes on one bone.
local function readWorn()
    local out = {}
    for category, baseId in pairs(worn) do
        local entry = CAKE.get(baseId)
        if entry then out[category] = entry end
    end
    return out
end

local function refresh(isRetry)
    detachAll()
    boneCache = nil

    local worn = readWorn()
    if next(worn) == nil then return false end

    if camera.getMode() == FIRST_PERSON and not settings:get('SHOWFIRSTPERSON') then
        return true
    end

    local retryNeeded = false

    for categoryName, entry in pairs(worn) do
        local cat  = CAKE.CATEGORIES[categoryName]
        local bone = resolveBone(cat)
        if not bone then
            retryNeeded = true
        else
            local ok = pcall(anim.addVfx, self, entry.model, {
                vfxId           = cat.vfxId,
                boneName        = bone,
                loop            = true,
                useAmbientLight = false,
            })
            if not ok then retryNeeded = true end
        end
    end

    if retryNeeded and not isRetry then
        async:newUnsavableSimulationTimer(BONE_RETRY_DELAY, function() refresh(true) end)
    end

    return true
end

-- ---------------------------------------------------------------------------
-- ANIMREFRESH
-- ---------------------------------------------------------------------------
-- Subscribed only while something is worn, so a player wearing nothing pays
-- nothing: AnimRefresh returns on an empty-subscriber check and its TogglePOV
-- handler is never reached.

local subscribed = false

local function syncSubscription(wornNow)
    if wornNow == subscribed then return end
    if not (I.AnimRefresh and I.AnimRefresh.subscribe) then return end
    if wornNow then
        I.AnimRefresh.subscribe('CAKE', function() refresh() end)
    else
        I.AnimRefresh.unsubscribe('CAKE')
    end
    subscribed = wornNow
end

local function refreshAndSync()
    syncSubscription(refresh())
end

-- ---------------------------------------------------------------------------
-- OPTIONAL GESTURE
-- ---------------------------------------------------------------------------
-- Required lazily and inside a pcall, so deleting cake_anim.lua is a supported
-- way to opt out. Loaded once and remembered, including the failure, so a
-- missing file is not re-required on every equip.

local animModule = nil   -- nil = not tried, false = unavailable

local function playGesture(categoryName)
    if not categoryName or not settings:get('EQUIPANIM') then return end
    if animModule == nil then
        local ok, mod = pcall(require, 'scripts.cake.cake_anim')
        animModule = (ok and type(mod) == 'table' and mod) or false
    end
    if animModule then animModule.playEquip(categoryName) end
end

-- ---------------------------------------------------------------------------
-- HANDLERS
-- ---------------------------------------------------------------------------

local REFRESH_AFTER = {}
if I.UI and I.UI.MODE then
    for _, key in ipairs({ 'Rest', 'Travel', 'Training', 'Inventory',
                           'Container', 'Barter', 'Companion' }) do
        if I.UI.MODE[key] then REFRESH_AFTER[I.UI.MODE[key]] = true end
    end
end

-- ---------------------------------------------------------------------------
-- LOOSE WORN RECORDS
-- ---------------------------------------------------------------------------
-- An `_eq` record can still end up loose in the world -- dropped, sold, put in
-- a chest. With worn state explicit that is no longer a correctness problem:
-- looting one does not make you wear it, and using one converts it back. It is
-- only untidy, so cake_global's cell sweep is still worth running, just not
-- often.
--
-- reconcile() tells us exactly when it is worth running: if an entry lost its
-- backing record, one went missing and may now be lying somewhere. That is the
-- same trigger Sun's Dusk uses (`if not inventory:find(backpackId) then
-- sendGlobalEvent("SunsDusk_convertInCell")`), and it is strictly better than
-- the snapshot-around-transfer-UI guess it replaces here -- state knows, so
-- there is nothing left to infer.

local function refreshAfterReconcile()
    if reconcile() then
        core.sendGlobalEvent('Cake_ConvertInCell', self.object)
    end
    refreshAndSync()
end

local function pushNpcSetting()
    core.sendGlobalEvent('Cake_SetShowNpcs', { value = settings:get('SHOWNPCS') ~= false })
end

settings:subscribe(async:callback(function(_, key)
    if key == 'SHOWNPCS' then pushNpcSetting() else refreshAndSync() end
end))

return {
    interfaceName = 'CAKE',
    interface = {
        version = CAKE.version,
        refresh = refreshAndSync,
        getWorn = readWorn,
    },
    engineHandlers = {
        onActive = function()
            refreshAfterReconcile()
            pushNpcSetting()
        end,
        onSave = function() return { worn = worn } end,
        onLoad = function(data)
            worn = (data and type(data.worn) == 'table') and data.worn or {}
        end,
    },
    eventHandlers = {
        -- The ONLY writer of `worn`. Fired by cake_global from the
        -- I.ItemUsage handler, i.e. only when the player actually used the
        -- item. `equipped` carries the `_eq` id on the way on and is absent on
        -- the way off, which is exactly the set/clear signal needed.
        Cake_Changed = function(data)
            if data and data.category then
                if data.equipped then
                    worn[data.category] = CAKE.baseOf(data.equipped)
                else
                    worn[data.category] = nil
                end
            end
            refreshAndSync()
            -- Only on the way on. `equipped` is absent when the event came
            -- from taking something off, and a gesture there would look like
            -- the player putting on the item they just removed.
            if data and data.equipped then playGesture(data.category) end
            -- No cell sweep here. Equipping and unequipping both keep the
            -- record inside this inventory, so nothing can have been stranded;
            -- see the LOOSE WORN RECORDS note above for where it moved to.
        end,
        Cake_Refresh = refreshAndSync,
        vfxRemoveAll = refreshAndSync,
        UiModeChanged = function(e)
            -- Leaving a menu is when an `_eq` record most often stops being
            -- in the inventory, so audit here rather than guessing.
            if e and e.oldMode and REFRESH_AFTER[e.oldMode] then
                refreshAfterReconcile()
            end
        end,
    },
}
