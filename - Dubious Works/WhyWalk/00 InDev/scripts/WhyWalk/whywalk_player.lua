---@omw-context player
--[[
    whywalk_player.lua -- input, targeting, rider state

    ZERO per-frame handlers. Both reference implementations (Devilish and
    Sturdy Steed) run three: player onFrame + mount onUpdate + global onUpdate.
    The player-side one exists in both purely to poll held movement keys and
    re-send the same control values every frame.

    That poll is avoidable. Held state is tracked from onKeyPress/onKeyRelease
    and a control event is sent only when the intent actually CHANGES -- which
    for a rider is a handful of events per journey, not 60/sec. The global
    script integrates movement from the last-known intent.

    What is NOT avoidable is the rider pin itself: nothing in the OpenMW Lua
    API parents one object's transform to another, so something has to place
    the rider every frame. That lives in whywalk_global.lua behind a single
    early-out, and is the only per-frame cost in the whole mod.

    WHEN NOT MOUNTED THIS FILE COSTS: nothing. No handler runs until a key is
    pressed or the activate trigger fires.
]]

local self   = require('openmw.self')
local core   = require('openmw.core')
local camera = require('openmw.camera')
local input  = require('openmw.input')
local types  = require('openmw.types')
local async  = require('openmw.async')
local I      = require('openmw.interfaces')

local shared = require('scripts.WhyWalk.whywalk_shared')

local TUNING = shared.TUNING

local EV = {
    REQUEST_MOUNT   = 'WhyWalk_RequestMount',
    REQUEST_DISMOUNT= 'WhyWalk_RequestDismount',
    CONTROL         = 'WhyWalk_Control',
    PERSPECTIVE     = 'WhyWalk_Perspective',
    MOUNTED         = 'WhyWalk_Mounted',
    DISMOUNTED      = 'WhyWalk_Dismounted',
}

local DEBUG = false

-- ---------------------------------------------------------------------------
-- STATE
-- ---------------------------------------------------------------------------

local mounted        = false
local freeRiding     = false
local mountType      = nil
local controlsLocked = false
local levitationAdded = false

local held = { forward = false, back = false, left = false, right = false,
               gallop = false }
local lastSent = nil

-- ---------------------------------------------------------------------------
-- CONTROL LOCK
-- ---------------------------------------------------------------------------
-- One-shot, not per-frame writes to self.controls.
--
-- I.Controls.overrideMovementControls rather than CONTROL_SWITCH.Controls: the
-- control-switch route ALSO disables third-person camera zoom (it is routed
-- through the built-in camera script), which is unacceptable on a mod whose
-- point is watching the rider. Sturdy Steed documents this in two places.
--
-- One call replaces two: overrideMovementControls suppresses jump and sneak
-- along with movement, so the separate Jumping switch is redundant.
--
-- Still recorded in the save and undone on load. The override lives in the
-- built-in playercontrols script rather than in engine actor state, but a
-- half-restored lock is bad enough that the handshake is worth keeping either
-- way.

local function lockControls()
    if controlsLocked then return end
    I.Controls.overrideMovementControls(true)
    controlsLocked = true
end

local function releaseControls()
    if not controlsLocked then return end
    I.Controls.overrideMovementControls(false)
    controlsLocked = false
end

-- ---------------------------------------------------------------------------
-- LEVITATION
-- ---------------------------------------------------------------------------
-- Suppresses rider gravity so it stops dragging the rider down between pin
-- updates -- the artefact both reference mods work around. It does not move
-- anything; the pin still does the moving.
--
-- Applied by modifying the Levitate effect magnitude directly rather than by
-- adding a spell. The spell route needed a record in the ESP, which meant a
-- placeholder id that could not resolve, which in turn meant wrapping both
-- add and remove in pcall to absorb the guaranteed failure -- a pcall standing
-- in for a missing asset. p37z demonstrates the record-free form; this is that
-- technique. Cod3x types activeEffects(actor) as taking an openmw.Object and
-- documents modify(value, effectId) as a permanent magnitude change, so it is
-- legal on self from a player script.
--
-- Symmetric by construction: +1 on mount, -1 on dismount, gated by the
-- levitationAdded flag so the pair can never drift out of balance and leave a
-- permanently levitating player.

local function addLevitation()
    if not TUNING.useLevitation or levitationAdded then return end
    types.Actor.activeEffects(self):modify(1, core.magic.EFFECT_TYPE.Levitate)
    levitationAdded = true
end

local function removeLevitation()
    if not levitationAdded then return end
    types.Actor.activeEffects(self):modify(-1, core.magic.EFFECT_TYPE.Levitate)
    levitationAdded = false
end

-- ---------------------------------------------------------------------------
-- CONTROL INTENT
-- ---------------------------------------------------------------------------
-- Sent only on change. A rider holding W across a valley generates one event,
-- not one per frame.

local function intentKey(throttle, steer, gallop)
    return tostring(throttle) .. ":" .. tostring(steer) .. ":" .. tostring(gallop)
end

local function sendControl(force)
    if not mounted or freeRiding then return end

    local throttle = 0
    if held.forward and not held.back then throttle = 1
    elseif held.back and not held.forward then throttle = -1 end

    local steer = 0
    if held.left and not held.right then steer = -1
    elseif held.right and not held.left then steer = 1 end

    local key = intentKey(throttle, steer, held.gallop)
    if not force and key == lastSent then return end
    lastSent = key

    core.sendGlobalEvent(EV.CONTROL, {
        player   = self.object,
        throttle = throttle,
        steer    = steer,
        gallop   = held.gallop,
    })
end

-- ---------------------------------------------------------------------------
-- PERSPECTIVE REPORTING
-- ---------------------------------------------------------------------------
-- The global script pins the rider and needs to know which view is active,
-- because the rider's BODY yaw is only forced to the mount in third person.
-- In first person the body yaw IS the look direction, so overwriting it every
-- frame would fight mouse-look. Camera state is player-context only, hence
-- this relay.
--
-- Sent on change, not per frame: AnimRefresh already detects perspective
-- changes for the animation layer, so this rides on the same notification
-- rather than adding a poll of its own.

local lastFirstPerson = nil

local function sendPerspective(force)
    if not mounted then return end
    local fp = camera.getMode() == camera.MODE.FirstPerson
    if not force and fp == lastFirstPerson then return end
    lastFirstPerson = fp
    core.sendGlobalEvent(EV.PERSPECTIVE, { player = self.object, firstPerson = fp })
end

local function subscribePerspective()
    if I.AnimRefresh and I.AnimRefresh.subscribe then
        I.AnimRefresh.subscribe("WhyWalkPerspective", function() sendPerspective(false) end)
    end
end

local function unsubscribePerspective()
    if I.AnimRefresh and I.AnimRefresh.unsubscribe then
        I.AnimRefresh.unsubscribe("WhyWalkPerspective")
    end
end

-- ---------------------------------------------------------------------------
-- TARGETING
-- ---------------------------------------------------------------------------
-- Reading SharedRay issues no cast: the service already casts once per frame
-- for whoever listens. requestDistance only raises the shared ray length.

if I.SharedRay and I.SharedRay.requestDistance then
    I.SharedRay.requestDistance(TUNING.freeRideRange)
end

local function findMountTarget()
    if not (I.SharedRay and I.SharedRay.get) then return nil end
    local result = I.SharedRay.get()
    if not result or not result.hit then return nil end

    local obj = result.hitObject
    -- SharedRay validates hitObject at delivery, but the cast is async so
    -- delivery was last frame; any access to an invalidated object raises.
    if not obj or not obj:isValid() then return nil end
    if result.distance and result.distance > TUNING.freeRideRange then return nil end
    if not types.Creature.objectIsInstance(obj) then return nil end
    if shared.isBlacklisted(obj.recordId) then return nil end

    local mt = shared.getMountType(obj.recordId)
    if mt then return obj, mt, false end
    if TUNING.freeRideEnabled then return obj, nil, true end
    return nil
end

-- ---------------------------------------------------------------------------
-- MOUNT LIFECYCLE (driven by the global script's confirmation)
-- ---------------------------------------------------------------------------

local function onMounted(data)
    mounted    = true
    freeRiding = data and data.freeRide == true
    mountType  = data and data.mountType or nil

    held.forward, held.back = false, false
    held.left, held.right   = false, false
    held.gallop             = false
    lastSent = nil

    lockControls()
    addLevitation()
    subscribePerspective()
    lastFirstPerson = nil
    sendPerspective(true)

    -- Hand off to the animation controller, which is a separate player script
    -- on the same object and needs no reference to this one.
    self.object:sendEvent('WhyWalk_AnimMounted', {
        mount = data and data.mount, mountType = mountType, freeRide = freeRiding,
    })

    if not freeRiding then sendControl(true) end
end

local function onDismounted()
    mounted, freeRiding, mountType = false, false, nil
    held.forward, held.back = false, false
    held.left, held.right   = false, false
    held.gallop             = false
    lastSent = nil

    releaseControls()
    removeLevitation()
    unsubscribePerspective()
    lastFirstPerson = nil
    self.object:sendEvent('WhyWalk_AnimDismounted', {})
end

-- ---------------------------------------------------------------------------
-- INPUT
-- ---------------------------------------------------------------------------

local function requestMount()
    if I.UI and I.UI.isHudVisible and not I.UI.isHudVisible() then return end

    if mounted then
        core.sendGlobalEvent(EV.REQUEST_DISMOUNT, { player = self.object })
        return
    end

    local target, mt, free = findMountTarget()
    if not target then return end

    core.sendGlobalEvent(EV.REQUEST_MOUNT, {
        player = self.object, mount = target, mountType = mt, freeRide = free,
    })
end

input.registerTriggerHandler("Activate", async:callback(requestMount))

local KEYMAP = {
    w = "forward", s = "back", a = "left", d = "right",
}

local function onKeyPress(key)
    if not mounted then return end
    local sym = key and key.symbol
    if not sym then return end

    local slot = KEYMAP[sym]
    if slot then
        held[slot] = true
    elseif sym == "x" then
        core.sendGlobalEvent(EV.REQUEST_DISMOUNT, { player = self.object })
        return
    elseif sym == "space" or sym == " " then
        core.sendGlobalEvent(EV.CONTROL, { player = self.object, jump = true })
        return
    else
        -- Shift has no portable symbol, so gallop is read fresh on any key
        -- event rather than matched by name. Re-read below covers it.
    end

    held.gallop = input.isShiftPressed()
    sendControl(false)
end

local function onKeyRelease(key)
    if not mounted then return end
    local sym = key and key.symbol
    if not sym then return end

    local slot = KEYMAP[sym]
    if slot then held[slot] = false end

    held.gallop = input.isShiftPressed()
    sendControl(false)
end

-- ---------------------------------------------------------------------------
-- SAVE / LOAD
-- ---------------------------------------------------------------------------

local function onSave()
    return { controlsLocked = controlsLocked, levitationAdded = levitationAdded }
end

local function onLoad(data)
    mounted, freeRiding, mountType = false, false, nil
    lastSent = nil
    held.forward, held.back = false, false
    held.left, held.right   = false, false
    held.gallop             = false

    -- Undo only what we recorded holding, rather than blanket-clearing: a
    -- blanket clear would stomp a lock another mod legitimately holds.
    unsubscribePerspective()
    lastFirstPerson = nil
    controlsLocked  = data and data.controlsLocked == true or false
    levitationAdded = data and data.levitationAdded == true or false
    releaseControls()
    removeLevitation()

    -- The global script re-sends WhyWalk_Mounted after a load if the ride was
    -- still active, which re-enters onMounted above.
end

return {
    eventHandlers = {
        [EV.MOUNTED]    = onMounted,
        [EV.DISMOUNTED] = onDismounted,
    },
    engineHandlers = {
        onKeyPress   = onKeyPress,
        onKeyRelease = onKeyRelease,
        onSave       = onSave,
        onLoad       = onLoad,
    },
}
