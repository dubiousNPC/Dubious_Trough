---@omw-context player
--[[
    ridingAnim.lua -- rider animation controller for WhyWalk

    Zero per-frame handlers. Reacts only to:
      * WhyWalk_AnimMounted / _AnimDismounted from whywalk_player.lua
      * WhyWalk_AnimState from whywalk_global.lua (sent on CHANGE, not per frame)
      * one-shot completion, via the clip's own ended handler OR a timeout
      * addAnimationEndedHandler, for recovery from engine interruption
      * I.AnimRefresh, for perspective changes
      * WhyWalk_AnimVesselStart / _AnimVesselHelm / _AnimVesselStop from the
        Boats module: the pilot's pose aboard (see VESSEL POSE)

    Animates the RIDER only. The MOUNT's gait belongs to the engine's character
    controller on purpose.

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

local function hasGroup(group) return anim.hasGroup(self, group) end

local STATE = shared.STATE

local DEBUG = false

local ONE_SHOT_TIMEOUT = 1.5

local MOUNT_SETTLE = 0.05

local RIDE_PRIORITY = {
    [anim.BONE_GROUP.LowerBody] = anim.PRIORITY.Scripted,
    [anim.BONE_GROUP.Torso]     = anim.PRIORITY.Weapon,
    [anim.BONE_GROUP.LeftArm]   = anim.PRIORITY.Weapon,
    [anim.BONE_GROUP.RightArm]  = anim.PRIORITY.Weapon,
}
local RIDE_BLEND_MASK = anim.BLEND_MASK.LowerBody + anim.BLEND_MASK.Torso

local LOOPS = 999999

-- ---------------------------------------------------------------------------
-- STATE
-- ---------------------------------------------------------------------------

local mounted      = false
local mountType    = nil
local currentState = nil
local currentGroup = nil

local lastLocomotion = STATE.IDLE

local oneShotActive = false

local reissueTotal, rideStartedAt = 0, 0

local replayDisabled = false

-- ---------------------------------------------------------------------------
-- PLAYBACK
-- ---------------------------------------------------------------------------

local function playLoop(state)
    if not mounted then return end
    if currentState == state then return end

    local group = shared.resolveAnim(mountType, state, nil, hasGroup)
    if not group then return end   -- mount has no clip for this state

    I.AnimationController.playBlendedAnimation(group, {
        startKey = "start", stopKey = "stop",
        priority = RIDE_PRIORITY, blendMask = RIDE_BLEND_MASK,
        loops = LOOPS, forceLoop = true, autoDisable = false,
    })
    currentState, currentGroup = state, group
end

local pendingOneShot = nil

local function finishOneShot(group)
    local p = pendingOneShot
    if not p then return end
    if group and p.group ~= group then return end
    pendingOneShot = nil
    p.done()
end

for _, group in ipairs(shared.allJumpGroups()) do
    I.AnimationController.addTextKeyHandler(group, function(groupname, key)
        if key == "stop" then finishOneShot(groupname) end
    end)
end

-- One ended-handler covering every one-shot group, rather than one per group.
I.AnimationController.addAnimationEndedHandler(function(groupname)
    finishOneShot(groupname)
end)

local function playOneShot(state, done)
    local group = shared.resolveAnim(mountType, state, nil, hasGroup)
    if not group then return done() end   -- no clip for this state: proceed

    pendingOneShot = { group = group, done = done }

    I.AnimationController.playBlendedAnimation(group, {
        startKey = "start", stopKey = "stop",
        priority = RIDE_PRIORITY, blendMask = RIDE_BLEND_MASK,
        loops = 0, autoDisable = true,
    })
    currentState, currentGroup = state, group

    local mine = pendingOneShot
    async:newUnsavableSimulationTimer(ONE_SHOT_TIMEOUT, function()
        if pendingOneShot ~= mine then return end
        finishOneShot(nil)
    end)
end

local function cancelOneShot()
    pendingOneShot = nil
    oneShotActive  = false
end

local function stopAnim()
    if not currentGroup then return end
    anim.cancel(self, currentGroup)
    currentGroup, currentState = nil, nil
end

local function resumeLocomotion()
    oneShotActive = false
    currentState = nil
    playLoop(lastLocomotion)
end

-- ---------------------------------------------------------------------------
-- VESSEL POSE
-- ---------------------------------------------------------------------------

local VESSEL_LAYER = shared.buildVesselLayer(anim)
local VESSEL_TUNING = shared.VESSEL_TUNING

local aboard = nil              -- stance name while piloting
local vesselGroup = nil         -- the group actually playing
local helmTurn, helmThrottle = 0, 0
local helmFast = true
local vesselSwitchedAt = 0
local vesselGeneration = 0      -- invalidates a pending deferred switch
local vesselReported = {}

local function vesselKeys(group)
    local candidates = shared.VESSEL_KEY_CANDIDATES
    for _, c in ipairs(candidates) do
        if anim.getTextKeyTime(self, group .. ": " .. c.start)
            and anim.getTextKeyTime(self, group .. ": " .. c.stop) then
            return c
        end
    end
    return candidates[#candidates]
end

local function playVessel(force)
    if not aboard then return end
    local stance = shared.VESSEL_STANCE[aboard] or shared.VESSEL_STANCE.stand
    local field = shared.vesselField(stance, helmTurn, helmThrottle, helmFast)
    local group = shared.resolveVesselGroup(aboard, field, hasGroup)
    if not group then
        if not vesselReported[aboard] then
            vesselReported[aboard] = true
            print("[WhyWalk] vessel stance '" .. tostring(aboard) .. "' resolves to no group on this"
                  .. " skeleton, not even 'idle'. The pilot will walk on the spot.")
        end
        return
    end
    if group == vesselGroup and not force then return end

    -- Bookkeeping, play, then release the outgoing loop (RESEARCH Part 5 #13).
    local previous = vesselGroup
    local keys = vesselKeys(group)
    vesselGroup, vesselSwitchedAt = group, core.getSimulationTime()
    I.AnimationController.playBlendedAnimation(group, {
        startKey = keys.start, stopKey = keys.stop,
        priority = VESSEL_LAYER.priority, blendMask = VESSEL_LAYER.blendMask,
        loops = LOOPS, forceLoop = true, autoDisable = false,
    })
    if previous and previous ~= group then anim.cancel(self, previous) end
    if DEBUG then print("[WhyWalk] vessel pose " .. group .. " (" .. field .. ")") end
end

local function requestVesselSwitch()
    local wait = VESSEL_TUNING.minPoseTime - (core.getSimulationTime() - vesselSwitchedAt)
    if wait <= 0 or not vesselGroup then return playVessel(false) end
    vesselGeneration = vesselGeneration + 1
    local mine = vesselGeneration
    async:newUnsavableSimulationTimer(wait, function()
        if mine ~= vesselGeneration or not aboard then return end
        playVessel(false)
    end)
end

local function stopVessel()
    vesselGeneration = vesselGeneration + 1
    if vesselGroup then anim.cancel(self, vesselGroup) end
    aboard, vesselGroup = nil, nil
    helmTurn, helmThrottle = 0, 0
    helmFast = true
end

-- ---------------------------------------------------------------------------
-- CAMERA OFFSET
-- ---------------------------------------------------------------------------

local L10N_CONTEXT   = "WhyWalk"
local SETTINGS_PAGE  = "WhyWalk"
local SETTINGS_GROUP = "SettingsWhyWalkCamera"
local CAMERA_TAG     = "WhyWalk"

I.Settings.registerGroup {
    key              = SETTINGS_GROUP,
    page             = SETTINGS_PAGE,
    l10n             = L10N_CONTEXT,
    name             = "camera_group_name",
    description      = "camera_group_description",
    permanentStorage = true,
    order            = 0,
    settings = {
        {
            key         = "CAMERA_OFFSET_ENABLED",
            name        = "camera_enabled_name",
            description = "camera_enabled_description",
            renderer    = "checkbox",
            default     = true,
        },
        {
            key         = "FP_OFFSET_V",
            name        = "camera_fp_v_name",
            description = "camera_fp_v_description",
            renderer    = "number",
            integer     = true,
            default     = 0,
            argument    = { min = -400, max = 400 },
        },
        {
            key         = "FP_OFFSET_H",
            name        = "camera_fp_h_name",
            description = "camera_fp_h_description",
            renderer    = "number",
            integer     = true,
            default     = 0,
            argument    = { min = -400, max = 400 },
        },
        {
            key         = "TP_OFFSET_V",
            name        = "camera_tp_v_name",
            description = "camera_tp_v_description",
            renderer    = "number",
            integer     = true,
            default     = -75,
            argument    = { min = -400, max = 400 },
        },
        {
            key         = "TP_OFFSET_H",
            name        = "camera_tp_h_name",
            description = "camera_tp_h_description",
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

cameraSettings:subscribe(async:callback(function()
    applyCameraOffset()
end))

-- ---------------------------------------------------------------------------
-- PERSPECTIVE CHANGE
-- ---------------------------------------------------------------------------
local function onPerspectiveChanged()
    applyCameraOffset()
    if aboard then
        playVessel(true)
        if vesselGroup and not anim.isPlaying(self, vesselGroup) then return false end
        return
    end
    if not mounted then return end

    cancelOneShot()
    currentState = nil
    playLoop(lastLocomotion)

    if currentGroup and not anim.isPlaying(self, currentGroup) then
        currentState = nil
        return false
    end
end

local function subscribeRefresh()
    if I.AnimRefresh and I.AnimRefresh.subscribe then
        I.AnimRefresh.subscribe("WhyWalk", onPerspectiveChanged, { verify = true })
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
    if aboard then stopVessel() end
    mounted        = true
    mountType      = data and data.mountType or nil
    cancelOneShot()
    replayDisabled = false
    reissueTotal, rideStartedAt = 0, core.getSimulationTime()
    currentState   = nil
    currentGroup   = nil
    lastLocomotion = STATE.IDLE

    if DEBUG then
        print("[WhyWalk] anim mounted, type=" .. tostring(mountType))
    end
    subscribeRefresh()
    applyCameraOffset()

    async:newUnsavableSimulationTimer(MOUNT_SETTLE, function()
        if not mounted then return end
        playLoop(STATE.IDLE)
    end)
end

local function onAnimDismounted()
    if mounted and reissueTotal > 0 then
        local secs = math.max(0.001, core.getSimulationTime() - rideStartedAt)
        local rate = reissueTotal / secs
        if rate >= 1.0 then
            print(string.format(
                "[WhyWalk] rider pose was re-issued %d times in %.1fs (%.1f/s)."
                .. " Each one is a visible flicker: the engine is interrupting"
                .. " the pose, most likely the fall/levitate animation on a"
                .. " pinned rider. Try turning useLevitation off in"
                .. " whywalk_shared.lua to confirm.",
                reissueTotal, secs, rate))
        end
    end

    mounted       = false
    mountType     = nil
    cancelOneShot()
    if not aboard then unsubscribeRefresh() end
    clearCameraOffset()
    stopAnim()
end

local function onAnimState(data)
    if not mounted then return end
    local state = data and data.state
    if not state then return end

    if state == STATE.JUMP then
        if oneShotActive then return end
        oneShotActive = true
        playOneShot(STATE.JUMP, resumeLocomotion)
        return
    end

    lastLocomotion = state

    if oneShotActive then return end   -- the one-shot owns the pose until it ends
    playLoop(state)
end

-- ---------------------------------------------------------------------------
-- VESSEL EVENTS (sent by WhyWalk Boats' boats_player.lua)
-- ---------------------------------------------------------------------------

local function sign(x)
    x = tonumber(x) or 0
    if x > 0 then return 1 elseif x < 0 then return -1 end
    return 0
end

local function onAnimVesselStart(data)
    if mounted then return end
    stopVessel()
    aboard = data and data.stance or "stand"
    replayDisabled = false
    subscribeRefresh()
    -- Boarding teleports the pilot; pose after it lands (MOUNT_SETTLE).
    local mine = vesselGeneration
    async:newUnsavableSimulationTimer(MOUNT_SETTLE, function()
        if mine ~= vesselGeneration or not aboard then return end
        playVessel(true)
    end)
end

local function onAnimVesselHelm(data)
    if not aboard then return end
    local turn, throttle = sign(data and data.turn), sign(data and data.throttle)
    local fast = not (data and data.fast == false)
    if turn == helmTurn and throttle == helmThrottle and fast == helmFast then return end
    helmTurn, helmThrottle, helmFast = turn, throttle, fast
    requestVesselSwitch()
end

local function onAnimVesselStop()
    if not aboard then return end
    stopVessel()
    if not mounted then unsubscribeRefresh() end
end

-- ---------------------------------------------------------------------------
-- RECOVERY
-- ---------------------------------------------------------------------------
local REPLAY_BURST_LIMIT  = 5
local REPLAY_BURST_WINDOW = 1.0
local replayCount, replayWindowStart = 0, 0

local function burstAllows(group)
    local now = core.getSimulationTime()
    if now - replayWindowStart > REPLAY_BURST_WINDOW then
        replayWindowStart, replayCount = now, 0
    end
    replayCount = replayCount + 1
    if replayCount <= REPLAY_BURST_LIMIT then return true end
    print("[WhyWalk] '" .. tostring(group) .. "' keeps ending immediately; check the group name and its"
          .. " text keys. Pose disabled until the next mount or boarding.")
    replayDisabled = true
    return false
end

I.AnimationController.addAnimationEndedHandler(function(groupname)
    if aboard and not replayDisabled and groupname == vesselGroup then
        if burstAllows(groupname) then playVessel(true) end
        return
    end
    if not mounted or oneShotActive or replayDisabled then return end
    if groupname ~= currentGroup then return end

    local now = core.getSimulationTime()
    if now - replayWindowStart > REPLAY_BURST_WINDOW then
        replayWindowStart, replayCount = now, 0
    end
    replayCount = replayCount + 1
    if replayCount > REPLAY_BURST_LIMIT then
        print("[WhyWalk] '" .. tostring(currentGroup) ..
              "' keeps ending immediately; check the group name and its"
              .. " start/stop text keys. Rider pose disabled for this ride.")
        replayDisabled = true
        return
    end

    reissueTotal = reissueTotal + 1
    local state = currentState or lastLocomotion
    currentState = nil
    playLoop(state)
end)

-- ---------------------------------------------------------------------------
-- SAVE / LOAD
-- ---------------------------------------------------------------------------

local function onSave()
    return { group = currentGroup, vessel = vesselGroup }
end

local function onLoad(data)
    if data and data.group then anim.cancel(self, data.group) end
    if data and data.vessel then anim.cancel(self, data.vessel) end
    aboard, vesselGroup, helmTurn, helmThrottle = nil, nil, 0, 0
    vesselGeneration = vesselGeneration + 1
    mounted, mountType = false, nil
    cancelOneShot()
    replayDisabled = false
    currentState, currentGroup = nil, nil
    lastLocomotion = STATE.IDLE
    unsubscribeRefresh()
    clearCameraOffset()
end

return {
    eventHandlers = {
        WhyWalk_AnimMounted    = onAnimMounted,
        WhyWalk_AnimDismounted = onAnimDismounted,
        WhyWalk_AnimState      = onAnimState,
        WhyWalk_AnimVesselStart = onAnimVesselStart,
        WhyWalk_AnimVesselHelm  = onAnimVesselHelm,
        WhyWalk_AnimVesselStop  = onAnimVesselStop,
    },
    engineHandlers = {
        onSave = onSave,
        onLoad = onLoad,
    },
}
