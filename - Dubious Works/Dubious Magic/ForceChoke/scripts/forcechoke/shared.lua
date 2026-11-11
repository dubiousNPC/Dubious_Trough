---@omw-context none
--[[
    ForceChoke / shared.lua

    Pure data. No engine handlers, no interface, no side effects, and NO
    requires: global.lua, player.lua and target.lua all load this file, so
    it must be legal in every one of those contexts.
]]--

local M = {}

-- ============================================================
-- RECORD IDS
-- ============================================================
M.EFFECT_ID     = "forcechoke"
M.SPELL_ID      = "forcechoke_spell"
M.HOLD_SPELL_ID = "forcechoke_hold"


-- ============================================================
-- ANIMATION GROUPS
-- ============================================================
M.GROUPS = {
    HOLD = "fchokeidle",   -- target: suspended and choking
    FLY  = "fchokefly",    -- target: in flight after a throw
    DROP = "fchokedrop",   -- target: collapse, on release or landing
    CAST = "fchoke1",      -- player: outstretched hand
}

-- ============================================================
-- TEXT KEYS
-- ============================================================
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
    throwSpeed          = 1260, -- u/s   (was 42/step)
     throwVerticalFactor = 0.55, -- upward bias added to the away-vector
     throwFriction       = 450,  -- u/s^2 horizontal drag (was 0.5/step; x30 for /s, x30 again for /s^2)
     throwGravity        = 1800, -- u/s^2 (was 2.0/step; an acceleration scales by 30^2)
     throwMaxFallSpeed   = 3600, -- u/s   (was 120/step)
     throwSpinDecay      = 9,    -- rad/s^2 (was 0.01/step, x30^2)
     throwRestSpeed      = 150,  -- u/s below which a grounded actor has landed
     throwMaxBounces     = 3,
     throwRayRadius      = 45,
    -- Detach
    dropSettleGrace     = 0.15, -- s; isPlaying is false until the engine has
                                -- actually started the group
    dropSettleTimeout   = 4,    -- s; detach anyway if the clip never reports
                                -- finishing, so a script can never be stuck on

    throwMaxStep        = 0.1,  -- s; integration steps are clamped to this so
                                -- a long stall cannot teleport an actor
                                -- through geometry in one jump
}

return M
