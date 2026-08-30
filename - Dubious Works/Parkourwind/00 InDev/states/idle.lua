local BaseState = require('states/base_state')
local types = require('openmw.types')
local mwSelf = require('openmw.self')
local Sensor = require('core/sensor')
local VaultState = require('states/vault')
local MantleState = require('states/mantle')

local IdleState = BaseState.new("Idle")

function IdleState:update(dt, syncData, inputData)
    -- 1. To Airborne
    if not syncData.isGrounded then
        return "Airborne"
    end

    -- 2. Obstacle Handling (Jump Pressed)
    if inputData.jump then
        local fat = types.Actor.stats.dynamic.fatigue(mwSelf).current

        if Sensor.data.interaction == "Vault" and not VaultState.isBlocked() then
            if fat > 5 then return "Vault" end
        elseif Sensor.data.interaction == "Mantle" and not MantleState.isBlocked() then
            if fat > 10 then return "Mantle" end
        end
    end

    return nil
end

return IdleState
