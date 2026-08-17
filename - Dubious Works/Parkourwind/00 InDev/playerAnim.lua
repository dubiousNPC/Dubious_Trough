--[[
    playerAnim.lua

    Full-body animation controller for FLOW, built the same way as the
    Hookshot mod's playerAnim.lua: this file owns every animation call FLOW
    makes. States never touch the animation API directly -
    core/state_manager.lua's single setState() choke point calls
    Anim.onStateChange(newState, oldState) on every transition, and that's
    the only entry point into this file from the rest of the mod. Nothing
    else needs to change when you swap in a different animation set.

    Uses openmw.animation's module-level playBlended/cancel (explicit actor
    argument) rather than the I.AnimationController interface - both work
    the same way, this just matches the convention used more consistently
    in surf.zip. animation.cancel(actor, group) is also a cleaner way to
    stop a specific blended group than Hookshot's "reissue at Default
    priority" trick; used that way here.

    GROUPS below are placeholder vanilla-safe group names so the mod stays
    functional out of the box. Swap in your own custom set - see
    animated_climbing_and_slowdown.zip and chim_climbing.zip for a sense of
    what a climb-oriented group set can look like. This file is the only
    place animation group names appear anywhere in FLOW.
]]--

local self = require('openmw.self')
local animation = require('openmw.animation')

local Anim = {}

-- ==============================================
-- CONFIGURATION - replace with your own custom groups
-- ==============================================
-- Each entry: { group = "kf group name", startKey, stopKey, speed,
--               priority, blendMask, autoDisable }
-- startKey/stopKey are optional - only set them if your .kf file has named
-- text keys marking a sub-segment of the group; omit them (nil) to just
-- play the group's own default range, like surf.zip does.
-- priority/blendMask/autoDisable are also optional - omit to use the
-- FULLBODY_PRIORITY/FULLBODY_BLEND_MASK defaults below and the standard
-- "one-shot autoDisables, looping doesn't" rule. Mantle and LedgeHang set
-- their own here because they used to call openmw.animation directly
-- with this exact tuning (before that got centralized here, which was
-- the actual cause of LedgeHang's custom animation not reliably
-- showing - two competing playBlended calls racing each other).
local GROUPS = {
    Vault     = { group = "pwvault1",       speed = 1 },  -- one-shot, plays over the vault's physics duration
    Mantle    = {
        group = "pwmantle", speed = 1,
        priority = animation.PRIORITY.Movement + 10,
        blendMask = animation.BLEND_MASK.All,
        autoDisable = false,  -- hold the last frame instead of reverting mid-climb if
                               -- the clip is shorter than the height-scaled duration
    },
    LedgeHang = {
        group = "pwwallhangidle", speed = 1,  -- looping hang pose
        priority = animation.PRIORITY.Movement + 20,
        blendMask = animation.BLEND_MASK.All,
    },

    -- Optional states below are inert unless re-enabled - see
    -- states/optional/README.md. Kept here so re-enabling one of them
    -- doesn't require touching this file at all, just uncommenting/adding
    -- its name to the ONE_SHOT_STATES/LOOPING_STATES sets below.
    Sprint    = { group = "pwrun1", speed = 1 },  -- looping
        priority = animation.PRIORITY.Movement + 10,
        blendMask = animation.BLEND_MASK.All,
        startKey = "start",
        stopKey = "stop",

    Roll      = {
        group = "pwroll1", speed = 1,  -- one-shot landing roll
        priority = animation.PRIORITY.Movement + 20,
        blendMask = animation.BLEND_MASK.All,
        startKey = "start",
        stopKey = "stop",
    },
}

-- Which states get a looping animation, which get a one-shot, and which
-- get nothing at all. Idle/Airborne intentionally get nothing - vanilla's
-- own idle/jump/fall animations are already correct for those; FLOW only
-- needs to add NEW motions for its own mechanics, not replace basic ones.
--
-- IMPORTANT: only list a state here if its GROUPS entry names a group
-- that actually exists in the loaded animation set. playBlended with
-- FULLBODY_BLEND_MASK masks out vanilla's own animation for those bone
-- groups; if the named group has no matching clip, nothing replaces it
-- and the character T-poses for as long as the state is active. That is
-- exactly what the removed WallJump entry ("pwwalljump") was doing.
local LOOPING_STATES = { LedgeHang = true, Sprint = true }
local ONE_SHOT_STATES = { Vault = true, Mantle = true, Roll = true }

local FULLBODY_PRIORITY = {
    [animation.BONE_GROUP.RightArm] = animation.PRIORITY.Jump,
    [animation.BONE_GROUP.LeftArm] = animation.PRIORITY.Jump,
    [animation.BONE_GROUP.Torso] = animation.PRIORITY.Jump,
    [animation.BONE_GROUP.LowerBody] = animation.PRIORITY.Jump,
}
local FULLBODY_BLEND_MASK = animation.BLEND_MASK.LeftArm + animation.BLEND_MASK.Torso
                           + animation.BLEND_MASK.RightArm + animation.BLEND_MASK.LowerBody

-- ==============================================
-- INTERNAL STATE
-- ==============================================
local currentGroup = nil

-- =============================================================================
-- ONE-SHOT GROUP VERIFICATION
--
-- Every animation failure in this mod so far has come down to the same
-- question - is the configured group actually present in the animation set
-- loaded on THIS actor? - and until now there was no way to answer it
-- except by inference from the symptom (T-pose = missing, nothing at all =
-- ambiguous). animation.hasGroup() answers it directly.
--
-- Called once from main.lua's cold init, not per frame. Also probes the
-- vanilla 'jump' group, since states/airborne.lua's landing fast-path
-- depends on it existing.
-- =============================================================================
local verified = false

function Anim.verifyGroups()
    if verified then return end
    verified = true

    if not animation.hasGroup then
        print("[FLOW][anim] animation.hasGroup unavailable - skipping group probe")
        return
    end

    for stateName, entry in pairs(GROUPS) do
        local ok, present = pcall(animation.hasGroup, self, entry.group)
        if not ok then
            print(string.format("[FLOW][anim] %-10s '%s' -> probe FAILED", stateName, entry.group))
        elseif present then
            print(string.format("[FLOW][anim] %-10s '%s' -> OK", stateName, entry.group))
        else
            print(string.format("[FLOW][anim] %-10s '%s' -> MISSING (will T-pose or do nothing)",
                stateName, entry.group))
        end
    end

    local ok, present = pcall(animation.hasGroup, self, 'jump')
    if ok then
        print(string.format("[FLOW][anim] vanilla   'jump' -> %s", present and "OK" or "MISSING"))
    end
end

local function stopCurrent()
    if not currentGroup then return end
    animation.cancel(self, currentGroup)
    currentGroup = nil
end

local function playGroup(stateName, looping)
    local entry = GROUPS[stateName]
    if not entry or not entry.group then return end

    if currentGroup == entry.group then return end -- already playing, avoid restart stutter
    stopCurrent()

    local autoDisable = entry.autoDisable
    if autoDisable == nil then autoDisable = not looping end

    animation.playBlended(self, entry.group, {
        startKey = entry.startKey,
        stopKey = entry.stopKey,
        priority = entry.priority or FULLBODY_PRIORITY,
        blendMask = entry.blendMask or FULLBODY_BLEND_MASK,
        speed = entry.speed or 1,
        loops = looping and -1 or 0,
        forceLoop = looping and true or nil,
        autoDisable = autoDisable,
    })
    currentGroup = entry.group
end

-- ==============================================
-- PUBLIC API - called only from core/state_manager.lua's setState()
-- ==============================================
function Anim.onStateChange(newState, oldState)
    if ONE_SHOT_STATES[newState] then
        playGroup(newState, false)
    elseif LOOPING_STATES[newState] then
        playGroup(newState, true)
    else
        -- Idle, Airborne, or anything else: hand control back to vanilla.
        stopCurrent()
    end
end

return Anim
