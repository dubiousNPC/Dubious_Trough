-- Drives the REAL AnimRefresh_v3.lua with Bardcraft's REAL subscriber
-- (syncAnimRefresh, extracted from player.lua) and REAL setSheatheVfx /
-- verifySheathedInstrument (extracted from performer.lua) through simulated
-- perspective switches. Run from the mod root:
--     python3 tools/luarun.py tools/test_bc_animrefresh_v3.lua
local FAILED = false
local function check(n, c, e)
    print((c and '  ok   ' or '  FAIL ') .. n .. (c and '' or ('  ' .. tostring(e or ''))))
    if not c then FAILED = true end
end

local BONE = 'Bip01 BOInstrumentBack'
local world = { vfx = {}, bones = { [BONE] = true }, hasAnim = true, mode = 'third',
                inv = { misc_de_lute_01 = true }, getModeCalls = 0, prints = {} }
local timers, now = {}, 0
local function advance(dt)
    now = now + dt
    local due = {}
    for _, t in ipairs(timers) do if t.at <= now then due[#due + 1] = t end end
    for _, t in ipairs(due) do
        for i, x in ipairs(timers) do if x == t then table.remove(timers, i) break end end
        t.fn()
    end
end

package.preload['openmw.camera'] = function() return {
    MODE = { FirstPerson = 'first', ThirdPerson = 'third' },
    getMode = function() world.getModeCalls = world.getModeCalls + 1; return world.mode end } end
package.preload['openmw.input'] = function() return {
    triggers = { TogglePOV = true },
    registerTriggerHandler = function(_, cb) world.trigger = cb end } end
package.preload['openmw.async'] = function() return {
    callback = function(_, f) return f end,
    newUnsavableSimulationTimer = function(_, d, f) timers[#timers + 1] = { at = now + d, fn = f } end } end
local IFACES = {}
package.preload['openmw.interfaces'] = function() return IFACES end

local realPrint = print
print = function(...) world.prints[#world.prints + 1] = table.concat({ ... }, ' ') end
local AR = dofile('scripts/AnimRefresh/AnimRefresh_v3.lua')
print = realPrint
IFACES[AR.interfaceName] = AR.interface
check('AnimRefresh_v3 registers version 3', AR.interface.version == 3)

-- ---- real Bardcraft code, extracted ------------------------------------
local perf = io.open('scripts/Bardcraft/performer.lua'):read('a')
local sheatheSrc = perf:match('(function P:setSheatheVfx%(%).-\nfunction P:verifySheathedInstrument%(%).-\nend\n)')
assert(sheatheSrc, 'could not extract setSheatheVfx/verifySheathedInstrument')
local omwself = { type = { inventory = function() return {
    find = function(_, id) return world.inv[id] and { recordId = id } or nil end } end } }
local P = { stats = {}, instrumentItem = nil }
function P.hasAnim() return world.hasAnim end
local penv = setmetatable({
    P = P, omwself = omwself,
    types = { Miscellaneous = { record = function(id) return { id = id, model = 'meshes/bardcraft/' .. id .. '.nif' } end } },
    anim = {
        hasBone = function(_, b) return world.bones[b] == true end,
        addVfx = function(_, model, o) world.vfx[o.vfxId] = { model = model, bone = o.boneName } end,
        removeVfx = function(_, id) world.vfx[id] = nil end,
    },
}, { __index = _G })
load(sheatheSrc, 'performer-extract', 't', penv)()

local pl = io.open('scripts/Bardcraft/player.lua'):read('a')
local syncSrc = pl:match('(local animRefreshWarned = false\nlocal function syncAnimRefresh%(%).-\nend\n)')
assert(syncSrc, 'could not extract syncAnimRefresh')
local senv = setmetatable({ Performer = P, I = IFACES, animRefreshSubscribed = false,
    print = function(...) world.prints[#world.prints + 1] = table.concat({ ... }, ' ') end },
    { __index = _G })
local sync = load(syncSrc .. '\nreturn syncAnimRefresh', 'player-extract', 't', senv)()

local function run(seconds, onTick)
    for _ = 1, math.floor(seconds / 0.05 + 0.5) do
        advance(0.05)
        if onTick then onTick() end
        AR.engineHandlers.onUpdate(0.05)
    end
end

-- ---- 1. idle cost ------------------------------------------------------
print('idle')
sync()
world.getModeCalls = 0
run(5)
check('nothing sheathed: zero camera.getMode calls over 5s', world.getModeCalls == 0, world.getModeCalls)

-- ---- 2. sheathe + POV with late rebuild --------------------------------
print('sheathe, then POV switch with a late engine rebuild')
P.stats.sheathedInstrument = 'misc_de_lute_01'
P:setSheatheVfx(); sync()
check('sheathed instrument drawn on ' .. BONE, world.vfx.BC_BackInstrument and world.vfx.BC_BackInstrument.bone == BONE)
check('mesh path is the sheathe VFS path', world.vfx.BC_BackInstrument and
    world.vfx.BC_BackInstrument.model == 'meshes/bardcraft/vfx/sheathe/misc_de_lute_01.nif',
    world.vfx.BC_BackInstrument and world.vfx.BC_BackInstrument.model)

-- Engine drops the VFX on the press, then wipes again when the new animation
-- object finishes coming up -- after the 0.1s settle delivery.
world.vfx = {}; world.trigger(); world.mode = 'first'
local pressAt, wiped = now, false
run(1.5, function()
    if not wiped and now - pressAt >= 0.45 then world.vfx = {}; wiped = true end
end)
check('instrument recovered after a rebuild that finished 0.45s after the press',
    world.vfx.BC_BackInstrument ~= nil)

-- ---- 3. POV without the key (poll backstop) ----------------------------
print('mode change with no key press')
world.vfx = {}; world.mode = 'first'
run(2.0)
check('poll backstop restores the instrument within 2s', world.vfx.BC_BackInstrument ~= nil)

-- ---- 4. readiness: no animation object at settle time ------------------
print('animation object not ready at settle time')
world.vfx = {}; world.hasAnim = false; world.prints = {}
world.trigger(); world.mode = 'third'
local pressAt2 = now
run(1.5, function() if now - pressAt2 >= 0.15 then world.hasAnim = true end end)
check('recovered once the animation object exists', world.vfx.BC_BackInstrument ~= nil)
local gaveUp = 0
for _, s in ipairs(world.prints) do if s:find('still not ready') then gaveUp = gaveUp + 1 end end
check('no "still not ready" log when the object appears within the retry', gaveUp == 0, gaveUp)

-- ---- 5. skeleton without the bone: no log spam -------------------------
print('skeleton without ' .. BONE)
world.bones[BONE] = nil; world.vfx = {}; world.prints = {}
for _ = 1, 5 do world.trigger(); world.mode = (world.mode == 'first') and 'third' or 'first'; run(1.2) end
check('missing bone draws nothing', world.vfx.BC_BackInstrument == nil)
check('missing bone logs nothing across 5 switches', #world.prints == 0, table.concat(world.prints, ' | '))
world.bones[BONE] = true

-- ---- 6. playing the sheathed instrument hides it -----------------------
print('playing the same instrument')
P.instrumentItem = { id = 'misc_de_lute_01' }
world.trigger(); world.mode = 'first'; run(1.5)
check('instrument in hand is not also drawn on the back', world.vfx.BC_BackInstrument == nil)
P.instrumentItem = nil

-- ---- 7. unsheathe -> unsubscribed, idle again --------------------------
print('unsheathe')
P.stats.sheathedInstrument = nil
P:setSheatheVfx(); sync()
world.getModeCalls = 0
run(5)
check('after unsheathing: zero camera.getMode calls over 5s', world.getModeCalls == 0, world.getModeCalls)
check('VFX removed', world.vfx.BC_BackInstrument == nil)

print(FAILED and 'FAILURES' or 'ALL PASS')
if FAILED then os.exit(1) end
