-- Behavioural test for ridingAnim.lua's state machine.
--
-- Per RESEARCH.md 4.1, the mock asserts the contract the engine enforces
-- rather than accepting anything: playBlendedAnimation records what was
-- played, and the test checks the POSE THE RIDER IS ACTUALLY IN, not merely
-- that no error was raised.

local log = {}
local timers = {}          -- pending async timers, fired manually
local textKeyHandlers = {} -- group -> { fn, ... }
local endedHandlers = {}

local function reset() log, timers = {}, {} end

-- --- mock modules ---------------------------------------------------------
local playing = nil        -- the group the engine currently considers active

package.loaded['openmw.self'] = { object = {} }
package.loaded['openmw.animation'] = {
    BONE_GROUP = { LowerBody = 1, Torso = 2, LeftArm = 3, RightArm = 4 },
    BLEND_MASK = { LowerBody = 1, Torso = 2, LeftArm = 4, RightArm = 8 },
    PRIORITY   = { Default = 0, Weapon = 5, Scripted = 9 },
    cancel = function(_, g)
        log[#log+1] = 'cancel:' .. tostring(g)
        if playing == g then playing = nil end
    end,
    isPlaying = function(_, g) return playing == g end,
}
package.loaded['openmw.core'] = { getSimulationTime = function() return os.clock() end }
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
            playing = group
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

package.loaded['scripts.WhyWalk.whywalk_shared'] = {
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

print(failures == 0 and '\nALL PASS' or ('\n' .. failures .. ' FAILURE(S)'))
os.exit(failures == 0 and 0 or 1)
