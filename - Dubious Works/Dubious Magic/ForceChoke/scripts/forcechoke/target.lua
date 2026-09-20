---@omw-context local
--[[
    ForceChoke / target.lua   (NPC / CREATURE local script)

    Runs on every actor, inert until global.lua addresses this one. Two jobs
    that MUST happen in a script running on the actor itself:

      1. animation.playBlended takes a SelfObject, so a global script cannot
         pose another actor.
      2. The throw integrates a velocity per frame and needs nearby.castRay
         from the actor's own context.

    Movement still round-trips through global.lua, because teleport() is
    global-only: local computes nextPos -> global teleports -> global pings
    the local script back for the next step. Same split Knockback uses.

    onUpdate early-returns on one boolean unless this actor is mid-throw, so
    the per-frame cost for every other actor in the cell is nil.
]]--

local self   = require('openmw.self')
local core   = require('openmw.core')
local types  = require('openmw.types')
local util   = require('openmw.util')
local nearby = require('openmw.nearby')
local anim   = require('openmw.animation')

local S = require('scripts.forcechoke.shared')
local P = require('scripts.forcechoke.poses')
local T = S.TUNING

-- ============================================================
-- STATE
-- ============================================================
local currentGroup = nil
local throwing     = false
local waiting      = false  -- true while a teleport round-trip is in flight
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
-- Releases use animation.cancel, which removes the group from the active
-- list outright regardless of the mask it was played with.
--
-- Previous revisions instead reissued the outgoing group at PRIORITY.Default
-- with loops = 0 and let it expire, each call wrapped in pcall, on the theory
-- that cancel's presence and signature were unconfirmed for this build. They
-- are confirmed: animation.cancel(actor, groupName). The reissue dance and
-- every pcall guarding it are gone.
--
-- Every pose here is loops = -1 / autoDisable = false, so an outgoing group
-- that is not cancelled keeps running forever underneath the new one. That is
-- why both play paths funnel through playPose.
local function playPose(group, looping)
    if currentGroup == group then return end

    if currentGroup then
        anim.cancel(self, currentGroup)
    end

    -- A missing animation asset is a normal, supported state: the mod ships
    -- clips for the standard skeletons, and a heavily replaced or modded
    -- skeleton may not carry them. Checked rather than attempted, so the
    -- actor is left in a sane pose instead of an undefined one.
    if not anim.hasGroup(self, group) then
        currentGroup = nil
        return
    end

    anim.playBlended(self, group, P.targetPoseOptions(looping))
    currentGroup = group
end

local function clearPose()
    if not currentGroup then return end
    anim.cancel(self, currentGroup)
    currentGroup = nil
end

-- ============================================================
-- EVENT HANDLERS (addressed to this actor by global.lua)
-- ============================================================
local function onGrab()
    throwing = false
    waiting  = false
    playPose(S.GROUPS.HOLD, true)
end

local function onDrop()
    throwing = false
    waiting  = false
    playPose(S.GROUPS.DROP, false)
end

local function onClear()
    throwing = false
    waiting  = false
    clearPose()
end

--- Thrown: seed the velocity and switch to the in-air pose. `dir` is the
--- normalised away-from-player vector, computed globally where both actors'
--- positions are known.
local function onThrow(data)
    if not data or not data.dir then return end

    local dir = data.dir
    local mag = data.magnitude or T.throwMagnitude

    vx = dir.x * mag
    vy = dir.y * mag
    vz = math.abs(dir.z * mag) + mag * T.throwVerticalFactor

    -- Random tumble direction, so thrown actors do not all spin the same way.
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

--- Global finished the teleport; the next step may be computed.
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

    -- Hard time cap: an actor wedged in geometry still lands, so the mod can
    -- never leave someone permanently airborne.
    elapsed = elapsed + (dt or 0)
    if elapsed > T.throwMaxSeconds then
        land()
        return
    end

    -- Died mid-flight. Report it, or global.lua would sit in active+thrown
    -- with no landing ever arriving. (Previously this cleared locally and
    -- told nobody, stranding global state until the next cast reset it.)
    if types.Actor.stats.dynamic.health(self).current <= 0 then
        throwing = false
        waiting  = false
        clearPose()
        core.sendGlobalEvent('ForceChoke_Landed', { actor = self.object, died = true })
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

    -- Nearly stationary and close to the floor: landed.
    if util.vector3(vx, vy, vz):length() < 5 then
        local down = nearby.castRay(box.center, box.center + util.vector3(0, 0, -500), {
            collisionType = COLLISION,
            radius        = T.throwRayRadius,
        })
        if down.hit and math.abs(down.hitPos.z - self.position.z) < T.throwRayRadius * 2 then
            land()
            return
        end
    end

    local res = nearby.castRay(box.center, box.center + util.vector3(vx, vy, vz) * 3, {
        collisionType = COLLISION,
        radius        = T.throwRayRadius,
    })

    if res.hit and res.hitNormal then
        bounces = bounces + 1
        local n = res.hitNormal
        local dot = vx * n.x + vy * n.y + vz * n.z
        -- Reflect with no restitution term: hitting a wall mid-choke should
        -- read as a body slamming into it, not a rubber ball.
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

-- ============================================================
-- SAVE / LOAD
-- ============================================================
-- Without this, a save taken mid-choke stranded the actor forever. The hold
-- pose is full-body at PRIORITY.Scripted, and Scripted pauses every
-- non-Scripted animation on that actor for as long as it is present. On load
-- global.lua resets to inactive, so nothing ever sends ForceChoke_Clear: the
-- NPC kept the choke pose and could never play any other animation again.
-- (The paralysis self-heals -- it is timed and expires. The pose does not.)
--
-- The cancel happens in onActive, NOT onLoad. onLoad runs for every actor
-- carrying this script -- every NPC and creature in the save -- including
-- disabled ones and ones not yet in the scene. The previous revision
-- cancelled there and the engine refused both kinds:
--     onLoad failed: Lua error: Can't use a disabled object
--     onLoad failed: Lua error: Object has no animation
-- onActive fires once the actor is actually in the scene, which is the only
-- time it has an animation to cancel. A disabled actor gets it when enabled.
--
-- And only for actors that were posed when the game was saved: onSave returns
-- nothing otherwise, so every other actor in the world does no work at all,
-- where the old onLoad issued four cancels on each of them.
local pendingCancel = nil   -- group saved as playing; cancelled on activation

local function onSave()
    if currentGroup then
        return { group = currentGroup }
    end
end

local function onLoad(data)
    throwing      = false
    waiting       = false
    currentGroup  = nil
    pendingCancel = data and data.group or nil
end

local function onActive()
    if not pendingCancel then return end
    anim.cancel(self, pendingCancel)
    pendingCancel = nil
end

return {
    engineHandlers = {
        onUpdate = onUpdate,
        onSave   = onSave,
        onLoad   = onLoad,
        onActive = onActive,
    },
    eventHandlers = {
        ForceChoke_Grab     = onGrab,
        ForceChoke_Drop     = onDrop,
        ForceChoke_Clear    = onClear,
        ForceChoke_Throw    = onThrow,
        ForceChoke_StepDone = onStepDone,
    },
}
