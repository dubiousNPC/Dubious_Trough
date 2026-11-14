-- test_intercept.lua -- the shipmaster's menu, against Caravans' engine model
--
--   run from "03 Shipping":  luarun.py tools/test_intercept.lua
--
-- The engine model is Caravans' (tools/test_intercept.lua there): I.UI.MODE
-- as a non-table proxy, opaque cellIds, a UI mode stack that records order,
-- and the REAL global script answering the quote against the real routes.
do
    local hostAtan, hostAtan2 = math.atan, math.atan2
    if not hostAtan2 then
        math.atan2 = function(y, x) return hostAtan(y, x) end
        math.atan = function(y) return hostAtan(y) end
    end
end

package.path = './?.lua;' .. package.path

local passed, failed = 0, 0
local function check(name, cond, detail)
    if cond then
        passed = passed + 1
        print(('  ok   %s'):format(name))
    else
        failed = failed + 1
        print(('  FAIL %s  -> %s'):format(name, tostring(detail)))
    end
end

-- ---------------------------------------------------------------- vectors
local V = {}
V.__index = V
local function vec3(x, y, z) return setmetatable({ x = x, y = y, z = z }, V) end
V.__sub = function(a, b) return vec3(a.x - b.x, a.y - b.y, a.z - b.z) end
function V:length() return math.sqrt(self.x ^ 2 + self.y ^ 2 + self.z ^ 2) end
function V:length2() return self.x ^ 2 + self.y ^ 2 + self.z ^ 2 end

-- ---------------------------------------------------------------- the log
-- Every call that matters lands here in order, so the tests assert on
-- SEQUENCE and not just on final state.
local log = {}
local function note(what) log[#log + 1] = what end
local function sequence() return table.concat(log, ' | ') end
local function sawBefore(a, b)
    local ia, ib
    for i, v in ipairs(log) do
        if v == a and not ia then ia = i end
        if v == b and not ib then ib = i end
    end
    return ia and ib and ia < ib
end

-- The last event sent to the global, so the quote round-trip can be run
-- through the real global handler.
lastGlobal = nil

-- ---------------------------------------------------------------- engine
local guideRecord = {
    class = 'Shipmaster',
    servicesOffered = { Travel = true },
    -- Baleni Salavel, Hla Oad, from Morrowind.esm: three destinations with a
    -- route and one (Molag Mar) without.
    travelDestinations = {
        { cellId = 'Esm3ExteriorCell:2:-13', position = vec3(20380, -102414, 184) },  -- Ebonheart
        { cellId = 'Esm3ExteriorCell:-8:3',  position = vec3(-58675, 26485, 186) },   -- Gnaar Mok
        { cellId = 'Esm3ExteriorCell:4:-10', position = vec3(35749, -74467, 189) },   -- Vivec, Foreign Quarter
        { cellId = 'Esm3ExteriorCell:13:-8', position = vec3(113960, -61258, 761) },  -- Molag Mar
    },
}
local CELL_NAMES = {
    ['Esm3ExteriorCell:2:-13'] = 'Ebonheart', ['Esm3ExteriorCell:-8:3'] = 'Gnaar Mok',
    ['Esm3ExteriorCell:4:-10'] = 'Vivec, Foreign Quarter', ['Esm3ExteriorCell:13:-8'] = 'Molag Mar',
}

local guide = {
    sendEvent = function() end,
    recordId = 'baleni salavel',
    id = '0x1000001',
    position = vec3(-48637, -39658, 112),
    rotation = { getYaw = function() return 0 end },
    cell = { name = 'Hla Oad', displayName = 'Hla Oad', isExterior = true },
    isValid = function() return true end,
}
local caravaner = {
    sendEvent = function() end, recordId = 'darvame hleran', id = '0x1000002',
    position = vec3(-11000, -71000, 300),
    cell = { name = 'Seyda Neen', isExterior = true }, isValid = function() return true end,
}

local playerObj = {
    recordId = 'player',
    position = vec3(-48637, -39808, 112),
    isValid = function() return true end,
    sendEvent = function(_, name) note('player:' .. name) end,
}

local uiMode = nil
local modeStack = {}

local Isettings = {
    registerGroup = function() note('registerGroup') end,
}

-- I.UI.MODE as the engine has it: NOT a table. A coroutine is the only
-- userdata-like value plain Lua can hand out, and giving threads a metatable
-- makes it indexable. Unknown keys raise, as a typo would in the engine, and
-- pairs() raises, because nothing may enumerate it.
local MODE = coroutine.create(function() end)
debug.setmetatable(MODE, {
    __index = function(_, k)
        local known = { Interface = 'Interface', Travel = 'Travel', Dialogue = 'Dialogue' }
        if known[k] == nil then error('I.UI.MODE has no ' .. tostring(k), 2) end
        return known[k]
    end,
    __pairs = function() error('I.UI.MODE cannot be iterated', 2) end,
})
assert(type(MODE) ~= 'table' and MODE.Travel == 'Travel')

local UI = {
    MODE = MODE,
    -- Deliberately WITHOUT a Travel entry, which is the state that broke the
    -- first implementation. If anything starts depending on it again, the
    -- "leaves the vanilla menu alone" assertions below stop passing.
    WINDOW = { Inventory = 'Inventory', Map = 'Map' },
    getMode = function() return uiMode end,
    removeMode = function(m)
        note('removeMode:' .. tostring(m))
        for i = #modeStack, 1, -1 do
            if modeStack[i] == m then table.remove(modeStack, i) end
        end
        uiMode = modeStack[#modeStack]
    end,
    addMode = function(m, opts)
        note('addMode:' .. tostring(m) .. (opts and opts.target and (':' .. opts.target.recordId) or ''))
        modeStack[#modeStack + 1] = m
        uiMode = m
    end,
    registerWindow = function(n) note('registerWindow:' .. tostring(n)) end,
    setMode = function(m)
        note('setMode:' .. tostring(m))
        if m == nil then modeStack = {} else modeStack = { m } end
        uiMode = m
    end,
}

-- UIToolkit, present by default; a later test removes it.
local shownPopup = nil
local listItems = nil
local UIToolkit = {
    version = 4,
    Components = {
        itemList = function(opts)
            note('itemList')
            local l = { opts = opts }
            function l:setItems(items) listItems = items; note('setItems') end
            return l
        end,
    },
    Popups = {
        show = function(opts)
            note('popup:show')
            shownPopup = opts
            return function() note('popup:close') end
        end,
    },
}

package.loaded['openmw.self'] = {
    object = playerObj,
    position = playerObj.position,
    cell = guide.cell,
    rotation = { getYaw = function() return 0 end },
}
package.loaded['openmw.core'] = {
    l10n = function() return function(k) return k end end,
    getGMST = function(n)
        local g = { fTravelMult = 4000, fFatigueBase = 1.25,
                    fFatigueMult = 0.5, fTravelTimeMult = 16000 }
        return g[n]
    end,
    sendGlobalEvent = function(n, payload)
        note('global:' .. n)
        lastGlobal = { name = n, payload = payload }
    end,
    getGameTime = function() return 0 end,
}
package.loaded['openmw.types'] = {
    NPC = {
        objectIsInstance = function(o) return o == guide or o == playerObj or o == caravaner end,
        record = function(o)
            if o == guide then return guideRecord end
            if o == caravaner then return { class = 'Caravaner', servicesOffered = { Travel = true }, travelDestinations = {} } end
            return { servicesOffered = {} }
        end,
        getDisposition = function() return 50 end,
        stats = { skills = { mercantile = function() return { modified = 30 } end } },
    },
    Creature = { objectIsInstance = function() return false end, record = function() return nil end },
    Player = { objectIsInstance = function(o) return o == playerObj end },
    Actor = {
        inventory = function() return { countOf = function() return 500 end } end,
        stats = {
            attributes = {
                luck = function() return { modified = 50 } end,
                personality = function() return { modified = 50 } end,
            },
            dynamic = {
                fatigue = function() return { current = 100, base = 100 } end,
            },
        },
    },
}
package.loaded['openmw.ui'] = {
    showMessage = function(m) note('message:' .. tostring(m)) end,
}
package.loaded['openmw.util'] = {
    vector2 = function(x, y) return { x = x, y = y } end,
    vector3 = vec3,
}
package.loaded['openmw.nearby'] = { actors = { guide } }
-- Settings the module reads. PASSENGER_POSE is a live table rather than a
-- literal so a test can turn it on without reloading the module -- which it
-- could not do anyway, since the section is read once at load.
local SETTINGS = { ANIMATED_TRAVEL = true, SPEED = 1600, ADVANCE_CLOCK = true,
                   PASSENGER_POSE = false }
package.loaded['openmw.storage'] = {
    playerSection = function()
        return { get = function(_, k) return SETTINGS[k] end }
    end,
}
local activationHandlers = {}
local flowOwners = {}
package.loaded['openmw.interfaces'] = {
    Settings = Isettings, UI = UI, UIToolkit = UIToolkit,
    Activation = { addHandlerForType = function(t, fn) activationHandlers[#activationHandlers + 1] = fn end },
    -- Parkourwind FLOW: a passenger is placed every frame and never grounded,
    -- so FLOW is stood down for the journey (caravans_player flowYield).
    Flow = {
        yield = function(o) flowOwners[o] = true end,
        resume = function(o) flowOwners[o] = nil end,
    },
}
package.loaded['openmw.world'] = {
    getCellById = function(id) return { name = CELL_NAMES[id] or '', isExterior = true } end,
}
-- Which files the VFS has. The in-place strider (meshes/whywalk/caravans/) is
-- installed by default; the fallback is exercised against a fresh module below.
local vfsFiles = {
    ['meshes/x/ex_de_ship.nif'] = true,
    ['meshes/x/ex_longboat.nif'] = true,
}
package.loaded['openmw.vfs'] = {
    fileExists = function(f) return vfsFiles[f:lower()] == true end,
}
-- A rotation stub that keeps the YAW recoverable through a roll multiply:
-- placeVehicle composes rotateZ(yaw) * rotateY(roll) for the sway lean, and
-- the tests need to read the yaw back out of the result.
local RotMT = {}
RotMT.__index = RotMT
RotMT.__mul = function(a, b)
    return setmetatable({ yaw = a.yaw, roll = (a.roll or 0) + (b.roll or 0) }, RotMT)
end
function RotMT:getYaw() return self.yaw end
package.loaded['openmw.util'].transform = {
    rotateZ = function(a) return setmetatable({ yaw = a, roll = 0 }, RotMT) end,
    rotateY = function(a) return setmetatable({ yaw = 0, roll = a }, RotMT) end,
}
package.loaded['scripts.UIToolkit.components.list_items.text_item'] = {
    new = function() return {} end,
}


local P = assert(loadfile('scripts/WhyWalk/Shipping/shipping_player.lua'))()
local G = assert(loadfile('scripts/WhyWalk/Shipping/shipping_global.lua'))()
local db = dofile('scripts/WhyWalk/Shipping/shipping_db.lua')
local ev = P.eventHandlers

local function roundTrip()
    assert(lastGlobal and lastGlobal.name == 'WWShipping_RequestQuote', 'no quote request sent')
    local reply
    local sender = lastGlobal.payload.player
    local realSend = sender.sendEvent
    sender.sendEvent = function(_, n, d) reply = { name = n, data = d } end
    G.eventHandlers.WWShipping_RequestQuote(lastGlobal.payload)
    sender.sendEvent = realSend
    assert(reply and reply.name == 'WWShipping_Quote', 'global sent no quote')
    ev.WWShipping_Quote(reply.data)
    return reply.data
end

local function openTravel()
    modeStack, uiMode = { 'Dialogue', 'Travel' }, 'Travel'
    ev.UiModeChanged({ oldMode = 'Dialogue', newMode = 'Travel' })
end

print('registration')
check('UiModeChanged is an event handler', type(ev.UiModeChanged) == 'function'
      and (P.engineHandlers or {}).UiModeChanged == nil)

print('a caravaner is never ours')
log = {}
ev.WWShipping_GuideLatched({ actor = caravaner, ships = false })
openTravel()
check('a caravaner\'s travel window is left alone', not sequence():find('removeMode')
      and not sequence():find('global:WWShipping_RequestQuote'), sequence())

print('a shipmaster')
log = {}
ev.WWShipping_GuideLatched({ actor = guide, ships = true })
local q = roundTrip()
local routed = 0
for _ in pairs(q.byDest) do routed = routed + 1 end
check('three of Baleni Salavel\'s four destinations have a route', routed == 3, routed)
check('Molag Mar has none', q.byDest[4] == nil)
check('Vivec FQ is the Hla Oad route sailed forward', q.byDest[3] and q.byDest[3].reversed == false)
log = {}
openTravel()
check('the engine window is closed BEFORE the popup is shown', sawBefore('removeMode:Travel', 'popup:show'), sequence())
check('four rows: three voyages and "Other destinations"', listItems and #listItems == 4, listItems and #listItems)
local other = listItems and listItems[#listItems]
check('the last row is "Other destinations"', other and other.kind == 'other', other and other.id)
local voyages = 0
for _, r in ipairs(listItems or {}) do if r.destIndex then voyages = voyages + 1 end end
check('the voyage rows carry a destination index and a route', voyages == 3, voyages)

print('"Other destinations" hands the player the engine window')
log = {}
shownPopup.body.opts.onItemClicked(other)
check('the popup closes first', sawBefore('popup:close', 'addMode:Travel:baleni salavel'), sequence())
check('the engine travel window is opened for the same shipmaster', sequence():find('addMode:Travel:baleni salavel', 1, true) ~= nil, sequence())
log = {}
ev.UiModeChanged({ oldMode = nil, newMode = 'Travel' })
check('that window is NOT intercepted', not sequence():find('removeMode') and not sequence():find('popup:show'), sequence())
log = {}
openTravel()
check('the next time, the menu is offered again', sequence():find('popup:show') ~= nil, sequence())

print('booking a voyage')
local row
for _, r in ipairs(listItems) do if r.destIndex == 2 then row = r end end
log = {}; lastGlobal = nil
shownPopup.body.opts.onItemClicked(row)
check('a voyage request goes to the global', lastGlobal and lastGlobal.name == 'WWShipping_RequestTravel', sequence())
local req = lastGlobal and lastGlobal.payload or {}
check('it names the destination by index and the route', req.destIndex == 2 and req.route == q.byDest[2].route)
local d3 = (guideRecord.travelDestinations[2].position - playerObj.position):length()
check('the fare is computed on the 3D distance, as the engine does', req.price == row.price and row.distance == d3,
      tostring(row.distance) .. ' vs ' .. tostring(d3))
check('the clock owes vanilla\'s straight-line hours', req.vanillaHours == math.floor(d3 / 16000), req.vanillaHours)

print('aboard')
ev.WWShipping_Started({ displayName = 'Gnaar Mok', vessel = 'Longboat' })
log = {}
openTravel()
check('the travel window is closed while aboard', sequence():find('removeMode:Travel') ~= nil
      and sequence():find('message:msg_already_travelling') ~= nil, sequence())
ev.WWShipping_Arrived({ displayName = 'Gnaar Mok' })
log = {}
openTravel()
check('after arriving, nothing is latched: the window is left alone', not sequence():find('removeMode'), sequence())

print('without UI Toolkit')
local savedToolkit = package.loaded['openmw.interfaces'].UIToolkit
package.loaded['openmw.interfaces'].UIToolkit = nil
ev.WWShipping_GuideLatched({ actor = guide, ships = true })
roundTrip()
log = {}
openTravel()
check('the vanilla window is left alone', not sequence():find('removeMode') and not sequence():find('popup:show'), sequence())
package.loaded['openmw.interfaces'].UIToolkit = savedToolkit

print(('\n%d passed, %d failed'):format(passed, failed))
if failed > 0 then error('test_intercept failed') end
print('ALL PASS')
