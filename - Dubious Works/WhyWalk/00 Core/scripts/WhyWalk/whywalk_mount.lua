---@omw-context local
--[[
    whywalk_mount.lua -- gait animation for the ridden creature

    WHY THIS EXISTS

    whywalk_global.lua's header argued a mount script was unnecessary, because
    teleporting the creature every frame overwrites whatever its AI decides. It
    named the one thing that would justify bringing it back:

        "visible gait animation fighting (the creature playing a walk cycle in
         a direction it is not moving)"

    What actually happened in game was worse than the prediction, and in the
    opposite direction. The creature does not play the WRONG animation. It
    plays NOTHING AT ALL, and stands in its bind pose -- a T-pose -- while
    sliding across the ground and rotating to face its heading.

    The assumption behind that paragraph was that the AI would still drive the
    gait and we would merely be overriding the result. It does not. OpenMW's
    character controller picks a creature's locomotion animation from the
    movement IT is asked to perform. A teleport is not movement: the controller
    is never asked for anything, so it never selects a group, and an actor with
    no active animation group renders at bind pose.

    This is the p37z lesson from RESEARCH 1.10 arriving the expensive way --
    "integrating movement yourself and teleport-ing the mount every frame
    reimplements gait animation, root motion, collision, gravity and pathing,
    badly". p37z avoids it by writing `controls.movement` and letting the
    engine drive. That remains the better architecture and is the eventual
    answer; this file is the smaller, lower-risk fix that matches what
    Devilish Guar Riding does, which is the behaviour the mod is tuned against.

    WHAT IT DOES

    Plays one looping locomotion group on the creature, chosen by the gait the
    global script is already computing for the rider pose. Nothing else. No
    movement, no AI suppression, no per-frame handler.

    ATTACHMENT

    Registered CUSTOM and attached with addScript on mount / removeScript on
    dismount, so an unridden creature carries no code at all -- the condition
    the global script's header set for ever adding one of these back.
]]

local self      = require('openmw.self')
local animation = require('openmw.animation')
local types     = require('openmw.types')

-- Vanilla creature locomotion groups. These are the names Devilish Guar
-- Riding's config.ANIMATION uses, and they are what Morrowind's own creature
-- .kf files define, so they work on any creature that animates at all.
local GAIT = {
    idle    = "idle",
    walk    = "walkforward",
    gallop  = "runforward",
    reverse = "walkback",
    jump    = "jump",
}

-- A creature missing a group gets the next-best thing rather than nothing.
-- Falling back to `idle` matters: an unmatched group means playBlended does
-- nothing, which is the bind pose again.
local FALLBACK = {
    gallop  = { "runforward", "walkforward", "idle" },
    walk    = { "walkforward", "runforward", "idle" },
    reverse = { "walkback", "walkforward", "idle" },
    jump    = { "jump", "runforward", "idle" },
    idle    = { "idle" },
}

-- Resolved once per creature: hasGroup is a real lookup and the answer cannot
-- change for the life of the actor.
local resolved = {}

local function groupFor(state)
    local cached = resolved[state]
    if cached ~= nil then return cached or nil end

    local chain = FALLBACK[state] or FALLBACK.idle
    local found = false
    for _, name in ipairs(chain) do
        if animation.hasGroup(self, name) then found = name; break end
    end
    resolved[state] = found
    return found or nil
end

local currentState = nil
local currentGroup = nil

-- PRIORITY.Default, deliberately.
--
-- This is the creature's OWN locomotion, not a scripted override of it, so it
-- belongs at the priority the character controller would have used. Anything
-- higher would win fights it has no business winning -- a ridden creature that
-- gets hit should still play its hit reaction, and one that dies should still
-- play its death animation rather than carrying on walking at Scripted
-- priority (RESEARCH 2.2: Scripted pauses every non-Scripted animation
-- globally, which on a creature means its death animation never runs).
local function play(state)
    if state == currentState then return end

    local group = groupFor(state)
    if not group then
        currentState = state
        return
    end

    if group ~= currentGroup then
        if currentGroup then animation.cancel(self, currentGroup) end
        animation.playBlended(self, group, {
            loops       = -1,
            forceLoop   = true,
            priority    = animation.PRIORITY.Default,
            blendMask   = animation.BLEND_MASK.All,
            autoDisable = false,
        })
        currentGroup = group
    end
    currentState = state
end

local function stop()
    if currentGroup then
        animation.cancel(self, currentGroup)
        currentGroup = nil
    end
    currentState = nil
end

-- ---------------------------------------------------------------------------
-- EVENTS
-- ---------------------------------------------------------------------------
-- WhyWalk_MountGait carries the same state string the rider pose uses, sent
-- from whywalk_global on CHANGE only. There is no per-frame handler here and
-- no polling: a creature walking in a straight line generates no work.

local function onMountGait(data)
    local state = data and data.state
    if not state then return end
    play(state)
end

local function onMountRelease()
    stop()
end

-- The ride does not survive a load (the global script rebuilds the session and
-- re-sends), so drop any held group rather than leaving a looping animation
-- running on a creature nobody is riding.
local function onLoad()
    currentState, currentGroup = nil, nil
end

return {
    eventHandlers = {
        WhyWalk_MountGait    = onMountGait,
        WhyWalk_MountRelease = onMountRelease,
    },
    engineHandlers = {
        onLoad = onLoad,
    },
}
