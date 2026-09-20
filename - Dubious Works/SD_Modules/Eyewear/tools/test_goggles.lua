-- Drives the real g_goggles / p_goggles against a mocked Sun's Dusk
-- environment. Run from the MOD ROOT:
--     python3 tools/luarun.py tools/test_goggles.lua
local GLOBALM = 'scripts/SunsDusk/global_modules/'
local PLAYERM = 'scripts/SunsDusk/player_modules/'

local fails = 0
local function check(n, c, e)
    if c then print('  ok   ' .. n)
    else fails = fails + 1; print('  FAIL ' .. n .. ' ' .. tostring(e or '')) end
end

local world = { vfx = {}, bones = {}, spells = {}, files = {}, events = {} }
local inv, recs = {}, {}

local function mk(id)
    local m = 'RV\\' .. id .. '.nif'
    recs[id] = { id = id, model = m }
    world.files[m] = true
    local it
    it = { recordId = id, count = 1,
           remove = function(s)
               for i, x in ipairs(inv) do if x == s then table.remove(inv, i) break end end
           end }
    return it
end
local function add(id) local i = mk(id); inv[#inv + 1] = i; return i end
local function has(id) for _, x in ipairs(inv) do if x.recordId == id then return x end end end

local env = {}
env.types = {
    Miscellaneous = { record = function(o) return recs[type(o) == 'string' and o or o.recordId] end,
                      records = setmetatable({}, { __index = function(_, k) return recs[k] end }) },
    Player = { objectIsInstance = function(a) return a and a.isPlayer == true end },
    Actor  = { inventory = function() return {
                   getAll = function() return inv end,
                   find   = function(_, id) return has(id) end } end },
    Container = { content = function() return { getAll = function() return {} end } end },
    NPC = {}, Creature = {},
}
env.world = { createObject = function(id)
    local it = mk(id)
    return { moveInto = function() inv[#inv + 1] = it end, teleport = function() end }
end }
env.util = { vector3 = function(x, y, z) return { x = x, y = y, z = z } end }
local itemHandlers = {}
local interfaces = { ItemUsage = { addHandlerForType = function(_, fn) itemHandlers[#itemHandlers + 1] = fn end } }
-- openmw.interfaces is a read-only userdata in the engine: reads work, any
-- write raises. A plain table here let v0.02's `I.SunsDuskGoggles = {...}`
-- pass every test while it aborted sd_p.lua in game. Keep this proxy.
env.I = setmetatable({}, {
    __index = interfaces,
    __newindex = function(_, k)
        error("attempt to index global 'I' (a userdata value) [write to I." .. tostring(k) .. "]", 2)
    end,
})
env.animation = {
    removeVfx = function(_, id)
        for b, v in pairs(world.vfx) do if v == id then world.vfx[b] = nil end end
    end,
    addVfx = function(_, m, o)
        assert(world.files[m], 'addVfx got a path not in the VFS: ' .. tostring(m))
        world.vfx[o.boneName] = o.vfxId
    end,
    hasBone = function(_, b) return world.bones[b] == true end,
}
-- Sun's Dusk exposes vfs as a global (sd_p.lua:18).
env.vfs = { fileExists = function(p) return world.files[p] == true end }
env.core = {
    magic = { spells = { records = setmetatable({}, { __index = function(_, k)
        return k:find('^sd_goggles_') and { id = k } or nil end }) } },
    sendGlobalEvent = function(n, d) world.events[#world.events + 1] = { n = n, d = d } end,
}
env.async = { newUnsavableSimulationTimer = function(_, _, f) f() end }
env.self = { isPlayer = true }
env.saveData = {}
env.typesActorSpellsSelf = { add = function(_, id) world.spells[id] = true end,
                             remove = function(_, id) world.spells[id] = nil end }
env.typesActorInventorySelf = { find = function(_, id) return has(id) end }
env.log = function() end
env.G_eventHandlers, env.G_onFrameJobsSluggish = {}, {}
env.G_onFrameJobs, env.G_onLoadJobs = {}, {}
env.G_UiModeChangedJobs, env.G_settingsChangedJobs = {}, {}
env.GOGGLES_ENABLED = true
env.math, env.table, env.ipairs, env.pairs = math, table, ipairs, pairs
env.tostring, env.print, env.type, env.error = tostring, print, type, error
env.require = function(path)
    if path == 'scripts.SunsDusk.settings.goggles_settings' then return true end
    error('unexpected require: ' .. tostring(path))
end

local function run(f) local c = assert(loadfile(f, 't', env)); c() end
run(GLOBALM .. 'g_goggles.lua')
run(PLAYERM .. 'p_goggles.lua')

world.bones['Bip01 eyesDBS'] = true
world.bones['head'] = true

local onUse = itemHandlers[1]
local player = { isPlayer = true, sendEvent = function(_, n, d)
    local h = env.G_eventHandlers[n]; if h then h(d) end end }

print('equip swap')
check('one ItemUsage handler registered', #itemHandlers == 1, #itemHandlers)

local g1 = add('dbs_rv_goggles1_h')
onUse(g1, player)
check('base consumed, _eq created',
      has('dbs_rv_goggles1_h') == nil and has('dbs_rv_goggles1_h_eq') ~= nil)
check('vfx attached to the DBS eyes bone',
      world.vfx['Bip01 eyesDBS'] ~= nil, tostring(world.vfx['Bip01 eyesDBS']))
check('luck ability granted', world.spells['sd_goggles_luck1'] == true)

print('replacement and toggle')
local g2 = add('dbs_rv_glasses2_h')
onUse(g2, player)
check('second pair returns the first to the inventory',
      has('dbs_rv_goggles1_h') ~= nil and has('dbs_rv_goggles1_h_eq') == nil
      and has('dbs_rv_glasses2_h_eq') ~= nil)

onUse(has('dbs_rv_glasses2_h_eq'), player)
check('using a worn pair takes it off', has('dbs_rv_glasses2_h') ~= nil)
check('ability removed with the last pair', world.spells['sd_goggles_luck1'] == nil)

print('pass-through')
local junk = add('misc_com_bottle_01')
local result = onUse(junk, player)
check('an unrelated Miscellaneous item is not consumed',
      has('misc_com_bottle_01') ~= nil)
check('and the handler lets others see it', result ~= false, tostring(result))

print('fallback bone')
local g3 = add('dbs_rv_lenses1_h')
onUse(g3, player)
world.bones['Bip01 eyesDBS'] = nil
world.vfx = {}
env.G_UiModeChangedJobs[1]({ oldMode = 'Rest' })
check('falls back to a vanilla bone when the DBS rig is absent',
      world.vfx['head'] ~= nil, 'a missing bone is a SILENT no-show')
world.bones['Bip01 eyesDBS'] = true

print('missing mesh')
-- Eyewear meshes ship separately. A record whose mesh is not in the VFS must be
-- reported and skipped, never attached silently.
local ghost = add('dbs_rv_goggles9_h')
recs['dbs_rv_goggles9_h_eq'] = { id = 'dbs_rv_goggles9_h_eq', model = 'RV\\absent.nif' }
world.files['RV\\absent.nif'] = nil
world.vfx = {}
onUse(ghost, player)
check('a record with no mesh in the VFS attaches nothing and does not error',
      next(world.vfx) == nil)

print(fails == 0 and 'ALL PASS' or (fails .. ' FAILURES'))
if fails > 0 then os.exit(1) end
