---@omw-context player

--[[
    playerAnim.lua
    Full-body animation controller for the hookshot mod.

    This module owns ALL animation calls for the mod. player.lua knows
    nothing about animation groups, priorities, or blend masks - it just
    tells this module when HookshotState changes (via Anim.onStateChange)
    and, once per frame while hanging, what the hang movement looks like
    (via Anim.updateHanging). Everything else lives here.

    HOOKUP (already done in player.lua, described here for reference):
      1. `local Anim = require('scripts.OpenMWHookshot.playerAnim')`
      2. A single setMode(newMode) helper wraps every state.mode write and
         calls Anim.onStateChange(newMode, oldMode, state).
      3. updateHangingState() calls Anim.updateHanging(state.hanging) once
         per frame, since the up/down/idle hang pose changes with movement
         input without a HookshotState transition happening.
]]--

local I = require('openmw.interfaces')
local anim = require('openmw.animation')
local self = require('openmw.self')

local Anim = {}

-- ==============================================
-- CONFIGURATION
-- ==============================================
-- Animation group names - these must match the group names baked into your
-- .kf files (i.e. whatever "loop start"/"loop stop" text keys live under).
local GROUPS = {
    DRAWN     = "hookaim",     -- held while aiming (HookshotState.DRAWN)
    HANDOFF   = "hookoff",
    HANG_IDLE = "hookhang",    -- hanging still
    HANG_UP   = "hookhangup",  -- ascending the rope
    HANG_DOWN = "hookhangdwn", -- descending the rope
}

-- FIRING split by target type. hookshotState.targeting.lastTargetType is
-- already computed and threaded through via setMode()'s
-- Anim.onStateChange(newState, oldState, hookshotState) call by the time
-- FIRING fires - Targeting.getTargetType() returns "enemy" for actors,
-- "item" for carriable items, and "wall"/"floor"/"ceiling"/"rappel"/"none"
-- for world geometry. No new plumbing needed for this. Placeholder group
-- names - swap for your real ones.
local FIRING_GROUPS = {
    enemy   = "hookshoot",
    item    = "hookitem",
    default = "hookgo", -- wall, floor, ceiling, rappel, none
}

-- Full body: every hookshot pose overrides the whole skeleton so it reads
-- clearly instead of blending oddly with locomotion/idle.
local FULLBODY_PRIORITY = {
    [anim.BONE_GROUP.RightArm] = anim.PRIORITY.Weapon,
    [anim.BONE_GROUP.LeftArm] = anim.PRIORITY.Weapon,
    [anim.BONE_GROUP.Torso] = anim.PRIORITY.Weapon,
    [anim.BONE_GROUP.LowerBody] = anim.PRIORITY.Weapon,
}
local FULLBODY_BLEND_MASK = anim.BLEND_MASK.LeftArm + anim.BLEND_MASK.Torso
                           + anim.BLEND_MASK.RightArm + anim.BLEND_MASK.LowerBody

-- Upper body: legs stay under normal control (LowerBody deliberately
-- omitted from both tables below) so aiming doesn't stomp locomotion.
-- FIX: RightArm was PRIORITY.Scripted while LeftArm/Torso were
-- PRIORITY.Weapon in the same playBlendedAnimation call. Per Cod3x,
-- Scripted is documented as special: "When any animation with this
-- priority is present, all animations without this priority are paused" -
-- mixing it with Weapon on the other two bone groups of the SAME pose
-- almost certainly wasn't intentional (nothing else in this file mixes
-- priority tiers within one call) and risks pausing other non-Scripted
-- animation on this actor while just aiming. Set to Weapon to match the
-- other two bone groups - flag if Scripted was actually deliberate here.
local UPPERBODY_PRIORITY = {
    [anim.BONE_GROUP.RightArm] = anim.PRIORITY.Weapon,
    [anim.BONE_GROUP.LeftArm] = anim.PRIORITY.Weapon,
    [anim.BONE_GROUP.Torso] = anim.PRIORITY.Weapon,
}
local UPPERBODY_BLEND_MASK = anim.BLEND_MASK.LeftArm + anim.BLEND_MASK.Torso
                           + anim.BLEND_MASK.RightArm
-- ==============================================
-- INTERNAL STATE
-- ==============================================
-- Tracks whatever group we last told the engine to play, so redundant
-- calls (e.g. two HANGING frames in a row with the same pose) don't
-- restart/stutter the animation.
local currentGroup = nil

-- ==============================================
-- LOW-LEVEL HELPERS
-- ==============================================
local function releaseGroup(group)
    -- animation.cancel() removes the group from the active animation list
    -- outright, regardless of which blend mask it was originally played
    -- with. Confirmed against Cod3x: plain openmw.animation module call
    -- (not on I.AnimationController), only works on self, hence the
    -- require above. This also fixes a real mismatch the old version had:
    -- reissuing at FULLBODY_BLEND_MASK to cancel a group that was actually
    -- played via playLoopAlt's UPPERBODY_BLEND_MASK (e.g. DRAWN) would
    -- touch LowerBody for a pose that never included it. cancel() doesn't
    -- need to know or guess which mask a group was played with.
    anim.cancel(self, group)
end

-- Starts `group` as the single pose this module owns, releasing whatever
-- pose it was previously holding.
--
-- THE RELEASE IS THE WHOLE POINT OF THIS HELPER. Every pose here is played
-- with loops = -1, forceLoop = true, autoDisable = false, so it runs until
-- something explicitly cancels it. playLoop/playLoopAlt used to just
-- overwrite currentGroup and leave the outgoing group running - the engine
-- kept looping it forever, and stopAnim() could no longer name it to
-- cancel it because currentGroup had already moved on.
--
-- That leak was invisible while fireHookshot() routed DRAWN -> IDLE ->
-- FIRING, because IDLE hits stopAnim() in between. The rope rewrite made
-- that transition direct (DRAWN -> FIRING), which exposed it. The same
-- applies to FIRING -> HANDOFF, FIRING -> HANGING, and every hang sub-pose
-- swap in Anim.updateHanging, which have always switched pose-to-pose.
--
-- Both play paths go through here specifically so the release can never be
-- present in one and forgotten in the other.
local function playPose(group, priority, blendMask)
    if not group then return end
    if currentGroup == group then return end -- already playing this pose

    -- Different group name, so this can never cancel the one we're about to
    -- start. Both calls resolve before the engine processes the animation
    -- list at end of frame, so there is no gap where neither pose is held.
    if currentGroup then
        releaseGroup(currentGroup)
    end

    I.AnimationController.playBlendedAnimation(group, {
        startKey = "loop start",
        stopKey = "loop stop",
        priority = priority,
        blendMask = blendMask,
        loops = -1,
        forceLoop = true,
        autoDisable = false,
    })

    currentGroup = group
end

-- Full-body pose: overrides locomotion too (includes LowerBody).
local function playLoop(group)
    playPose(group, FULLBODY_PRIORITY, FULLBODY_BLEND_MASK)
end

-- Upper-body pose: legs stay under normal locomotion control.
local function playLoopAlt(group)
    playPose(group, UPPERBODY_PRIORITY, UPPERBODY_BLEND_MASK)
end

-- Hands the bone groups this file owns back to normal animation.
local function stopAnim()
    if not currentGroup then return end

    releaseGroup(currentGroup)

    currentGroup = nil
end

-- ==============================================
-- HANGING SUB-POSE SELECTION
-- ==============================================
-- Called once per frame while HANGING (from updateHangingState in
-- player.lua) so the pose tracks W/S (ascend/descend) in real time.
-- hangingData is player.lua's state.hanging table:
--   isMoving      - bool, true while ascending or descending
--   pitchOverride - the pitchChange value updateHangingState just set;
--                   negative while ascending, positive while descending
function Anim.updateHanging(hangingData)
    if not hangingData or not hangingData.isMoving then
        playLoop(GROUPS.HANG_IDLE)
        return
    end

    if (hangingData.pitchOverride or 0) < 0 then
        playLoop(GROUPS.HANG_UP)
    else
        playLoop(GROUPS.HANG_DOWN)
    end
end

-- ==============================================
-- PUBLIC API
-- ==============================================
-- Called from player.lua's setMode() on every HookshotState transition.
-- newState/oldState are the HookshotState.* strings; hookshotState is
-- player.lua's whole `state` table (only state.hanging is used here).
function Anim.onStateChange(newState, oldState, hookshotState)
    if newState == "DRAWN" then
        playLoopAlt(GROUPS.DRAWN)

    elseif newState == "FIRING" then
        local targeting = hookshotState and hookshotState.targeting
        local targetType = targeting and targeting.lastTargetType
        playLoop(FIRING_GROUPS[targetType] or FIRING_GROUPS.default)

    elseif newState == "HANDOFF" then
        -- Upper-body only, and the dedicated hookoff clip - not full-body
        -- DRAWN. updateHandoffState() in player.lua actively drives
        -- self.controls.movement/sideMovement/jump during this state (the
        -- player is really running/jumping the last stretch under normal
        -- engine movement); a full-body pose would fight that every frame.
        -- GROUPS.HANDOFF ("hookoff") was already defined but never actually
        -- used - this was calling playLoop(GROUPS.DRAWN) instead.
        playLoopAlt(GROUPS.HANDOFF)

    elseif newState == "HANGING" then
        local hangingData = hookshotState and hookshotState.hanging
        Anim.updateHanging(hangingData)

    else
        -- IDLE, LANDING, ITEM_MENU: no hookshot pose active.
        stopAnim()
    end
end

function Anim.isActive()
    return currentGroup ~= nil
end

-- reloadlua recreates this module and loses currentGroup, while the engine can
-- still be holding the blended loop. Explicitly release every Hookshot-owned
-- group so load cleanup does not depend on that Lua bookkeeping surviving.
-- Was missing HANDOFF and the FIRING_GROUPS variants entirely - only the
-- single group actually recorded in currentGroup matters for correctness
-- (releaseGroup on a group that isn't active is a harmless no-op), but
-- listing every group this file can ever play keeps this future-proof
-- against exactly the kind of gap that left HANDOFF/FIRING variants out
-- the first time.
function Anim.forceReset()
    releaseGroup(GROUPS.DRAWN)
    releaseGroup(GROUPS.HANDOFF)
    releaseGroup(GROUPS.HANG_IDLE)
    releaseGroup(GROUPS.HANG_UP)
    releaseGroup(GROUPS.HANG_DOWN)
    for _, group in pairs(FIRING_GROUPS) do
        releaseGroup(group)
    end
    currentGroup = nil
end

return Anim
