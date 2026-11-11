-- Run from the MOD ROOT:  python3 tools/luarun.py tools/test_detach.lua
-- Drives target.lua's attach/settle/detach lifecycle against a mock engine.
--
-- The thing under test is the rule that makes the CUSTOM-script rework safe:
-- target.lua must ask to be detached ONLY once the one-shot drop clip has
-- finished. Detaching earlier leaves fchokedrop in the active list at
-- PRIORITY.Scripted with nothing able to cancel it, which is the stranded
-- pose the autoDisable fix closed.
ROOT = ROOT or '.'

local actor   = { disabled = false, inScene = true }
local playing = {}   -- group -> true while the engine considers it running
local events  = {}   -- global events this script sent
local cancels = {}

local function stub() local t; t = setmetatable({}, { __index = function() return stub() end, __call = function() return stub() end }); return t end

local mods = {
  ['openmw.animation'] = {
    cancel = function(_, g)
      if actor.disabled then error("Can't use a disabled object", 2) end
      if not actor.inScene then error("Object has no animation", 2) end
      cancels[#cancels + 1] = g; playing[g] = nil
    end,
    hasGroup  = function() return true end,
    playBlended = function(_, g, o) playing[g] = true; return o end,
    isPlaying = function(_, g) return playing[g] == true end,
    BONE_GROUP = { LowerBody = 1, Torso = 2, LeftArm = 3, RightArm = 4 },
    PRIORITY = { Scripted = 9, Weapon = 5 }, BLEND_MASK = { All = 15, UpperBody = 14 },
  },
  ['openmw.self'] = setmetatable({ object = 'SELF' }, { __index = function() return stub() end }),
  ['openmw.core'] = setmetatable({
    isWorldPaused   = function() return false end,
    sendGlobalEvent = function(name, data) events[#events + 1] = { name = name, data = data } end,
  }, { __index = function() return stub() end }),
  ['openmw.types'] = stub(),
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
  loaded = {}; cancels = {}; events = {}; playing = {}
  return assert(loadfile(ROOT .. '/scripts/forcechoke/target.lua', 't', setmetatable({ require = req }, { __index = _G })))()
end

local fails = 0
local function check(name, cond) print((cond and '  ok   ' or '  FAIL ') .. name); if not cond then fails = fails + 1 end end
local function sent(name)
  for _, e in ipairs(events) do if e.name == name then return true end end
  return false
end
local function countSent(name)
  local n = 0
  for _, e in ipairs(events) do if e.name == name then n = n + 1 end end
  return n
end
local S = req('scripts.forcechoke.shared')
local DROP, HOLD = S.GROUPS.DROP, S.GROUPS.HOLD
local GRACE, TIMEOUT = S.TUNING.dropSettleGrace, S.TUNING.dropSettleTimeout

print('attach via initData starts the hold')
local R = fresh()
R.engineHandlers.onInit({ grab = true })
check('hold pose playing', playing[HOLD] == true)
check('no detach requested', not sent('ForceChoke_Detach'))

print('attach without initData does nothing')
R = fresh()
R.engineHandlers.onInit(nil)
check('no pose played', next(playing) == nil)

print('release: detach waits for the drop clip')
R = fresh()
R.engineHandlers.onInit({ grab = true })
R.eventHandlers.ForceChoke_Drop()
check('drop pose playing', playing[DROP] == true)
R.engineHandlers.onUpdate(GRACE / 2)
check('silent inside the grace window', not sent('ForceChoke_Detach'))
R.engineHandlers.onUpdate(GRACE)
check('still attached while clip runs', not sent('ForceChoke_Detach'))
playing[DROP] = nil   -- autoDisable removes the group at clip end
R.engineHandlers.onUpdate(0.05)
check('detach requested once the clip ends', sent('ForceChoke_Detach'))
R.engineHandlers.onUpdate(0.05)
check('detach requested exactly once', countSent('ForceChoke_Detach') == 1)

print('release: timeout detaches even if the clip never reports finishing')
R = fresh()
R.engineHandlers.onInit({ grab = true })
R.eventHandlers.ForceChoke_Drop()
R.engineHandlers.onUpdate(TIMEOUT + 0.1)   -- playing[DROP] still true
check('detach requested on timeout', sent('ForceChoke_Detach'))

print('re-grab during the settle window cancels the detach')
R = fresh()
R.engineHandlers.onInit({ grab = true })
R.eventHandlers.ForceChoke_Drop()
R.engineHandlers.onUpdate(GRACE / 2)
R.eventHandlers.ForceChoke_Grab()
check('hold pose playing again', playing[HOLD] == true)
playing[DROP] = nil
R.engineHandlers.onUpdate(TIMEOUT + 0.1)
check('no detach while held', not sent('ForceChoke_Detach'))

print('clear detaches immediately -- nothing is playing')
R = fresh()
R.engineHandlers.onInit({ grab = true })
R.eventHandlers.ForceChoke_Clear()
check('pose cancelled', cancels[1] == HOLD)
check('detach requested at once', sent('ForceChoke_Detach'))

print('stranded pose from a save also sheds the script')
R = fresh()
R.engineHandlers.onInit({ grab = true })
local saved = R.engineHandlers.onSave()
check('onSave records the hold', saved and saved.group == HOLD)
R = fresh()
R.engineHandlers.onLoad(saved)
R.engineHandlers.onActive()
check('stranded pose cancelled', cancels[1] == HOLD)
check('detach requested after self-heal', sent('ForceChoke_Detach'))

print(fails == 0 and 'ALL PASS' or (fails .. ' FAILED'))
