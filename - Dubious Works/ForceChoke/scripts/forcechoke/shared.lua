-- ============================================================
-- ForceChoke — SHARED DATA LIBRARY
--
-- Pure data + pure helpers. No engine handlers, no interface, no
-- side effects. Controllers (global/player/target) require this;
-- this file requires nothing but openmw.animation for the enum
-- values it maps.
--
-- ANIMATION GROUPS AND TEXT KEYS
-- ------------------------------
-- Group names and text keys below were read directly out of the
-- shipped xForce.kf / xForcechoke.kf / xForceEffect.kf, not guessed:
--
--   fchokeidle : Start | Loop Start | Loop Stop | Stop
--   fchokefly  : Start | Loop Start | Loop Stop | Stop
--   fchokedrop : Start | Loop Start | Loop Stop         <-- NO "Stop"
--   fchokeend  : Start | Stop
--   fchoke1    : Start | Loop Start | Loop Stop | Stop
--   fchokel / fchoker / fchokerfwd / fchokertwd : Start | Stop
--
-- HISTORY: earlier revisions of xForce.kf shipped fchokedrop with
-- only Start / Loop Start / Loop Stop -- it was the one group in the
-- file missing a "Stop" key, so stopping it at "stop" named a key
-- that did not exist and the group never terminated where intended.
-- The current assets add "fchokedrop: Stop" and all five groups are
-- now symmetrical.
--
-- STOP_KEY stays a per-group table anyway. It costs nothing, it keeps
-- the mapping explicit next to the keys it mirrors, and it means a
-- future asset revision that drops or renames a key is a one-line
-- change here rather than a hunt through the controllers.
-- ============================================================

local anim = require('openmw.animation')

local M = {}

-- ============================================================
-- ANIMATION GROUPS
-- ============================================================
M.GROUPS = {
    -- Target (NPC) side
    HOLD = "fchokeidle",   -- looping suspended-and-choking pose
    FLY  = "fchokefly",    -- looping in-air pose, played while thrown
    DROP = "fchokedrop",   -- collapse; released or landed

    -- Player side
    CAST = "fchoke1",      -- looping outstretched-hand pose
}

-- Start key is "loop start" for every looping group here, so the
-- animation enters at the top of its loop section rather than
-- replaying its intro every cycle.
M.START_KEY = {
    [M.GROUPS.HOLD] = "loop start",
    [M.GROUPS.FLY]  = "loop start",
    [M.GROUPS.DROP] = "start",
    [M.GROUPS.CAST] = "loop start",
}

-- Verified against the shipped xForce.kf / Force.nif: every group
-- below defines all four of Start / Loop Start / Loop Stop / Stop.
M.STOP_KEY = {
    [M.GROUPS.HOLD] = "loop stop",
    [M.GROUPS.FLY]  = "loop stop",
    -- fchokedrop is played once, not looped, so it runs to the real
    -- end of the clip and settles on its final collapsed frame.
    [M.GROUPS.DROP] = "stop",
    [M.GROUPS.CAST] = "loop stop",
}

-- ============================================================
-- PRIORITIES AND BLEND MASKS
-- ============================================================
-- Target poses are full-body at PRIORITY.Scripted, applied uniformly
-- across all four bone groups. Scripted pauses all non-Scripted
-- animation on that actor globally, which is exactly what "held,
-- paralyzed" wants — the NPC must stop doing anything else. Because
-- every bone group gets the SAME priority, this is not the
-- mixed-priority mistake (Scripted on one bone group, Weapon on
-- another) that silently freezes an actor's other animations.
M.FULLBODY_PRIORITY = {
    [anim.BONE_GROUP.LowerBody] = anim.PRIORITY.Scripted,
    [anim.BONE_GROUP.Torso]     = anim.PRIORITY.Scripted,
    [anim.BONE_GROUP.LeftArm]   = anim.PRIORITY.Scripted,
    [anim.BONE_GROUP.RightArm]  = anim.PRIORITY.Scripted,
}

M.FULLBODY_BLEND_MASK = anim.BLEND_MASK.LowerBody + anim.BLEND_MASK.Torso
                      + anim.BLEND_MASK.LeftArm + anim.BLEND_MASK.RightArm

-- Player pose is upper-body only: LowerBody is deliberately absent
-- from both the priority table and the mask, so the player keeps
-- normal locomotion and can walk while maintaining the choke.
-- Weapon (7) is the same priority band OpenMW uses for casting, so
-- this reads as a held cast rather than overriding everything.
M.UPPERBODY_PRIORITY = {
    [anim.BONE_GROUP.Torso]    = anim.PRIORITY.Weapon,
    [anim.BONE_GROUP.LeftArm]  = anim.PRIORITY.Weapon,
    [anim.BONE_GROUP.RightArm] = anim.PRIORITY.Weapon,
}

M.UPPERBODY_BLEND_MASK = anim.BLEND_MASK.Torso + anim.BLEND_MASK.LeftArm
                       + anim.BLEND_MASK.RightArm

-- ============================================================
-- RECORD IDS / NAMES
-- ============================================================
-- SPELL MATCHING
-- --------------
-- Preferred: match on a custom magic effect. If an .omwaddon in the load
-- order defines MARKER_EFFECT, ANY spell containing it triggers Force Choke
-- -- including spells the player builds at a spellmaker, which is how
-- NiftySpellPack and the TR spell packs do it. Nothing here creates that
-- effect: createRecordDraft can make spells, not magic effects, so a plugin
-- is the only way and this mod does not ship one.
--
-- Fallback: match on the runtime-generated record id. Works with no plugin,
-- but only ever matches the single record this mod creates.
--
-- The fallback effect is deliberately NOT used for matching. Force Choke is
-- built on vanilla "paralyze", so matching by effect id without the marker
-- would fire on every paralyze spell in the game.
M.MARKER_EFFECT    = "forcechoke"

M.SPELL_NAME       = "Force Choke"
M.SPELL_COST       = 25
M.HOLD_SPELL_NAME  = "Force Choke (Held)"

-- ============================================================
-- TUNING
-- ============================================================
M.TUNING = {
    -- Acquisition (SharedRay). castRange is how far the crosshair ray is
    -- allowed to reach when grabbing; maxHoldRange below is how far the target
    -- may then drift before the grip breaks, so it is deliberately larger.
    castRange           = 1200, -- floor; Telekinesis raises it, never lowers
    maxReach            = 4096, -- hard clamp global.lua applies to any
                                -- reach reported by the player script

    -- Hold
    holdParalyzeSeconds = 4,    -- paralyze duration applied per refresh
    holdRefreshInterval = 1.0,  -- re-apply cadence (never faster than 1s)
    maxHoldRange        = 2048, -- hold breaks past this distance

    -- Release (sheathe-spell key)
    dropFatigueDamage   = 40,

    -- Throw (attack key, on a successful re-cast)
    throwFatigueDamage  = 90,   -- applied on landing, instead of dropFatigueDamage
    throwHealthDamage   = 25,
    throwMagnitude      = 42,   -- initial speed, units/frame-step
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

--- Build the option table for a full-body scripted target pose.
-- `looping` groups run until explicitly replaced; fchokedrop is
-- played non-looping so it settles into its final collapsed frame.
function M.targetPoseOptions(group, looping)
    return {
        startKey    = M.START_KEY[group] or "start",
        stopKey     = M.STOP_KEY[group] or "stop",
        priority    = M.FULLBODY_PRIORITY,
        blendMask   = M.FULLBODY_BLEND_MASK,
        loops       = looping and -1 or 0,
        forceLoop   = looping and true or false,
        autoDisable = false,
    }
end

--- Build the option table for the player's upper-body pose.
function M.playerPoseOptions(group)
    return {
        startKey    = M.START_KEY[group] or "start",
        stopKey     = M.STOP_KEY[group] or "stop",
        priority    = M.UPPERBODY_PRIORITY,
        blendMask   = M.UPPERBODY_BLEND_MASK,
        loops       = -1,
        forceLoop   = true,
        autoDisable = false,
    }
end

return M
