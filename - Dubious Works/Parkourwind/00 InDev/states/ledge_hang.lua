--[[
    states/ledge_hang.lua

    Detection (targetPos/wallNormal/etc) comes from
    core/optional/sensor_ext.lua. The climb-up-to-Mantle handoff still
    writes into core/sensor.lua's Sensor.data, since states/mantle.lua only
    ever reads from there.
]]--

local BaseState = require('states/base_state')
local core = require('openmw.core')
local mwSelf = require('openmw.self')
local types = require('openmw.types')
local util = require('openmw.util')
local I = require('openmw.interfaces')
local nearby = require('openmw.nearby')
local camera = require('openmw.camera')
local Sensor = require('core/sensor')
local SensorExt = require('core/optional/sensor_ext')

local LedgeHangState = BaseState.new("LedgeHang")

-- =============================================================================
-- CONFIGURATION
-- =============================================================================
local LEVITATE_MAG = 200      
local HANG_OFFSET_Z = 125     
local WALL_OFFSET = 35        
local KICK_FORCE_BACK = 350
local KNEE_CHECK_DIST = 60
local CLIMB_COOLDOWN = 0.3    -- [NEW] Time to wait before allowing climb-up

-- =============================================================================
-- INTERNAL STATE
-- =============================================================================
local levitationApplied = false
local wallNormal = nil
local timeInState = 0         -- [NEW] Track how long we've been hanging
local cachedTargetPos = nil   -- [NEW] Store the ledge position

-- =============================================================================
-- HELPERS
-- =============================================================================

local function applyGravityHack(enable)
    local activeEffects = types.Actor.activeEffects(mwSelf)
    if not activeEffects then return end

    if enable then
        if not levitationApplied then
            activeEffects:modify(LEVITATE_MAG, core.magic.EFFECT_TYPE.Levitate)
            levitationApplied = true
        end
    else
        if levitationApplied then
            activeEffects:modify(-LEVITATE_MAG, core.magic.EFFECT_TYPE.Levitate)
            levitationApplied = false
        end
    end
end

local function snapTo(pos, rot)
    core.sendGlobalEvent('FLOW_SnapTo', {
        actor = mwSelf,
        position = pos,
        rotation = rot 
    })
end

-- =============================================================================
-- STATE INTERFACE
-- =============================================================================

function LedgeHangState:enter(syncData)
    print("[FLOW_STATE] >>> ENTERING LEDGE HANG")
    
    local DebugHUD = require('core/debug_hud')
    DebugHUD.update("LedgeHang", SensorExt.data.debugReason, "GRABBED")

    timeInState = 0 -- Reset timer

    -- 1. Suspend Gravity
    applyGravityHack(true)
    
    -- 2. Snap Position & Rotation
    if SensorExt.data.targetPos then
        -- [CRITICAL] Cache the target position so we don't lose it if the sensor misses next frame
        cachedTargetPos = SensorExt.data.targetPos

        local forward = util.transform.rotateZ(mwSelf.rotation:getYaw()):apply(util.vector3(0,1,0))
        wallNormal = SensorExt.data.wallNormal or -forward 
        
        local hangPos = cachedTargetPos - util.vector3(0, 0, HANG_OFFSET_Z)
        hangPos = hangPos + (wallNormal * WALL_OFFSET)
        
        local lookDir = -wallNormal
        local targetYaw = math.atan2(lookDir.x, lookDir.y)
        local targetRot = util.transform.rotateZ(targetYaw)
        
        snapTo(hangPos, targetRot)
    end
    
    -- Animation is owned entirely by playerAnim.lua now (called right
    -- after this enter() returns, via state_manager.lua's setState choke
    -- point) - this used to call anim.playBlended('swimidle', ...)
    -- directly, which raced with playerAnim.lua's own attempt to play
    -- whatever's configured for "LedgeHang" and is exactly why the
    -- configured custom animation wasn't reliably showing. See
    -- playerAnim.lua's GROUPS.LedgeHang entry for the tuning (priority,
    -- blendMask) that used to live here.
    
    I.Controls.overrideMovementControls(true)
    I.Controls.overrideCombatControls(true)
end

function LedgeHangState:exit()
    print("[FLOW_STATE] <<< EXITING LEDGE HANG")
    applyGravityHack(false)
    
    I.Controls.overrideMovementControls(false)
    I.Controls.overrideCombatControls(false)
    
    cachedTargetPos = nil
end

function LedgeHangState:update(dt, syncData, inputData)
    timeInState = timeInState + dt

    -- 1. WALL KICK / JUMP AWAY
    --
    -- [BUGFIX] This MUST be tested before the climb-up below. Both branches
    -- are gated on inputData.jump, and the climb had no directional
    -- condition at all - so once CLIMB_COOLDOWN elapsed it swallowed every
    -- jump press, including jump+back. The kick was unreachable for the
    -- entire life of the hang after the first 0.3s, and KICK_FORCE_BACK sat
    -- as a dead constant. Checking the more specific condition first
    -- restores it.
    if inputData.jump and inputData.moveVector.y < 0 then
        local kneePos = mwSelf.position + util.vector3(0,0, 30)
        local forward = util.transform.rotateZ(mwSelf.rotation:getYaw()):apply(util.vector3(0,1,0))
        local kickTarget = kneePos + (forward * KNEE_CHECK_DIST)
        
        local res = nearby.castRay(kneePos, kickTarget, { ignore = mwSelf })
        
        if res.hit then
            local nudge = mwSelf.position + (-forward * (KICK_FORCE_BACK * 0.15)) + (util.vector3(0,0,20))
            snapTo(nudge)
            return "Airborne"
        else
            return "Airborne"
        end
    end

    -- 2. CLIMB UP (Mantle) - any jump press that isn't a deliberate
    -- kick-away, once the entry cooldown has elapsed.
    if inputData.jump and timeInState > CLIMB_COOLDOWN then

        -- [CRITICAL] Restore the cached target position into the Sensor data
        -- This ensures Mantle receives the valid ledge position even if the sensor missed this frame.
        Sensor.data.interaction = "Mantle"
        Sensor.data.targetPos = cachedTargetPos  -- core Sensor, so mantle.lua picks it up

        return "Mantle"
    end

    -- 3. DROP
    if inputData.crouch then
        local forward = util.transform.rotateZ(mwSelf.rotation:getYaw()):apply(util.vector3(0,1,0))
        local nudge = mwSelf.position + (-forward * 20) 
        snapTo(nudge)
        return "Airborne"
    end

    return nil
end

return LedgeHangState