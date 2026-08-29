--- START OF FILE core/input.lua ---

local input = require('openmw.input')
local self = require('openmw.self')
local util = require('openmw.util')
local I = require('openmw.interfaces')

local Settings = require('settings')

-- =============================================================================
-- SPRINT BINDING - RAW KEYCODE, NOT input.registerAction
--
-- This previously used input.registerAction/getBooleanActionValue. That path
-- shares the ENGINE'S action-binding registry across every mod that uses it,
-- and collisions there are observed rather than theoretical: AcrobaticsEnhanced
-- documents refusing the same API after confirming a clash with Character
-- Panel, and deliberately reads a raw key code from its own settings instead.
--
-- FLOW now does the same. The binding lives in FLOW's own storage section, so
-- nothing is published into the shared registry and no other mod can be
-- displaced by (or displace) it.
-- =============================================================================
local function sprintKeyCode()
    local v = Settings.sprintKeyCode()
    if type(v) == 'number' then return v end
    return input.KEY.LeftAlt
end

local sprintDown = false

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

    -- Movement Vector.
    --
    -- [BUGFIX] Read from the raw ACTIONS, not self.controls. Once a state
    -- calls I.Controls.overrideMovementControls(true) the engine stops
    -- writing player input into self.controls - the script owns those fields
    -- from then on - so self.controls.sideMovement/movement read back as
    -- whatever the script last wrote, i.e. 0.
    --
    -- LedgeHang overrides movement controls on enter(), which meant
    -- moveVector was pinned at (0,0) for the entire hang. That silently
    -- disabled every directional branch in that state: Shimmy (moveVector.x)
    -- never fired at all and never reached the log, and the wall-kick
    -- (moveVector.y < 0) was equally dead. Action state is unaffected by the
    -- control override, so it stays correct throughout.
    local mx, my = 0, 0
    if input.isActionPressed(input.ACTION.MoveRight) then mx = mx + 1 end
    if input.isActionPressed(input.ACTION.MoveLeft) then mx = mx - 1 end
    if input.isActionPressed(input.ACTION.MoveForward) then my = my + 1 end
    if input.isActionPressed(input.ACTION.MoveBackward) then my = my - 1 end
    InputManager.intents.moveVector = util.vector2(mx, my)

    -- Actions
    local jumpHeld = input.isActionPressed(input.ACTION.Jump)
    local sprintHeld = sprintDown

    InputManager.intents.jump = jumpHeld
    InputManager.intents.crouch = input.isActionPressed(input.ACTION.Sneak)
    InputManager.intents.interact = input.isActionPressed(input.ACTION.Activate)
    InputManager.intents.sprint = sprintHeld

    InputManager.intents.jumpPressed = jumpHeld and not wasJumpHeld
    InputManager.intents.sprintPressed = sprintHeld and not wasSprintHeld

    wasJumpHeld = jumpHeld
    wasSprintHeld = sprintHeld
end

-- Key state is tracked from the engine's key events rather than polled, so a
-- rebind applies immediately and costs nothing per frame. Wired to
-- engineHandlers in main.lua.
function InputManager.onKeyPress(key)
    if key.code == sprintKeyCode() then sprintDown = true end
end

function InputManager.onKeyRelease(key)
    if key.code == sprintKeyCode() then sprintDown = false end
end

function InputManager.reset()
    InputManager.intents.moveVector = util.vector2(0, 0)
    InputManager.intents.jump = false
    InputManager.intents.sprint = false
    InputManager.intents.crouch = false
    InputManager.intents.interact = false
    sprintDown = false
    InputManager.intents.jumpPressed = false
    InputManager.intents.sprintPressed = false
    wasJumpHeld = false
    wasSprintHeld = false
end

return InputManager
