---@omw-context local|player
--[[
    common.lua -- shared equipment display logic

    Attaches inventory weapons and shields to their sheath bones as looping
    VFX, so carried gear is visible on the body.

    WHAT CHANGED FROM THE ORIGINAL
    ------------------------------
    * types.Actor.equipment does not exist -- the API is getEquipment. Because
      the call sat inside a pcall it failed silently, so equippedWeapon and
      equippedShield were ALWAYS nil and the equipped weapon/shield were never
      excluded from the display. They were being drawn twice.
    * The whole VFX set was torn down and rebuilt every 10 frames regardless of
      whether anything had changed, including a vfs.fileExists filesystem hit
      per weapon and a record() lookup per inventory item. Now a cheap
      signature is compared first and the rebuild is skipped when nothing moved.
    * That unconditional rebuild was accidentally load-bearing: switching
      perspective rebuilds the player's animation object and drops attached
      VFX, and rebuilding constantly happened to restore them within 10 frames.
      Skipping redundant rebuilds would have made gear vanish permanently on
      every POV switch, so AnimRefresh now forces a rebuild on that event. Same
      problem, and same fix, as Sun's Dusk uses for its backpack VFX.
    * Record and resolved-mesh lookups are memoized. Both are immutable per
      record id, so they only need computing once per session.
    * Polling is time-based rather than frame-count based; the old
      `frameCount % 10` ran ~14x/sec at 144fps and ~3x/sec at 30fps.
    * resolveMesh's if/else branches were character-for-character identical, so
      USE_SHEATH_MODEL was dead code. Removed.
    * addVfx was passed `tag` and `isMagic`, neither of which exist in the API.
    * Every shield in the inventory attached to the same bone, so three shields
      meant three overlapping meshes in one spot. Capped.
    * The ammo loop was unbounded and relied on a missing bone to stop it.

    CLASHES WITH OPENMW'S NATIVE WEAPON SHEATHING
    ---------------------------------------------
    These are the same bones the engine's own sheathing uses, so both can put a
    mesh on one bone. Two cases were doing exactly that:

    * Occupancy was keyed by weapon TYPE, but bones.lua maps AxeOneHand and
      LongBladeOneHand onto the same bone (and Arrow/Bolt onto another). An
      equipped, sheathed longsword plus a carried axe therefore stacked two
      meshes on `Bip01 LongBladeOneHand`. Keyed by bone now.
    * The equipped shield was excluded only by record id, so a SECOND, different
      shield in the pack went onto `Bip01 AttachShield` alongside the engine's.

    The equipped weapon's bone is also claimed only while the weapon is
    sheathed, which is when the engine actually occupies it.
]]

local types = require('openmw.types')
local vfs   = require('openmw.vfs')
local anim  = require('openmw.animation')
local I     = require('openmw.interfaces')
local bones = require('scripts.show-all-weapons.bones')

local M = {}

-- ---------------------------------------------------------------------------
-- TUNING
-- ---------------------------------------------------------------------------

-- Seconds between change checks. The check itself is cheap (see buildSignature)
-- and a full rebuild only happens when something actually moved.
local POLL_INTERVAL = 0.5

-- Ammo is one VFX per arrow, attached to "Bip01 Ammo 1", "Bip01 Ammo 2"...
-- The original looped to the full stack count and relied on the first missing
-- bone to break out; a 500 arrow stack meant 500 attach attempts. Real quivers
-- have a handful of bones, so cap explicitly and stop wasting the attempts.
local MAX_AMMO_DISPLAY = 12

-- All shields attach to the same bone, so more than one is just overlapping
-- geometry in the same spot.
local MAX_SHIELDS = 1

local AMMO_TYPES = {
    [types.Weapon.TYPE.Arrow] = true,
    [types.Weapon.TYPE.Bolt]  = true,
}

local RANGED_TYPES = {
    [types.Weapon.TYPE.MarksmanBow]      = true,
    [types.Weapon.TYPE.MarksmanCrossbow] = true,
}

local AMMO_FOR_RANGED = {
    [types.Weapon.TYPE.Arrow] = types.Weapon.TYPE.MarksmanBow,
    [types.Weapon.TYPE.Bolt]  = types.Weapon.TYPE.MarksmanCrossbow,
}

-- ---------------------------------------------------------------------------
-- CACHES
-- ---------------------------------------------------------------------------
-- Each local script gets its own Lua environment, so these are per-actor
-- already. That is also why the original's activeVfx table keyed by actor only
-- ever held a single entry.

local weaponRecCache = {}   -- recordId -> WeaponRecord | false
local armorRecCache  = {}   -- recordId -> ArmorRecord  | false
local meshCache      = {}   -- model    -> resolved path | false

local function weaponRecord(item)
    local rid = item.recordId
    local cached = weaponRecCache[rid]
    if cached ~= nil then return cached or nil end
    local ok, rec = pcall(types.Weapon.record, item)
    weaponRecCache[rid] = (ok and rec) or false
    return (ok and rec) or nil
end

local function armorRecord(item)
    local rid = item.recordId
    local cached = armorRecCache[rid]
    if cached ~= nil then return cached or nil end
    local ok, rec = pcall(types.Armor.record, item)
    armorRecCache[rid] = (ok and rec) or false
    return (ok and rec) or nil
end

local function normPath(path)
    if not path then return nil end
    return (path:gsub("\\", "/"):lower())
end

-- Prefers the "_sh" sheathed variant when one exists in the VFS. Memoized
-- because vfs.fileExists is a filesystem lookup and model paths never change
-- for a given record.
local function resolveMesh(model)
    if not model then return nil end
    local cached = meshCache[model]
    if cached ~= nil then return cached or nil end

    local path   = normPath(model)
    local result = path
    if path then
        local sheath = path:gsub("%.nif$", "_sh.nif")
        if vfs.fileExists(sheath) then result = sheath end
    end
    meshCache[model] = result or false
    return result
end

-- ---------------------------------------------------------------------------
-- VFX TRACKING
-- ---------------------------------------------------------------------------

local activeTags = {}

local function clearVfx(actor)
    for i = 1, #activeTags do
        pcall(anim.removeVfx, actor, activeTags[i])
    end
    activeTags = {}
end

local function attachVfx(actor, mesh, bone, tag)
    if not mesh or not bone then return false end
    if not anim.hasBone(actor, bone) then return false end
    -- Only the documented options: loop, boneName, particleTextureOverride,
    -- vfxId, useAmbientLight.
    local ok = pcall(anim.addVfx, actor, mesh, {
        boneName        = bone,
        vfxId           = tag,
        loop            = true,
        useAmbientLight = false,
    })
    if not ok then return false end
    activeTags[#activeTags + 1] = tag
    return true
end

-- ---------------------------------------------------------------------------
-- STATE READ
-- ---------------------------------------------------------------------------

-- Returns equipped weapon, equipped shield, isDrawn.
local function readState(actor)
    local equippedWeapon, equippedShield

    -- getEquipment, NOT equipment. The original called a function that does not
    -- exist, and the surrounding pcall hid it completely.
    local ok, slots = pcall(types.Actor.getEquipment, actor)
    if ok and slots then
        local w = slots[types.Actor.EQUIPMENT_SLOT.CarriedRight]
        if w and types.Weapon.objectIsInstance(w) then
            local rec = weaponRecord(w)
            if rec and not AMMO_TYPES[rec.type] then equippedWeapon = w end
        end
        local s = slots[types.Actor.EQUIPMENT_SLOT.CarriedLeft]
        if s and types.Armor.objectIsInstance(s) then
            local rec = armorRecord(s)
            if rec and rec.type == types.Armor.TYPE.Shield then equippedShield = s end
        end
    end

    local isDrawn = false
    local sok, stance = pcall(types.Actor.getStance, actor)
    if sok then isDrawn = (stance == types.Actor.STANCE.Weapon) end

    return equippedWeapon, equippedShield, isDrawn
end

-- Cheap change detector. Deliberately avoids record() lookups -- recordId and
-- count are already on the object -- so the common "nothing changed" path never
-- touches the record store or the filesystem.
--
-- getAll ordering is not documented as stable; if it ever varies the signature
-- differs and we do one redundant rebuild, which is harmless.
local function buildSignature(actor, equippedWeaponId, equippedShieldId, isDrawn)
    local inv = types.Actor.inventory(actor)
    local parts = {
        equippedWeaponId or "-",
        equippedShieldId or "-",
        isDrawn and "1" or "0",
    }
    for _, item in ipairs(inv:getAll(types.Weapon)) do
        parts[#parts + 1] = item.recordId .. ":" .. item.count
    end
    for _, item in ipairs(inv:getAll(types.Armor)) do
        parts[#parts + 1] = item.recordId .. ":" .. item.count
    end
    return table.concat(parts, "|")
end

-- ---------------------------------------------------------------------------
-- REBUILD
-- ---------------------------------------------------------------------------

local function handler(actor, equippedWeapon, equippedShield, isDrawn)
    clearVfx(actor)

    local inv = types.Actor.inventory(actor)
    local equippedWeaponId = equippedWeapon and equippedWeapon.recordId or nil
    local equippedShieldId = equippedShield and equippedShield.recordId or nil

    -- Occupancy is tracked BY BONE, not by weapon type. Two weapon types share
    -- `Bip01 LongBladeOneHand` and two more share `Bip01 Ammo`, so a type-keyed
    -- table let a second mesh land on a bone that was already taken -- an
    -- equipped longsword sheathed by the engine plus a carried axe from this
    -- mod, both on the one bone.
    local boneTaken     = {}
    local ammoForRanged = {}
    local rangedPresent = {}
    local rangedEquipped = {}

    -- An equipped weapon that is NOT drawn is sitting on its sheath bone, put
    -- there by OpenMW's own weapon sheathing rather than by this mod. Claim the
    -- bone so nothing is stacked on top of the engine's mesh. Once drawn the
    -- weapon moves to the hand and the bone is free again.
    if equippedWeapon then
        local rec = weaponRecord(equippedWeapon)
        if rec then
            if not isDrawn then
                boneTaken[bones.boneForWeapon(rec.type)] = true
            end
            if RANGED_TYPES[rec.type] then
                rangedPresent[rec.type]  = true
                rangedEquipped[rec.type] = true
            end
        end
    end

    local seen = {}
    for _, item in ipairs(inv:getAll(types.Weapon)) do
        local rec = weaponRecord(item)
        if rec then
            local rid = item.recordId
            local wt  = rec.type

            if AMMO_TYPES[wt] then
                if types.Actor.hasEquipped(actor, item) then
                    ammoForRanged[wt] = item
                end
            else
                local bone = bones.boneForWeapon(wt)
                if not boneTaken[bone] and rid ~= equippedWeaponId
                   and not seen[rid] then
                    seen[rid] = true
                    boneTaken[bone] = true
                    if RANGED_TYPES[wt] then rangedPresent[wt] = true end
                    attachVfx(actor, resolveMesh(rec.model), bone, "saw_w_" .. rid)
                elseif RANGED_TYPES[wt] then
                    -- Still counts as owning a bow for quiver purposes even
                    -- when its bone is already spoken for.
                    rangedPresent[wt] = true
                end
            end
        end
    end

    -- Quiver: skipped while actually aiming the matching ranged weapon, so the
    -- drawn arrow is not duplicated on the back.
    for ammoType, rangedType in pairs(AMMO_FOR_RANGED) do
        local ammoItem = ammoForRanged[ammoType]
        if ammoItem and rangedPresent[rangedType]
           and not (isDrawn and rangedEquipped[rangedType]) then
            local rec = weaponRecord(ammoItem)
            if rec then
                local baseBone = bones.boneForWeapon(ammoType)
                local mesh     = normPath(rec.model)
                if baseBone and mesh then
                    local count = math.min(inv:countOf(rec.id), MAX_AMMO_DISPLAY)
                    for i = 1, count do
                        if not attachVfx(actor, mesh, baseBone .. " " .. i,
                                         "saw_ammo_" .. ammoType .. "_" .. i) then
                            break
                        end
                    end
                end
            end
        end
    end

    -- Shields all share one bone. An equipped shield that is not drawn is
    -- already on that bone, placed there by the engine's sheathing, so showing
    -- a carried shield as well stacks two meshes in one spot. Yield the bone
    -- entirely in that case; once the shield is drawn it moves to the arm and
    -- the back is free again.
    local shieldsShown = (equippedShield and not isDrawn) and MAX_SHIELDS or 0
    for _, item in ipairs(inv:getAll(types.Armor)) do
        if shieldsShown >= MAX_SHIELDS then break end
        local rid = item.recordId
        if rid ~= equippedShieldId then
            local rec = armorRecord(item)
            if rec and rec.model and rec.type == types.Armor.TYPE.Shield then
                if attachVfx(actor, normPath(rec.model), bones.SHIELD_BONE,
                             "saw_sh_" .. shieldsShown) then
                    shieldsShown = shieldsShown + 1
                end
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- UPDATE HANDLER
-- ---------------------------------------------------------------------------

function M.makeUpdateHandler(actor)
    local timer         = 0
    local lastSignature = nil
    local forceRebuild  = true   -- first pass always builds

    local function rebuildNow()
        local w, s, drawn = readState(actor)
        lastSignature = buildSignature(actor,
            w and w.recordId or nil, s and s.recordId or nil, drawn)
        handler(actor, w, s, drawn)
        forceRebuild = false
    end

    -- Perspective changes rebuild the player's animation object and drop
    -- attached VFX. Only the player is affected, and I.AnimRefresh is a
    -- player-context interface, so this is nil for NPC scripts and the
    -- subscription simply does not happen there.
    if I.AnimRefresh and I.AnimRefresh.subscribe then
        I.AnimRefresh.subscribe("InventoryEquipmentDisplay", function()
            forceRebuild = true
        end)
    end

    return function(dt)
        timer = timer + (dt or 0)
        if timer < POLL_INTERVAL and not forceRebuild then return end
        timer = 0

        if forceRebuild then
            rebuildNow()
            return
        end

        local w, s, drawn = readState(actor)
        local signature = buildSignature(actor,
            w and w.recordId or nil, s and s.recordId or nil, drawn)
        if signature == lastSignature then return end

        lastSignature = signature
        handler(actor, w, s, drawn)
    end
end

M.handler = handler

return M
