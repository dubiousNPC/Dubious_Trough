---@omw-context player
--[[
    ridingAnim.lua -- rider animation controller for WhyWalk

    Zero per-frame handlers. Reacts only to:
      * WhyWalk_AnimMounted / _AnimDismounted from whywalk_player.lua
      * WhyWalk_AnimState from whywalk_global.lua (sent on CHANGE, not per frame)
      * one-shot completion, via the clip's own ended handler OR a timeout
      * addAnimationEndedHandler, for recovery from engine interruption
      * I.AnimRefresh, for perspective changes

    Animates the RIDER only. The MOUNT's gait belongs to the engine's character
    controller on purpose.

    WHAT CHANGED IN THIS REVISION, and why each mattered:

    1. LOCOMOTION STATE SURVIVES A JUMP. Previously the jump's stop key called
       playLoop(IDLE) unconditionally, and the pre-jump state was already gone
       because playOnce had overwritten currentState. Combined with global
       sending state only on CHANGE and this file discarding state events while
       jumpActive, a gallop -> jump -> land sequence could leave the rider
       galloping in an idle pose indefinitely: the landing event arrived while
       jumpActive was still true and was dropped, then the stop key forced IDLE,
       and global never resent because its lastRiderState already said GALLOP.
       `lastLocomotion` is now tracked separately and is what a jump returns to.

    2. ONE-SHOTS CANNOT HANG. A group the skeleton does not define is a silent
       no-op: playBlended neither errors nor fires the ended handler. The old
       jump path waited solely on a 'stop' text key, so a missing or mis-keyed
       jump clip left jumpActive true forever and every subsequent state event
       was discarded -- the rider froze in whatever pose preceded the jump.
       Every one-shot now runs through playOneShot(), which guarantees its
       completion callback via a timeout backstop. Technique taken from Take a
       Seat's playOneShot, including the `finished` latch that stops the ended
       handler and the timeout from both firing.

    3. THE ANIMREFRESH RETRY IS ACTUALLY USED. v3 asks a subscriber to return
       false when the model was not ready so it can deliver again. The old
       callback returned nothing, so it always counted as delivered and the
       retry never engaged -- the exact failure the retry exists to fix.

    4. THE BURST GUARD REPORTS. Its message was behind `if DEBUG`, which is
       false in shipping config, so a bad group name produced no pose and no
       explanation. A tripped burst guard is always a real fault, never trace
       noise, so it prints unconditionally and then stops retrying until the
       next mount rather than re-arming every second.
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

-- Tracing only. Anything that indicates a FAULT prints regardless of this.
local DEBUG = false

-- Longest a one-shot may hold the pose before the controller moves on. Long
-- enough for a real clip, short enough that an unshipped group name is a blink
-- rather than a rider frozen for the rest of the ride.
local ONE_SHOT_TIMEOUT = 1.5

-- Teleports land next frame, so the mount pin has not placed the rider yet at
-- the instant the mounted event arrives. Playing the pose into the old
-- position is what produces the "pose starts, then the rider snaps" hitch.
local MOUNT_SETTLE = 0.05

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

-- The locomotion state the rider should return to once a one-shot ends. Kept
-- separate from currentState precisely because a one-shot overwrites that.
local lastLocomotion = STATE.IDLE

-- A one-shot owns the pose while it runs. Named for what it does rather than
-- for jump specifically, since mount/dismount clips use the same path.
local oneShotActive = false

-- Set when the burst guard trips. Cleared on the next mount, so a broken group
-- name costs one burst per ride instead of one burst per second forever.
local replayDisabled = false

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

-- The one-shot currently awaiting completion: { group = <name>, finish = fn }.
-- A single slot rather than a table keyed by group, because only one one-shot
-- can own the pose at a time -- oneShotActive enforces that.
local pendingOneShot = nil

---Complete the in-flight one-shot, if `group` is the one we are waiting on.
---Latched by clearing the slot, so the text key, the ended handler and the
---timeout can all fire without the callback running more than once.
local function finishOneShot(group)
    local p = pendingOneShot
    if not p then return end
    if group and p.group ~= group then return end
    pendingOneShot = nil
    p.done()
end

-- Registered ONCE at load, for every one-shot group any mount type can use.
-- Per-play registration would leak two handlers per jump, and OpenMW offers no
-- way to remove one -- over a long ride that is hundreds of live closures all
-- testing the same condition. This is also why the handlers have to bind to a
-- fixed name at load: the handler must already exist when the clip's stop key
-- fires, so it cannot be created lazily at play time either.
for _, group in ipairs(shared.allJumpGroups()) do
    I.AnimationController.addTextKeyHandler(group, function(groupname, key)
        if key == "stop" then finishOneShot(groupname) end
    end)
end

-- One ended-handler covering every one-shot group, rather than one per group.
I.AnimationController.addAnimationEndedHandler(function(groupname)
    finishOneShot(groupname)
end)

---Play a one-shot and call `done` exactly once when it finishes.
---
---`done` is guaranteed to run. Three things can end a one-shot and all three
---converge on the same latch:
---   * the clip's own 'stop' text key (the normal path),
---   * the animation-ended handler (a clip with no 'stop' key still ends),
---   * the timeout (a group the skeleton does not define never starts, so it
---     never ends either -- this is the only thing that covers that case).
---Without the timeout a typo in a group name is indistinguishable from a
---permanently stuck rider.
local function playOneShot(state, done)
    local group = shared.resolveAnim(mountType, state)
    if not group then return done() end   -- no clip for this state: proceed

    pendingOneShot = { group = group, done = done }

    I.AnimationController.playBlendedAnimation(group, {
        startKey = "start", stopKey = "stop",
        priority = RIDE_PRIORITY, blendMask = RIDE_BLEND_MASK,
        loops = 0, autoDisable = true,
    })
    currentState, currentGroup = state, group

    -- Backstop. Captures the slot it was created for, so a timeout belonging
    -- to an earlier one-shot cannot complete a later one.
    local mine = pendingOneShot
    async:newUnsavableSimulationTimer(ONE_SHOT_TIMEOUT, function()
        if pendingOneShot ~= mine then return end
        finishOneShot(nil)
    end)
end

---Drop an in-flight one-shot without running its completion callback. Used on
---dismount, load, and perspective change -- anywhere the thing the callback
---would resume no longer applies.
local function cancelOneShot()
    pendingOneShot = nil
    oneShotActive  = false
end

-- animation.cancel is on the base openmw.animation module, NOT on
-- I.AnimationController, and is only valid on self.
local function stopAnim()
    if not currentGroup then return end
    anim.cancel(self, currentGroup)
    currentGroup, currentState = nil, nil
end

---Return to the locomotion pose a one-shot interrupted. currentState is
---cleared first because playLoop early-outs on an unchanged state, so without
---this the re-issue would be a no-op whenever the one-shot's own state had
---already been overwritten.
local function resumeLocomotion()
    oneShotActive = false
    currentState = nil
    playLoop(lastLocomotion)
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

local L10N_CONTEXT   = "WhyWalk"
local SETTINGS_PAGE  = "WhyWalk"
local SETTINGS_GROUP = "SettingsWhyWalkCamera"
local CAMERA_TAG     = "WhyWalk"

-- Strings live in l10n/WhyWalk/<locale>.yaml. `name` and `description` below
-- are KEYS resolved through that context, not display text. OpenMW returns the
-- key itself when a context is missing, which is why the previous
-- l10n = "none" appeared to work -- the English text was acting as its own
-- key. That echoes rather than translates, so a real context is used here.
I.Settings.registerPage {
    key         = SETTINGS_PAGE,
    l10n        = L10N_CONTEXT,
    name        = "settings_page_name",
    description = "settings_page_description",
}

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
-- Returning false tells AnimRefresh the model was not ready and asks it to
-- deliver again. That contract is the entire reason v2 added a retry and v3
-- added a confirmation pass, and a subscriber that never returns false opts
-- out of both -- which is what the previous version did.
local function onPerspectiveChanged()
    -- Runs even when unmounted so a lingering offset is released if the ride
    -- ended while the notification was still settling.
    applyCameraOffset()
    if not mounted then return end

    -- A one-shot cannot be resumed part-way through, so a perspective change
    -- mid-clip drops to locomotion rather than replaying the whole thing.
    -- Going through resumeLocomotion (rather than forcing IDLE) is what keeps
    -- a rider who switches view mid-jump from landing in an idle pose while
    -- still galloping -- global will not resend, so this is the only chance to
    -- get it right.
    cancelOneShot()
    currentState = nil
    playLoop(lastLocomotion)

    -- Readiness check. The pose was just issued; if it did not take, the
    -- animation object is still being rebuilt and this change needs
    -- redelivering. currentState is cleared so the retry's playLoop is not
    -- swallowed by the unchanged-state early-out.
    if currentGroup and not anim.isPlaying(self, currentGroup) then
        currentState = nil
        return false
    end
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
    mounted        = true
    mountType      = data and data.mountType or nil
    cancelOneShot()
    replayDisabled = false
    currentState   = nil
    currentGroup   = nil
    lastLocomotion = STATE.IDLE

    if DEBUG then
        print("[WhyWalk] anim mounted, type=" .. tostring(mountType))
    end
    subscribeRefresh()
    applyCameraOffset()

    -- Let the pin place the rider before posing them. Re-checked inside the
    -- timer because a mount can be aborted within a frame or two of starting.
    async:newUnsavableSimulationTimer(MOUNT_SETTLE, function()
        if not mounted then return end
        playLoop(STATE.IDLE)
    end)
end

local function onAnimDismounted()
    mounted       = false
    mountType     = nil
    cancelOneShot()
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
        if oneShotActive then return end
        oneShotActive = true
        -- resumeLocomotion returns to lastLocomotion, NOT to idle, and
        -- playOneShot guarantees it runs even if the jump clip is missing.
        playOneShot(STATE.JUMP, resumeLocomotion)
        return
    end

    -- Recorded even while a one-shot owns the pose. This is the fix for the
    -- dropped-landing case: global sends state on CHANGE only, so the GALLOP
    -- that arrives mid-jump is the last one it will ever send for that gallop.
    -- Discarding it outright is what used to strand the rider in an idle pose.
    lastLocomotion = state

    if oneShotActive then return end   -- the one-shot owns the pose until it ends
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
    if not mounted or oneShotActive or replayDisabled then return end
    if groupname ~= currentGroup then return end

    local now = core.getSimulationTime()
    if now - replayWindowStart > REPLAY_BURST_WINDOW then
        replayWindowStart, replayCount = now, 0
    end
    replayCount = replayCount + 1
    if replayCount > REPLAY_BURST_LIMIT then
        -- Unconditional: a tripped burst guard is always a real fault, and
        -- this is the only place it is visible. Latching replayDisabled stops
        -- the retry until the next mount instead of re-arming every second.
        print("[WhyWalk] '" .. tostring(currentGroup) ..
              "' keeps ending immediately; check the group name and its"
              .. " start/stop text keys. Rider pose disabled for this ride.")
        replayDisabled = true
        return
    end

    local state = currentState or lastLocomotion
    currentState = nil
    playLoop(state)
end)

-- ---------------------------------------------------------------------------
-- SAVE / LOAD
-- ---------------------------------------------------------------------------

local function onLoad()
    mounted, mountType = false, nil
    cancelOneShot()
    replayDisabled = false
    currentState, currentGroup = nil, nil
    lastLocomotion = STATE.IDLE
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
