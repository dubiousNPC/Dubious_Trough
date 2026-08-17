---@omw-context player
--[[
    ridingAnim.lua -- rider animation controller for WhyWalk

    Zero per-frame handlers. Reacts only to:
      * WhyWalk_AnimMounted / _AnimDismounted from whywalk_player.lua
      * WhyWalk_AnimState from whywalk_global.lua (sent on CHANGE, not per frame)
      * the jump clip's own 'stop' text key
      * addAnimationEndedHandler, for recovery

    Descended from the Devilish ridingAnim.lua, which was already the healthiest
    file in either reference mod -- the two shipped copies (Guar and Horse) were
    byte-identical apart from the rideg/rideh prefix, which is what motivated
    folding them into one table-driven controller.

    Animates the RIDER only, torso bone group only, so weapons, spells and the
    rider's own leg animation keep working while mounted. The MOUNT's gait is
    left to the engine's character controller on purpose (see whywalk_mount.lua).
]]

local self    = require('openmw.self')
local anim    = require('openmw.animation')
local core    = require('openmw.core')
local camera  = require('openmw.camera')
local util    = require('openmw.util')
local storage = require('openmw.storage')
local async   = require('openmw.async')
local I       = require('openmw.interfaces')

local shared = require('scripts.WhyWalk.whywalk_shared')

local STATE = shared.STATE

local DEBUG = false

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

-- ---------------------------------------------------------------------------
-- STATE
-- ---------------------------------------------------------------------------

local mounted      = false
local mountType    = nil
local currentState = nil
local currentGroup = nil
local jumpActive   = false

-- ---------------------------------------------------------------------------
-- PLAYBACK
-- ---------------------------------------------------------------------------

local function playLoop(state)
    if not mounted then return end
    -- Compare STATE, not the resolved group name: with variant lists the name
    -- differs between entries into the same state, so comparing names would
    -- restart the clip on every refresh.
    if currentState == state then return end

    local group = shared.resolveAnim(mountType, state)
    if not group then return end   -- mount has no clip for this state

    I.AnimationController.playBlendedAnimation(group, {
        startKey = "start", stopKey = "stop",
        priority = RIDE_PRIORITY, blendMask = RIDE_BLEND_MASK,
        loops = -1, forceLoop = true, autoDisable = false,
    })
    currentState, currentGroup = state, group
end

local function playOnce(state)
    local group = shared.resolveAnim(mountType, state)
    if not group then return nil end

    I.AnimationController.playBlendedAnimation(group, {
        startKey = "start", stopKey = "stop",
        priority = RIDE_PRIORITY, blendMask = RIDE_BLEND_MASK,
        loops = 0, autoDisable = true,
    })
    currentState, currentGroup = state, group
    return group
end

-- animation.cancel is on the base openmw.animation module, NOT on
-- I.AnimationController, and is only valid on self.
local function stopAnim()
    if not currentGroup then return end
    anim.cancel(self, currentGroup)
    currentGroup, currentState = nil, nil
end

-- ---------------------------------------------------------------------------
-- JUMP
-- ---------------------------------------------------------------------------
-- Text key handlers must bind to a fixed group name at load time, so every
-- jump variant across every mount type is registered once up front. Lazy
-- per-play registration cannot work: the handler must already exist when the
-- clip's stop key fires.

local function onJumpStop()
    if not jumpActive then return end
    jumpActive   = false
    currentState = nil          -- let playLoop re-issue the locomotion pose
    playLoop(STATE.IDLE)
end

for _, group in ipairs(shared.allJumpGroups()) do
    I.AnimationController.addTextKeyHandler(group, function(_, key)
        if key == "stop" then onJumpStop() end
    end)
end



-- ---------------------------------------------------------------------------
-- CAMERA OFFSET
-- ---------------------------------------------------------------------------
-- The player's chosen perspective is honoured -- this never switches the view.
-- Instead each view gets its own offset, because they need different framing
-- and use different APIs:
--
--   first person : camera.setFirstPersonOffset, a 3d vector measured from the
--                  character's head (x right, y forward, z up)
--   third person : camera.setFocalPreferredOffset, a 2d vector from the tracked
--                  position (x right, y up)
--
-- Vertical defaults are 0 in first person and -75 in third: the first person
-- camera already sits at head height so it usually needs nothing, while the
-- third person focal point frames riding from too high without help.
--
-- The built-in camera script manages the third person offset too, so it is
-- told to stand down for the duration via disableThirdPersonOffsetControl. The
-- tag is this mod's name, so it cannot clash with another mod holding its own.

local SETTINGS_PAGE  = "WhyWalk"
local SETTINGS_GROUP = "SettingsWhyWalkCamera"
local CAMERA_TAG     = "WhyWalk"

I.Settings.registerPage {
    key         = SETTINGS_PAGE,
    l10n        = "none",
    name        = "WhyWalk",
    description = "Camera framing while riding.",
}

I.Settings.registerGroup {
    key              = SETTINGS_GROUP,
    page             = SETTINGS_PAGE,
    l10n             = "none",
    name             = "Camera offset",
    description      = "Adjusts the camera while riding. Each perspective is"
                    .. " offset separately; neither changes which view you are in.",
    permanentStorage = true,
    order            = 0,
    settings = {
        {
            key         = "CAMERA_OFFSET_ENABLED",
            name        = "Adjust camera",
            description = "Turn off to leave the camera exactly as it is normally.",
            renderer    = "checkbox",
            default     = true,
        },
        {
            key         = "FP_OFFSET_V",
            name        = "First person: vertical offset",
            description = "Negative lowers the view.\n\nDefault is 0.",
            renderer    = "number",
            integer     = true,
            default     = 0,
            argument    = { min = -400, max = 400 },
        },
        {
            key         = "FP_OFFSET_H",
            name        = "First person: horizontal offset",
            description = "Positive shifts right, negative left.\n\nDefault is 0.",
            renderer    = "number",
            integer     = true,
            default     = 0,
            argument    = { min = -400, max = 400 },
        },
        {
            key         = "TP_OFFSET_V",
            name        = "Third person: vertical offset",
            description = "Negative lowers the view.\n\nDefault is -75.",
            renderer    = "number",
            integer     = true,
            default     = -75,
            argument    = { min = -400, max = 400 },
        },
        {
            key         = "TP_OFFSET_H",
            name        = "Third person: horizontal offset",
            description = "Positive shifts right, negative left.\n\nDefault is 0.",
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
    camera.setFirstPersonOffset(util.vector3(0, 0, 0))
    camera.setFocalPreferredOffset(util.vector2(0, 0))
    if I.Camera and I.Camera.enableThirdPersonOffsetControl then
        I.Camera.enableThirdPersonOffsetControl(CAMERA_TAG)
    end
    cameraOffsetHeld = false
end

local function applyCameraOffset()
    if not mounted or not cameraSettings:get("CAMERA_OFFSET_ENABLED") then
        clearCameraOffset()
        return
    end

    if not cameraOffsetHeld then
        if I.Camera and I.Camera.disableThirdPersonOffsetControl then
            I.Camera.disableThirdPersonOffsetControl(CAMERA_TAG)
        end
        cameraOffsetHeld = true
    end

    -- Only the active view is offset and the other is zeroed, so a stale value
    -- cannot survive a perspective change. Vanity and preview modes are
    -- third-person-shaped, so anything that is not FirstPerson takes the third
    -- person offset.
    if camera.getMode() == camera.MODE.FirstPerson then
        camera.setFirstPersonOffset(util.vector3(
            cameraSettings:get("FP_OFFSET_H") or 0,
            0,
            cameraSettings:get("FP_OFFSET_V") or 0))
        camera.setFocalPreferredOffset(util.vector2(0, 0))
    else
        camera.setFocalPreferredOffset(util.vector2(
            cameraSettings:get("TP_OFFSET_H") or 0,
            cameraSettings:get("TP_OFFSET_V") or -75))
        camera.setFirstPersonOffset(util.vector3(0, 0, 0))
    end
end

-- Live update: changing a value in the settings menu applies immediately
-- instead of waiting for the next riding session.
cameraSettings:subscribe(async:callback(function()
    applyCameraOffset()
end))

-- ---------------------------------------------------------------------------
-- PERSPECTIVE CHANGE
-- ---------------------------------------------------------------------------
-- Switching perspective rebuilds the player's animation object and drops
-- scripted animations with it. The reference riding mods avoid this by pinning
-- the camera to first person; that is not acceptable here, since the whole
-- point of a rider animation is being able to look at it.
--
-- I.AnimRefresh notifies after the switch has settled (it defers past the
-- skeleton rebuild). Clearing currentState is what makes playLoop re-issue --
-- it early-outs on an unchanged state, so without this the re-assert is a
-- no-op.
local function onPerspectiveChanged()
    -- Runs even when unmounted so a lingering offset is released if the ride
    -- ended while the notification was still settling.
    applyCameraOffset()
    if not mounted then return end
    local state = currentState or STATE.IDLE
    currentState = nil
    if jumpActive then
        -- A one-shot jump clip cannot be resumed part-way; drop back to
        -- locomotion rather than replaying the whole hop mid-air.
        jumpActive = false
        state = STATE.IDLE
    end
    playLoop(state)
end

local function subscribeRefresh()
    if I.AnimRefresh and I.AnimRefresh.subscribe then
        I.AnimRefresh.subscribe("WhyWalk", onPerspectiveChanged)
    end
end

local function unsubscribeRefresh()
    if I.AnimRefresh and I.AnimRefresh.unsubscribe then
        I.AnimRefresh.unsubscribe("WhyWalk")
    end
end

-- ---------------------------------------------------------------------------
-- EVENTS
-- ---------------------------------------------------------------------------

local function onAnimMounted(data)
    mounted      = true
    mountType    = data and data.mountType or nil
    jumpActive   = false
    currentState = nil
    currentGroup = nil

    if DEBUG then
        print("[WhyWalk] anim mounted, type=" .. tostring(mountType))
    end
    subscribeRefresh()
    applyCameraOffset()
    playLoop(STATE.IDLE)
end

local function onAnimDismounted()
    mounted    = false
    mountType  = nil
    jumpActive = false
    -- Unsubscribing is what keeps AnimRefresh free when nobody is riding: with
    -- no subscribers its onUpdate is a single count check.
    unsubscribeRefresh()
    clearCameraOffset()
    stopAnim()
end

local function onAnimState(data)
    if not mounted then return end
    local state = data and data.state
    if not state then return end

    if state == STATE.JUMP then
        if jumpActive then return end
        local group = shared.resolveAnim(mountType, STATE.JUMP)
        if not group then return end     -- flyers, or no jump clip
        jumpActive = true
        playOnce(STATE.JUMP)
        return
    end

    if jumpActive then return end        -- jump owns the pose until its stop key
    playLoop(state)
end

-- ---------------------------------------------------------------------------
-- RECOVERY
-- ---------------------------------------------------------------------------
-- A pinned/levitating rider counts as airborne, so the engine's falling
-- animation interrupts the scripted pose. Sturdy Steed re-asserts every frame
-- to fix this; an ended-handler does the same job as an event.
--
-- Burst-guarded: a poll is implicitly rate-limited by the frame rate, an
-- ended-handler is not, so a clip that ends immediately (bad group name,
-- missing text keys) would otherwise replay in a tight loop.
local REPLAY_BURST_LIMIT  = 5
local REPLAY_BURST_WINDOW = 1.0
local replayCount, replayWindowStart = 0, 0

I.AnimationController.addAnimationEndedHandler(function(groupname)
    if not mounted or jumpActive then return end
    if groupname ~= currentGroup then return end

    local now = core.getSimulationTime()
    if now - replayWindowStart > REPLAY_BURST_WINDOW then
        replayWindowStart, replayCount = now, 0
    end
    replayCount = replayCount + 1
    if replayCount > REPLAY_BURST_LIMIT then
        if DEBUG then
            print("[WhyWalk] '" .. tostring(currentGroup) ..
                  "' keeps ending immediately; check group name and text keys")
        end
        return
    end

    local state = currentState
    currentState = nil
    playLoop(state or STATE.IDLE)
end)

-- ---------------------------------------------------------------------------
-- SAVE / LOAD
-- ---------------------------------------------------------------------------

local function onLoad()
    mounted, mountType = false, nil
    jumpActive = false
    currentState, currentGroup = nil, nil
    unsubscribeRefresh()
    clearCameraOffset()
    -- whywalk_global re-sends WhyWalk_Mounted after a load if the ride was
    -- active, which reaches whywalk_player and lands back here.
end

return {
    eventHandlers = {
        WhyWalk_AnimMounted    = onAnimMounted,
        WhyWalk_AnimDismounted = onAnimDismounted,
        WhyWalk_AnimState      = onAnimState,
    },
    engineHandlers = {
        onLoad = onLoad,
    },
}
