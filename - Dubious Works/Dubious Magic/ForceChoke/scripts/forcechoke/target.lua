-- ============================================================
-- ForceChoke — TARGET (NPC / CREATURE local script)
--
-- Runs on every actor, but stays completely inert until global.lua
-- addresses this specific actor. Two jobs, both of which MUST happen
-- in a script running on the actor itself:
--
--   1. openmw.animation.playBlended takes a SelfObject. A global
--      script cannot pose another actor; only the actor's own local
--      script can. That is why the target poses live here and not in
--      global.lua.
--   2. The throw integrates a velocity per frame and needs
--      nearby.castRay from the actor's own context.
--
-- Movement itself still round-trips through global.lua, because
-- teleport() is global-only. That is the same split Knockback uses:
-- local script computes nextPos -> global teleports -> global pings
-- the local script back so it can compute the next step.
--
-- onUpdate early-returns in one comparison unless this actor is
-- mid-throw, so the per-frame cost is nil for every actor in the
-- cell that is not currently being flung.
-- ============================================================

local self    = require('openmw.self')
local core    = require('openmw.core')
local types   = require('openmw.types')
local util    = require('openmw.util')
local nearby  = require('openmw.nearby')
local anim    = require('openmw.animation')
local I       = require('openmw.interfaces')

local S = require('scripts.forcechoke.shared')
local T = S.TUNING

-- ============================================================
-- STATE
-- ============================================================
local currentGroup = nil   -- which ForceChoke pose we believe is playing
local throwing     = false
local waiting      = false -- true while a teleport round-trip is in flight
local vx, vy, vz   = 0, 0, 0
local spin         = 0
local bounces      = 0
local elapsed      = 0

local COLLISION = util.bitOr(
    nearby.COLLISION_TYPE.World,
    nearby.COLLISION_TYPE.HeightMap,
    nearby.COLLISION_TYPE.Door
)

-- ============================================================
-- ANIMATION
-- ============================================================
-- Every pose swap goes through here so the outgoing pose is always
-- released. These are loops = -1 / autoDisable = false animations:
-- if the outgoing group is not explicitly ended it keeps running
-- forever underneath the new one.
local function playPose(group, looping)
    if not group then return end
    if currentGroup == group then return end

    if currentGroup then
        -- Release by reissuing the outgoing group at Default priority
        -- and letting it finish, rather than animation.cancel(). Same
        -- reasoning as elsewhere in this codebase: the reissue path
        -- uses the identical call the pose already used, so it cannot
        -- raise on a build where cancel's signature differs. pcall'd
        -- regardless, because a failed release must never prevent the
        -- incoming pose from starting.
        pcall(function()
            I.AnimationController.playBlendedAnimation(currentGroup, {
                startKey    = S.START_KEY[currentGroup] or "start",
                stopKey     = S.STOP_KEY[currentGroup] or "stop",
                priority    = anim.PRIORITY.Default,
                blendMask   = S.FULLBODY_BLEND_MASK,
                loops       = 0,
                autoDisable = true,
            })
        end)
    end

    pcall(function()
        I.AnimationController.playBlendedAnimation(group, S.targetPoseOptions(group, looping))
    end)

    currentGroup = group
end

local function clearPose()
    if not currentGroup then return end
    local g = currentGroup
    -- Cleared unconditionally: a stale name here would make every
    -- later playPose early-return on `currentGroup == group` and no
    -- pose would ever start again.
    currentGroup = nil
    pcall(function()
        I.AnimationController.playBlendedAnimation(g, {
            startKey    = S.START_KEY[g] or "start",
            stopKey     = S.STOP_KEY[g] or "stop",
            priority    = anim.PRIORITY.Default,
            blendMask   = S.FULLBODY_BLEND_MASK,
            loops       = 0,
            autoDisable = true,
        })
    end)
end

-- ============================================================
-- EVENT HANDLERS (all addressed to this actor by global.lua)
-- ============================================================

--- Grabbed: enter the looping suspended pose.
local function onGrab()
    throwing = false
    waiting  = false
    playPose(S.GROUPS.HOLD, true)
end

--- Released without a throw: collapse.
local function onDrop()
    throwing = false
    waiting  = false
    playPose(S.GROUPS.DROP, false)
end

--- Fully finished (or the actor died): hand the bones back.
local function onClear()
    throwing = false
    waiting  = false
    clearPose()
end

--- Thrown: seed the velocity and switch to the in-air pose.
-- `dir` is the normalised away-from-player vector computed globally,
-- where both actors' positions are known.
local function onThrow(data)
    if not data or not data.dir then return end

    local dir = data.dir
    local mag = data.magnitude or T.throwMagnitude

    vx = dir.x * mag
    vy = dir.y * mag
    vz = math.abs(dir.z * mag) + mag * T.throwVerticalFactor

    -- Random tumble direction, same trick Knockback uses to stop
    -- every thrown actor spinning the same way.
    if math.random() > 0.5 then
        spin = 0.4 + math.random() * 0.3
    else
        spin = -0.4 - math.random() * 0.3
    end

    bounces  = 0
    elapsed  = 0
    throwing = true
    waiting  = false

    playPose(S.GROUPS.FLY, true)
end

--- Global finished the teleport; we may compute the next step.
local function onStepDone()
    waiting = false
end

-- ============================================================
-- LANDING
-- ============================================================
local function land()
    throwing = false
    waiting  = false
    playPose(S.GROUPS.DROP, false)
    core.sendGlobalEvent('ForceChoke_Landed', { actor = self.object })
end

-- ============================================================
-- PER-FRAME (throw only)
-- ============================================================
local function onUpdate(dt)
    if not throwing then return end
    if core.isWorldPaused() then return end
    if waiting then return end

    -- Hard time cap: an actor wedged in geometry still lands, so the
    -- mod can never leave someone permanently airborne and paralyzed.
    elapsed = elapsed + (dt or 0)
    if elapsed > T.throwMaxSeconds then
        land()
        return
    end

    if types.Actor.stats.dynamic.health(self).current <= 0 then
        onClear()
        return
    end

    -- Horizontal drag
    if vx > 0 then vx = math.max(0, vx - T.throwFriction)
    elseif vx < 0 then vx = math.min(0, vx + T.throwFriction) end
    if vy > 0 then vy = math.max(0, vy - T.throwFriction)
    elseif vy < 0 then vy = math.min(0, vy + T.throwFriction) end

    if spin > 0 then spin = math.max(0, spin - 0.01)
    elseif spin < 0 then spin = math.min(0, spin + 0.01) end

    vz = vz - T.throwGravity
    if vz < -T.throwMaxFallSpeed then vz = -T.throwMaxFallSpeed end

    local box = self:getBoundingBox()

    -- Nearly stationary and close to the floor -> we have landed.
    if util.vector3(vx, vy, vz):length() < 5 then
        local down = nearby.castRay(box.center, box.center + util.vector3(0, 0, -500), {
            collisionType = COLLISION,
            radius = T.throwRayRadius,
        })
        if down.hit then
            if math.abs(down.hitPos.z - self.position.z) < T.throwRayRadius * 2 then
                land()
                return
            end
        end
    end

    local rayEnd = box.center + util.vector3(vx, vy, vz) * 3
    local res = nearby.castRay(box.center, rayEnd, {
        collisionType = COLLISION,
        radius = T.throwRayRadius,
    })

    if res.hit and res.hitNormal then
        bounces = bounces + 1
        local n = res.hitNormal
        local dot = vx * n.x + vy * n.y + vz * n.z
        -- Reflect, with no restitution term: hitting a wall mid-choke
        -- should look like a body slamming into it, not a rubber ball.
        vx = vx - 2 * dot * n.x
        vy = vy - 2 * dot * n.y
        vz = vz - 2 * dot * n.z
        if bounces >= T.throwMaxBounces then
            land()
            return
        end
    end

    core.sendGlobalEvent('ForceChoke_ThrowStep', {
        actor    = self.object,
        nextPos  = self.position + util.vector3(vx, vy, vz),
        rotation = util.transform.rotateZ(self.rotation:getYaw() + spin),
    })
    waiting = true
end

-- [BUGFIX] Without this, a save taken mid-choke stranded the actor forever.
-- The hold pose is full-body at PRIORITY.Scripted, and Scripted is documented
-- as pausing every non-Scripted animation on that actor for as long as it is
-- present. On load, global.lua resets its state to inactive, so nothing ever
-- sends ForceChoke_Clear -- the NPC kept the choke pose and could not play any
-- other animation again. (The paralysis self-heals: it is a timed effect and
-- expires. The pose does not.)
--
-- Every ForceChoke group is cancelled by name rather than relying on
-- currentGroup, which is a module local and is nil again by the time this runs.
local function onLoad()
    throwing = false
    waiting  = false
    currentGroup = nil
    for _, group in pairs(S.GROUPS) do
        pcall(anim.cancel, self, group)
    end
end

return {
    engineHandlers = {
        onUpdate = onUpdate,
        onLoad   = onLoad,
    },
    eventHandlers = {
        ForceChoke_Grab      = onGrab,
        ForceChoke_Drop      = onDrop,
        ForceChoke_Clear     = onClear,
        ForceChoke_Throw     = onThrow,
        ForceChoke_StepDone  = onStepDone,
    },
}
