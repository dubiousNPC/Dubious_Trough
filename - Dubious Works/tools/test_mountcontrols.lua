-- test_mountcontrols.lua -- whywalk_mount.lua, the controls-driven controller
--
--   run from "00 Core":  luarun.py tools/test_mountcontrols.lua
--
-- The mount script is the whole movement model since the controls port, so
-- these are the tests that decide whether the mount moves at all. They cover
-- the three things that cannot be seen by reading the file:
--
--   * ORDER. MountStop must clear the controls BEFORE handing AI back, or the
--     last written movement survives into the first AI frame and the creature
--     walks off on its own.
--   * FRAMERATE INDEPENDENCE. yawChange is a per-frame delta, so it has to
--     scale with dt or the turn rate doubles when the framerate does.
--   * THE EDGE. controls.jump held true retriggers forever; it must be one
--     frame only.
--
-- Plus the thing the port exists to fix: the rider's pose follows the
-- creature's ACTUAL speed, so a mount pressed into a wall reads as idle even
-- at full throttle.

local pass, fail = 0, 0
local function check(name, cond, got)
    if cond then
        pass = pass + 1
        print(('  ok   %s'):format(name))
    else
        fail = fail + 1
        print(('  FAIL %s  -> %s'):format(name, tostring(got)))
    end
end

-- --- stubs -----------------------------------------------------------------

-- Every call that changes the creature's state lands here in order, so the
-- tests can assert on sequence and not just final values.
local log = {}

local controls = {}
local function resetControls()
    controls.movement     = nil
    controls.sideMovement = nil
    controls.yawChange    = nil
    controls.pitchChange  = nil
    controls.run          = nil
    controls.sneak        = nil
    controls.jump         = nil
end
resetControls()

-- The engine's own view of the creature, which the tests drive directly.
local engine = { onGround = true, speed = 0, walkSpeed = 100 }

local sentToRider = {}
local rider = {
    isValid = function() return true end,
    sendEvent = function(_, name, data)
        sentToRider[#sentToRider + 1] = { name = name, data = data }
    end,
}

local selfStub
selfStub = {
    controls = controls,
    object = { recordId = 'guar_test' },
    enableAI = function(_, v)
        log[#log + 1] = 'enableAI(' .. tostring(v) .. ')'
    end,
}

package.loaded['openmw.self'] = selfStub
package.loaded['openmw.types'] = {
    Actor = {
        isOnGround      = function() return engine.onGround end,
        getCurrentSpeed = function() return engine.speed end,
        getWalkSpeed    = function() return engine.walkSpeed end,
    },
}
package.loaded['scripts.WhyWalk.whywalk_shared'] = {
    STATE = { IDLE = 'idle', WALK = 'walk', GALLOP = 'gallop',
              REVERSE = 'reverse', JUMP = 'jump' },
    TUNING = { suppressMountAI = true },
}

-- clearControls writes zeros, so record them as a single log entry rather
-- than seven. Wrapping the table is the only way to see WHEN it happened
-- relative to enableAI, which is the ordering test below.
local realControls = controls
local watched = setmetatable({}, {
    __index = realControls,
    __newindex = function(_, k, v)
        if k == 'movement' and v == 0 then log[#log + 1] = 'clearControls' end
        realControls[k] = v
    end,
})
selfStub.controls = watched

local mod = dofile('scripts/WhyWalk/whywalk_mount.lua')
local ev  = mod.eventHandlers
local eh  = mod.engineHandlers

check('registers onUpdate', type(eh.onUpdate) == 'function', type(eh.onUpdate))
check('registers onLoad', type(eh.onLoad) == 'function', type(eh.onLoad))
check('registers the three mount events',
      type(ev.WhyWalk_MountStart) == 'function'
      and type(ev.WhyWalk_MountStop) == 'function'
      and type(ev.WhyWalk_MountControl) == 'function', 'missing one')

-- --- TEST 1: nothing happens before a ride ---------------------------------

eh.onUpdate(1 / 60)
check('onUpdate is inert before MountStart',
      realControls.movement == nil, realControls.movement)

ev.WhyWalk_MountControl({ throttle = 1 })
eh.onUpdate(1 / 60)
check('control events are ignored before MountStart',
      realControls.movement == nil, realControls.movement)

-- --- TEST 2: MountStart disables AI ----------------------------------------

log = {}
ev.WhyWalk_MountStart({ player = rider, turnRate = 2.0 })
check('MountStart disables standard AI',
      log[#log - 0] == 'clearControls' and log[1] == 'enableAI(false)',
      table.concat(log, ', '))
check('MountStart clears the controls after disabling AI',
      log[1] == 'enableAI(false)' and log[2] == 'clearControls',
      table.concat(log, ', '))

-- --- TEST 3: throttle reaches controls.movement ----------------------------

ev.WhyWalk_MountControl({ throttle = 1, steer = 0, gallop = true })
engine.speed = 300
eh.onUpdate(1 / 60)
check('full throttle writes movement = 1', realControls.movement == 1,
      realControls.movement)
check('gallop sets run', realControls.run == true, realControls.run)

ev.WhyWalk_MountControl({ throttle = 0.4, steer = 0, gallop = false })
eh.onUpdate(1 / 60)
check('partial throttle passes through for analog speed',
      math.abs(realControls.movement - 0.4) < 1e-9, realControls.movement)
check('no gallop clears run', realControls.run == false, realControls.run)

-- --- TEST 4: reverse is never a run ---------------------------------------

ev.WhyWalk_MountControl({ throttle = -1, steer = 0, gallop = true })
eh.onUpdate(1 / 60)
check('reverse writes negative movement', realControls.movement == -1,
      realControls.movement)
check('reverse never runs, even with gallop held',
      realControls.run == false, realControls.run)

-- --- TEST 5: yawChange scales with dt ------------------------------------

ev.WhyWalk_MountControl({ throttle = 0, steer = 1, gallop = false })
eh.onUpdate(1 / 60)
local at60 = realControls.yawChange
eh.onUpdate(1 / 30)
local at30 = realControls.yawChange

check('steering turns right for positive steer', at60 > 0, at60)
check('yawChange = steer * turnRate * dt',
      math.abs(at60 - 2.0 * (1 / 60)) < 1e-9, at60)
-- The whole point: half the framerate, twice the per-frame delta, same
-- radians per second.
check('halving the framerate doubles the per-frame delta',
      math.abs(at30 - at60 * 2) < 1e-9, ('%s vs %s'):format(at30, at60))

ev.WhyWalk_MountControl({ throttle = 0, steer = 0, gallop = false })
eh.onUpdate(1 / 60)
check('no steer writes exactly zero yawChange',
      realControls.yawChange == 0, realControls.yawChange)

-- --- TEST 6: jump is a one-frame edge ------------------------------------

ev.WhyWalk_MountControl({ jump = true })
eh.onUpdate(1 / 60)
check('jump reaches controls.jump', realControls.jump == true,
      realControls.jump)
eh.onUpdate(1 / 60)
check('jump is released on the very next frame',
      realControls.jump == false, realControls.jump)
eh.onUpdate(1 / 60)
check('jump stays released without a new request',
      realControls.jump == false, realControls.jump)

-- A jump request must not disturb the throttle: it arrives as its own event
-- with no throttle field, and an earlier version would have zeroed it.
ev.WhyWalk_MountControl({ throttle = 1, steer = 0, gallop = true })
eh.onUpdate(1 / 60)
ev.WhyWalk_MountControl({ jump = true })
eh.onUpdate(1 / 60)
check('a jump request leaves the throttle alone',
      realControls.movement == 1, realControls.movement)

-- --- TEST 7: rider state follows the ENGINE, not the throttle ------------

sentToRider = {}
local function lastState()
    for i = #sentToRider, 1, -1 do
        if sentToRider[i].name == 'WhyWalk_AnimState' then
            return sentToRider[i].data.state
        end
    end
    return nil
end

engine.onGround, engine.speed = true, 0
ev.WhyWalk_MountControl({ throttle = 1, steer = 0, gallop = true })
eh.onUpdate(1 / 60)
check('full throttle against a wall reads as IDLE, not WALK',
      lastState() == 'idle', lastState())

engine.speed = 90
eh.onUpdate(1 / 60)
check('moving below walk speed reads as WALK', lastState() == 'walk',
      lastState())

engine.speed = 400
eh.onUpdate(1 / 60)
check('moving well above walk speed reads as GALLOP',
      lastState() == 'gallop', lastState())

ev.WhyWalk_MountControl({ throttle = -1, steer = 0, gallop = false })
engine.speed = 60
eh.onUpdate(1 / 60)
check('negative throttle while moving reads as REVERSE',
      lastState() == 'reverse', lastState())

engine.onGround = false
eh.onUpdate(1 / 60)
check('off the ground reads as JUMP regardless of speed',
      lastState() == 'jump', lastState())

-- Sent on change only.
engine.onGround, engine.speed = true, 400
ev.WhyWalk_MountControl({ throttle = 1, steer = 0, gallop = true })
eh.onUpdate(1 / 60)
local before = #sentToRider
eh.onUpdate(1 / 60)
eh.onUpdate(1 / 60)
eh.onUpdate(1 / 60)
check('an unchanged state sends nothing', #sentToRider == before,
      ('%d events for 3 idle frames'):format(#sentToRider - before))

-- --- TEST 8: MountStop order --------------------------------------------

log = {}
ev.WhyWalk_MountStop({})
check('MountStop clears the controls BEFORE re-enabling AI',
      log[1] == 'clearControls' and log[2] == 'enableAI(true)',
      table.concat(log, ', '))
check('MountStop leaves movement at zero', realControls.movement == 0,
      realControls.movement)

eh.onUpdate(1 / 60)
realControls.movement = nil
eh.onUpdate(1 / 60)
check('onUpdate is inert again after MountStop',
      realControls.movement == nil, realControls.movement)

-- --- TEST 9: a stranded script restores the creature --------------------

-- addScript persists in the save, so this script can come back attached to a
-- creature nobody is riding -- with AI still off and the last controls still
-- set. onLoad has to undo both or the creature is a statue for the rest of
-- the save.
ev.WhyWalk_MountStart({ player = rider, turnRate = 2.0 })
ev.WhyWalk_MountControl({ throttle = 1, steer = 1, gallop = true })
eh.onUpdate(1 / 60)
check('precondition: the stranded script was driving', realControls.movement == 1,
      realControls.movement)

log = {}
eh.onLoad()
check('onLoad re-enables standard AI',
      log[#log] == 'enableAI(true)', table.concat(log, ', '))
check('onLoad clears the controls', realControls.movement == 0,
      realControls.movement)
realControls.movement = nil
eh.onUpdate(1 / 60)
check('onLoad leaves the script dormant, not riding',
      realControls.movement == nil, realControls.movement)

print(('\n%d passed, %d failed'):format(pass, fail))
if fail > 0 then os.exit(1) end
print('ALL PASS')
