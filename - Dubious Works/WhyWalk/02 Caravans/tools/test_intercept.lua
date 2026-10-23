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

-- ---------------------------------------------------------------- engine
local guideRecord = {
    servicesOffered = { Travel = true },
    travelDestinations = {
        { cellId = 'Ald-ruhn', position = vec3(-18799, 55681, 2630) },
        { cellId = 'Vivec',    position = vec3(19000, -70000, 100) },
        -- No caravan route runs to Gnaar Mok, so this one must be dropped
        -- rather than offered and then failing.
        { cellId = 'Gnaar Mok', position = vec3(-30000, 40000, 100) },
    },
}

local guide = {
    recordId = 'caravaner_test',
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

local UI = {
    MODE = { Interface = 'Interface', Travel = 'Travel', Dialogue = 'Dialogue' },
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
    sendGlobalEvent = function(n) note('global:' .. n) end,
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
package.loaded['openmw.interfaces'] = { Settings = Isettings, UI = UI, UIToolkit = UIToolkit }
package.loaded['scripts.UIToolkit.components.list_items.text_item'] = {
    new = function() return {} end,
}

local P = assert(loadfile('scripts/WhyWalk/Caravans/caravans_player.lua'))()

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

ev.WWCaravans_Quote({
    from = 'balmora',
    routes = {
        ['ald-ruhn'] = { key = 'ald-ruhn', displayName = 'Ald-ruhn', length = 137132 },
        ['vivec'] = { key = 'vivec', displayName = 'Vivec', length = 90000 },
    },
})

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

-- A build with no I.UI.MODE.Travel at all must say so ONCE and not on every
-- travel menu. This is the state the real 0.51 log was in for I.UI.WINDOW, so
-- the diagnostic is the thing that would tell us next time.
--
-- The dump goes to `print`, not to the call log, so print is captured here.
local printed = {}
local realPrint = print
print = function(...)
    local parts = {}
    for i = 1, select('#', ...) do parts[#parts + 1] = tostring((select(i, ...))) end
    printed[#printed + 1] = table.concat(parts, ' ')
end

local savedMode = UI.MODE
UI.MODE = { Interface = 'Interface' }
ev.UiModeChanged({ oldMode = nil, newMode = 'Travel' })
local afterFirst = #printed
ev.UiModeChanged({ oldMode = nil, newMode = 'Travel' })
ev.UiModeChanged({ oldMode = nil, newMode = 'Travel' })
local afterRest = #printed
UI.MODE = savedMode
print = realPrint

local dump = table.concat(printed, '\n')
check('a build without MODE.Travel says so', afterFirst > 0, afterFirst)
check('and lists what I.UI.MODE does expose',
      dump:find('I.UI.MODE', 1, true) ~= nil, dump)
check('and lists I.UI.WINDOW too, which is what was missing in 0.51',
      dump:find('I.UI.WINDOW', 1, true) ~= nil, dump)
check('and names the modes it found, so a report is actionable',
      dump:find('Interface', 1, true) ~= nil, dump)
check('it reports ONCE, not on every travel menu',
      afterRest == afterFirst,
      ('%d lines, then %d'):format(afterFirst, afterRest))

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

print(('\n%d passed, %d failed'):format(passed, failed))
if failed > 0 then os.exit(1) end
print('ALL PASS')
