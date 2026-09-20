-- Run from the MOD ROOT:  python3 tools/luarun.py tools/test_target.lua
-- Drives the real target.lua save/load path against a mock engine whose
-- animation.cancel raises the engine's errors for disabled / out-of-scene actors.
ROOT = ROOT or '.'
-- ROOT set by runner. Mock engine: an actor is {disabled, inScene}.
local actor = { disabled = false, inScene = false }
local cancels = {}
local function stub() local t; t = setmetatable({}, { __index = function() return stub() end, __call = function() return stub() end }); return t end
local mods = {
  ['openmw.animation'] = {
    cancel = function(_, g)
      if actor.disabled then error("Can't use a disabled object", 2) end
      if not actor.inScene then error("Object has no animation", 2) end
      cancels[#cancels + 1] = g
    end,
    hasGroup = function() return true end, playBlended = function() end,
    BONE_GROUP = { LowerBody = 1, Torso = 2, LeftArm = 3, RightArm = 4 },
    PRIORITY = { Scripted = 9, Weapon = 5 }, BLEND_MASK = { All = 15, UpperBody = 14 },
  },
  ['openmw.self'] = stub(), ['openmw.core'] = stub(), ['openmw.types'] = stub(),
  ['openmw.util'] = { bitOr = function() return 0 end, vector3 = stub(), transform = stub() },
  ['openmw.nearby'] = { COLLISION_TYPE = { World = 1, HeightMap = 2, Door = 4 } },
}
local loaded = {}
local function req(n)
  if mods[n] then return mods[n] end
  if loaded[n] then return loaded[n] end
  local f = assert(loadfile(ROOT .. '/' .. n:gsub('%.', '/') .. '.lua', 't', setmetatable({ require = req }, { __index = _G })))
  loaded[n] = f(); return loaded[n]
end
local function fresh()
  loaded = {}; cancels = {}
  return assert(loadfile(ROOT .. '/scripts/forcechoke/target.lua', 't', setmetatable({ require = req }, { __index = _G })))()
end
local fails = 0
local function check(name, cond) print((cond and '  ok   ' or '  FAIL ') .. name); if not cond then fails = fails + 1 end end
local function try(fn, ...) local ok, e = pcall(fn, ...); return ok, e end
local E

print('idle actor, disabled, save loaded')
E = fresh().engineHandlers; actor.disabled, actor.inScene = true, false
local saved = E.onSave and E.onSave() or nil
check('onLoad does not error', (try(E.onLoad, saved)))
check('issues no cancels', #cancels == 0)

print('idle actor, enabled but not yet in scene')
E = fresh().engineHandlers; actor.disabled, actor.inScene = false, false
check('onLoad does not error', (try(E.onLoad, E.onSave and E.onSave() or nil)))
check('issues no cancels', #cancels == 0)

print('actor saved mid-choke, disabled at load, enabled later')
local R = fresh(); E = R.engineHandlers; actor.disabled, actor.inScene = false, true
R.eventHandlers.ForceChoke_Grab()
saved = E.onSave and E.onSave()
check('onSave records the playing group', saved and saved.group == 'fchokeidle')
E = fresh().engineHandlers; actor.disabled, actor.inScene = true, false
check('onLoad does not error', (try(E.onLoad, saved)))
check('nothing cancelled while disabled', #cancels == 0)
actor.disabled, actor.inScene = false, true
check('onActive does not error', E.onActive ~= nil and (try(E.onActive)))
check('stranded pose cancelled exactly once', #cancels == 1 and cancels[1] == 'fchokeidle')
if E.onActive then E.onActive() end
check('second activation does nothing', #cancels == 1)

print(fails == 0 and 'ALL PASS' or (fails .. ' FAILED'))
