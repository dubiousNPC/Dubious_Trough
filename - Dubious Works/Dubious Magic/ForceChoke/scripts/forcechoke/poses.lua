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
M.FULLBODY_PRIORITY = {
    [anim.BONE_GROUP.LowerBody] = anim.PRIORITY.Scripted,
    [anim.BONE_GROUP.Torso]     = anim.PRIORITY.Scripted,
    [anim.BONE_GROUP.LeftArm]   = anim.PRIORITY.Scripted,
    [anim.BONE_GROUP.RightArm]  = anim.PRIORITY.Scripted,
}

M.UPPERBODY_PRIORITY = {
    [anim.BONE_GROUP.Torso]    = anim.PRIORITY.Weapon,
    [anim.BONE_GROUP.LeftArm]  = anim.PRIORITY.Weapon,
    [anim.BONE_GROUP.RightArm] = anim.PRIORITY.Weapon,
}

M.FULLBODY_BLEND_MASK  = anim.BLEND_MASK.All
M.UPPERBODY_BLEND_MASK = anim.BLEND_MASK.UpperBody

-- ============================================================
-- HELPERS
-- ============================================================

function M.targetPoseOptions(looping)
    return {
        startKey    = S.START_KEY,
        stopKey     = S.STOP_KEY,
        priority    = M.FULLBODY_PRIORITY,
        blendMask   = M.FULLBODY_BLEND_MASK,
        loops       = looping and -1 or 0,
        forceLoop   = looping and true or false,
        autoDisable = not looping,
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
