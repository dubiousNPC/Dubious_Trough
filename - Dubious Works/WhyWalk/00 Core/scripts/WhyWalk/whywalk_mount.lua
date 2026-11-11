---@omw-context local
--[[
    whywalk_mount.lua -- the mount controller

    PER-FRAME COST

    One `onUpdate`, attached only while this creature is ridden, whose first
    statement returns when it is not. While riding it performs five field
    assignments and no allocation, no API calls, no queries. The controls have
    to be restated each frame -- that is how the engine consumes them -- and
    this is the floor for a driven actor. It replaces: nine raycasts, two
    teleports, a heightmap query and a hand-integrated gravity step, per frame.

    ATTACHMENT

    Registered CUSTOM, attached with addScript on mount and removed on
    dismount, so an unridden creature carries no code at all.
]]

local self   = require('openmw.self')
local types  = require('openmw.types')
local shared = require('scripts.WhyWalk.whywalk_shared')

local STATE = shared.STATE

local SUPPRESS_AI = shared.TUNING.suppressMountAI ~= false

local EV_START   = 'WhyWalk_MountStart'
local EV_STOP    = 'WhyWalk_MountStop'
local EV_CONTROL = 'WhyWalk_MountControl'

local EV_ANIM_STATE = 'WhyWalk_AnimState'

local mounted  = false
local throttle = 0        -- -1..1, forward positive
local steer    = 0        -- -1..1, right positive
local gallop   = false
local turnRate = 2.6      -- radians/sec at full steer, from the mount profile

local jumpPending = false

local rider = nil
local lastState = nil

local function clearControls()
    local c = self.controls
    c.movement     = 0
    c.sideMovement = 0
    c.yawChange    = 0
    c.pitchChange  = 0
    c.run          = false
    c.sneak        = false
    c.jump         = false
end

-- ---------------------------------------------------------------------------
-- RIDER STATE
-- ---------------------------------------------------------------------------
local IDLE_SPEED_EPSILON = 5     -- units/sec; below this the mount is standing

local function currentState()
    -- Airborne first: a jumping or falling mount is neither walking nor idle.
    if not types.Actor.isOnGround(self) then return STATE.JUMP end

    local speed = types.Actor.getCurrentSpeed(self)
    if not speed or speed < IDLE_SPEED_EPSILON then return STATE.IDLE end

    if throttle < 0 then return STATE.REVERSE end

    local walk = types.Actor.getWalkSpeed(self)
    if walk and speed > walk * 1.15 then return STATE.GALLOP end
    return STATE.WALK
end

local function reportState()
    if not rider or not rider:isValid() then return end
    local st = currentState()
    if st == lastState then return end
    lastState = st
    rider:sendEvent(EV_ANIM_STATE, { state = st })
end

-- ---------------------------------------------------------------------------
-- EVENTS
-- ---------------------------------------------------------------------------

local function onMountStart(data)
    mounted  = true
    throttle, steer, gallop = 0, 0, false
    jumpPending = false
    rider    = data and data.player
    lastState = nil
    turnRate = (data and tonumber(data.turnRate)) or turnRate

    if SUPPRESS_AI then self:enableAI(false) end
    clearControls()
end

local function onMountStop()
    mounted = false
    throttle, steer, gallop = 0, 0, false
    jumpPending = false
    rider, lastState = nil, nil

    clearControls()
    if SUPPRESS_AI then self:enableAI(true) end
end

local function onMountControl(data)
    if not mounted or type(data) ~= 'table' then return end

    if data.jump then
        jumpPending = true
        return
    end

    throttle = tonumber(data.throttle) or 0
    steer    = tonumber(data.steer) or 0
    gallop   = data.gallop == true
end

-- ---------------------------------------------------------------------------
-- THE PER-FRAME HANDLER
-- ---------------------------------------------------------------------------

local function onUpdate(dt)
    if not mounted then return end
    if dt <= 0 then return end

    local c = self.controls

    c.movement = throttle

    c.run = gallop and throttle > 0

    c.yawChange = steer ~= 0 and (steer * turnRate * dt) or 0

    if jumpPending then
        c.jump = true
        jumpPending = false
    else
        c.jump = false
    end

    reportState()
end

-- ---------------------------------------------------------------------------
-- SAVE / LOAD
-- ---------------------------------------------------------------------------

local function onLoad()
    mounted = false
    throttle, steer, gallop = 0, 0, false
    jumpPending = false
    rider, lastState = nil, nil
    clearControls()
    self:enableAI(true)
end

return {
    eventHandlers = {
        [EV_START]   = onMountStart,
        [EV_STOP]    = onMountStop,
        [EV_CONTROL] = onMountControl,
    },
    engineHandlers = {
        onUpdate = onUpdate,
        onLoad   = onLoad,
    },
}
