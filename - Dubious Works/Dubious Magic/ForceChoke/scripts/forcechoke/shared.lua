---@omw-context any
--[[
    ForceChoke / shared.lua

    Pure data and pure helpers. No engine handlers, no interface, no side
    effects. Controllers require this; this file requires only
    openmw.animation, for the enum values it maps.
]]--

local anim = require('openmw.animation')

local M = {}

-- ============================================================
-- RECORD IDS
-- ============================================================
-- Fixed, because load.lua declares them via openmw.content. Nothing is
-- generated at runtime and nothing needs to be told what its id turned out
-- to be.
M.EFFECT_ID     = "forcechoke"
M.SPELL_ID      = "forcechoke_spell"
M.HOLD_SPELL_ID = "forcechoke_hold"

-- The skill a successful cast trains. forcechoke is templated from paralyze,
-- which is ALTERATION. An earlier revision asserted Mysticism here and would
-- have filtered out every real cast.
M.SCHOOL = "alteration"

-- ============================================================
-- ANIMATION GROUPS
-- ============================================================
-- Verified against the shipped xForce.kf and Force.nif. Both files agree and
-- all four groups below define Start / Loop Start / Loop Stop / Stop.
M.GROUPS = {
    HOLD = "fchokeidle",   -- target: suspended and choking
    FLY  = "fchokefly",    -- target: in flight after a throw
    DROP = "fchokedrop",   -- target: collapse, on release or landing
    CAST = "fchoke1",      -- player: outstretched hand
}

-- ============================================================
-- TEXT KEYS
-- ============================================================
-- START_KEY / STOP_KEY are "start" / "stop" for every group, NOT
-- "loop start" / "loop stop".
--
-- This was wrong in previous revisions and is worth stating plainly, because
-- the mistake is invisible in play -- the pose appears, so it looks correct.
-- startKey/stopKey delimit the whole segment the engine plays. The loop
-- points are found by the engine from the clip's own "loop start"/"loop stop"
-- keys once loops is non-zero. Passing the loop keys as the segment bounds
-- means the intro and outro frames are never played at all, and a group asked
-- to stop at "loop stop" is cut at the loop boundary rather than the clip's
-- real end.
--
-- Because it is now one pair for every group, there is no per-group table.
-- The previous per-group STOP_KEY table existed to special-case fchokedrop,
-- which in an older asset build genuinely lacked a "Stop" key. The current
-- asset has it, so the special case is gone with it.
M.START_KEY = "start"
M.STOP_KEY  = "stop"

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
-- TUNING
-- ============================================================
M.TUNING = {
    -- Hold
    holdParalyzeSeconds = 4,    -- must match load.lua's forcechoke_hold duration
    holdRefreshInterval = 1.0,  -- re-apply cadence; never faster than 1s
    maxHoldRange        = 2048, -- hold breaks past this distance

    -- Reach
    castRange           = 1200, -- floor; Telekinesis raises it, never lowers
    maxReach            = 4096, -- hard clamp global.lua applies to any reach
                                -- reported by the player script

    -- Release (sheathe-spell key)
    dropFatigueDamage   = 40,

    -- Throw (a second successful cast)
    throwFatigueDamage  = 90,   -- on landing, instead of dropFatigueDamage
    throwHealthDamage   = 25,
    throwMagnitude      = 42,   -- initial speed
    throwVerticalFactor = 0.55, -- upward bias added to the away-vector
    throwFriction       = 0.5,
    throwGravity        = 2.0,
    throwMaxFallSpeed   = 120,
    throwMaxBounces     = 3,
    throwRayRadius      = 45,
    throwMaxSeconds     = 6,    -- hard cap so a stuck actor always lands
}

-- ============================================================
-- HELPERS
-- ============================================================

--- Options for a full-body scripted target pose.
-- `looping` groups run until explicitly cancelled; DROP is played once so it
-- runs to the clip's real end and settles on the final collapsed frame.
function M.targetPoseOptions(looping)
    return {
        startKey    = M.START_KEY,
        stopKey     = M.STOP_KEY,
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
        startKey    = M.START_KEY,
        stopKey     = M.STOP_KEY,
        priority    = M.UPPERBODY_PRIORITY,
        blendMask   = M.UPPERBODY_BLEND_MASK,
        loops       = -1,
        forceLoop   = true,
        autoDisable = false,
    }
end

return M
