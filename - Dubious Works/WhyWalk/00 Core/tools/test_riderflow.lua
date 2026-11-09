-- whywalk_player and Parkourwind FLOW: a rider is placed every frame and never
-- grounded, so FLOW is stood down for the ride, yielding BEFORE the control
-- lock is taken (the override flag is shared and FLOW releases its own hold
-- as it stands down) and resumed after the lock is released.
--   python3 -I tools/luarun.py tools/test_riderflow.lua
package.path = './?.lua;' .. package.path

local passed, failed = 0, 0
local function check(name, ok, got)
    if ok then passed = passed + 1; print('  ok   ' .. name)
    else failed = failed + 1; print('  FAIL ' .. name .. '  -> ' .. tostring(got)) end
end

local log, owners = {}, {}
local any = setmetatable({}, { __index = function(t, k) return k end })
local section = { get = function() return nil end, subscribe = function() end, set = function() end }

local effects = 0
package.loaded['openmw.self'] = {
    object = { sendEvent = function() end, recordId = 'player' },
    position = { x = 0, y = 0, z = 0 },
    cell = { isExterior = true },
}
local globalEvents, triggers = {}, {}
package.loaded['openmw.core'] = {
    sendGlobalEvent = function(name, data) globalEvents[#globalEvents + 1] = { name = name, data = data } end,
    magic = { EFFECT_TYPE = any },
    l10n = function() return function(k) return k end end,
}
package.loaded['openmw.input'] = {
    registerTriggerHandler = function(name, cb) triggers[name] = cb end,
    registerActionHandler = function() end,
    isShiftPressed = function() return false end,
    isActionPressed = function() return false end,
    ACTION = any,
}
package.loaded['openmw.types'] = { Actor = { activeEffects = function() return {
    modify = function(_, v) effects = effects + v end } end } }
package.loaded['openmw.async'] = { callback = function(_, f) return f end }
package.loaded['openmw.ui'] = { showMessage = function() end }
package.loaded['openmw.storage'] = { playerSection = function() return section end }
package.loaded['openmw.nearby'] = { castRay = function() return { hit = false } end }
package.loaded['openmw.camera'] = {}
package.loaded['openmw.util'] = { vector3 = function(x, y, z) return { x = x, y = y, z = z } end }
package.loaded['openmw.interfaces'] = {
    Controls = { overrideMovementControls = function(v) log[#log + 1] = 'override ' .. tostring(v) end },
    UI = { isHudVisible = function() return true end },
    Settings = { registerPage = function() end, registerGroup = function() end },
    Flow = {
        yield = function(o) owners[o] = true; log[#log + 1] = 'yield' end,
        resume = function(o) owners[o] = nil; log[#log + 1] = 'resume' end,
    },
}

local P = assert(loadfile('scripts/WhyWalk/whywalk_player.lua'))()
local ev = P.eventHandlers

local function seq() return table.concat(log, ', ') end
local function before(a, b)
    local ia, ib
    for i, e in ipairs(log) do
        if e == a and not ia then ia = i end
        if e == b and not ib then ib = i end
    end
    return ia and ib and ia < ib
end

ev.WhyWalk_Mounted({ mountType = 'guar', freeRide = true })
check('mounting yields FLOW', owners['WhyWalk.Core'] == true, seq())
check('and yields before taking the control lock', before('yield', 'override true'), seq())

log = {}
ev.WhyWalk_Dismounted({})
check('dismounting resumes FLOW', owners['WhyWalk.Core'] == nil, seq())
check('after releasing the lock', before('override false', 'resume'), seq())
check('levitation balanced across the ride', effects == 0, effects)

ev.WhyWalk_Mounted({ mountType = 'guar', freeRide = true })
P.engineHandlers.onLoad({ controlsLocked = true, levitationAdded = true })
check('a load resumes FLOW', owners['WhyWalk.Core'] == nil, seq())

-- The mount's jump is the Jump action. Space is Activate in Morrowind's
-- default bindings, and a literal-Space jump dismounted the rider in-engine.
local function sent(name, field)
    for _, e in ipairs(globalEvents) do
        if e.name == name and (not field or e.data[field]) then return true end
    end
    return false
end
ev.WhyWalk_Mounted({ mountType = 'guar', freeRide = true })
globalEvents = {}
check('a Jump trigger handler is registered', triggers.Jump ~= nil)
if triggers.Jump then triggers.Jump() end
check('Jump while mounted asks the mount to jump', sent('WhyWalk_Control', 'jump'))
check('and does not dismount', not sent('WhyWalk_RequestDismount'))
globalEvents = {}
P.engineHandlers.onKeyPress({ symbol = 'space' })
check('the literal Space key no longer sends a jump', not sent('WhyWalk_Control', 'jump'))
ev.WhyWalk_Dismounted({})
globalEvents = {}
if triggers.Jump then triggers.Jump() end
check('Jump while not mounted sends nothing', #globalEvents == 0, #globalEvents)

-- Without FLOW installed nothing changes and nothing throws.
package.loaded['openmw.interfaces'].Flow = nil
local ok, err = pcall(function()
    ev.WhyWalk_Mounted({ mountType = 'guar', freeRide = true })
    ev.WhyWalk_Dismounted({})
end)
check('no FLOW installed: a ride still works', ok, err)

print(string.format('%d passed, %d failed', passed, failed))
if failed > 0 then error('tests failed') end
