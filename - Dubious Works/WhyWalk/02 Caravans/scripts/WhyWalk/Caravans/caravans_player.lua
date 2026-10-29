---@omw-context player
--[[
    caravans_player.lua -- intercepting the travel menu, and the fare

    HOW THE VANILLA TRAVEL MENU IS REPLACED

    By watching the UI MODE, not by overriding the window. The detail is in
    the INTERCEPTION section below; the short version is that the first
    version of this file tried I.UI.registerWindow and the game said no:

        [WhyWalk Caravans] this OpenMW build exposes no Travel window name
        through I.UI.WINDOW, so the travel menu cannot be intercepted.

    I.UI.WINDOW has no Travel entry in OpenMW 0.51. That was the one thing
    this header previously called INFERRED, and it was the thing that was
    wrong -- `registerWindow` can only override windows the engine publishes
    by name, and the travel window is not among them.

    What replaced it rests only on things known from working code:
    UiModeChanged's { oldMode, newMode } payload (AnimRefresh v5 reads exactly
    those), I.UI.MODE.Travel (Ben's Rideable Silt Striders keys its whole mod
    off it), and I.UI.removeMode.

    Still event-driven. Ben's mod reaches the same moment with a per-frame
    `if I.UI.getMode() == I.UI.MODE.Travel`, which spends a frame handler for
    the whole game to catch a menu opened twice an hour.

    WHEN IT CANNOT HELP, THE VANILLA MENU IS LEFT ALONE -- no UI Toolkit, no
    guide, or no imported route from here, and the engine's own travel window
    stays up and works. The module never leaves the player with no way to
    travel.

    HOW THE GUIDE IS IDENTIFIED

    UiModeChanged carries { oldMode, newMode } and no target -- AnimRefresh v5
    reads exactly those two fields and nothing else. So the guide is latched
    at ACTIVATION instead: the global script watches NPC activation and sends
    the actor here, because activating an NPC is the only way to reach their
    travel topic. Nearest-Travel-offering-actor is the fallback, which is what
    Ben's mod relies on entirely.
]]

local core    = require('openmw.core')
local self    = require('openmw.self')
local types   = require('openmw.types')
local ui      = require('openmw.ui')
local util    = require('openmw.util')
local nearby  = require('openmw.nearby')
local storage = require('openmw.storage')
local I       = require('openmw.interfaces')

local db     = require('scripts.WhyWalk.Caravans.caravans_db')
local routes = require('scripts.WhyWalk.Caravans.caravans_routes')

local EV = {
    REQUEST_TRAVEL = 'WWCaravans_RequestTravel',
    REQUEST_QUOTE  = 'WWCaravans_RequestQuote',
    QUOTE          = 'WWCaravans_Quote',
    STARTED        = 'WWCaravans_Started',
    ARRIVED        = 'WWCaravans_Arrived',
    ABORTED        = 'WWCaravans_Aborted',
    REQUEST_ABORT  = 'WWCaravans_RequestAbort',
    GUIDE_LATCHED  = 'WWCaravans_GuideLatched',
}

local L10N = 'WhyWalkCaravans'
local l10n = core.l10n(L10N)

-- ---------------------------------------------------------------------------
-- SETTINGS
-- ---------------------------------------------------------------------------
-- A group on Core WhyWalk's page, which Core's whywalk_player.lua registers.
-- This module loads after Core, so the page exists -- the same ordering Boats
-- relies on, and the reason Core's page registration moved to the first-
-- loading file on 2026-10-22.

local GROUP = 'SettingsWhyWalkCaravans'

I.Settings.registerGroup {
    key = GROUP, page = 'WhyWalk', l10n = L10N,
    name = 'caravans_group_name', description = 'caravans_group_description',
    permanentStorage = true,
    order = 1,
    settings = {
        {
            key = 'ANIMATED_TRAVEL', name = 'caravans_enabled_name',
            description = 'caravans_enabled_description',
            renderer = 'checkbox', default = true,
        },
        {
            key = 'SPEED', name = 'caravans_speed_name',
            description = 'caravans_speed_description',
            renderer = 'number', integer = true, default = 1400,
            argument = { min = 200, max = 6000 },
        },
        {
            key = 'ADVANCE_CLOCK', name = 'caravans_clock_name',
            description = 'caravans_clock_description',
            renderer = 'checkbox', default = true,
        },
    },
}

local settings = storage.playerSection(GROUP)

local function animatedTravel() return settings:get('ANIMATED_TRAVEL') ~= false end
local function advanceClock()   return settings:get('ADVANCE_CLOCK') ~= false end
local function travelSpeed()
    local v = tonumber(settings:get('SPEED'))
    return (v and v > 0) and v or 1400
end

-- ---------------------------------------------------------------------------
-- STATE
-- ---------------------------------------------------------------------------

local latchedGuide = nil     -- the NPC whose dialogue we are in, if any
local quote = nil            -- { guide, from, byDest[i] } from the global; see onQuote
local travelling = false
local closeMenu = nil        -- the close function Popups.show returns

-- ---------------------------------------------------------------------------
-- THE PASSENGER'S POSE
-- ---------------------------------------------------------------------------
-- Core's vessel-pose layer, reused rather than reimplemented. ridingAnim.lua
-- is already attached to the player, already owns the blend layer and the
-- group fallback chain, and already re-asserts the pose when the engine
-- interrupts it -- which it does here constantly, because a passenger
-- teleported along a route counts as AIRBORNE and the engine's falling
-- animation outranks a pose that is not re-played.
--
-- Nothing is required from Core to send these: they are plain events, so
-- Caravans still works with Core absent (no pose, no error).
--
-- The stance is 'passenger' (whywalk_shared.VESSEL_STANCE): rasit2 from the
-- xRAsit1 pack, falling through to a floor sit and then vanilla idle when
-- that pack is not installed.
--
-- No HELM event. The passenger is not steering, so the stance has one field
-- and there is nothing to switch between -- which also means this costs
-- exactly two events per journey rather than anything per frame.
local POSE = {
    START = 'WhyWalk_AnimVesselStart',
    STOP  = 'WhyWalk_AnimVesselStop',
}
local POSE_STANCE = 'passenger'

-- ---------------------------------------------------------------------------
-- THE GUIDE
-- ---------------------------------------------------------------------------

---Does this actor sell travel?
---
---servicesOffered and travelDestinations are RECORD fields, so an actor with
---no record (or a creature guide, which Morrowind has none of but a mod may)
---falls through to false rather than raising.
local function offersTravel(actor)
    if not actor or not actor:isValid() then return false end
    local rec
    if types.NPC.objectIsInstance(actor) then
        rec = types.NPC.record(actor)
    elseif types.Creature.objectIsInstance(actor) then
        rec = types.Creature.record(actor)
    end
    if not rec then return false end
    local services = rec.servicesOffered
    return services ~= nil and services.Travel == true
end

local function travelDestinationsOf(actor)
    local rec
    if types.NPC.objectIsInstance(actor) then
        rec = types.NPC.record(actor)
    elseif types.Creature.objectIsInstance(actor) then
        rec = types.Creature.record(actor)
    end
    return rec and rec.travelDestinations or nil
end

---The guide the player is dealing with: the latched one if it still offers
---travel, else the nearest actor that does.
local function currentGuide()
    if latchedGuide and latchedGuide:isValid() and offersTravel(latchedGuide) then
        return latchedGuide
    end
    local best, bestDist = nil, math.huge
    for _, actor in ipairs(nearby.actors) do
        if offersTravel(actor) then
            local d = (actor.position - self.position):length2()
            if d < bestDist then best, bestDist = actor, d end
        end
    end
    return best
end

-- ---------------------------------------------------------------------------
-- PRICE
-- ---------------------------------------------------------------------------

---Gather everything caravans_db.price needs from the engine.
---
---Kept in one place so the pure module stays pure and every GMST read is
---visible together. Reads are per MENU OPEN, not per frame.
local function priceInputs(guide, distance, followers)
    local stat, npcStat = types.Actor.stats, types.NPC.stats

    -- Mercantile is read through an existence check rather than assumed.
    -- Cod3x declares SkillStats as an empty class with no documented members,
    -- so `skills.mercantile` is evidence from Immersive Travel's working code
    -- rather than from the API surface -- and it does not exist at all for a
    -- CREATURE, which Morrowind has no travel-selling example of but a mod
    -- may. A guide with no mercantile skill prices as if it were 0, which is
    -- the engine's own behaviour for an actor without the skill.
    local function mercantileOf(actor)
        if not types.NPC.objectIsInstance(actor) then return 0 end
        local skills = npcStat and npcStat.skills
        local accessor = skills and skills.mercantile
        if not accessor then return 0 end
        local v = accessor(actor)
        return (v and v.modified) or 0
    end

    local function statsOf(actor)
        return {
            luck = stat.attributes.luck(actor).modified,
            personality = stat.attributes.personality(actor).modified,
            mercantile = mercantileOf(actor),
            fatigueCurrent = stat.dynamic.fatigue(actor).current,
            fatigueBase = stat.dynamic.fatigue(actor).base,
        }
    end
    return {
        distance = distance,
        fTravelMult = core.getGMST('fTravelMult'),
        fFatigueBase = core.getGMST('fFatigueBase'),
        fFatigueMult = core.getGMST('fFatigueMult'),
        disposition = types.NPC.getDisposition(guide, self.object),
        followers = followers or 0,
        player = statsOf(self.object),
        guide = statsOf(guide),
    }
end

---Gold on hand. `Inventory:countOf` does this in one call; iterating
---getAll(Miscellaneous) and summing counts was the long way round.
local function playerGold()
    return types.Actor.inventory(self):countOf('gold_001') or 0
end

-- ---------------------------------------------------------------------------
-- THE MENU
-- ---------------------------------------------------------------------------
-- Built with UI Toolkit's Popups, which is modal, dims the world and manages
-- the UI mode itself -- a plain WindowManager window does none of those and
-- would need I.UI.setMode boilerplate plus a resize handler.
--
-- OPTIONAL DEPENDENCY. Without UI Toolkit installed, this falls through to
-- ui.showMessage and the vanilla window is left alone, so the player gets
-- ordinary fast travel rather than a broken menu.

local TextProvider = nil
local function toolkit()
    local T = I.UIToolkit
    if not T or not T.Popups or not T.Components then return nil end
    if not TextProvider then
        -- Required lazily: requiring a missing VFS path at load would take
        -- this whole script down on an install without UI Toolkit.
        TextProvider = require('scripts.UIToolkit.components.list_items.text_item')
    end
    return T
end

local function dismissMenu()
    if closeMenu then
        local fn = closeMenu
        closeMenu = nil
        fn()
    end
end

---Rows for the destination list: every destination the guide offers that this
---module also has a route for.
---
---Paired with the quote BY INDEX. The global resolved each destination's
---position to a route stop (caravans_stops.lua); an earlier version folded
---dest.cellId to lower case and looked it up by name, but an exterior
---destination's cellId is an engine id, not "Balmora", so nothing matched.
---@return table rows, number offered, number animatable
local function buildRows(guide, byDest)
    local dests = travelDestinationsOf(guide) or {}
    local gold = playerGold()
    local rows, offered, animatable = {}, 0, 0

    for i, dest in ipairs(dests) do
        offered = offered + 1
        local info = byDest[i]
        if info then
            local key = info.key
            animatable = animatable + 1
            local distance = (dest.position - self.position):length()
            local price = db.price(priceInputs(guide, distance, 0))
            local display = routes.names[key] or info.displayName or key
            rows[#rows + 1] = {
                id = 'dest:' .. key,
                text = string.format('%s  -  %d gp', display, price),
                key = key,
                price = price,
                affordable = price <= gold,
                length = info.length,
            }
        end
    end

    table.sort(rows, function(a, b) return a.text < b.text end)
    return rows, offered, animatable
end

local function beginJourney(guide, fromKey, row)
    if not row.affordable then
        ui.showMessage(l10n('msg_cannot_afford'))
        return
    end
    local hours = advanceClock()
        and db.vanillaHours(row.length, core.getGMST('fTravelTimeMult'))
        or 0

    core.sendGlobalEvent(EV.REQUEST_TRAVEL, {
        player = self.object,
        guide = guide,
        service = 'caravaner',
        from = fromKey,
        to = row.key,
        price = row.price,
        vanillaHours = hours,
        speed = travelSpeed(),
    })
end

-- Why the vanilla window was left up, printed once per distinct reason. The
-- first report of this module was "no indication of travel ui functioning",
-- and a module that stands down in silence cannot be told apart from one that
-- is not installed.
local stoodDown = {}
local function standDown(reason)
    if stoodDown[reason] then return end
    stoodDown[reason] = true
    print('[WhyWalk Caravans] vanilla travel window kept: ' .. reason)
end

---Can this module handle the travel menu right now? Returns everything
---`presentMenu` needs, or nil to leave the vanilla window alone.
---
---SPLIT FROM presentMenu on purpose. The interception has to decide whether it
---can take over BEFORE it closes the engine's travel window, because once
---that window is gone there is no way to hand the player back to it. Deciding
---and acting in one function meant either closing the window and hoping, or
---not closing it at all.
local function prepareMenu()
    local T = toolkit()
    if not T then
        standDown('UI Toolkit is not installed')
        return nil
    end

    local guide = currentGuide()
    if not guide then
        standDown('no travel guide nearby')
        return nil
    end

    -- The quote is requested at activation and answered a couple of frames
    -- later. A quote for a different guide is stale, and none at all means the
    -- reply has not landed; either way the vanilla window is the safe answer.
    if not quote or quote.guide ~= guide or not quote.from then
        standDown(quote and quote.guide == guide and 'guide is not at a known stop'
            or 'no route quote for this guide yet')
        return nil
    end
    local fromKey = quote.from

    local rows, offered, animatable = buildRows(guide, quote.byDest or {})
    if animatable == 0 then
        -- The guide sells travel but none of their destinations has a route in
        -- the imported set. Leaving the vanilla window up is the only useful
        -- thing to do; suppressing it would strand the player.
        standDown(string.format('%s offers %d destinations, none with a route from %s',
            tostring(guide.recordId), offered, fromKey))
        return nil
    end

    return { toolkit = T, guide = guide, fromKey = fromKey, rows = rows }
end

---Show the destination menu for a prepared plan.
local function presentMenu(plan)
    local T, guide, fromKey, rows = plan.toolkit, plan.guide, plan.fromKey, plan.rows
    local C = T.Components
    local list
    list = C.itemList {
        provider = TextProvider:new(),
        size = util.vector2(320, math.min(360, 28 + #rows * 24)),
        onItemClicked = function(item)
            -- ItemList has ONE callback for the whole list, not one per row,
            -- so the row is dispatched on here.
            dismissMenu()
            beginJourney(guide, fromKey, item)
        end,
    }
    -- Required: the list starts empty and silently renders an empty scroll
    -- area if setItems is never called.
    list:setItems(rows)

    closeMenu = T.Popups.show {
        title = l10n('menu_title'),
        body = list,
        buttons = { { text = l10n('menu_cancel') } },
        getFocusedScrollable = function() return list end,
        onClosed = function() closeMenu = nil end,
    }
end

-- ---------------------------------------------------------------------------
-- INTERCEPTION
-- ---------------------------------------------------------------------------
-- VIA THE UI MODE: notice the mode change, decide whether this module can
-- take over, close the engine's travel window, and show ours.
--
--   * UiModeChanged is an EVENT carrying { oldMode, newMode }. AnimRefresh v5
--     reads exactly those two fields in production.
--   * I.UI.MODE.Travel exists -- Ben's Rideable Silt Striders keys its whole
--     mod off `I.UI.getMode() == I.UI.MODE.Travel` and works.
--   * I.UI.removeMode(mode) drops a mode from the stack.
--
-- I.UI.MODE IS NOT A TABLE. It is a read-only userdata proxy: index it, never
-- type()-check or pairs() it. The 2026-10-23 build gated on
-- `type(I.UI.MODE) ~= 'table'`, which is always true in the engine, so the
-- interception stood down on every travel menu and logged "(not a table)".
-- The registerWindow version before it was abandoned on the same misreading
-- of I.UI.WINDOW. See FIX_2026-10-28.md.
--
-- ORDER MATTERS. The window is closed only AFTER prepareMenu succeeds,
-- because once it is gone the player cannot be handed back to it. And the
-- close happens BEFORE the popup is shown: UIToolkit's Popups only adds its
-- own UI mode when the stack is empty, so showing first would leave the popup
-- under Travel mode and then pull Travel out from under it -- a visible but
-- unclickable menu, which is that library's documented trap.

-- Indexed directly, at load. A build without it errors here, loudly, rather
-- than standing down in silence the way the type() check did.
local TRAVEL_MODE = I.UI.MODE.Travel

-- Guards re-entry: removeMode causes another UiModeChanged, and handling that
-- one would ask the same question again with the window already gone.
local intercepting = false

local function onUiModeChanged(data)
    local newMode = data and data.newMode
    if not newMode then return end

    local travel = TRAVEL_MODE
    if newMode ~= travel then return end

    if intercepting then return end
    if not animatedTravel() then return end

    local plan = prepareMenu()
    if not plan then
        -- Nothing this module can carry. The vanilla window stays up and the
        -- player travels normally; prepareMenu has said why.
        return
    end

    intercepting = true
    I.UI.removeMode(travel)
    presentMenu(plan)
    intercepting = false
end

-- ---------------------------------------------------------------------------
-- EVENTS
-- ---------------------------------------------------------------------------

local function onGuideLatched(data)
    local actor = data and data.actor
    if actor and actor:isValid() and offersTravel(actor) then
        latchedGuide = actor
        -- Ask the global for the routes available from here, so the menu has
        -- them ready the moment the travel topic is clicked. One event per
        -- conversation with a caravaner, not per frame. The global works out
        -- where "here" is from the guide's position.
        quote = nil
        core.sendGlobalEvent(EV.REQUEST_QUOTE,
            { player = self.object, guide = actor })
    end
end

local function onQuote(data)
    -- Kept whole: prepareMenu checks quote.guide against the guide in front
    -- of the player, so a late reply for an earlier guide is never used.
    quote = data
end

local function onStarted(data)
    travelling = true
    dismissMenu()
    -- Drop every UI mode, which means the DIALOGUE window underneath.
    --
    -- Interception removes only the Travel mode, so the conversation the
    -- travel topic was reached through is still open beneath the menu. Left
    -- alone, the journey would begin with the player staring at the
    -- caravaner's dialogue while the strider walks off, and they would have
    -- to close it by hand to see where they were going.
    I.UI.setMode()
    ui.showMessage(string.format(l10n('msg_departing'),
        tostring(data and data.displayName or '')))
    -- Seat the player. ridingAnim defers the first play by MOUNT_SETTLE so the
    -- pose lands after the boarding teleport rather than under it.
    self.object:sendEvent(POSE.START, { stance = POSE_STANCE })
end

local function onArrived(data)
    travelling = false
    self.object:sendEvent(POSE.STOP, {})
    ui.showMessage(string.format(l10n('msg_arrived'),
        tostring(data and data.displayName or '')))
end

local REASONS = {
    noroute = 'msg_no_route_fallback',
    novehicle = 'msg_no_vehicle',
    died = 'msg_journey_interrupted',
    invalid = 'msg_journey_interrupted',
}

local function onAborted(data)
    travelling = false
    -- Unconditional, and before the message: an abort for ANY reason has to
    -- clear the pose, or a journey cut short leaves the player sitting
    -- cross-legged in mid-stride for the rest of the save.
    self.object:sendEvent(POSE.STOP, {})
    local key = data and REASONS[data.reason]
    if key then ui.showMessage(l10n(key)) end
end

local function onKeyPress(key)
    if not travelling then return end
    if key.symbol == 'x' then
        core.sendGlobalEvent(EV.REQUEST_ABORT, { player = self.object })
    end
end

local function onInit()
    -- Nothing to install: interception is an event handler now. Kept so the
    -- quote cache starts clean if the player loads straight into a caravaner.
    quote = nil
end

local function onLoad()
    travelling = false
    latchedGuide, quote, closeMenu = nil, nil, nil
    intercepting = false
    -- A save taken mid-journey reloads with the player on the ground (the
    -- global releases them in its own onLoad), so the pose must not survive
    -- into the reloaded game. ridingAnim ignores a STOP it has no pose for.
    self.object:sendEvent(POSE.STOP, {})
end

return {
    eventHandlers = {
        [EV.GUIDE_LATCHED] = onGuideLatched,
        [EV.QUOTE]         = onQuote,
        [EV.STARTED]       = onStarted,
        [EV.ARRIVED]       = onArrived,
        [EV.ABORTED]       = onAborted,
        -- UiModeChanged is an EVENT, not an engine handler. Registering it
        -- under engineHandlers makes OpenMW reject it outright with "Not
        -- supported handler" -- which is how AnimRefresh v4 shipped a feature
        -- that never once ran. check_handlers.py enforces this.
        UiModeChanged      = onUiModeChanged,
    },
    engineHandlers = {
        onInit     = onInit,
        onLoad     = onLoad,
        onKeyPress = onKeyPress,
    },
}
