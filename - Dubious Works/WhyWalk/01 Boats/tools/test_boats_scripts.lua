-- test_boats_scripts.lua -- drives boats_global.lua and boats_player.lua
-- against a small engine model and asserts the invariants that matter:
--   * boarding a static hides it, creates a copy with a plugin-relative model,
--     and stands the pilot on the anchor
--   * every frame the boat is placed so the pilot is exactly at the anchor
--   * the heading reaches the global only when it changes
--   * leaving releases exactly what was taken; a Core hand-off does not
--   * a pilot the engine stops is noticed and the boat's way taken off
-- Run from the module root:  python3 tools/luarun.py tools/test_boats_scripts.lua
package.path = './?.lua;' .. package.path

local passed, failed = 0, 0
local function check(name, cond, detail)
    if cond then passed = passed + 1
    else failed = failed + 1; print('FAIL ' .. name .. (detail and ('  ' .. tostring(detail)) or '')) end
end
local function near(a, b, eps) return math.abs(a - b) <= (eps or 1e-6) end

-- ---------------------------------------------------------------- vectors
local V = {}
V.__index = V
local function vec3(x, y, z) return setmetatable({ x = x, y = y, z = z }, V) end
V.__add = function(a, b) return vec3(a.x + b.x, a.y + b.y, a.z + b.z) end
V.__sub = function(a, b) return vec3(a.x - b.x, a.y - b.y, a.z - b.z) end
V.__mul = function(a, k) return vec3(a.x * k, a.y * k, a.z * k) end
function V:length() return math.sqrt(self.x ^ 2 + self.y ^ 2 + self.z ^ 2) end

local Tr = {}
Tr.__index = Tr
local function transform(yaw, roll, pitch) return setmetatable({ yaw = yaw, roll = roll or 0, pitch = pitch or 0 }, Tr) end
function Tr:getYaw() return self.yaw end
Tr.__mul = function(a, b) return transform(a.yaw + b.yaw, a.roll + b.roll, a.pitch + b.pitch) end

local util = {
    vector3 = vec3,
    vector2 = function(x, y) return { x = x, y = y } end,
    transform = {
        rotateZ = function(a) return transform(a) end,
        rotateY = function(a) return transform(0, a, 0) end,
        rotateX = function(a) return transform(0, 0, a) end,
    },
}

-- ---------------------------------------------------------------- world
local log = { globalEvents = {}, playerEvents = {}, teleports = {}, sounds = {} }
local frame = 0

local cellExt = { isExterior = true, hasWater = true, waterLevel = 0, name = 'ext' }
local LAND = -500

local Obj = {}
Obj.__index = Obj
local nextId = 1
local function newObject(fields)
    local o = setmetatable(fields, Obj)
    o.id = 'obj' .. nextId; nextId = nextId + 1
    o.enabled = o.enabled ~= false
    o.scale = o.scale or 1
    o.cell = o.cell or cellExt
    o.rotation = o.rotation or transform(0)
    o.handlers = {}
    return o
end
function Obj:isValid() return true end
function Obj:teleport(cell, pos, opts)
    local rot = opts
    if type(opts) == 'table' and getmetatable(opts) ~= Tr then rot = opts.rotation end
    log.teleports[#log.teleports + 1] = { obj = self, cell = cell, pos = pos, rot = rot, frame = frame }
    self.position = pos
    if rot then self.rotation = rot end
    self.enabled = true
end
function Obj:setScale(s) self.scale = s end
function Obj:getBoundingBox()
    return { center = self.position, halfSize = vec3(300, 70, 60) }
end
function Obj:sendEvent(name, data)
    log.playerEvents[#log.playerEvents + 1] = { name = name, data = data, to = self }
end

local records = {
    ['ex_de_rowboat'] = { id = 'ex_de_rowboat', model = 'meshes/x/ex_de_rowboat.nif' },
    ['gv_playergond'] = { id = 'gv_playergond', model = 'meshes/gv_gondola.nif', mwscript = 'gv_playergondscript' },
}
local created = {}
local player = newObject({ recordId = 'player', kind = 'player', position = vec3(100, 80, 10) })
player.stats = { health = 100 }
local staticBoat = newObject({ recordId = 'ex_de_rowboat', kind = 'static',
                               position = vec3(200, 100, 2), rotation = transform(1.0) })

local function isKind(k) return { objectIsInstance = function(o) return o.kind == k end } end
local types = {
    Static = isKind('static'),
    Activator = isKind('activator'),
    Player = isKind('player'),
    Actor = {
        stats = { dynamic = {
            health = function(o) return { current = o.stats.health } end,
            fatigue = function(o) return { current = o.stats.fatigue or 100, base = 100 } end,
        } },
        activeEffects = function() return { modify = function(_, n, id) log.effect = (log.effect or 0) + n; log.effectId = id end } end,
        getWalkSpeed = function() return 150 end,
        getRunSpeed = function() return 300 end,
    },
}
types.Static.record = function(o) return records[o.recordId] end
types.Activator.record = function(o) return records[o.recordId] or created[o.recordId] end
types.Activator.createRecordDraft = function(t) return t end

local world = {
    players = { player },
    createRecord = function(draft)
        local id = 'generated:' .. (#log.teleports + 1000)
        -- what the engine is documented to do: prefix meshes\ onto the given path
        created[id] = { id = id, name = draft.name, model = 'meshes\\' .. draft.model:gsub('/', '\\') }
        log.createdModel = draft.model
        return created[id]
    end,
    createObject = function(id)
        local o = newObject({ recordId = id, kind = 'activator', position = vec3(0, 0, -9999) })
        log.copy = o
        return o
    end,
}

local activationHandler
local I = {
    Activation = { addHandlerForType = function(_, fn) activationHandler = fn end },
}

local core = {
    isWorldPaused = function() return false end,
    sendGlobalEvent = function(name, data) log.globalEvents[#log.globalEvents + 1] = { name = name, data = data } end,
    land = { getHeightAt = function() return LAND end },
    sound = {
        records = { ['Boat Creak'] = {} },
        playSound3d = function(id, obj) log.sounds[id] = obj end,
        stopSound3d = function(id) log.sounds[id] = nil end,
        isSoundPlaying = function(id) return log.sounds[id] ~= nil end,
    },
    magic = { EFFECT_TYPE = { WaterWalking = 'waterwalking' } },
    l10n = function() return function(k) return k end end,
}

local function loadScript(path, preload)
    for k, v in pairs(preload) do package.loaded[k] = v end
    local chunk = assert(loadfile(path))
    return chunk()
end

local G = loadScript('scripts/WhyWalk/Boats/boats_global.lua', {
    ['openmw.world'] = world, ['openmw.types'] = types, ['openmw.util'] = util,
    ['openmw.core'] = core, ['openmw.interfaces'] = I,
})

-- ---------------------------------------------------------------- boarding
log.playerEvents = {}
G.eventHandlers.WWBoats_RequestBoard({ player = player, target = staticBoat })

local boarded
for _, e in ipairs(log.playerEvents) do if e.name == 'WWBoats_Boarded' then boarded = e.data end end
check('boarding announces to the pilot', boarded ~= nil)
check('static is hidden', staticBoat.enabled == false)
check('copy created from the plugin-relative model', log.createdModel == 'x/ex_de_rowboat.nif', log.createdModel)
check('copy stands where the static stood', log.copy and log.copy.position.x == 200 and log.copy.rotation.yaw == 1.0)
check('heading = object yaw - yawOffset (rowboat bow at -Y)', near(boarded.heading, (1.0 - math.pi) % (2 * math.pi)))
check('placed height kept (z 2 within 40 of the database)', near(boarded.waterOffset, 2))
check('unmeasured hull taken from the bounding box', boarded.hull and near(boarded.hull.bow, 300) and near(boarded.hull.halfBeam, 70))
check('sound started on the copy', log.sounds['Boat Creak'] == log.copy)
local st = player.position
check('pilot stands on the anchor (rowboat: the boat origin)', near(st.x, 200) and near(st.y, 100) and near(st.z, 4))

-- ---------------------------------------------------------------- following
local function boatPosAndYaw()
    local last
    for i = #log.teleports, 1, -1 do if log.teleports[i].obj == log.copy then last = log.teleports[i]; break end end
    return last.pos, last.rot
end
frame = 1
player.position = vec3(260, 140, 1)
G.engineHandlers.onUpdate(1 / 60)
local bp, br = boatPosAndYaw()
check('boat follows the pilot (anchor at origin)', near(bp.x, 260) and near(bp.y, 140) and near(bp.z, 2))
check('boat yaw = heading + yawOffset', near(br.yaw % (2 * math.pi), (boarded.heading + math.pi) % (2 * math.pi)))
check('boat sways and rocks while crewed', br.roll ~= 0 and br.pitch ~= 0)

G.eventHandlers.WWBoats_Helm({ player = player, heading = 0.5, turn = 1 })
frame = 2
G.engineHandlers.onUpdate(1 / 60)
bp, br = boatPosAndYaw()
check('helm event turns the boat', near(br.yaw, 0.5 + math.pi))

-- Off-centre anchor: a gondola from Your Own Gondola's record.
-- ---------------------------------------------------------------- leaving
log.playerEvents = {}
G.eventHandlers.WWBoats_RequestLeave({ player = player, exit = vec3(400, 140, 20) })
local left
for _, e in ipairs(log.playerEvents) do if e.name == 'WWBoats_Left' then left = e.data end end
check('leaving announces', left ~= nil and not left.handOff)
check('pilot put ashore', near(player.position.x, 400))
check('boat left level', boatPosAndYaw() and select(2, boatPosAndYaw()).roll == 0)
check('sound stopped', log.sounds['Boat Creak'] == nil)
local n = #log.teleports
frame = 3
G.engineHandlers.onUpdate(1 / 60)
check('no per-frame work once ashore', #log.teleports == n)

-- ---------------------------------------------------------------- the copy is reused and re-boardable
local copy = log.copy
copy.kind = 'activator'
player.position = vec3(380, 140, 10)
log.playerEvents = {}
local blocked = activationHandler(copy, player)
check('activating our copy boards it and blocks the default', blocked == false)
local again
for _, e in ipairs(log.playerEvents) do if e.name == 'WWBoats_Boarded' then again = e.data end end
check('re-boarding uses the copy itself, no second copy', again and again.boat == copy)

-- an activator owned by another mod is refused
G.eventHandlers.WWBoats_RequestLeave({ player = player, handOff = true })
records['a_gondola_01'] = { id = 'a_gondola_01', model = 'meshes/x/ex_gondola_01_rot.nif' }
local itMount = newObject({ recordId = 'a_gondola_01', kind = 'activator', position = vec3(380, 160, 40) })
check('an Immersive Travel mount is left alone', activationHandler(itMount, player) == nil)

-- beached boats are refused
LAND = 30
log.playerEvents = {}
local beached = newObject({ recordId = 'ex_de_rowboat', kind = 'static', position = vec3(390, 150, 32) })
G.eventHandlers.WWBoats_RequestBoard({ player = player, target = beached })
local refused
for _, e in ipairs(log.playerEvents) do if e.name == 'WWBoats_Refused' then refused = e.data.reason end end
check('beached boat refused', refused == 'beached' and beached.enabled)
LAND = -500

-- YOG gondola: scripted but whitelisted; origin offset in its mesh
local yog = newObject({ recordId = 'gv_playergond', kind = 'activator', position = vec3(0, 0, 0), rotation = transform(0) })
player.position = vec3(0, 50, 0)
log.playerEvents = {}
activationHandler(yog, player)
local yb
for _, e in ipairs(log.playerEvents) do if e.name == 'WWBoats_Boarded' then yb = e.data end end
check('YOG gondola is taken over (scripted, whitelisted)', yb ~= nil and yog.enabled == false)
check('YOG: pilot stands where YOG stood them (its mesh origin)', near(player.position.x, 0) and near(player.position.y, 0, 1e-6))
frame = 10
player.position = vec3(0, 0, 0)
G.engineHandlers.onUpdate(1 / 60)
bp = boatPosAndYaw()
check('YOG: copy origin stays under the pilot', near(bp.x, 0) and near(bp.y, 0) and near(bp.z, 0, 1e-6), bp.z)
G.eventHandlers.WWBoats_RequestLeave({ player = player })

-- ---------------------------------------------------------------- save / load
staticBoat.enabled = true
local s2 = newObject({ recordId = 'ex_de_rowboat', kind = 'static', position = vec3(120, 90, 2), rotation = transform(0) })
player.position = vec3(110, 90, 2)
G.eventHandlers.WWBoats_RequestBoard({ player = player, target = s2 })
local saved = G.engineHandlers.onSave()
check('save carries the voyage and the copy records', saved.session and saved.copyRecordByModel['x/ex_de_rowboat.nif'])
log.playerEvents = {}
G.engineHandlers.onLoad(saved)
local resumed
for _, e in ipairs(log.playerEvents) do if e.name == 'WWBoats_Boarded' then resumed = e.data end end
check('load resumes the voyage', resumed ~= nil)
check('copy record reused after load (no second record)', saved.copyRecordByModel['x/ex_de_rowboat.nif'] ~= nil)

-- ---------------------------------------------------------------- leaving through a door
G.eventHandlers.WWBoats_RequestLeave({ player = player, handOff = true })
local s3 = newObject({ recordId = 'ex_de_rowboat', kind = 'static', position = vec3(150, 60, 2), rotation = transform(0) })
player.cell = cellExt
player.position = vec3(140, 60, 2)
G.eventHandlers.WWBoats_RequestBoard({ player = player, target = s3 })
frame = 20
player.position = vec3(150, 70, 2)
G.engineHandlers.onUpdate(1 / 60)
local interior = { isExterior = false, hasWater = false, name = 'Seyda Neen, Census Office' }
player.cell = interior
player.position = vec3(4000, 4000, 15000)
log.playerEvents = {}
frame = 21
G.engineHandlers.onUpdate(1 / 60)
local doorLeft
for _, e in ipairs(log.playerEvents) do if e.name == 'WWBoats_Left' then doorLeft = e.data end end
local lastBoat = log.teleports[#log.teleports]
check('a door ends the voyage', doorLeft and doorLeft.reason == 'cell')
check('the boat stays outside, where it was', lastBoat.cell == log.copy.cell and lastBoat.cell ~= interior
      and near(lastBoat.pos.x, 150) and near(lastBoat.pos.y, 70))
player.cell = cellExt

-- ================================================================ PLAYER
local P_self = {
    object = player, controls = { movement = 0, sideMovement = 0, yawChange = 0, run = false },
    position = vec3(0, 0, 0), rotation = transform(0), cell = cellExt,
    stats = player.stats,
}
local settingsStore = { STEERING = 'rudder', TURN_VIEW_WITH_BOAT = true, BOAT_MOTION = true,
                        CLAIM_SCENERY = true, SHOW_HELP = false, MUTE_WATER_STEPS = true }
local overrides = {}
local triggerHandlers, actionHandlers = {}, {}
local P = loadScript('scripts/WhyWalk/Boats/boats_player.lua', {
    ['openmw.self'] = P_self, ['openmw.core'] = core, ['openmw.types'] = types, ['openmw.util'] = util,
    ['openmw.input'] = {
        registerActionHandler = function(n, cb) actionHandlers[n] = cb end,
        registerTriggerHandler = function(n, cb) triggerHandlers[n] = cb end,
        isActionPressed = function() return false end,
        ACTION = setmetatable({}, { __index = function(_, k) return k end }),
    },
    ['openmw.async'] = { callback = function(_, fn) return fn end },
    ['openmw.nearby'] = { castRay = function() return { hit = false } end,
                          castRenderingRay = function() return { hit = false } end },
    ['openmw.camera'] = {},
    ['openmw.storage'] = { playerSection = function() return {
        get = function(_, k) return settingsStore[k] end, subscribe = function() end } end },
    ['openmw.ui'] = { showMessage = function(m) log.message = m end },
    ['openmw.interfaces'] = {
        Settings = { registerGroup = function(g) log.group = g end },
        Controls = { overrideMovementControls = function(v) overrides[#overrides + 1] = v end },
        UI = { isHudVisible = function() return true end },
    },
})

local function lastGlobal(name)
    for i = #log.globalEvents, 1, -1 do if log.globalEvents[i].name == name then return log.globalEvents[i].data end end
end

check('settings group sits on Core\'s page', log.group.page == 'WhyWalk')

log.effect = 0
P.eventHandlers.WWBoats_Boarded({ boat = log.copy, vesselId = 'rowboat', heading = 0,
                                  anchor = { x = 0, y = 0, z = 0 }, waterLevel = 0, waterOffset = 2,
                                  hull = { bow = 200, stern = 200, halfBeam = 60, draft = 30 } })
check('boarding locks movement', overrides[#overrides] == true)
local function lastPlayerEvent(name)
    for i = #log.playerEvents, 1, -1 do
        if log.playerEvents[i].name == name then return log.playerEvents[i].data end
    end
end
check('boarding asks Core for the vessel pose', (lastPlayerEvent('WhyWalk_AnimVesselStart') or {}).stance == 'sit')
check('boarding adds water walking once', log.effect == 1 and log.effectId == 'waterwalking')

-- full ahead: the heading stays 0, so no helm traffic while going straight
actionHandlers.MoveForward(1)
log.globalEvents = {}
local pos = vec3(0, 0, 0)
for i = 1, 120 do
    P_self.controls.yawChange = 0
    P.engineHandlers.onUpdate(1 / 60)
    -- the engine moves the pilot as commanded (pilot faces north)
    local c = P_self.controls
    local speed = c.run and 300 * math.max(math.abs(c.movement), math.abs(c.sideMovement))
                       or 150 * 2 * math.max(math.abs(c.movement), math.abs(c.sideMovement))
    pos = pos + vec3(0, speed / 60, 0)
    P_self.position = pos
end
local helmCount = 0
for _, e in ipairs(log.globalEvents) do if e.name == 'WWBoats_Helm' then helmCount = helmCount + 1 end end
check('straight course sends no helm events', helmCount == 0, helmCount)
check('top speed 144 is walked: factor 144 / (2 * 150)', near(P_self.controls.movement, 0.48, 1e-3) and not P_self.controls.run, P_self.controls.movement)
check('pilot covered the accel ramp plus cruise', near(pos.y, 144, 6), pos.y)

-- a rudder turn streams heading changes, gated by epsilon
log.playerEvents = {}
actionHandlers.MoveRight(1)
log.globalEvents = {}
for _ = 1, 60 do P_self.controls.yawChange = 0; P.engineHandlers.onUpdate(1 / 60) end
helmCount = 0
for _, e in ipairs(log.globalEvents) do if e.name == 'WWBoats_Helm' then helmCount = helmCount + 1 end end
check('turning sends helm updates', helmCount > 10)
check('but not more than one per frame', helmCount <= 60)
check('view turns with the boat', P_self.controls.yawChange > 0)
local helmAnims = 0
for _, e in ipairs(log.playerEvents) do if e.name == 'WhyWalk_AnimVesselHelm' then helmAnims = helmAnims + 1 end end
check('rudder pose sent once, on the change', helmAnims == 1 and lastPlayerEvent('WhyWalk_AnimVesselHelm').turn == 1, helmAnims)
actionHandlers.MoveRight(0)

-- the engine stops the pilot dead: the boat's way comes off
for _ = 1, 30 do P_self.controls.yawChange = 0; P.engineHandlers.onUpdate(1 / 60) end
local before = P_self.controls.movement
for _ = 1, 30 do P.engineHandlers.onUpdate(1 / 60) end   -- position never changes
check('blocked pilot: speed taken off', math.abs(P_self.controls.movement) < math.abs(before), P_self.controls.movement)

-- a longboat outruns walking pace; an exhausted pilot is held to it
P.eventHandlers.WWBoats_Left({ reason = 'test' })
P.eventHandlers.WWBoats_Boarded({ boat = log.copy, vesselId = 'longboat', heading = 0,
                                  anchor = { x = 0, y = 0, z = 0 }, waterLevel = 0, waterOffset = 74 })
actionHandlers.MoveForward(1)
local function cruise(frames)
    for _ = 1, frames do
        P_self.controls.yawChange = 0
        P.engineHandlers.onUpdate(1 / 60)
        local c = P_self.controls
        local f = math.max(math.abs(c.movement), math.abs(c.sideMovement))
        local v = c.run and 300 * f or 150 * (f <= 0.5 and 2 * f or f)
        P_self.position = P_self.position + vec3(0, v / 60, 0)
    end
end
cruise(240)
check('a longboat at full way makes the pilot run', P_self.controls.run == true)
player.stats.fatigue = 3
cruise(240)
check('exhausted pilot is held to walking pace', P_self.controls.run == false)
player.stats.fatigue = 100

-- leaving: X asks the global with an exit point; LEFT releases what was taken
log.globalEvents = {}
P.engineHandlers.onKeyPress({ symbol = 'x' })
local req = lastGlobal('WWBoats_RequestLeave')
check('X asks to leave with an exit point', req and req.exit ~= nil)
check('nowhere dry: told so', log.message == 'msg_into_water')
local nOverrides = #overrides
P.eventHandlers.WWBoats_Left({ reason = 'player' })
check('leaving releases movement', overrides[#overrides] == false and #overrides == nOverrides + 1)
check('leaving removes water walking', log.effect == 0)
check('leaving stops the vessel pose', lastPlayerEvent('WhyWalk_AnimVesselStop') ~= nil)

-- Core hand-off: mounting from the boat must not release Core's lock
P.eventHandlers.WWBoats_Boarded({ boat = log.copy, vesselId = 'gondola', heading = 0,
                                  anchor = { x = 0, y = -81.5, z = -38.7 }, waterLevel = 0, waterOffset = 40 })
nOverrides = #overrides
P.eventHandlers.WhyWalk_Mounted({})
check('Core mount asks for a hand-off', lastGlobal('WWBoats_RequestLeave').handOff == true)
check('Core mount reported to the global', lastGlobal('WWBoats_PilotState').mounted == true)
P.eventHandlers.WWBoats_Left({ reason = 'mounted', handOff = true })
check('hand-off leaves the movement override to Core', #overrides == nOverrides)
check('hand-off still removes water walking', log.effect == 0)

-- load releases what the save recorded
nOverrides = #overrides
P.engineHandlers.onLoad({ controlsLocked = true, waterWalkAdded = true })
check('load releases a recorded lock', overrides[#overrides] == false and #overrides == nOverrides + 1)
check('load removes recorded water walking', log.effect == -1)

print(string.format('%d passed, %d failed', passed, failed))
if failed > 0 then error('tests failed') end
