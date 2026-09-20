---@omw-context local | player
--[[
    ForceChoke / poses.lua

    The animation half of what used to be shared.lua: priority and blend-mask
    tables built from openmw.animation's enums, and the playBlended option
    builders. openmw.animation exists only in actor contexts, so this file is
    required by player.lua and target.lua and NEVER by global.lua.
]]--

local anim = require('openmw.animation')
local S    = require('scripts.forcechoke.shared')

local M = {}

-- ============================================================
-- PRIORITIES AND BLEND MASKS
-- ============================================================
-- Target poses are full-body at PRIORITY.Scripted, uniformly across all four
-- bone groups. Scripted pauses all non-Scripted animation on that actor,
-- which is exactly what "held, paralyzed" wants. Applying the SAME priority
-- to every bone group is what keeps this correct: mixing Scripted on one bone
-- group with a lower priority on another silently freezes the actor's other
-- animations.
--
-- Keys are the BONE_GROUP enum values, never numeric literals. Cod3x
-- annotates them 1-4 while the corpus records them as 0-3; using the symbols
-- makes this code correct either way.
M.FULLBODY_PRIORITY = {
    [anim.BONE_GROUP.LowerBody] = anim.PRIORITY.Scripted,
    [anim.BONE_GROUP.Torso]     = anim.PRIORITY.Scripted,
    [anim.BONE_GROUP.LeftArm]   = anim.PRIORITY.Scripted,
    [anim.BONE_GROUP.RightArm]  = anim.PRIORITY.Scripted,
}

-- Player pose is upper-body only: LowerBody is absent from both the priority
-- table and the mask, so locomotion stays under normal engine control and the
-- player can walk while maintaining the grip. Weapon is the band OpenMW uses
-- for casting, so this reads as a held cast rather than an override.
M.UPPERBODY_PRIORITY = {
    [anim.BONE_GROUP.Torso]    = anim.PRIORITY.Weapon,
    [anim.BONE_GROUP.LeftArm]  = anim.PRIORITY.Weapon,
    [anim.BONE_GROUP.RightArm] = anim.PRIORITY.Weapon,
}

-- Engine-provided composites rather than hand-summed flags: All is 15,
-- UpperBody is 14 (Torso + both arms, no LowerBody).
M.FULLBODY_BLEND_MASK  = anim.BLEND_MASK.All
M.UPPERBODY_BLEND_MASK = anim.BLEND_MASK.UpperBody

-- ============================================================
-- HELPERS
-- ============================================================

--- Options for a full-body scripted target pose.
-- `looping` groups run until explicitly cancelled; DROP is played once so it
-- runs to the clip's real end and settles on the final collapsed frame.
function M.targetPoseOptions(looping)
    return {
        startKey    = S.START_KEY,
        stopKey     = S.STOP_KEY,
        priority    = M.FULLBODY_PRIORITY,
        blendMask   = M.FULLBODY_BLEND_MASK,
        loops       = looping and -1 or 0,
        forceLoop   = looping and true or false,
        autoDisable = false,
    }
end

--- Options for the player's looping upper-body pose.
function M.playerPoseOptions()
    return {
        startKey    = S.START_KEY,
        stopKey     = S.STOP_KEY,
        priority    = M.UPPERBODY_PRIORITY,
        blendMask   = M.UPPERBODY_BLEND_MASK,
        loops       = -1,
        forceLoop   = true,
        autoDisable = false,
    }
end

return M
