---@omw-context none
--[[
    ForceChoke / shared.lua

    Pure data. No engine handlers, no interface, no side effects, and NO
    requires: global.lua, player.lua and target.lua all load this file, so
    it must be legal in every one of those contexts.

    It used to require openmw.animation for the priority/blend-mask enums.
    That module exists only in local and player scripts, so global.lua died
    at startup with "module not found: openmw.animation" and the whole mod
    was inert. The header said `any`, which is not a Cod3x context, so the
    context checker never saw the conflict. Anything that needs
    openmw.animation lives in poses.lua, which only the actor scripts load.
]]--

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

return M
