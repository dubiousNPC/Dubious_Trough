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
local stepDt       = 0
local settling      = false
local settleElapsed = 0

local COLLISION = util.bitOr(
    nearby.COLLISION_TYPE.World,
    nearby.COLLISION_TYPE.HeightMap,
    nearby.COLLISION_TYPE.Door
)

-- ============================================================
-- ANIMATION
-- ============================================================
local function playPose(group, looping)
    if currentGroup == group then return end

    if currentGroup then
        anim.cancel(self, currentGroup)
    end

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
local function requestDetach()
    core.sendGlobalEvent('ForceChoke_Detach', { actor = self.object })
end

local function beginSettle()
    settling      = true
    settleElapsed = 0
end

local function onGrab()
    throwing = false
    waiting  = false
    settling = false   -- re-grabbed mid-settle: this actor is in use again
    playPose(S.GROUPS.HOLD, true)
end

local function onDrop()
    throwing = false
    waiting  = false
    playPose(S.GROUPS.DROP, false)
    beginSettle()
end

local function onClear()
    throwing = false
    waiting  = false
    settling = false
    clearPose()
    -- Nothing is playing any more, so there is nothing to wait for.
    requestDetach()
end

local function onThrow(data)
    if not data or not data.dir then return end

    local dir = data.dir
    local mag = data.magnitude or T.throwSpeed

    vx = dir.x * mag
    vy = dir.y * mag
    vz = math.abs(dir.z * mag) + mag * T.throwVerticalFactor

    -- Random tumble direction, so thrown actors do not all spin the same way.
    if math.random() > 0.5 then
        spin = (0.4 + math.random() * 0.3) * 30   -- rad/s (was rad/step)
    else
        spin = (-0.4 - math.random() * 0.3) * 30
    end

    bounces  = 0
    elapsed  = 0
    stepDt   = 0
    throwing = true
    waiting  = false

    playPose(S.GROUPS.FLY, true)
end

--- Landing or release damage, sent by global.lua.
local function onDamage(data)
    if data.fatigue then
        local f = types.Actor.stats.dynamic.fatigue(self)
        f.current = math.max(0, f.current - data.fatigue)
    end
    if data.health then
        local h = types.Actor.stats.dynamic.health(self)
        h.current = h.current - data.health
    end
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
    beginSettle()
end

-- ============================================================
-- PER-FRAME (throw only)
-- ============================================================
local function onUpdate(dt)
    if core.isWorldPaused() then return end
    dt = dt or 0

    if settling then
        settleElapsed = settleElapsed + dt
        if settleElapsed >= T.dropSettleGrace
           and (not anim.isPlaying(self, S.GROUPS.DROP)
                or settleElapsed > T.dropSettleTimeout) then
            settling = false
            currentGroup = nil
            requestDetach()
        end
        return
    end

    if not throwing then return end

    elapsed = elapsed + dt
    if elapsed > T.throwMaxSeconds then
        land()
        return
    end

    stepDt = stepDt + dt
    if waiting then return end

    local h = stepDt
    stepDt = 0
    if h <= 0 then return end
    if h > T.throwMaxStep then h = T.throwMaxStep end

    if types.Actor.stats.dynamic.health(self).current <= 0 then
        throwing = false
        waiting  = false
        clearPose()
        core.sendGlobalEvent('ForceChoke_Landed', { actor = self.object, died = true })
        requestDetach()
        return
    end

    -- Horizontal drag, per second
    local drag = T.throwFriction * h
    if vx > 0 then vx = math.max(0, vx - drag)
    elseif vx < 0 then vx = math.min(0, vx + drag) end
    if vy > 0 then vy = math.max(0, vy - drag)
    elseif vy < 0 then vy = math.min(0, vy + drag) end

    local spinDrag = T.throwSpinDecay * h
    if spin > 0 then spin = math.max(0, spin - spinDrag)
    elseif spin < 0 then spin = math.min(0, spin + spinDrag) end

    vz = vz - T.throwGravity * h
    if vz < -T.throwMaxFallSpeed then vz = -T.throwMaxFallSpeed end

    local box = self:getBoundingBox()
    local step = util.vector3(vx, vy, vz) * h

    -- Nearly stationary and close to the floor: landed.
    if util.vector3(vx, vy, vz):length() < T.throwRestSpeed then
        local down = nearby.castRay(box.center, box.center + util.vector3(0, 0, -500), {
            collisionType = COLLISION,
            radius        = T.throwRayRadius,
        })
        if down.hit and math.abs(down.hitPos.z - self.position.z) < T.throwRayRadius * 2 then
            land()
            return
        end
    end

    -- Three steps of lookahead, so a bounce is seen before it is reached.
    local res = nearby.castRay(box.center, box.center + step * 3, {
        collisionType = COLLISION,
        radius        = T.throwRayRadius,
    })

    if res.hit and res.hitNormal then
        bounces = bounces + 1
        local n = res.hitNormal
        local dot = vx * n.x + vy * n.y + vz * n.z
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
        nextPos  = self.position + step,
        rotation = util.transform.rotateZ(self.rotation:getYaw() + spin * h),
    })
    waiting = true
end

-- ============================================================
-- SAVE / LOAD
-- ============================================================
local pendingCancel = nil   -- group saved as playing; cancelled on activation

local function onInit(data)
    if data and data.grab then
        onGrab()
    end
end

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
    requestDetach()
end

return {
    engineHandlers = {
        onInit   = onInit,
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
        ForceChoke_Damage   = onDamage,
    },
}
