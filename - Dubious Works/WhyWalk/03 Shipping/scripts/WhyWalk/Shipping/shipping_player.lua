---@omw-context player
--[[
    shipping_player.lua -- the shipmaster's travel menu, the fare, the passenger

    Caravans' interception, unchanged in mechanism (see caravans_player.lua for
    why each step is the way it is): UiModeChanged to Travel -> decide -> close
    the engine's window -> show ours with UI Toolkit. Three differences:

    ONLY SHIPMASTERS. The guide is latched by the global script only when they
    sell ship travel (class Shipmaster, or one of Immersive Travel's named
    exceptions), and the menu is offered only for a latched guide. A caravaner
    is never intercepted here.

    NOTHING BECOMES UNREACHABLE. A vanilla shipmaster sells routes Immersive
    Travel never recorded -- Gals Arethi in Sadrith Mora offers Tel Mora and
    Dagon Fel, and neither has a route from there. Caravans drops such
    destinations from its menu once any one of the guide's destinations has a
    route. Here they are behind one row, "Other destinations", which reopens
    the engine's own travel window for the same shipmaster
    (I.UI.addMode('Travel', { target = guide })) with this module standing
    aside for it.

    FARE AND HOURS ARE VANILLA'S, to the gold piece: the straight 3D distance
    and the engine's two truncations (shipping_db.price), and the straight
    distance for the clock (shipping_db.vanillaHours says why not the route).
]]

local core    = require('openmw.core')
local self    = require('openmw.self')
local types   = require('openmw.types')
local ui      = require('openmw.ui')
local util    = require('openmw.util')
local storage = require('openmw.storage')
local nearby  = require('openmw.nearby')
local I       = require('openmw.interfaces')

local db     = require('scripts.WhyWalk.Shipping.shipping_db')

local EV = {
    REQUEST_TRAVEL = 'WWShipping_RequestTravel',
    REQUEST_QUOTE  = 'WWShipping_RequestQuote',
    QUOTE          = 'WWShipping_Quote',
    STARTED        = 'WWShipping_Started',
    ARRIVED        = 'WWShipping_Arrived',
    ABORTED        = 'WWShipping_Aborted',
    REQUEST_ABORT  = 'WWShipping_RequestAbort',
    GUIDE_LATCHED  = 'WWShipping_GuideLatched',
    FOOTING        = 'WWShipping_Footing',
    RESCUED        = 'WWShipping_Rescued',
    DECK_PINNED    = 'WWShipping_DeckPinned',
}

local L10N = 'WhyWalkShipping'
local l10n = core.l10n(L10N)

-- ---------------------------------------------------------------------------
-- SETTINGS: a group on Core's WhyWalk page
-- ---------------------------------------------------------------------------
local GROUP = 'SettingsWhyWalkShipping'

I.Settings.registerGroup {
    key = GROUP, page = 'WhyWalk', l10n = L10N,
    name = 'shipping_group_name', description = 'shipping_group_description',
    permanentStorage = true,
    order = 2,
    settings = {
        { key = 'ANIMATED_TRAVEL', name = 'shipping_enabled_name',
          description = 'shipping_enabled_description',
          renderer = 'checkbox', default = true },
        { key = 'SPEED', name = 'shipping_speed_name',
          description = 'shipping_speed_description',
          renderer = 'number', integer = true, default = 1600,
          argument = { min = 200, max = 8000 } },
        { key = 'ADVANCE_CLOCK', name = 'shipping_clock_name',
          description = 'shipping_clock_description',
          renderer = 'checkbox', default = true },
        { key = 'DECK_WALK', name = 'shipping_deckwalk_name',
          description = 'shipping_deckwalk_description',
          renderer = 'checkbox', default = true },
        { key = 'PASSENGER_POSE', name = 'shipping_pose_name',
          description = 'shipping_pose_description',
          renderer = 'checkbox', default = false },
    },
}

local settings = storage.playerSection(GROUP)
local function animatedTravel() return settings:get('ANIMATED_TRAVEL') ~= false end
local function advanceClock()   return settings:get('ADVANCE_CLOCK') ~= false end
local function passengerPose()  return settings:get('PASSENGER_POSE') == true end
local function deckWalk()       return settings:get('DECK_WALK') ~= false end
local function travelSpeed()
    local v = tonumber(settings:get('SPEED'))
    return (v and v > 0) and v or 1600
end

-- ---------------------------------------------------------------------------
-- STATE
-- ---------------------------------------------------------------------------
local latchedGuide = nil
local quote = nil
local travelling = false
local closeMenu = nil
-- Set when the player asks for the vanilla window: the next Travel mode for
-- this guide is theirs, not ours.
local standAsideFor = nil

-- Walking the deck: the vessel under way, and the last footing reported.
local vessel, walking, lastFooting = nil, false, nil

local POSE = { START = 'WhyWalk_AnimVesselStart', STOP = 'WhyWalk_AnimVesselStop' }

-- ---------------------------------------------------------------------------
-- PRICE
-- ---------------------------------------------------------------------------
local function priceInputs(guide, distance)
    local stat = types.Actor.stats
    local function mercantileOf(actor)
        if not types.NPC.objectIsInstance(actor) then return 0 end
        local accessor = types.NPC.stats and types.NPC.stats.skills
            and types.NPC.stats.skills.mercantile
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
        followers = 0,
        player = statsOf(self.object),
        guide = statsOf(guide),
    }
end

-- The fare is measured in 3D (TravelWindow::addDestination); the clock in 2D
-- would be vanilla's too if it mattered, but the engine uses the same d.
local function distance3(a, b) return (a - b):length() end

local function playerGold() return types.Actor.inventory(self):countOf('gold_001') or 0 end

-- ---------------------------------------------------------------------------
-- THE MENU
-- ---------------------------------------------------------------------------
local TextProvider = nil
local function toolkit()
    local T = I.UIToolkit
    if not T or not T.Popups or not T.Components then return nil end
    if not TextProvider then
        TextProvider = require('scripts.UIToolkit.components.list_items.text_item')
    end
    return T
end

local function dismissMenu()
    if closeMenu then local fn = closeMenu; closeMenu = nil; fn() end
end

local OTHER = 'other'

local function buildRows(guide, byDest)
    local rec = types.NPC.record(guide)
    local dests = (rec and rec.travelDestinations) or {}
    local gold = playerGold()
    local rows, others = {}, 0
    for i, dest in ipairs(dests) do
        local info = byDest[i]
        if info then
            local distance = distance3(dest.position, self.position)
            local price = db.price(priceInputs(guide, distance))
            rows[#rows + 1] = {
                id = 'dest:' .. i,
                text = string.format('%s  -  %d gp', info.displayName, price),
                destIndex = i, route = info.route, reversed = info.reversed,
                price = price, affordable = price <= gold, distance = distance,
            }
        else
            others = others + 1
        end
    end
    table.sort(rows, function(a, b) return a.text < b.text end)
    if others > 0 then
        rows[#rows + 1] = { id = OTHER, kind = OTHER,
            text = string.format(l10n('menu_other'), others) }
    end
    return rows, #dests, others
end

local function openVanilla(guide)
    standAsideFor = guide
    I.UI.addMode('Travel', { target = guide })
end

local function beginJourney(guide, row)
    if not row.affordable then ui.showMessage(l10n('msg_cannot_afford')); return end
    local hours = advanceClock()
        and db.vanillaHours(row.distance, core.getGMST('fTravelTimeMult')) or 0
    core.sendGlobalEvent(EV.REQUEST_TRAVEL, {
        player = self.object, guide = guide, destIndex = row.destIndex,
        route = row.route, reversed = row.reversed, price = row.price,
        vanillaHours = hours, speed = travelSpeed(), deckWalk = deckWalk(),
    })
end

local stoodDown = {}
local function standDown(reason)
    if stoodDown[reason] then return end
    stoodDown[reason] = true
    print('[WhyWalk Shipping] vanilla travel window kept: ' .. reason)
end

local function prepareMenu()
    local T = toolkit()
    if not T then standDown('UI Toolkit is not installed'); return nil end
    local guide = latchedGuide
    if not guide or not guide:isValid() then return nil end   -- not a shipmaster
    if not quote or quote.guide ~= guide then
        standDown('no route quote for this shipmaster yet'); return nil
    end
    if not next(quote.byDest or {}) then return nil end
    local rows = buildRows(guide, quote.byDest)
    return { toolkit = T, guide = guide, rows = rows }
end

local function presentMenu(plan)
    local T, guide, rows = plan.toolkit, plan.guide, plan.rows
    local C = T.Components
    local list
    list = C.itemList {
        provider = TextProvider:new(),
        size = util.vector2(340, math.min(380, 28 + #rows * 24)),
        onItemClicked = function(item)
            dismissMenu()
            if item.kind == OTHER then openVanilla(guide) else beginJourney(guide, item) end
        end,
    }
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
local TRAVEL_MODE = I.UI.MODE.Travel
local intercepting = false

local function onUiModeChanged(data)
    local newMode = data and data.newMode
    if newMode ~= TRAVEL_MODE or intercepting then return end

    if standAsideFor then
        -- The player asked for the engine's window; let this one through.
        standAsideFor = nil
        return
    end
    if not latchedGuide then return end          -- not a shipmaster: not ours

    if travelling then
        intercepting = true
        I.UI.removeMode(TRAVEL_MODE)
        intercepting = false
        ui.showMessage(l10n('msg_already_travelling'))
        return
    end
    if not animatedTravel() then return end

    local plan = prepareMenu()
    if not plan then return end
    intercepting = true
    I.UI.removeMode(TRAVEL_MODE)
    presentMenu(plan)
    intercepting = false
end

-- ---------------------------------------------------------------------------
-- EVENTS
-- ---------------------------------------------------------------------------
local function onGuideLatched(data)
    local actor = data and data.actor
    quote = nil
    if not actor or not actor:isValid() or not data.ships then
        latchedGuide = nil
        return
    end
    latchedGuide = actor
    core.sendGlobalEvent(EV.REQUEST_QUOTE, { player = self.object, guide = actor })
end

local function onQuote(data) quote = data end

local FLOW_OWNER = 'WhyWalk.Shipping'
local function flowYield(on)
    local F = I.Flow
    if not (F and F.yield and F.resume) then return end
    if on then F.yield(FLOW_OWNER) else F.resume(FLOW_OWNER) end
end

local function onStarted(data)
    travelling = true
    flowYield(true)
    dismissMenu()
    I.UI.setMode()
    ui.showMessage(string.format(l10n('msg_departing'),
        tostring(data and data.vessel or ''), tostring(data and data.displayName or '')))
    vessel = data and data.object
    walking = data and data.deckWalk == true
    lastFooting = nil
    -- A pinned passenger is never grounded, so without a pose the engine
    -- plays the falling animation for the whole voyage (Caravans 2026-11-03c);
    -- 'stand' is vanilla idle on Core's vessel layer. A passenger walking the
    -- deck stands on it and animates as anyone on foot does.
    if not walking then
        self.object:sendEvent(POSE.START, { stance = passengerPose() and 'passenger' or 'stand' })
    end
end

local function finish()
    travelling = false
    vessel, walking, lastFooting = nil, false, nil
    latchedGuide, quote = nil, nil
    flowYield(false)
    self.object:sendEvent(POSE.STOP, {})
end

local function onArrived(data)
    finish()
    ui.showMessage(string.format(l10n('msg_arrived'), tostring(data and data.displayName or '')))
end

local REASONS = {
    noroute = 'msg_no_route', novehicle = 'msg_no_vehicle',
    cannotafford = 'msg_cannot_afford',
    died = 'msg_interrupted', invalid = 'msg_interrupted',
    ['player request'] = 'msg_disembarked',
}
local function onAborted(data)
    finish()
    local key = data and REASONS[data.reason]
    if key then ui.showMessage(l10n(key)) end
end

-- ---------------------------------------------------------------------------
-- FOOTING: WHAT THE PASSENGER STANDS ON
-- ---------------------------------------------------------------------------
-- The global script carries a walking passenger only while they stand on the
-- vessel, and cannot cast rays itself. A ray from the knees to FOOTING_REACH
-- below the feet: long enough that a jump, or a step off the quarterdeck,
-- still sees the deck under it; short enough that someone over the side does
-- not see the hull's keel. Sent only when the answer changes.
local FOOTING_REACH = 300
local function footingKey(onVessel, swimming)
    return (onVessel and 'v' or '-') .. (swimming and 's' or '-')
end

local function reportFooting()
    if not (travelling and walking and vessel and vessel:isValid()) then return end
    local p = self.position
    local hit = nearby.castRay(p + util.vector3(0, 0, 40), p - util.vector3(0, 0, FOOTING_REACH),
        { collisionType = nearby.COLLISION_TYPE.World, ignore = self.object })
    local onVessel = hit.hit and hit.hitObject ~= nil and hit.hitObject == vessel
    local swimming = types.Actor.isSwimming(self)
    local key = footingKey(onVessel, swimming)
    if key == lastFooting then return end
    lastFooting = key
    core.sendGlobalEvent(EV.FOOTING, { onVessel = onVessel, swimming = swimming })
end

-- The global script found no MWScript pin: pinned after all, so posed.
local function onDeckPinned()
    walking = false
    self.object:sendEvent(POSE.START, { stance = passengerPose() and 'passenger' or 'stand' })
end

local function onRescued()
    ui.showMessage(l10n('msg_rescued'))
    lastFooting = nil
end

local function onKeyPress(key)
    if travelling and key.symbol == 'x' then
        core.sendGlobalEvent(EV.REQUEST_ABORT, { player = self.object })
    end
end

local function onLoad()
    travelling = false
    flowYield(false)
    latchedGuide, quote, closeMenu, standAsideFor = nil, nil, nil, nil
    vessel, walking, lastFooting = nil, false, nil
    intercepting = false
    self.object:sendEvent(POSE.STOP, {})
end

return {
    eventHandlers = {
        [EV.GUIDE_LATCHED] = onGuideLatched,
        [EV.QUOTE]         = onQuote,
        [EV.STARTED]       = onStarted,
        [EV.ARRIVED]       = onArrived,
        [EV.ABORTED]       = onAborted,
        [EV.RESCUED]       = onRescued,
        [EV.DECK_PINNED]   = onDeckPinned,
        UiModeChanged      = onUiModeChanged,
    },
    engineHandlers = {
        onLoad     = onLoad,
        onKeyPress = onKeyPress,
        onUpdate   = reportFooting,
    },
}
