--- START OF FILE core/input.lua ---

local input = require('openmw.input')
local self = require('openmw.self')
local util = require('openmw.util')
local I = require('openmw.interfaces')

-- Register the Sprint Action
input.registerAction {
    key = "FLOW_Sprint",
    l10n = "FLOW_AMF",
    name = "activateInput_name",
    defaultValue = false,
    type = input.ACTION_TYPE.Boolean
}

local InputManager = {
    intents = {
        moveVector = util.vector2(0, 0),
        jump = false,
        sprint = false,
        crouch = false,
        interact = false,
        -- Edge-triggered (true only on the frame the level signal goes
        -- false->true). Sole consumer is main.lua's idle-throttle bypass, so
        -- a keypress never waits out the throttle interval. Roll's tap
        -- detection used to live here too, but moved to a proper engine
        -- trigger handler in states/airborne.lua - polled edges could drop a
        -- tap completed inside a single frame.
        jumpPressed = false,
        sprintPressed = false
    }
}

local wasJumpHeld = false
local wasSprintHeld = false

function InputManager.update()
    -- UI Lock Check
    if I.UI.getMode() ~= nil then
        InputManager.reset()
        return
    end

    -- Movement Vector
    InputManager.intents.moveVector = util.vector2(
        self.controls.sideMovement,
        self.controls.movement
    )

    -- Actions
    local jumpHeld = input.isActionPressed(input.ACTION.Jump)
    local sprintHeld = input.getBooleanActionValue("FLOW_Sprint")

    InputManager.intents.jump = jumpHeld
    InputManager.intents.crouch = input.isActionPressed(input.ACTION.Sneak)
    InputManager.intents.interact = input.isActionPressed(input.ACTION.Activate)
    InputManager.intents.sprint = sprintHeld

    InputManager.intents.jumpPressed = jumpHeld and not wasJumpHeld
    InputManager.intents.sprintPressed = sprintHeld and not wasSprintHeld

    wasJumpHeld = jumpHeld
    wasSprintHeld = sprintHeld
end

function InputManager.reset()
    InputManager.intents.moveVector = util.vector2(0, 0)
    InputManager.intents.jump = false
    InputManager.intents.sprint = false
    InputManager.intents.crouch = false
    InputManager.intents.interact = false
    InputManager.intents.jumpPressed = false
    InputManager.intents.sprintPressed = false
    wasJumpHeld = false
    wasSprintHeld = false
end

return InputManager
