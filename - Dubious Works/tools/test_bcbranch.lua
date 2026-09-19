-- Extracts syncAnimRefresh from the patched player.lua and drives it, so the
-- subscribe/unsubscribe logic is checked without loading all 55KB of Bardcraft.
local fails=0
local function check(n,c,e) if c then print('  ok   '..n) else fails=fails+1; print('  FAIL '..n..' '..tostring(e or '')) end end

local src = io.open(arg and arg[1] or 'scripts/Bardcraft/player.lua'):read('a')
local body = src:match('(local function syncAnimRefresh%(%).-\nend\n)')
assert(body, 'could not extract syncAnimRefresh')

local calls = {sub=0, unsub=0}
local subs = {}
-- syncAnimRefresh closes over `local animRefreshSubscribed = false`, which is
-- declared separately in player.lua and is not part of the extracted body.
-- Seed it, or the first comparison is `false == nil` and the guard never trips.
local env = {
    animRefreshSubscribed = false, animRefreshWarned = false, print = function() end,
    Performer = { stats = {}, setSheatheVfx = function() end, hasAnim = function() return true end },
    I = { AnimRefresh = {
        subscribe = function(k, cb) subs[k]=cb; calls.sub=calls.sub+1 end,
        unsubscribe = function(k) subs[k]=nil; calls.unsub=calls.unsub+1 end,
    }},
}
local chunk = load(body .. '\nreturn syncAnimRefresh', 'sync', 't', env)
local sync = chunk()

print('AnimRefresh subscription')
sync()
check('no subscription while nothing is sheathed', subs['Bardcraft']==nil and calls.sub==0)

env.Performer.stats.sheathedInstrument = 'misc_de_lute_01'
sync()
check('subscribes once something is sheathed', subs['Bardcraft']~=nil and calls.sub==1)

sync(); sync()
check('repeat calls do not re-subscribe', calls.sub==1, calls.sub)

env.Performer.stats.sheathedInstrument = 'r_bc_fiddle'
sync()
check('swapping instruments keeps one subscription', calls.sub==1 and calls.unsub==0)

env.Performer.stats.sheathedInstrument = nil
sync()
check('unsubscribes when nothing is sheathed', subs['Bardcraft']==nil and calls.unsub==1)
sync()
check('repeat calls do not re-unsubscribe', calls.unsub==1, calls.unsub)

-- the callback must re-issue the VFX
local reissued = 0
env.Performer.setSheatheVfx = function() reissued = reissued + 1 end
env.Performer.stats.sheathedInstrument = 'misc_de_lute_01'
sync()
subs['Bardcraft']('third','first')
local r = subs['Bardcraft']('third','first')
check('the AnimRefresh callback re-issues the sheathe VFX', reissued==2, reissued)
check('callback reports ready (not false) when the animation exists', r ~= false)

-- v3 readiness: no animation object yet is transient -> exactly false, no VFX call
env.Performer.hasAnim = function() return false end
local before = reissued
r = subs['Bardcraft']('third','first')
check('callback returns exactly false while no animation object exists', r == false and reissued == before)
env.Performer.hasAnim = function() return true end

-- v3 subscribe() rejects non-functions; make sure what we pass is a function
check('subscriber is a function (v3 validates at subscribe)', type(subs['Bardcraft']) == 'function')

-- absent interface must not error
local printed = 0
local env2 = { animRefreshSubscribed = false, animRefreshWarned = false,
    print = function() printed = printed + 1 end,
    Performer = { stats = {sheathedInstrument='x'}, setSheatheVfx=function() end, hasAnim=function() return true end }, I = {} }
local sync2 = load(body..'\nreturn syncAnimRefresh','sync2','t',env2)()
local ok = pcall(sync2); pcall(sync2); pcall(sync2)
check('does not error when AnimRefresh is absent', ok)
check('warns exactly once when AnimRefresh is absent', printed == 1, printed)

-- conductor gate in performer.lua: setSheatheVfx only on start/stop
local perf = io.open((arg and arg[2]) or 'scripts/Bardcraft/performer.lua'):read('a')
local h = perf:match('function P%.handleConductorEvent%(data%).-\nend\n')
assert(h, 'could not extract handleConductorEvent')
local vfx = 0
local P = { playing = true, setSheatheVfx = function() vfx = vfx + 1 end,
    handlePerformEvent=function() end, handleStopEvent=function() end,
    handleTempoEvent=function() end, handleNoteEvent=function() return true end, stopNote=function() end }
local henv = { P = P, instrumentData = {}, core = { getRealTime = function() return 0 end } }
load(h, 'hce', 't', henv)()
for _ = 1, 50 do P.handleConductorEvent({ type = 'NoteEvent' }) end
P.handleConductorEvent({ type = 'TempoEvent' })
check('notes and tempo events do not touch the sheathe VFX', vfx == 0, vfx)
P.handleConductorEvent({ type = 'PerformStart' })
P.handleConductorEvent({ type = 'PerformStop' })
check('start and stop each refresh the sheathe VFX', vfx == 2, vfx)

print(fails==0 and 'ALL PASS' or (fails..' FAILURES'))
if fails>0 then os.exit(1) end
