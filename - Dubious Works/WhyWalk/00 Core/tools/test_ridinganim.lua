-- Behavioural test for ridingAnim.lua's state machine.
--
-- Per RESEARCH.md 4.1, the mock asserts the contract the engine enforces
-- rather than accepting anything: playBlendedAnimation records what was
-- played, and the test checks the POSE THE RIDER IS ACTUALLY IN, not merely
-- that no error was raised.

-- Run from "00 Core":  python3 tools/luarun.py tools/test_ridinganim.lua
-- (SCRIPT_PATH used to be required from the caller; luarun never set it, so
-- this test could not run at all.)
SCRIPT_PATH = SCRIPT_PATH or 'scripts/WhyWalk/ridingAnim.lua'
package.path = './?.lua;' .. package.path

local log = {}
local timers = {}          -- pending async timers, fired manually
local textKeyHandlers = {} -- group -> { fn, ... }
local endedHandlers = {}

local function reset() log, timers = {}, {} end

-- --- mock modules ---------------------------------------------------------
local playing = nil        -- the group the engine currently considers active
local clock = 0            -- simulation time, advanced by the vessel tests
local skeletonGroups = {   -- what animation.hasGroup answers
    idle = true, gondola1 = true, gondolar = true, gondolal = true,
    rideh1 = true, rideh2 = true, rideh3 = true, rideh4 = true, rideh5 = true,
    -- xRowing1.kf. rowingl is the segment that shipped misnamed as a second
    -- rowingr and was renamed in place; it being here is the point.
    rowingidle = true, rowing1 = true, rowslow = true,
    rowingl = true, rowingr = true,
}
local textKeys = {         -- "group: key" -> time, as in xGondola1.kf (fixed)
    ['gondola1: start'] = 0, ['gondola1: loop start'] = 0.5,
    ['gondola1: loop stop'] = 4.167, ['gondola1: stop'] = 4.333,
    ['gondolar: start'] = 4.5, ['gondolar: loop start'] = 4.833,
    ['gondolar: loop stop'] = 5.667, ['gondolar: stop'] = 6.0,
    ['gondolal: start'] = 6.333, ['gondolal: loop start'] = 6.667,
    ['gondolal: loop stop'] = 7.5, ['gondolal: stop'] = 7.833,
    ['idle: start'] = 0, ['idle: stop'] = 2,
    -- Real times, read out of the shipped clip with the key dumper. Note
    -- rowingidle has NO loop pair, so it must fall back to start/stop.
    ['rowingidle: start'] = 0, ['rowingidle: stop'] = 2.833,
    ['rowing1: start'] = 3.667, ['rowing1: loop start'] = 4.167,
    ['rowing1: loop stop'] = 9.833, ['rowing1: stop'] = 10.533,
    ['rowingr: start'] = 10.833, ['rowingr: loop start'] = 11.7,
    ['rowingr: loop stop'] = 13.0, ['rowingr: stop'] = 13.7,
    ['rowingl: start'] = 13.733, ['rowingl: loop start'] = 14.5,
    ['rowingl: loop stop'] = 15.833, ['rowingl: stop'] = 16.333,
    ['rowslow: start'] = 16.667, ['rowslow: loop start'] = 17.467,
    ['rowslow: loop stop'] = 18.8, ['rowslow: stop'] = 19.3,
}
local lastOpts = nil

package.loaded['openmw.self'] = { object = {} }
package.loaded['openmw.animation'] = {
    BONE_GROUP = { LowerBody = 1, Torso = 2, LeftArm = 3, RightArm = 4 },
    BLEND_MASK = { LowerBody = 1, Torso = 2, LeftArm = 4, RightArm = 8, All = 15 },
    PRIORITY   = { Default = 0, Movement = 5, Hit = 6, Weapon = 7, Scripted = 13 },
    hasGroup = function(_, g) return skeletonGroups[g] == true end,
    getTextKeyTime = function(_, text) return textKeys[text] end,
    cancel = function(_, g)
        log[#log+1] = 'cancel:' .. tostring(g)
        if playing == g then playing = nil end
    end,
    isPlaying = function(_, g) return playing == g end,
}
package.loaded['openmw.core'] = { getSimulationTime = function() return clock end }
package.loaded['openmw.camera'] = {
    MODE = { FirstPerson = 0, ThirdPerson = 1 },
    getMode = function() return 1 end,
    setFirstPersonOffset = function() end,
    setFocalPreferredOffset = function() end,
}
package.loaded['openmw.util'] = {
    vector2 = function(a,b) return {x=a,y=b} end,
    vector3 = function(a,b,c) return {x=a,y=b,z=c} end,
}
package.loaded['openmw.storage'] = {
    playerSection = function()
        return { get = function(_, k)
                     if k == 'CAMERA_OFFSET_ENABLED' then return true end
                     return 0
                 end,
                 subscribe = function() end }
    end,
}
package.loaded['openmw.async'] = {
    callback = function(f) return f end,
    newUnsavableSimulationTimer = function(_, delay, fn)
        timers[#timers+1] = fn
    end,
}
-- async is used as `async:newUnsavableSimulationTimer(d, fn)` -> colon call
-- passes self, which the shim above absorbs as the first arg.

package.loaded['openmw.interfaces'] = {
    Settings = { registerPage = function() end, registerGroup = function() end },
    Camera = {},
    AnimRefresh = nil,
    AnimationController = {
        playBlendedAnimation = function(group, opts)
            assert(type(group) == 'string' and group ~= '',
                   'playBlendedAnimation needs a group name')
            assert(opts.startKey and opts.stopKey,
                   'ride clips are keyed: startKey/stopKey required')
            log[#log+1] = 'play:' .. group
            playing, lastOpts = group, opts
        end,
        addTextKeyHandler = function(group, fn)
            textKeyHandlers[group] = textKeyHandlers[group] or {}
            table.insert(textKeyHandlers[group], fn)
        end,
        addAnimationEndedHandler = function(fn)
            endedHandlers[#endedHandlers+1] = fn
        end,
    },
}

-- The rider tables are stubbed so the state machine is tested in isolation;
-- the vessel stances are the REAL ones, so a typo there fails here.
local realShared = dofile('scripts/WhyWalk/whywalk_shared.lua')
package.loaded['scripts.WhyWalk.whywalk_shared'] = {
    VESSEL_STANCE = realShared.VESSEL_STANCE,
    VESSEL_KEY_CANDIDATES = realShared.VESSEL_KEY_CANDIDATES,
    VESSEL_TUNING = realShared.VESSEL_TUNING,
    buildVesselLayer = realShared.buildVesselLayer,
    vesselField = realShared.vesselField,
    resolveVesselGroup = realShared.resolveVesselGroup,
    STATE = { IDLE='idle', WALK='walk', GALLOP='gallop', REVERSE='reverse', JUMP='jump' },
    resolveAnim = function(_, state)
        local m = { idle='rideh1', walk='rideh2', gallop='rideh3',
                    reverse='rideh4', jump='rideh5' }
        return m[state]
    end,
    allJumpGroups = function() return { 'rideh5' } end,
}

-- --- load the controller --------------------------------------------------
local mod = dofile(SCRIPT_PATH)
local ev  = mod.eventHandlers

local function fireTimers()
    local t = timers; timers = {}
    for _, fn in ipairs(t) do fn() end
end
local function fireTextKey(group, key)
    for _, fn in ipairs(textKeyHandlers[group] or {}) do fn(group, key) end
end

local failures = 0
local function check(name, cond, extra)
    if cond then print('  ok   ' .. name)
    else print('  FAIL ' .. name .. (extra and ('  [' .. extra .. ']') or '')); failures = failures + 1 end
end

-- === TEST 1: the stranded-gallop bug =====================================
-- gallop -> jump -> (land, GALLOP arrives while jump still owns the pose)
-- -> jump clip ends. Rider must end up galloping, not idle.
reset()
ev.WhyWalk_AnimMounted({ mountType = 'horse' })
fireTimers()                                   -- MOUNT_SETTLE -> idle pose
ev.WhyWalk_AnimState({ state = 'gallop' })
check('gallop pose issued', playing == 'rideh3', tostring(playing))

ev.WhyWalk_AnimState({ state = 'jump' })
check('jump pose issued', playing == 'rideh5', tostring(playing))

-- Landing: global sends GALLOP while the jump one-shot still owns the pose.
ev.WhyWalk_AnimState({ state = 'gallop' })
-- Now the jump clip finishes.
fireTextKey('rideh5', 'stop')
check('returns to GALLOP after jump, not idle', playing == 'rideh3', tostring(playing))

-- === TEST 2: missing jump clip must not strand the rider ==================
reset()
package.loaded['scripts.WhyWalk.whywalk_shared'].resolveAnim = function(_, state)
    if state == 'jump' then return 'rideh5_missing' end
    local m = { idle='rideh1', walk='rideh2', gallop='rideh3', reverse='rideh4' }
    return m[state]
end
ev.WhyWalk_AnimDismounted()
ev.WhyWalk_AnimMounted({ mountType = 'horse' })
fireTimers()
ev.WhyWalk_AnimState({ state = 'walk' })
ev.WhyWalk_AnimState({ state = 'jump' })
-- The clip name resolves but the skeleton has no such group: no text key ever
-- fires. Only the timeout can rescue this.
fireTimers()                                   -- ONE_SHOT_TIMEOUT
check('timeout resumes locomotion when jump clip never ends',
      playing == 'rideh2', tostring(playing))

-- state changes are accepted again afterwards
ev.WhyWalk_AnimState({ state = 'gallop' })
check('state events accepted after timeout recovery',
      playing == 'rideh3', tostring(playing))

-- === TEST 3: dismount cancels a pending one-shot ==========================
reset()
package.loaded['scripts.WhyWalk.whywalk_shared'].resolveAnim = function(_, state)
    local m = { idle='rideh1', walk='rideh2', gallop='rideh3',
                reverse='rideh4', jump='rideh5' }
    return m[state]
end
ev.WhyWalk_AnimDismounted()
ev.WhyWalk_AnimMounted({ mountType = 'horse' })
fireTimers()
ev.WhyWalk_AnimState({ state = 'gallop' })
ev.WhyWalk_AnimState({ state = 'jump' })
ev.WhyWalk_AnimDismounted()
local afterDismount = playing
fireTextKey('rideh5', 'stop')                  -- late stop key
fireTimers()                                   -- late timeout
check('late one-shot completion does not re-pose after dismount',
      playing == afterDismount and playing == nil, tostring(playing))

-- === TEST 4: no handler accumulation across repeated jumps ===============
reset()
ev.WhyWalk_AnimMounted({ mountType = 'horse' })
fireTimers()
local before = #endedHandlers
for _ = 1, 20 do
    ev.WhyWalk_AnimState({ state = 'walk' })
    ev.WhyWalk_AnimState({ state = 'jump' })
    fireTextKey('rideh5', 'stop')
end
check('ended handlers not leaked per jump (' .. before .. ' -> ' .. #endedHandlers .. ')',
      #endedHandlers == before, tostring(#endedHandlers))
local tkCount = #(textKeyHandlers['rideh5'] or {})
check('text key handlers not leaked per jump (' .. tkCount .. ')', tkCount <= 1, tostring(tkCount))

-- === TEST 5: the dismount flicker report actually fires =====================
-- Regression. reissueTotal/rideStartedAt were declared BELOW the two functions
-- that use them, so onAnimMounted and onAnimDismounted touched globals of the
-- same name while the ended-handler incremented the local. The report read a
-- global that mount had just zeroed, so the condition was always 0 > 0 and the
-- diagnostic could never print. Nothing in the toolchain catches declaration
-- order, so it is pinned here instead.
reset()
local printed = {}
local realprint = print
print = function(...)                      -- luacheck: ignore
    local parts = {}
    for i = 1, select('#', ...) do parts[#parts+1] = tostring((select(i, ...))) end
    printed[#printed+1] = table.concat(parts, ' ')
end

ev.WhyWalk_AnimMounted({ mountType = 'horse' })
fireTimers()
ev.WhyWalk_AnimState({ state = 'gallop' })
-- Four interruptions: under the burst limit of 5, so recovery stays enabled
-- and nothing else prints. simulation time advances via os.clock in the mock,
-- so the rate works out well above 1/s.
for _ = 1, 4 do
    for _, fn in ipairs(endedHandlers) do fn(playing) end
end
ev.WhyWalk_AnimDismounted()
print = realprint                          -- luacheck: ignore

local report = nil
for _, line in ipairs(printed) do
    if line:find('re%-issued') then report = line end
end
check('dismount reports the pose re-issue rate', report ~= nil,
      report or ('printed: ' .. tostring(#printed) .. ' line(s)'))
check('the report counts all 4 re-issues',
      report ~= nil and report:find('4 times') ~= nil, report or 'no report')


-- === TEST 6+: vessel poses (WhyWalk Boats) ===============================
local function lastPlay()
    for i = #log, 1, -1 do
        local g = log[i]:match('^play:(.*)$')
        if g then return g end
    end
end
local function cancels(g)
    local n = 0
    for _, e in ipairs(log) do if e == 'cancel:' .. g then n = n + 1 end end
    return n
end

reset(); clock = 10
ev.WhyWalk_AnimVesselStart({ stance = 'gondola' })
check('vessel pose waits for the boarding teleport to land', lastPlay() == nil)
fireTimers()
check('gondola stance poles on gondola1', playing == 'gondola1', tostring(playing))
check('gondola1 loops between its loop keys',
      lastOpts and lastOpts.startKey == 'loop start' and lastOpts.stopKey == 'loop stop')
check('vessel layer: whole body at Hit priority', lastOpts and lastOpts.priority == 6 and lastOpts.blendMask == 15)
check('loops is a valid count, not -1', lastOpts and lastOpts.loops and lastOpts.loops > 0)

clock = clock + 1
ev.WhyWalk_AnimVesselHelm({ turn = 1, throttle = 1 })
check('rudder to starboard: gondolar', playing == 'gondolar', tostring(playing))
check('the straight loop is released on the switch', cancels('gondola1') == 1)

clock = clock + 1
ev.WhyWalk_AnimVesselHelm({ turn = -1, throttle = 1 })
check('rudder to port: gondolal', playing == 'gondolal', tostring(playing))

-- a tapped rudder inside minPoseTime is deferred, then lands on the LATEST state
clock = clock + 0.05
ev.WhyWalk_AnimVesselHelm({ turn = 1, throttle = 1 })
ev.WhyWalk_AnimVesselHelm({ turn = 0, throttle = 1 })
check('switches inside minPoseTime are deferred, not played', playing == 'gondolal', tostring(playing))
clock = clock + 1
fireTimers()
check('the deferred switch plays the latest helm state', playing == 'gondola1', tostring(playing))
check('only the latest deferred switch plays', #timers == 0 and cancels('gondolar') == 1)

clock = clock + 1
local before = #log
ev.WhyWalk_AnimVesselHelm({ turn = 0, throttle = -1 })
check('throttle alone changes nothing on a stance without stroke/back', #log == before and playing == 'gondola1')

-- engine interruption: replayed, burst-guarded
for _, fn in ipairs(endedHandlers) do fn('gondola1') end
check('an ended vessel loop is re-issued', lastPlay() == 'gondola1')

ev.WhyWalk_AnimVesselStop()
check('stop releases the vessel loop', playing == nil)

-- a stance whose first choice is missing falls through to what the skeleton has
reset(); clock = clock + 1
ev.WhyWalk_AnimVesselStart({ stance = 'sit' })
fireTimers()
check('sit without a floor-sitting pack stands on idle', playing == 'idle', tostring(playing))
check('idle has no loop keys: falls back to start/stop', lastOpts.startKey == 'start' and lastOpts.stopKey == 'stop')
ev.WhyWalk_AnimVesselStop()

-- This used to assert that 'rowing' was an UNREGISTERED stance falling back
-- to stand. It ships now, so the fallback is tested with a name that really
-- is unknown -- which is what the assertion was always about.
reset(); clock = clock + 1
ev.WhyWalk_AnimVesselStart({ stance = 'coracle' })
fireTimers()
check('an unregistered stance falls back to stand', playing == 'idle', tostring(playing))
ev.WhyWalk_AnimVesselStop()

reset(); clock = clock + 1
ev.WhyWalk_AnimVesselStart({ stance = 'rowing' })
fireTimers()
check('rowing is a registered stance and does NOT fall back to idle',
      playing == 'rowingidle', tostring(playing))
ev.WhyWalk_AnimVesselStop()

-- mounting from the boat clears the vessel pose before the rider pose
reset(); clock = clock + 1
ev.WhyWalk_AnimVesselStart({ stance = 'gondola' }); fireTimers()
ev.WhyWalk_AnimMounted({ mountType = 'horse' }); fireTimers()
check('mounting clears the vessel pose', cancels('gondola1') == 1 and playing == 'rideh1', tostring(playing))
ev.WhyWalk_AnimVesselHelm({ turn = 1 })
check('helm events are ignored once mounted', playing == 'rideh1')
ev.WhyWalk_AnimDismounted()

-- save/load cancels a vessel loop that survived the load
reset(); clock = clock + 1
ev.WhyWalk_AnimVesselStart({ stance = 'gondola' }); fireTimers()
local saved = mod.engineHandlers.onSave()
mod.engineHandlers.onLoad(saved)
check('load cancels the saved vessel loop', cancels('gondola1') == 1)
ev.WhyWalk_AnimVesselHelm({ turn = 1 })
check('nothing plays after load until boarding is re-announced', playing ~= 'gondolar')

-- ---------------------------------------------------------------------------
-- ROWING STANCE
-- ---------------------------------------------------------------------------
-- Against the REAL stance table and the real clip's key times.

local VESSEL_MIN_POSE = realShared.VESSEL_TUNING.minPoseTime
local function settle()
    fireTimers()
    clock = clock + VESSEL_MIN_POSE + 0.01
end

reset(); clock = clock + 1
ev.WhyWalk_AnimVesselStart({ stance = 'rowing' })
fireTimers()
check('rowing at rest ships the oars', playing == 'rowingidle', tostring(playing))
-- rowingidle has no loop keys at all, so the candidate list has to fall
-- through to start/stop rather than asking for a pair that is not there.
check('rowingidle falls back to start/stop, having no loop pair',
      lastOpts and lastOpts.startKey == 'start' and lastOpts.stopKey == 'stop',
      lastOpts and (tostring(lastOpts.startKey) .. '/' .. tostring(lastOpts.stopKey)))

settle()
ev.WhyWalk_AnimVesselHelm({ turn = 0, throttle = 1, fast = true })
settle()
check('throttle ahead at speed pulls on rowing1', playing == 'rowing1', tostring(playing))
check('rowing1 loops between its loop keys',
      lastOpts and lastOpts.startKey == 'loop start' and lastOpts.stopKey == 'loop stop',
      lastOpts and tostring(lastOpts.startKey))

settle()
ev.WhyWalk_AnimVesselHelm({ turn = 0, throttle = 1, fast = false })
settle()
check('below hull speed eases to rowslow', playing == 'rowslow', tostring(playing))
check('the driving stroke is released on the switch', cancels('rowing1') == 1)

-- Turning outranks throttle: you turn an oared boat by pulling one oar, so
-- ahead-and-starboard is the starboard oar, not the ahead stroke.
settle()
ev.WhyWalk_AnimVesselHelm({ turn = 1, throttle = 1, fast = true })
settle()
check('ahead and starboard pulls the starboard oar', playing == 'rowingr', tostring(playing))
settle()
ev.WhyWalk_AnimVesselHelm({ turn = -1, throttle = 1, fast = true })
settle()
check('ahead and port pulls the port oar -- the renamed group',
      playing == 'rowingl', tostring(playing))

-- No backing stroke exists in the clip, so astern must ship the oars rather
-- than play a forward stroke while the boat slides backwards.
settle()
ev.WhyWalk_AnimVesselHelm({ turn = 0, throttle = -1, fast = false })
settle()
check('astern ships the oars; it does not row forwards',
      playing == 'rowingidle', tostring(playing))

-- The band only matters while pulling ahead.
settle()
ev.WhyWalk_AnimVesselHelm({ turn = 0, throttle = 0, fast = true })
settle()
check('centred helm ships the oars whatever the band', playing == 'rowingidle',
      tostring(playing))

-- A Boats build predating the speed band sends no `fast` at all; that must
-- mean the driving stroke, not the gentle one.
settle()
ev.WhyWalk_AnimVesselHelm({ turn = 0, throttle = 1 })
settle()
check('a helm event with no band drives, rather than easing off',
      playing == 'rowing1', tostring(playing))

-- vesselField's fallthrough rules, directly.
local VS = realShared.VESSEL_STANCE
local vf = realShared.vesselField
check('rowing: ahead + fast -> stroke', vf(VS.rowing, 0, 1, true) == 'stroke')
check('rowing: ahead + slow -> slow', vf(VS.rowing, 0, 1, false) == 'slow')
check('rowing: ahead + nil band -> stroke', vf(VS.rowing, 0, 1, nil) == 'stroke')
check('rowing: astern -> base (no back group)', vf(VS.rowing, 0, -1, true) == 'base')
check('rowing: turn beats throttle', vf(VS.rowing, -1, 1, true) == 'left')
check('gondola is unaffected by the band',
      vf(VS.gondola, 0, 1, false) == 'base' and vf(VS.gondola, 1, 0, false) == 'right')
check('stand ignores every helm input',
      vf(VS.stand, -1, 1, false) == 'base' and vf(VS.stand, 1, -1, true) == 'base')

-- A stance with `slow` but no `stroke` should use slow at any speed, so the
-- field is usable on its own.
local slowOnly = { base = 'idle', slow = 'rowslow' }
check('slow without stroke applies at any speed',
      vf(slowOnly, 0, 1, true) == 'slow' and vf(slowOnly, 0, 1, false) == 'slow')

print(failures == 0 and '\nALL PASS' or ('\n' .. failures .. ' FAILURE(S)'))
os.exit(failures == 0 and 0 or 1)
