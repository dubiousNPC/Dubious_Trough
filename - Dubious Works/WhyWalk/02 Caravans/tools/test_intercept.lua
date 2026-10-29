-- test_intercept.lua -- travel-menu interception, against a small engine model
--
--   run from "02 Caravans":  luarun.py tools/test_intercept.lua
--
-- WHY THIS EXISTS
--
-- The first interception shipped untested and did not work. It used
-- I.UI.registerWindow on the documented promise that it overrides a built-in
-- window; I.UI.WINDOW has no Travel entry in OpenMW 0.51, so the module stood
-- down and the player saw the vanilla menu. Nothing in the suite could have
-- caught that, because nothing exercised the interception at all.
--
-- The second shipped tested and still did not work, because this file's
-- engine model was wrong in two places the real engine is not forgiving
-- about (2026-10-28):
--
--   * I.UI.MODE was a plain table here. In OpenMW it is a read-only userdata
--     proxy, and the script's `type(I.UI.MODE) ~= 'table'` gate passed here
--     and failed there. MODE below is now a non-table proxy that errors on
--     unknown keys and on pairs().
--   * Destinations had cellId = 'Ald-ruhn'. An exterior destination's cellId
--     is an engine id, not a place name, so the name lookup the script did
--     matched here and nowhere else. cellIds below are now opaque, and the
--     quote comes from the REAL global script's handler, run against the real
--     route data, instead of being written by hand to fit.
--
-- These assertions cover the three things that decide whether the replacement
-- works, none of which are visible by reading the file:
--
--   * UiModeChanged is registered as an EVENT. Under engineHandlers OpenMW
--     rejects it outright, which is how AnimRefresh v4 shipped a feature that
--     never ran once.
--   * ORDER: the engine's travel window is closed BEFORE the popup is shown.
--     UIToolkit's Popups only adds its own UI mode when the stack is empty, so
--     showing first would leave the menu under Travel mode and then pull
--     Travel out from under it -- visible, unclickable.
--   * The vanilla menu is LEFT ALONE whenever this module cannot take over.
--     Closing it and then failing would leave the player unable to travel.

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
    servicesOffered = { Travel = true },
    travelDestinations = {
        -- Opaque ids on purpose: nothing may resolve a place from cellId.
        { cellId = '#-3, 6',   position = vec3(-18799, 55681, 2630) },  -- Ald-ruhn
        { cellId = '#4, -9',   position = vec3(32500, -70900, 100) },   -- Vivec
        -- Nowhere near any caravan stop, so this one must be dropped rather
        -- than offered and then failing.
        { cellId = '#-12, 18', position = vec3(-98000, 150000, 100) },
    },
}

local guide = {
    sendEvent = function() end,
    recordId = 'caravaner_test',
    id = '0x1000001',
    position = vec3(-21606, -19636, 1315),
    cell = { name = 'Balmora', displayName = 'Balmora', isExterior = true },
    isValid = function() return true end,
}

local playerObj = {
    recordId = 'player',
    position = vec3(-21600, -19630, 1315),
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
    addMode = function(m)
        note('addMode:' .. tostring(m))
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
        objectIsInstance = function(o) return o == guide or o == playerObj end,
        record = function(o) return o == guide and guideRecord or { servicesOffered = {} } end,
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
package.loaded['openmw.storage'] = {
    playerSection = function()
        return { get = function(_, k)
            local v = { ANIMATED_TRAVEL = true, SPEED = 1400, ADVANCE_CLOCK = true }
            return v[k]
        end }
    end,
}
local activationHandlers = {}
package.loaded['openmw.interfaces'] = {
    Settings = Isettings, UI = UI, UIToolkit = UIToolkit,
    Activation = { addHandlerForType = function(t, fn) activationHandlers[#activationHandlers + 1] = fn end },
}
package.loaded['openmw.world'] = {}
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

local P = assert(loadfile('scripts/WhyWalk/Caravans/caravans_player.lua'))()

-- The real global script, for its quote handler. Its load-time route
-- validation prints; that is captured so the dropped-route report can be
-- asserted on.
local globalPrints = {}
local realPrint0 = print
print = function(...) globalPrints[#globalPrints + 1] = table.concat({ ... }, ' ') end
local G = assert(loadfile('scripts/WhyWalk/Caravans/caravans_global.lua'))()
print = realPrint0

check('the global reports the mislabelled suran -> balmora file at load',
      table.concat(globalPrints, '\n'):find('suran -> balmora', 1, true) ~= nil,
      table.concat(globalPrints, ' / '))

-- Deliver the player's last global event to the real global handler, and the
-- global's reply back to the player script.
local function roundTrip()
    assert(lastGlobal and lastGlobal.name == 'WWCaravans_RequestQuote', 'no quote request sent')
    local reply
    local sender = lastGlobal.payload.player
    local realSend = sender.sendEvent
    sender.sendEvent = function(_, n, d) reply = { name = n, data = d } end
    G.eventHandlers.WWCaravans_RequestQuote(lastGlobal.payload)
    sender.sendEvent = realSend
    assert(reply and reply.name == 'WWCaravans_Quote', 'global sent no quote')
    P.eventHandlers.WWCaravans_Quote(reply.data)
    return reply.data
end

-- ---------------------------------------------------------------------------
-- REGISTRATION
-- ---------------------------------------------------------------------------

check('UiModeChanged is an EVENT handler, not an engine handler',
      type(P.eventHandlers.UiModeChanged) == 'function'
      and P.engineHandlers.UiModeChanged == nil,
      type(P.eventHandlers.UiModeChanged))
check('nothing calls registerWindow any more',
      not sawBefore('registerWindow:Travel', 'registerWindow:Travel')
      and not sequence():find('registerWindow'), sequence())

local ev, eh = P.eventHandlers, P.engineHandlers

-- ---------------------------------------------------------------------------
-- IRRELEVANT MODES
-- ---------------------------------------------------------------------------

log = {}
ev.UiModeChanged({ oldMode = nil, newMode = 'Dialogue' })
check('a non-travel mode change does nothing', #log == 0, sequence())
ev.UiModeChanged({ oldMode = 'Travel', newMode = nil })
check('closing a menu does nothing', #log == 0, sequence())
ev.UiModeChanged({})
check('a payload with no newMode does nothing', #log == 0, sequence())

-- ---------------------------------------------------------------------------
-- THE GUIDE MUST BE KNOWN BEFORE THE ROUTES ARE
-- ---------------------------------------------------------------------------

log = {}
ev.WWCaravans_GuideLatched({ actor = guide })
check('latching a travel-selling NPC asks the global for its routes',
      sequence():find('global:WWCaravans_RequestQuote') ~= nil, sequence())

-- Without the quote answered, there are no known routes, so the vanilla menu
-- must be left up.
log = {}
modeStack, uiMode = { 'Dialogue', 'Travel' }, 'Travel'
ev.UiModeChanged({ oldMode = 'Dialogue', newMode = 'Travel' })
check('with no route data yet, the vanilla travel menu is left alone',
      not sequence():find('removeMode') and not sequence():find('popup:show'),
      sequence())

-- ---------------------------------------------------------------------------
-- THE INTERCEPTION
-- ---------------------------------------------------------------------------

local q = roundTrip()
check('the global places the guide at Balmora from its position alone',
      q.from == 'balmora', q.from)
check('destination 1 (opaque cellId) resolves to ald-ruhn by position',
      q.byDest[1] and q.byDest[1].key == 'ald-ruhn', q.byDest[1] and q.byDest[1].key)
check('destination 2 resolves to vivec',
      q.byDest[2] and q.byDest[2].key == 'vivec', q.byDest[2] and q.byDest[2].key)
check('the destination at no stop gets no route',
      q.byDest[3] == nil, q.byDest[3] and q.byDest[3].key)
check('the quote names the guide it is for', q.guide == guide, tostring(q.guide))
check('route lengths are real, not zero',
      q.byDest[1] and q.byDest[1].length > 50000, q.byDest[1] and q.byDest[1].length)

log = {}
modeStack, uiMode = { 'Dialogue', 'Travel' }, 'Travel'
ev.UiModeChanged({ oldMode = 'Dialogue', newMode = 'Travel' })

check('travel mode is intercepted', sequence():find('popup:show') ~= nil, sequence())
check('the engine travel window is closed',
      sequence():find('removeMode:Travel') ~= nil, sequence())
-- THE ORDER ASSERTION. Showing first would leave the popup under Travel mode
-- and then remove it, which is UIToolkit's documented dead-window trap.
check('the window is closed BEFORE the popup is shown',
      sawBefore('removeMode:Travel', 'popup:show'), sequence())
check('the list is populated; an unpopulated itemList renders empty silently',
      sawBefore('itemList', 'setItems'), sequence())

-- ---------------------------------------------------------------------------
-- THE ROWS
-- ---------------------------------------------------------------------------

check('only destinations with a route are offered',
      listItems ~= nil and #listItems == 2, listItems and #listItems)
check('the unrouted destination is dropped, not offered and then failed',
      (function()
          for _, r in ipairs(listItems or {}) do
              if r.id:find('gnaar', 1, true) then return false end
          end
          return true
      end)())
check('every row has a unique id; duplicates make UIToolkit share components',
      (function()
          local seen = {}
          for _, r in ipairs(listItems or {}) do
              if type(r.id) ~= 'string' or seen[r.id] then return false end
              seen[r.id] = true
          end
          return true
      end)())
check('every row carries a price and a destination key',
      (function()
          for _, r in ipairs(listItems or {}) do
              if type(r.price) ~= 'number' or r.price < 1 then return false end
              if type(r.key) ~= 'string' then return false end
          end
          return true
      end)())
check('the row text names the place and the fare',
      listItems and listItems[1].text:find('gp') ~= nil,
      listItems and listItems[1].text)

-- ---------------------------------------------------------------------------
-- CHOOSING A DESTINATION
-- ---------------------------------------------------------------------------

log = {}
local row
for _, r in ipairs(listItems) do if r.key == 'ald-ruhn' then row = r end end
shownPopup.body = shownPopup.body    -- the itemList component
-- The click callback lives on the itemList opts: ItemList has ONE callback for
-- the whole list, so the row is dispatched on by the handler.
local onClick = nil
do
    -- recover the opts table the module passed to itemList
    local probe = UIToolkit.Components.itemList
    local captured
    UIToolkit.Components.itemList = function(opts)
        captured = opts
        local l = { opts = opts }
        function l:setItems() end
        return l
    end
    modeStack, uiMode = { 'Dialogue', 'Travel' }, 'Travel'
    ev.UiModeChanged({ oldMode = 'Dialogue', newMode = 'Travel' })
    onClick = captured and captured.onItemClicked
    UIToolkit.Components.itemList = probe
end

check('the list has a click callback', type(onClick) == 'function', type(onClick))

log = {}
onClick(row)
check('choosing a destination closes the menu',
      sequence():find('popup:close') ~= nil, sequence())
check('choosing a destination asks the global to travel',
      sequence():find('global:WWCaravans_RequestTravel') ~= nil, sequence())
check('the menu closes before the journey is requested',
      sawBefore('popup:close', 'global:WWCaravans_RequestTravel'), sequence())

-- The journey confirmation must clear the UI, including the DIALOGUE window
-- the travel topic was reached through -- interception removes only the
-- Travel mode, so dialogue is still open underneath.
log = {}
ev.WWCaravans_Started({ displayName = 'Ald-ruhn' })
check('departing clears every UI mode, dialogue included',
      sequence():find('setMode:nil') ~= nil, sequence())

-- ---------------------------------------------------------------------------
-- RE-ENTRY
-- ---------------------------------------------------------------------------
-- removeMode causes another UiModeChanged. Handling that one would ask the
-- same question with the window already gone.

log = {}
local reentered = 0
local realRemove = UI.removeMode
UI.removeMode = function(m)
    reentered = reentered + 1
    realRemove(m)
    -- the engine would deliver this as a consequence of the removal
    ev.UiModeChanged({ oldMode = 'Travel', newMode = 'Dialogue' })
end
modeStack, uiMode = { 'Dialogue', 'Travel' }, 'Travel'
ev.UiModeChanged({ oldMode = 'Dialogue', newMode = 'Travel' })
UI.removeMode = realRemove
check('the mode is removed exactly once, not recursively', reentered == 1, reentered)

-- ---------------------------------------------------------------------------
-- DEGRADING
-- ---------------------------------------------------------------------------

-- No UI Toolkit: the vanilla menu must be left up rather than closed.
log = {}
local savedToolkit = package.loaded['openmw.interfaces'].UIToolkit
package.loaded['openmw.interfaces'].UIToolkit = nil
modeStack, uiMode = { 'Dialogue', 'Travel' }, 'Travel'
ev.UiModeChanged({ oldMode = 'Dialogue', newMode = 'Travel' })
check('without UI Toolkit the vanilla menu is left alone',
      not sequence():find('removeMode') and not sequence():find('popup:show'),
      sequence())
package.loaded['openmw.interfaces'].UIToolkit = savedToolkit

-- No travel-selling actor anywhere: likewise.
log = {}
package.loaded['openmw.nearby'].actors = {}
local savedLatch = guideRecord.servicesOffered
guideRecord.servicesOffered = { Travel = false }
modeStack, uiMode = { 'Dialogue', 'Travel' }, 'Travel'
ev.UiModeChanged({ oldMode = 'Dialogue', newMode = 'Travel' })
check('with no travel-selling guide the vanilla menu is left alone',
      not sequence():find('removeMode') and not sequence():find('popup:show'),
      sequence())
guideRecord.servicesOffered = savedLatch
package.loaded['openmw.nearby'].actors = { guide }

-- A quote for a DIFFERENT guide must not be used for this one: the reply is
-- a couple of frames late, and the player may have walked to another stop.
log = {}
local otherGuide = { isValid = function() return true end }
P.eventHandlers.WWCaravans_Quote({ guide = otherGuide, from = 'vivec', byDest = { { key = 'balmora', length = 1 } } })
modeStack, uiMode = { 'Dialogue', 'Travel' }, 'Travel'
ev.UiModeChanged({ oldMode = 'Dialogue', newMode = 'Travel' })
check('a quote for another guide leaves the vanilla menu alone',
      not sequence():find('removeMode') and not sequence():find('popup:show'), sequence())

-- A guide away from any stop: the global says so, and so does the log.
local printed = {}
local realPrint = print
print = function(...) printed[#printed + 1] = table.concat({ ... }, ' ') end
local home = guide.position
guide.position = vec3(-98000, 150000, 100)
ev.WWCaravans_GuideLatched({ actor = guide })
local q2 = roundTrip()
modeStack, uiMode = { 'Dialogue', 'Travel' }, 'Travel'
log = {}
ev.UiModeChanged({ oldMode = 'Dialogue', newMode = 'Travel' })
ev.UiModeChanged({ oldMode = 'Dialogue', newMode = 'Travel' })
guide.position = home
print = realPrint
local out = table.concat(printed, '\n')
check('a guide at no stop gets no origin', q2.from == nil, q2.from)
check('and keeps the vanilla menu',
      not sequence():find('removeMode') and not sequence():find('popup:show'), sequence())
check('and the log says why, from both sides',
      out:find('not at a known stop', 1, true) ~= nil
      and out:find('vanilla travel window kept', 1, true) ~= nil, out)
local n = 0
for _ in out:gmatch('vanilla travel window kept') do n = n + 1 end
check('each stand-down reason is printed once, not every menu', n == 1, n)

-- The settings switch.
log = {}
local savedStorage = package.loaded['openmw.storage']
package.loaded['openmw.storage'] = {
    playerSection = function()
        return { get = function(_, k)
            if k == 'ANIMATED_TRAVEL' then return false end
            return nil
        end }
    end,
}
-- The module read its section at load, so this cannot be re-read here; the
-- assertion that matters is that the switch is consulted on every open rather
-- than cached, which the source does by calling animatedTravel() in the
-- handler. Documented rather than asserted.
package.loaded['openmw.storage'] = savedStorage

-- ---------------------------------------------------------------------------
-- THE JOURNEY: PLACEMENT, YAW AND POSE
-- ---------------------------------------------------------------------------
-- Drives the REAL global script through a real route and watches where it puts
-- the three bodies and how it rotates the player. These are the four faults
-- reported from the first working trip:
--
--   * the strider stood with its feet at the player's height
--   * no animation played on the player
--   * the camera was welded to the strider's heading
--   * the driver rode behind the passenger
--
-- Each assertion below fails if its fix is reverted; the file's own notes say
-- which line to put back.

local db = dofile('scripts/WhyWalk/Caravans/caravans_db.lua')
local VEH = db.VEHICLE.siltstrider

-- A world that records every teleport instead of performing one.
local placed = {}          -- [tag] = { x, y, z, yaw, hadRotation, onGround }
local history = { vehicle = {} }   -- every z the vehicle was placed at
local vehicleObj

local function tagOf(obj)
    if obj == playerObj then return 'player' end
    if obj == guide then return 'guide' end
    return 'vehicle'
end

-- THE ENGINE ALLOWS ONE TELEPORT PER OBJECT PER FRAME. A second call before
-- the first has landed raises, and it is a hard error that aborts the whole
-- handler -- which is exactly how the teardown used to die halfway through,
-- leaving a second strider standing at the stop and the player glued to its
-- back. The old mock let it through silently, so the suite passed on code
-- that could not finish a journey. Modelling the rule is the fix.
local frameNo = 0
local lastTeleportFrame = setmetatable({}, { __mode = 'k' })

local function recordTeleport(obj)
    obj.teleport = function(self_, cell, pos, options)
        if lastTeleportFrame[self_] == frameNo then
            error('Object is either removed or already in the process of teleporting', 0)
        end
        lastTeleportFrame[self_] = frameNo
        local yaw, had = nil, false
        if options then
            had = true
            if options.getYaw then yaw = options:getYaw()
            elseif options.rotation and options.rotation.getYaw then
                yaw = options.rotation:getYaw()
            else had = false end     -- a TeleportOptions with no rotation
        end
        self_.position = pos
        placed[tagOf(self_)] = { x = pos.x, y = pos.y, z = pos.z,
                                 yaw = yaw, hadRotation = had,
                                 onGround = options and options.onGround or false }
        local h = history[tagOf(self_)]
        if h then h[#h + 1] = pos.z end
    end
end
recordTeleport(playerObj)
recordTeleport(guide)

-- The player's own facing, which mouse-look owns. rotation:getYaw() must be
-- read back by the global, not assumed, or the delta has nothing to land on.
local playerYaw = 0
playerObj.rotation = { getYaw = function() return playerYaw end }
local realPlayerTeleport = playerObj.teleport
playerObj.teleport = function(self_, cell, pos, options)
    realPlayerTeleport(self_, cell, pos, options)
    if placed.player.hadRotation then playerYaw = placed.player.yaw end
end

package.loaded['openmw.world'].createObject = function(recordId)
    vehicleObj = {
        recordId = recordId,
        position = vec3(0, 0, 0),
        isValid = function() return true end,
        hasScript = function() return true end,
        addScript = function() end,
        removeScript = function() end,
        sendEvent = function() end,
    }
    recordTeleport(vehicleObj)
    return vehicleObj
end
package.loaded['openmw.world'].createRecord = function(d) return { id = 'ww_test_strider' } end
package.loaded['openmw.world'].advanceTime = function() end
package.loaded['openmw.core'].isWorldPaused = function() return false end
package.loaded['openmw.types'].Actor.stats.dynamic.health =
    function() return { current = 100, base = 100 } end
package.loaded['openmw.types'].Creature.createRecordDraft = function(d) return d end
-- A load order that HAS a strider creature, so the vehicle is a creature and
-- its gait can play. The activator fallback is a different path.
package.loaded['openmw.types'].Creature.records = {
    c_siltstrider = { id = 'c_siltstrider', model = 'r\\Siltstrider.nif' },
}
package.loaded['openmw.types'].Actor.inventory = function()
    return { countOf = function() return 100000 end,
             find = function() return { remove = function() end } end }
end

-- Journey events the player script would receive.
local poseLog = {}
local realPlayerSend = playerObj.sendEvent
playerObj.sendEvent = function(obj, name, data)
    realPlayerSend(obj, name)
    if P.eventHandlers[name] then P.eventHandlers[name](data) end
end
local realSelfSend = package.loaded['openmw.self'].object.sendEvent
package.loaded['openmw.self'].object.sendEvent = function(obj, name, data)
    if name:find('AnimVessel') then
        poseLog[#poseLog + 1] = { name = name, stance = data and data.stance }
    end
    return realSelfSend(obj, name, data)
end

---One simulation frame: bumps the counter the teleport rule is keyed on.
local guideHome = guide.position

local function frame(dt)
    frameNo = frameNo + 1
    return G.engineHandlers.onUpdate(dt or 0.016)
end

log = {}
G.eventHandlers.WWCaravans_RequestTravel({
    player = playerObj, guide = guide, from = 'balmora', to = 'ald-ruhn',
})

check('a journey starts', vehicleObj ~= nil)

-- ------------------------------------------------------------------ the pose
check('departing sends the vessel pose START',
      poseLog[1] and poseLog[1].name == 'WhyWalk_AnimVesselStart',
      poseLog[1] and poseLog[1].name)
check("the stance is 'passenger', which resolves rasit2",
      poseLog[1] and poseLog[1].stance == 'passenger',
      poseLog[1] and poseLog[1].stance)

-- ------------------------------------------------------- placement, frame 1
-- A teleport fall-through needs no proving, so it is reported at once: the
-- player whose camera is locking wants to know why on their first journey.
-- Once per session, not once per frame.
local pathSaid = {}
do
    local realPrint2 = print
    print = function(...) pathSaid[#pathSaid + 1] = table.concat({ ... }, ' ') end
    frame(0.016)
    frame(0.016)
    print = realPrint2
end
local pathMsg = table.concat(pathSaid, '\n')
check('with no rider pin, the teleport path is reported at once',
      pathMsg:find('carried by TELEPORT', 1, true) ~= nil, pathMsg)
check('and the report names onTeleported, which is the actual mechanism',
      pathMsg:find('onTeleported', 1, true) ~= nil, pathMsg)
check('and says what would avoid it',
      pathMsg:find('WhyWalkRiderPin', 1, true) ~= nil, pathMsg)
check('reported once, not on every frame',
      select(2, pathMsg:gsub('carried by', '')) == 1, pathMsg)
check('the vehicle is placed', placed.vehicle ~= nil)
check('the player is placed', placed.player ~= nil)
check('the guide is placed', placed.guide ~= nil)

-- THE HEIGHT FAULT. The strider's origin must sit bodyOffset BELOW the route,
-- and the riders must be measured up from that same origin. Placing the
-- vehicle at the route point instead is what put its feet at the rider's
-- waist.
check('the vehicle origin is bodyOffset below the riders, not level with them',
      math.abs((placed.player.z - placed.vehicle.z) - VEH.slots[1].z) < 1e-6,
      ('player z - vehicle z = %.1f, slot z = %d')
          :format(placed.player.z - placed.vehicle.z, VEH.slots[1].z))
check('the guide is measured from the same origin as the player',
      math.abs((placed.guide.z - placed.vehicle.z) - VEH.guideSlot.z) < 1e-6,
      placed.guide.z - placed.vehicle.z)
check('the strider therefore stands well below its riders',
      placed.vehicle.z < placed.player.z - 1000,
      ('vehicle %.1f vs player %.1f'):format(placed.vehicle.z, placed.player.z))

-- THE SEATING FAULT, as it lands in the world rather than as data.
local function along(p, yaw)
    -- distance along the vehicle's forward axis, which is (sin yaw, cos yaw)
    return p.x * math.sin(yaw) + p.y * math.cos(yaw)
end
do
    local yaw = placed.vehicle.yaw or 0
    check('the driver sits FORWARD of the player on the strider',
          along(placed.guide, yaw) > along(placed.player, yaw) + 1,
          ('guide %.1f vs player %.1f')
              :format(along(placed.guide, yaw), along(placed.player, yaw)))
end

-- -------------------------------------------------------------- the camera
check('the first frame does not rotate the player at all',
      placed.player.hadRotation == false,
      'rotation was written on the very first placement')

-- Mouse-look: the player turns their head 1 radian. Nothing about the journey
-- may undo that.
playerYaw = 1.0
local headingBefore = placed.vehicle.yaw
for _ = 1, 400 do frame(0.016) end
local headingAfter = placed.vehicle.yaw

check('the strider changed heading over those frames',
      math.abs(headingAfter - headingBefore) > 1e-3,
      ('%.4f -> %.4f'):format(headingBefore, headingAfter))

-- THE CAMERA FAULT. With an absolute `rotateZ(heading)` the player's yaw would
-- now BE the strider's heading and the 1 radian would be gone. With a delta it
-- is heading-change plus the radian the player added.
local turned = headingAfter - headingBefore
check("the player's own 1 rad of mouse-look survived the journey",
      math.abs(playerYaw - (1.0 + turned)) < 1e-6,
      ('player yaw %.6f, expected %.6f'):format(playerYaw, 1.0 + turned))
check('and the player is NOT simply facing the way the strider faces',
      math.abs(playerYaw - headingAfter) > 0.5,
      ('player %.4f vs strider %.4f'):format(playerYaw, headingAfter))
check('the player still turned WITH the strider, not against it',
      math.abs((playerYaw - 1.0) - turned) < 1e-6,
      playerYaw - 1.0)

-- The guide has no camera, so an absolute heading is right for them.
check('the guide faces the way the strider faces',
      placed.guide.hadRotation and math.abs(placed.guide.yaw - headingAfter) < 1e-6,
      placed.guide.yaw)

-- --------------------------------------------------------------- arriving
--
-- THE TEARDOWN MUST SURVIVE ITS OWN FRAME. It teleports all three bodies, and
-- onUpdate has already teleported all three, so running it inline raised
-- "Object is either removed or already in the process of teleporting" at its
-- very first statement -- aborting the handler and leaving the vehicle
-- unparked, the guide carried off, the player glued to the strider's back and
-- no ARRIVED event sent. The mock above now enforces that engine rule, so
-- putting the teardown back inline fails here instead of in the game.
local function lastPose() return poseLog[#poseLog] and poseLog[#poseLog].name end
local arriveErr
for _ = 1, 20000 do
    local ok, err = pcall(frame, 0.05)
    if not ok then arriveErr = err; break end
    if lastPose() == 'WhyWalk_AnimVesselStop' then break end
end
check('no frame of the journey, arrival included, raises',
      arriveErr == nil, tostring(arriveErr))
check('arriving sends the vessel pose STOP',
      lastPose() == 'WhyWalk_AnimVesselStop', tostring(lastPose()))
check('the vehicle is parked out of the world, not left at the stop',
      placed.vehicle.z < -20000, ('%.0f'):format(placed.vehicle.z))
check('the guide is put back on their post',
      math.abs(placed.guide.x - guideHome.x) < 1e-6
      and math.abs(placed.guide.y - guideHome.y) < 1e-6,
      ('%.0f,%.0f vs home %.0f,%.0f')
          :format(placed.guide.x, placed.guide.y, guideHome.x, guideHome.y))
-- Dismount: at the body origin of the last route point, with onGround so the
-- engine finds the real floor rather than a heightmap guess. Comparing against
-- the vehicle is no good here -- it has already been parked at -30000.
-- The last z the vehicle stood at before endJourney parked it at -30000.
-- That is the body origin of the final route point, and the dismount uses the
-- SAME origin -- which is the whole point of there being one bodyOrigin.
local ridingOrigin = history.vehicle[#history.vehicle - 1]
check('the player is put down at the body origin, not at riding height',
      ridingOrigin and math.abs(placed.player.z - ridingOrigin) < 1e-6,
      ('dismount %.1f vs last vehicle origin %s')
          :format(placed.player.z, tostring(ridingOrigin)))
check('and the engine is asked to settle them on the ground',
      placed.player.onGround == true, tostring(placed.player.onGround))

-- ---------------------------------------------------------------------------
-- THE RIDER PIN
-- ---------------------------------------------------------------------------
-- Everything above ran with Core's WhyWalkRiderPin ABSENT, which is the
-- teleport fallback -- so those assertions already cover the no-Core case.
-- This covers the case that matters for mod compatibility: with the pin
-- available, the player must not be teleported at all, because a teleport
-- fires onTeleported on every other player script in the load order and that
-- is what locked the camera to first person for a whole journey.

local pinCalls, pinReleases, pinHeldByOther = {}, 0, false
package.loaded['openmw.interfaces'].WhyWalkRiderPin = {
    isBridged = function() return true end,
    place = function(owner, player, pos, yawDelta)
        if pinHeldByOther then return false end
        pinCalls[#pinCalls + 1] = { owner = owner, pos = pos, yawDelta = yawDelta }
        return true
    end,
    release = function() pinReleases = pinReleases + 1 end,
}

placed.player = nil
pinCalls = {}
G.eventHandlers.WWCaravans_RequestTravel({
    player = playerObj, guide = guide, from = 'balmora', to = 'ald-ruhn',
})
frame(0.016)
frame(0.016)

check('with Core present the player goes through the pin',
      #pinCalls >= 2, #pinCalls)
check('and is NOT teleported, so no other mod sees onTeleported',
      placed.player == nil, placed.player and 'teleported anyway')
check('the pin is claimed by one owner, the same one every frame',
      pinCalls[1].owner ~= nil and pinCalls[1].owner == pinCalls[2].owner)
check('the pin still gets the yaw as a delta, not a heading',
      pinCalls[2].yawDelta == nil
      or math.abs(pinCalls[2].yawDelta) < 1,
      tostring(pinCalls[2].yawDelta))
check('the vehicle and the guide are still teleported; only the player is pinned',
      placed.vehicle ~= nil and placed.guide ~= nil)

-- The path report must wait for Core's liveness verdict. Reporting on frame 1
-- would print the optimistic "bridged" answer and then quietly fall back,
-- which is worse than silence -- the whole point of that line is to settle
-- which path is in use without another round of guessing.
do
    local said = {}
    local realPrint2 = print
    print = function(...) said[#said + 1] = table.concat({ ... }, ' ') end
    for _ = 1, 10 do frame(0.016) end
    print = realPrint2
    local joined = table.concat(said, '\n')
    check('no rider-path claim is made while the bridge is still unproven',
          not joined:find('carried by', 1, true), joined)
end

-- The pin must be given back, or it keeps writing the player to the saddle
-- after the journey has ended.
pinReleases = 0
G.eventHandlers.WWCaravans_RequestAbort({ player = playerObj })
frame(0.016)
check('ending the journey releases the pin', pinReleases >= 1, pinReleases)

-- Core's mount holds the pin: a journey started while riding must not fight
-- it for the player's position, so Caravans falls back to its own teleport
-- rather than silently not moving the player at all.
pinHeldByOther = true
placed.player, pinCalls = nil, {}
G.eventHandlers.WWCaravans_RequestTravel({
    player = playerObj, guide = guide, from = 'balmora', to = 'ald-ruhn',
})
frame(0.016)
check('a pin held elsewhere falls back to teleport rather than dropping the rider',
      placed.player ~= nil)

pinHeldByOther = false
G.eventHandlers.WWCaravans_RequestAbort({ player = playerObj })
frame(0.016)

package.loaded['openmw.interfaces'].WhyWalkRiderPin = nil

-- An abort must clear the pose too, or the player sits cross-legged forever.
--
-- And it is the case that CANNOT be fixed by skipping the placement on the
-- last frame: the abort arrives as an event, in a frame where onUpdate has
-- already moved everything. Requesting it right after a placement frame is
-- the hostile ordering, so that is what is tested.
poseLog = {}
G.eventHandlers.WWCaravans_RequestTravel({
    player = playerObj, guide = guide, from = 'balmora', to = 'ald-ruhn',
})
frame(0.016)
G.eventHandlers.WWCaravans_RequestAbort({ player = playerObj })
check('an abort in a frame that already placed the bodies does not raise',
      pcall(frame, 0.016))
check('aborting clears the pose as well as arriving',
      lastPose() == 'WhyWalk_AnimVesselStop', tostring(lastPose()))
check('and parks the vehicle', placed.vehicle.z < -20000,
      ('%.0f'):format(placed.vehicle.z))

-- And a load, because the global puts the player on the ground in its own
-- onLoad and a surviving pose would outlive the journey.
poseLog = {}
P.engineHandlers.onLoad({})
check('loading a save clears the pose', #poseLog == 1
      and poseLog[1].name == 'WhyWalk_AnimVesselStop', #poseLog)

print(('\n%d passed, %d failed'):format(passed, failed))
if failed > 0 then os.exit(1) end
print('ALL PASS')
