---@omw-context player
--[[
    states/sprint.lua

    The performance controller for the rest of the mod. No gameplay
    features of its own - no FOV warp, radial blur, headbob override,
    fatigue drain, Athletics skill progression, or speed-attribute buff.
    Just the state-machine skeleton (grounded/forward/fatigue gate,
    Vault/Mantle handoff, Airborne/Idle transitions) plus the one thing
    that actually matters for performance: main.lua only runs the full
    pipeline (Sensor raycasts, SensorExt's LedgeHang fallback,
    StateManager.update) at full rate while the active state is anything
    OTHER than Idle - which includes this state. So holding the Sprint
    hotkey (bound via the "activateInput" setting, same dedicated,
    user-configurable key as before - not tied to the base game's Always
    Run) is what keeps FLOW running at full rate; release it while
    grounded and FLOW drops back to a throttled tick until you press it
    (or jump toward something) again. See main.lua's IDLE_THROTTLE_INTERVAL.

    Also fixes a real bug from an earlier version: the Vault check used
    to be `if inputData.jump or isSprinting then return "Vault" end` -
    since isSprinting is already true for the whole time you're in this
    state, ANY false-positive Sensor reading (e.g. the camera-aimed
    SharedRay clipping a terrain bump while looking down and running)
    would force a Vault transition immediately, every frame, with no jump
    needed - freezing movement via overrideMovementControls while vanilla
    jump/run animation kept playing. It's gated on an actual jump press now,
    matching Idle and Airborne.
]]--

local BaseState = require('states/base_state')
local types = require('openmw.types')
local mwSelf = require('openmw.self')
local Sensor = require('core/sensor')

local SprintState = BaseState.new("Sprint")

function SprintState:enter(syncData)
end

function SprintState:exit()
    mwSelf.controls.run = false
end

function SprintState:update(dt, syncData, inputData)
    local currentFatigue = types.Actor.stats.dynamic.fatigue(mwSelf).current
    local isMovingForward = inputData.moveVector.y > 0
    local isSprintHeld = inputData.sprint
    local hasFatigue = currentFatigue > 0

    local isSprinting = isSprintHeld and isMovingForward and hasFatigue

    -- 1. Parkour Transitions (jump-gated, not sprint-gated - see header note)
    if inputData.jump then
        if Sensor.data.interaction == "Vault" then
            return "Vault"
        end
        if Sensor.data.interaction == "Mantle" then
            return "Mantle"
        end
    end

    -- 2. Basic run flag (no speed buff, no visuals, no fatigue drain)
    mwSelf.controls.run = isSprinting

    -- 3. Jump/Fall Transitions
    if not syncData.isGrounded then
        return "Airborne"
    end

    if not isSprinting then
        return "Idle"
    end

    return nil
end

return SprintState
