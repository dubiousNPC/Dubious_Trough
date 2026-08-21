---@omw-context player
--[[
    ridingAnim.lua -- all-in-one rider animation controller

    Consolidates the per-mod ridingAnim.lua files (Guar / Horse, which were
    byte-identical apart from the rideg*/rideh* group prefix) into one table-
    driven controller covering every mount type.

    SCOPE -- read this before extending
    -----------------------------------
    This file animates the RIDER, and nothing else. It does not move the
    player, does not steer the mount, and does not animate the mount. That
    split is deliberate and is the reason this file can be fully event-driven
    while every riding backend needs per-frame work (see VIABILITY below).

    Two things it deliberately does NOT do:
      * It does not script the MOUNT's gait. The engine's character controller
        already picks and speed-scales gait animations from movement controls;
        forcing scripted loops on top fights it and shows up as choppy motion
        at low speed. Sturdy Steed found this the hard way and says so in
        lib/horseanim.lua.
      * It does not own mounting. It listens for a backend's mounted event, or
        runs its own FREE_RIDE activation, but never both for one mount.

    CONVENTIONS
    -----------
    Follows sit_on_furniture.lua: no onFrame, exact record IDs first with
    ordered pattern fallback, memoized classification, SharedRay for
    targeting, one-shot control switches restored via onSave/onLoad.

    ###########################################################################
    #  ANIMATION GROUP NAMES AND SOME CREATURE IDS BELOW ARE PLACEHOLDERS.     #
    #  Entries marked VERIFIED were read out of the actual ESP/config files.   #
    #  Entries marked PLACEHOLDER are templates -- confirm before shipping.    #
    ###########################################################################
]]

local self    = require('openmw.self')
local anim    = require('openmw.animation')
local input   = require('openmw.input')
local types   = require('openmw.types')
local core    = require('openmw.core')
local camera  = require('openmw.camera')
local util    = require('openmw.util')
local storage = require('openmw.storage')
local async   = require('openmw.async')
local I       = require('openmw.interfaces')

-- ---------------------------------------------------------------------------
-- MOUNT TYPES
-- ---------------------------------------------------------------------------

local MOUNT_TYPE = {
    HORSE        = "horse",
    GUAR         = "guar",
    BOAR         = "boar",
    NIX          = "nix",
    STRIDENT     = "strident",
    SKYRENDER    = "skyrender",     -- flying
    KAGOUTI      = "kagouti",       -- PLACEHOLDER type
    SILT_STRIDER = "silt_strider",  -- PLACEHOLDER type
    NETCH        = "netch",         -- PLACEHOLDER type, flying
    GENERIC      = "generic",       -- free-ride / unresourced creatures
}

-- Rider states. JUMP is one-shot; the rest loop.
local STATE = {
    IDLE    = "idle",
    WALK    = "walk",
    GALLOP  = "gallop",
    REVERSE = "reverse",
    JUMP    = "jump",
}

-- ---------------------------------------------------------------------------
-- ANIMATION GROUPS PER MOUNT TYPE
-- ---------------------------------------------------------------------------
-- A state's value is either a single group name or a LIST of names. A list
-- means "pick one at random on entry" -- resolved once when the state is
-- entered, never re-rolled while it is running (re-rolling mid-state restarts
-- the animation and produces a visible hitch).
--
-- EXCEPTION -- JUMP: every jump variant needs a text key handler registered
-- against its exact group name at load time (see the handler registration at
-- the bottom). That is handled automatically for lists, but it means a jump
-- group name that never gets played still costs one dormant registration.
--
-- Horse and Guar groups are VERIFIED from the shipped mods. Everything below
-- them is PLACEHOLDER -- structure is right, names need confirming.
local RIDE_ANIM = {
    [MOUNT_TYPE.HORSE] = {                      -- VERIFIED (Devilish Horse Riding)
        [STATE.IDLE]    = "rideh1",
        [STATE.WALK]    = "rideh2",
        [STATE.GALLOP]  = "rideh3",
        [STATE.REVERSE] = "rideh4",
        [STATE.JUMP]    = "rideh5",
    },

    [MOUNT_TYPE.GUAR] = {                       -- VERIFIED (Devilish Guar Riding)
        [STATE.IDLE]    = "rideg1",
        [STATE.WALK]    = "rideg2",
        [STATE.GALLOP]  = "rideg3",
        [STATE.REVERSE] = "rideg4",
        [STATE.JUMP]    = "rideg5",
    },

    -- Below: PLACEHOLDER names, shown with variant lists to template the
    -- pattern. Idle variation reads best on long rides; gallop variation
    -- least (it cycles fast enough that the swap is hard to notice).
    [MOUNT_TYPE.BOAR] = {
        [STATE.IDLE]    = { "rideb1", "rideb1_alt" },
        [STATE.WALK]    = "rideb2",
        [STATE.GALLOP]  = "rideb3",
        [STATE.REVERSE] = "rideb4",
        [STATE.JUMP]    = "rideb5",
    },

    [MOUNT_TYPE.NIX] = {
        [STATE.IDLE]    = { "riden1", "riden1_alt" },
        [STATE.WALK]    = "riden2",
        [STATE.GALLOP]  = "riden3",
        [STATE.REVERSE] = "riden4",
        [STATE.JUMP]    = "riden5",
    },

    [MOUNT_TYPE.STRIDENT] = {
        [STATE.IDLE]    = "rides1",
        [STATE.WALK]    = "rides2",
        [STATE.GALLOP]  = { "rides3", "rides3_alt" },
        [STATE.REVERSE] = "rides4",
        [STATE.JUMP]    = "rides5",
    },

    -- Flying mounts: no reverse gait, and "gallop" is a dive/fast-flight pose.
    -- `false` means "this mount has no such state, and must NOT fall back to
    -- the generic clip" -- distinct from nil, which does fall back. Without
    -- this, a sky render would inherit ride_generic_jump and try to hop.
    [MOUNT_TYPE.SKYRENDER] = {
        [STATE.IDLE]    = "ridefly1",
        [STATE.WALK]    = "ridefly2",
        [STATE.GALLOP]  = "ridefly3",
        [STATE.REVERSE] = false,
        [STATE.JUMP]    = false,
    },

    [MOUNT_TYPE.NETCH] = {
        [STATE.IDLE]    = "ridenetch1",
        [STATE.WALK]    = "ridenetch2",
        [STATE.GALLOP]  = "ridenetch3",
        [STATE.REVERSE] = false,
        [STATE.JUMP]    = false,
    },

    [MOUNT_TYPE.KAGOUTI] = {
        [STATE.IDLE]    = "ridek1",
        [STATE.WALK]    = "ridek2",
        [STATE.GALLOP]  = "ridek3",
        [STATE.REVERSE] = "ridek4",
        [STATE.JUMP]    = "ridek5",
    },

    -- Very tall mount: rider sits rather than straddles.
    [MOUNT_TYPE.SILT_STRIDER] = {
        [STATE.IDLE]    = "ridesilt1",
        [STATE.WALK]    = "ridesilt2",
        [STATE.GALLOP]  = "ridesilt3",
    },
}

-- ---------------------------------------------------------------------------
-- FALLBACK SET
-- ---------------------------------------------------------------------------
-- Used for any mount with no RIDE_ANIM entry -- free-ride targets, creatures
-- from mods this pack has no resources for, modded mounts. Ships with the mod
-- so there is always something to play.
--
-- Set USE_FALLBACK_ANIM = false to make unresourced creatures play nothing at
-- all (the rider keeps their normal pose) rather than a generic straddle that
-- may look wrong on an unusual silhouette.
local USE_FALLBACK_ANIM = true

local FALLBACK_ANIM = {
    [STATE.IDLE]    = "ride_generic_idle",
    [STATE.WALK]    = "ride_generic_walk",
    [STATE.GALLOP]  = "ride_generic_gallop",
    [STATE.REVERSE] = "ride_generic_reverse",
    [STATE.JUMP]    = "ride_generic_jump",
}

-- ---------------------------------------------------------------------------
-- CREATURE -> MOUNT TYPE
-- ---------------------------------------------------------------------------
-- Exact record IDs win over patterns, same rule as sit_on_furniture: record
-- names lie often enough that substrings alone misfile mounts.
--
-- VERIFIED entries were read directly out of the shipped ESP/config files.
-- PLACEHOLDER entries are templates.
local MOUNT_TYPE_BY_RECORD = {
    -- VERIFIED -- Devilish Horse Riding config.lua HORSE_ID
    ["ttd_horseride"]         = MOUNT_TYPE.HORSE,
    -- VERIFIED -- Devilish Guar Riding config.lua GUAR_ID
    ["detd_guarride1"]        = MOUNT_TYPE.GUAR,
    -- VERIFIED -- Boar Riding.ESP CREA records
    ["ttd_boarride"]          = MOUNT_TYPE.BOAR,
    ["detd_boarnoride1"]      = MOUNT_TYPE.BOAR,
    -- VERIFIED -- Nix Riding.ESP CREA records
    ["ttd_nixride"]           = MOUNT_TYPE.NIX,
    ["detd_nixnoride"]        = MOUNT_TYPE.NIX,
    -- VERIFIED -- Strident Riding.ESP CREA records
    ["ttd_stridentride"]      = MOUNT_TYPE.STRIDENT,
    ["detd_stridentnoride1"]  = MOUNT_TYPE.STRIDENT,
    -- VERIFIED -- Devilish Sky Render Riding.esp CREA record
    ["detd_skybug_riding"]    = MOUNT_TYPE.SKYRENDER,

    -- PLACEHOLDER -- template rows for types with no shipped mod yet.
    ["placeholder_kagoutiride"]     = MOUNT_TYPE.KAGOUTI,
    ["placeholder_siltstriderride"] = MOUNT_TYPE.SILT_STRIDER,
    ["placeholder_netchride"]       = MOUNT_TYPE.NETCH,
}

-- Ordered fallback for creatures not listed above (other authors' mounts).
-- ORDER IS SIGNIFICANT where substrings nest. First match wins.
local MOUNT_TYPE_PATTERNS = {
    { mount = MOUNT_TYPE.SILT_STRIDER, patterns = { "siltstrider", "silt_strider" } },
    { mount = MOUNT_TYPE.SKYRENDER,    patterns = { "skyrender", "skybug", "sky_render" } },
    { mount = MOUNT_TYPE.STRIDENT,     patterns = { "strident" } },
    { mount = MOUNT_TYPE.KAGOUTI,      patterns = { "kagouti" } },
    { mount = MOUNT_TYPE.NETCH,        patterns = { "netch" } },
    { mount = MOUNT_TYPE.NIX,          patterns = { "nixmount", "nixhound", "nix" } },
    { mount = MOUNT_TYPE.BOAR,         patterns = { "boar" } },
    { mount = MOUNT_TYPE.GUAR,         patterns = { "guar" } },
    { mount = MOUNT_TYPE.HORSE,        patterns = { "horse", "pony", "steed" } },
}

-- Creatures that must never be mountable even under FREE_RIDE.
local BLACKLIST = {
    -- Bipedal humanoid-ish creatures read badly as mounts and several are
    -- quest-critical. Extend freely.
    ["placeholder_questcreature_01"] = true,
}

-- ---------------------------------------------------------------------------
-- CONFIG
-- ---------------------------------------------------------------------------

local DEBUG = false

-- FREE RIDE: mount any creature without adding a script to it. There is no
-- steering -- the creature keeps its own AI and the player rides along. That
-- is the whole point: no per-creature script, no control bridge, and by far
-- the lowest-impact mode in this file. Directional control REQUIRES a backend
-- (see VIABILITY note at the bottom); this mode deliberately does without.
local FREE_RIDE_ENABLED = true
local FREE_RIDE_KEY     = "x"      -- hold-modifier-free toggle key
local FREE_RIDE_RANGE   = 400      -- units; SharedRay ray length requested

-- Levitation replaces per-frame ground correction while mounted. It does NOT
-- move the player -- nothing in the OpenMW Lua API parents one object to
-- another, so a backend still has to place the rider. What levitation buys is
-- removing the gravity that otherwise drags the rider down between placements,
-- which is the artefact both shipped mods work around. Devilish says exactly
-- this in config.lua: "Player is levitated only so its own gravity does not
-- fight passenger placement."
local USE_LEVITATION      = true
local LEVITATION_SPELL_ID = "placeholder_ride_levitate"   -- PLACEHOLDER

-- Lower body carries the actual sitting pose -- it is the part that makes the
-- rider look seated rather than standing in mid-air -- so it must be in both
-- the blend mask and the priority table. The torso stays at Weapon priority so
-- weapon and spell animations keep control of the upper body.
--
-- Two different value spaces here, which is easy to get wrong:
--   BLEND_MASK is a BITMASK  -- LowerBody 1, Torso 2, LeftArm 4, RightArm 8
--   BONE_GROUP is an ENUM    -- LowerBody 1, Torso 2, LeftArm 3, RightArm 4
-- so the mask is summed while the priority table is keyed. Added rather than
-- bitwise-or'd because OpenMW runs LuaJIT (Lua 5.1), which has no `|`.
--
-- Arms are deliberately left out of the mask entirely, so weapon and spell arm
-- animations play untouched.
local RIDE_PRIORITY = {
    [anim.BONE_GROUP.LowerBody] = anim.PRIORITY.Scripted,
    [anim.BONE_GROUP.Torso]     = anim.PRIORITY.Weapon,
}
local RIDE_BLEND_MASK = anim.BLEND_MASK.LowerBody + anim.BLEND_MASK.Torso

local ALLOW_JUMP = true

-- Backend mounted/dismounted events this controller listens for. Adding a
-- backend is a data change here, not a code change.
local BACKEND_EVENTS = {
    mounted = {
        "DETD_HorseRiding_Mounted",
        "DETD_GuarRiding_Mounted",
        "SimpleHorseBaseRideAttach",
    },
    dismounted = {
        "DETD_HorseRiding_Dismounted",
        "DETD_GuarRiding_Dismounted",
        "SimpleHorseBaseRideDetach",
    },
}

-- ---------------------------------------------------------------------------
-- CLASSIFICATION (memoized)
-- ---------------------------------------------------------------------------

local mountTypeCache = {}

local function getMountType(recordId)
    if not recordId then return nil end
    local cached = mountTypeCache[recordId]
    if cached ~= nil then return cached or nil end

    local lower  = recordId:lower()
    local result = false

    if not BLACKLIST[lower] then
        result = MOUNT_TYPE_BY_RECORD[lower] or false
        if not result then
            for _, entry in ipairs(MOUNT_TYPE_PATTERNS) do
                for _, p in ipairs(entry.patterns) do
                    if lower:find(p, 1, true) then result = entry.mount; break end
                end
                if result then break end
            end
        end
    end

    mountTypeCache[recordId] = result
    return result or nil
end

-- A creature is rideable if it classifies to a known type, or if free ride is
-- on and it is simply a creature. Blacklist wins over both.
local function isRideable(obj)
    if not obj or not obj:isValid() then return false end
    if not types.Creature.objectIsInstance(obj) then return false end
    local rid = obj.recordId
    if rid and BLACKLIST[rid:lower()] then return false end
    if getMountType(rid) then return true end
    return FREE_RIDE_ENABLED
end

-- Resolve one state to a concrete group name. Returns nil when this mount type
-- has no group for the state (flying mounts have no reverse or jump), which
-- the state machine treats as "stay in the current state".
local function resolveGroup(mountType, state)
    local set = mountType and RIDE_ANIM[mountType]
    if not set and USE_FALLBACK_ANIM then set = FALLBACK_ANIM end
    if not set then return nil end

    local value = set[state]
    -- `false` is an explicit "this mount has no such state" and blocks the
    -- per-state fallback below. `nil` merely means "unspecified", which does
    -- fall back -- a mount type can leave an exotic state to the generic set
    -- rather than shipping a bespoke clip for it.
    if value == false then return nil end
    if value == nil and USE_FALLBACK_ANIM and set ~= FALLBACK_ANIM then
        value = FALLBACK_ANIM[state]
    end
    if value == nil or value == false then return nil end
    if type(value) ~= "table" then return value end

    local n = #value
    if n == 0 then return nil end
    if n == 1 then return value[1] end
    return value[math.random(n)]
end

-- ---------------------------------------------------------------------------
-- STATE
-- ---------------------------------------------------------------------------

local mountedActive  = false
local currentMount   = nil
local currentType    = nil
local currentState   = nil
local currentGroup   = nil
local jumpActive     = false
local heldForward    = false
local heldBackward   = false
local levitationAdded = false
local freeRiding     = false

-- ---------------------------------------------------------------------------
-- ANIMATION
-- ---------------------------------------------------------------------------

local function playLoop(state)
    if not mountedActive then return end
    -- Compare STATE, not resolved group name: with variant lists the resolved
    -- name differs between entries into the same state, so comparing names
    -- would restart the animation every refresh.
    if currentState == state then return end

    local group = resolveGroup(currentType, state)
    if not group then return end   -- no clip for this state on this mount

    I.AnimationController.playBlendedAnimation(group, {
        startKey    = "start",
        stopKey     = "stop",
        priority    = RIDE_PRIORITY,
        blendMask   = RIDE_BLEND_MASK,
        loops       = -1,
        forceLoop   = true,
        autoDisable = false,
    })

    currentState = state
    currentGroup = group
end

local function playOnce(state)
    local group = resolveGroup(currentType, state)
    if not group then return nil end

    I.AnimationController.playBlendedAnimation(group, {
        startKey    = "start",
        stopKey     = "stop",
        priority    = RIDE_PRIORITY,
        blendMask   = RIDE_BLEND_MASK,
        loops       = 0,
        autoDisable = true,
    })

    currentState = state
    currentGroup = group
    return group
end

-- animation.cancel lives on the base openmw.animation module, NOT on
-- I.AnimationController, and is only valid on self.
local function stopAnim()
    if not currentGroup then return end
    anim.cancel(self, currentGroup)
    currentGroup = nil
    currentState = nil
end

local function locomotionState()
    if heldForward and not heldBackward then
        return input.isShiftPressed() and STATE.GALLOP or STATE.WALK
    elseif heldBackward and not heldForward then
        return STATE.REVERSE
    end
    return STATE.IDLE
end

local function refreshLocomotion()
    if not mountedActive or jumpActive then return end
    playLoop(locomotionState())
end


-- ---------------------------------------------------------------------------
-- THIRD PERSON CAMERA OFFSET
-- ---------------------------------------------------------------------------
-- Sitting on a mount raises the character well above normal standing height, so
-- the default third person framing ends up looking down at the rider's head.
-- These settings pull the focal point back down (and optionally sideways).
--
-- setFocalPreferredOffset takes a 2d vector where X is horizontal (positive =
-- right of the character) and Y is vertical (positive = up), so the default
-- vertical offset is NEGATIVE to lower the view.
--
-- The built-in camera script also manages this offset, so it has to be told to
-- stand down for the duration via disableThirdPersonOffsetControl. The tag is
-- this mod's name, so enabling/disabling cannot clash with another mod holding
-- its own tag.

local SETTINGS_PAGE  = "AnimatedCreatureRiding"
local SETTINGS_GROUP = "SettingsAnimatedCreatureRidingCamera"
local CAMERA_TAG     = "AnimatedCreatureRiding"

I.Settings.registerPage {
    key         = SETTINGS_PAGE,
    l10n        = "none",
    name        = "Animated Creature Riding",
    description = "Mounted rider animation and camera.",
}

I.Settings.registerGroup {
    key              = SETTINGS_GROUP,
    page             = SETTINGS_PAGE,
    l10n             = "none",
    name             = "Third person camera",
    description      = "Adjusts the camera while mounted. Has no effect in first person.",
    permanentStorage = true,
    order            = 0,
    settings = {
        {
            key         = "CAMERA_OFFSET_ENABLED",
            name        = "Adjust camera while mounted",
            description = "Turn off to leave the third person camera exactly as it is normally.",
            renderer    = "checkbox",
            default     = true,
        },
        {
            key         = "CAMERA_OFFSET_V",
            name        = "Vertical offset",
            description = "Negative lowers the camera. Roughly matches the height a mount"
                       .. " adds to the rider.\n\nDefault is -75.",
            renderer    = "number",
            integer     = true,
            default     = -75,
            argument    = { min = -400, max = 400 },
        },
        {
            key         = "CAMERA_OFFSET_H",
            name        = "Horizontal offset",
            description = "Positive shifts the camera to the right of the rider,"
                       .. " negative to the left.\n\nDefault is 0.",
            renderer    = "number",
            integer     = true,
            default     = 0,
            argument    = { min = -400, max = 400 },
        },
    },
}

local cameraSettings   = storage.playerSection(SETTINGS_GROUP)
local cameraOffsetHeld = false

local function clearCameraOffset()
    if not cameraOffsetHeld then return end
    camera.setFocalPreferredOffset(util.vector2(0, 0))
    if I.Camera and I.Camera.enableThirdPersonOffsetControl then
        I.Camera.enableThirdPersonOffsetControl(CAMERA_TAG)
    end
    cameraOffsetHeld = false
end

local function applyCameraOffset()
    -- Offset only makes sense while mounted and in third person; every other
    -- case releases control back to the built-in camera script.
    if not mountedActive
       or not cameraSettings:get("CAMERA_OFFSET_ENABLED")
       or camera.getMode() ~= camera.MODE.ThirdPerson then
        clearCameraOffset()
        return
    end

    if not cameraOffsetHeld then
        if I.Camera and I.Camera.disableThirdPersonOffsetControl then
            I.Camera.disableThirdPersonOffsetControl(CAMERA_TAG)
        end
        cameraOffsetHeld = true
    end

    camera.setFocalPreferredOffset(util.vector2(
        cameraSettings:get("CAMERA_OFFSET_H") or 0,
        cameraSettings:get("CAMERA_OFFSET_V") or -75))
end

-- Live update: dragging a slider in the settings menu re-applies immediately
-- instead of waiting for the next mount.
cameraSettings:subscribe(async:callback(function()
    applyCameraOffset()
end))

-- ---------------------------------------------------------------------------
-- PERSPECTIVE CHANGE
-- ---------------------------------------------------------------------------
-- Switching perspective rebuilds the player's animation object and drops
-- scripted animations with it, so the rider pose vanishes on a POV press. The
-- reference riding mods avoid this by pinning the camera to first person; that
-- is not acceptable here, since being able to look at the animation is the
-- entire point of the mod.
--
-- I.AnimRefresh notifies after the switch has settled -- it defers past the
-- skeleton rebuild, because re-issuing immediately just writes onto a skeleton
-- about to be replaced.
--
-- Clearing currentState is what makes playLoop re-issue: it early-outs on an
-- unchanged state, so without this the re-assert is a silent no-op.
local function onPerspectiveChanged()
    -- Runs even when unmounted so a lingering offset is released if the ride
    -- ended while the notification was still settling.
    applyCameraOffset()
    if not mountedActive then return end
    if jumpActive then
        -- A one-shot jump clip cannot be resumed part-way, so drop back to
        -- locomotion rather than replaying the whole hop mid-air.
        jumpActive = false
    end
    currentState = nil
    playLoop(locomotionState())
end

local function subscribeRefresh()
    if I.AnimRefresh and I.AnimRefresh.subscribe then
        I.AnimRefresh.subscribe("AnimatedCreatureRiding", onPerspectiveChanged)
    end
end

local function unsubscribeRefresh()
    if I.AnimRefresh and I.AnimRefresh.unsubscribe then
        I.AnimRefresh.unsubscribe("AnimatedCreatureRiding")
    end
end

-- ---------------------------------------------------------------------------
-- LEVITATION
-- ---------------------------------------------------------------------------

local function addLevitation()
    if not USE_LEVITATION or levitationAdded then return end
    local spells = types.Actor.spells(self)
    levitationAdded = pcall(spells.add, spells, LEVITATION_SPELL_ID)
    if DEBUG and not levitationAdded then
        print("[ride] levitation spell '" .. tostring(LEVITATION_SPELL_ID) ..
              "' not found; rider gravity will fight placement")
    end
end

local function removeLevitation()
    if not levitationAdded then return end
    local spells = types.Actor.spells(self)
    pcall(spells.remove, spells, LEVITATION_SPELL_ID)
    levitationAdded = false
end

-- ---------------------------------------------------------------------------
-- JUMP
-- ---------------------------------------------------------------------------

local function startJump()
    if not (mountedActive and ALLOW_JUMP) or jumpActive then return end
    local group = resolveGroup(currentType, STATE.JUMP)
    if not group then return end   -- flying mounts, or no jump clip
    jumpActive = true
    playOnce(STATE.JUMP)
end

local function onJumpStopKey()
    if not jumpActive then return end
    jumpActive  = false
    currentState = nil   -- force playLoop to re-issue the locomotion pose
    refreshLocomotion()
end

-- Text key handlers must be registered against a fixed group name at load
-- time, so every jump variant across every mount type gets its own dormant
-- registration up front. Registering lazily per play is not an option: the
-- handler has to already exist when the clip's stop key fires.
local registeredJumpGroups = {}
local function registerJumpHandlers(set)
    local value = set and set[STATE.JUMP]
    if value == nil or value == false then return end
    local list = (type(value) == "table") and value or { value }
    for _, group in ipairs(list) do
        if not registeredJumpGroups[group] then
            registeredJumpGroups[group] = true
            I.AnimationController.addTextKeyHandler(group, function(_, key)
                if key == "stop" then onJumpStopKey() end
            end)
        end
    end
end

for _, set in pairs(RIDE_ANIM) do registerJumpHandlers(set) end
registerJumpHandlers(FALLBACK_ANIM)

-- ---------------------------------------------------------------------------
-- MOUNT LIFECYCLE
-- ---------------------------------------------------------------------------

local function keyIsPressed(key)
    local ok, value = pcall(input.isKeyPressed, key)
    return ok and value == true
end

local function beginRide(mount, isFreeRide)
    mountedActive = true
    freeRiding    = isFreeRide == true
    currentMount  = mount
    currentType   = mount and getMountType(mount.recordId) or nil
    jumpActive    = false
    currentState  = nil
    currentGroup  = nil

    if DEBUG then
        print(string.format("[ride] mounted %s -> type=%s freeRide=%s",
            tostring(mount and mount.recordId), tostring(currentType),
            tostring(freeRiding)))
    end

    addLevitation()

    -- One-time snapshot so the right pose starts immediately if W/S were
    -- already held at the moment of mounting. Runs once per mount, not a poll.
    heldForward  = keyIsPressed(input.KEY.W)
    heldBackward = keyIsPressed(input.KEY.S)

    subscribeRefresh()
    applyCameraOffset()
    refreshLocomotion()
end

local function endRide()
    mountedActive = false
    freeRiding    = false
    jumpActive    = false
    heldForward   = false
    heldBackward  = false
    currentMount  = nil
    currentType   = nil
    -- Unsubscribing is what keeps AnimRefresh free when nobody is riding: with
    -- no subscribers its onUpdate is a single count check.
    unsubscribeRefresh()
    clearCameraOffset()
    stopAnim()
    removeLevitation()
end

-- ---------------------------------------------------------------------------
-- FREE RIDE ACTIVATION (SharedRay)
-- ---------------------------------------------------------------------------
-- Reading SharedRay issues no cast of its own: the service already casts once
-- per frame for whoever is listening. requestDistance only raises the shared
-- ray length so mounts stay detectable at FREE_RIDE_RANGE.

if FREE_RIDE_ENABLED and I.SharedRay and I.SharedRay.requestDistance then
    I.SharedRay.requestDistance(FREE_RIDE_RANGE)
end

local function freeRideTarget()
    if not (I.SharedRay and I.SharedRay.get) then return nil end
    local result = I.SharedRay.get()
    if not result or not result.hit then return nil end
    local obj = result.hitObject
    -- SharedRay validates hitObject at delivery, but the cast is async so
    -- delivery was last frame; any access to an invalidated object raises.
    if not obj or not obj:isValid() then return nil end
    if result.distance and result.distance > FREE_RIDE_RANGE then return nil end
    if not isRideable(obj) then return nil end
    return obj
end

local function onFreeRideKey()
    if not FREE_RIDE_ENABLED then return end
    if I.UI and I.UI.isHudVisible and not I.UI.isHudVisible() then return end

    if mountedActive then
        -- Only free-ride sessions are ours to end. A backend-owned ride must
        -- be dismounted through that backend or the two disagree about state.
        if freeRiding then endRide() end
        return
    end

    local target = freeRideTarget()
    if target then beginRide(target, true) end
end

-- ---------------------------------------------------------------------------
-- INPUT
-- ---------------------------------------------------------------------------

local function onKeyPress(key)
    local sym = key and key.symbol
    if not sym then return end

    if sym == FREE_RIDE_KEY then
        onFreeRideKey()
        return
    end

    if not mountedActive then return end

    if sym == "w" then
        heldForward = true
    elseif sym == "s" then
        heldBackward = true
    elseif ALLOW_JUMP and (sym == "space" or sym == " ") then
        startJump()
    end

    refreshLocomotion()
end

local function onKeyRelease(key)
    if not mountedActive then return end
    local sym = key and key.symbol
    if sym == "w" then
        heldForward = false
    elseif sym == "s" then
        heldBackward = false
    end
    refreshLocomotion()
end

-- ---------------------------------------------------------------------------
-- ANIMATION RECOVERY
-- ---------------------------------------------------------------------------
-- A pinned/levitating rider counts as airborne, so the engine's falling
-- animation interrupts the scripted rider pose (Sturdy Steed re-asserts every
-- frame to fix this; an ended-handler does the same job as an event).
--
-- Burst-guarded: a poll is implicitly rate-limited by the frame rate, an
-- ended-handler is not, so a clip that ends immediately would replay in a
-- tight loop.
local REPLAY_BURST_LIMIT  = 5
local REPLAY_BURST_WINDOW = 1.0
local replayCount, replayWindowStart = 0, 0

I.AnimationController.addAnimationEndedHandler(function(groupname)
    if not mountedActive or jumpActive then return end
    if groupname ~= currentGroup then return end

    local now = core.getSimulationTime()
    if now - replayWindowStart > REPLAY_BURST_WINDOW then
        replayWindowStart, replayCount = now, 0
    end
    replayCount = replayCount + 1
    if replayCount > REPLAY_BURST_LIMIT then
        if DEBUG then
            print("[ride] '" .. tostring(currentGroup) ..
                  "' keeps ending immediately; check group name and text keys")
        end
        return
    end

    local state = currentState
    currentState = nil     -- allow playLoop to re-issue
    playLoop(state or locomotionState())
end)

-- ---------------------------------------------------------------------------
-- BACKEND EVENT WIRING
-- ---------------------------------------------------------------------------

local eventHandlers = {}

for _, name in ipairs(BACKEND_EVENTS.mounted) do
    eventHandlers[name] = function(data)
        -- Backends name the mount differently; accept the common spellings and
        -- fall through to nil (which resolves to the fallback set) rather than
        -- refusing to animate a mount we simply could not identify.
        local mount = data and (data.mount or data.horse or data.guar
                                or data.creature or data.target)
        beginRide(mount, false)
    end
end

for _, name in ipairs(BACKEND_EVENTS.dismounted) do
    eventHandlers[name] = function() endRide() end
end

-- ---------------------------------------------------------------------------
-- SAVE / LOAD
-- ---------------------------------------------------------------------------
-- The levitation spell is real actor state and IS written to the save, so a
-- save taken mid-ride would restore a floating player. Record it and undo on
-- load rather than blanket-stripping the spell, which would fight a backend
-- that manages its own.

local function onSave()
    return { levitationAdded = levitationAdded, freeRiding = freeRiding }
end

local function onLoad(data)
    mountedActive = false
    freeRiding    = false
    jumpActive    = false
    heldForward   = false
    heldBackward  = false
    currentMount  = nil
    currentType   = nil
    currentState  = nil
    currentGroup  = nil

    unsubscribeRefresh()
    clearCameraOffset()
    levitationAdded = data and data.levitationAdded == true or false
    removeLevitation()

    -- Backends re-send their mounted event after a load if the player was
    -- actually mounted, which re-enters beginRide above. Free rides do not
    -- survive a load by design: there is no backend to restore the pin.
end

return {
    eventHandlers  = eventHandlers,
    engineHandlers = {
        onKeyPress   = onKeyPress,
        onKeyRelease = onKeyRelease,
        onSave       = onSave,
        onLoad       = onLoad,
    },
}
