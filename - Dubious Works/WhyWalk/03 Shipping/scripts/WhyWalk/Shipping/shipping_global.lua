---@omw-context global
--[[
    shipping_global.lua -- the voyage: vessel, route walker, passenger, shipmaster

    Caravans' journey engine, carried over to the water. What is the same and
    what is not:

    THE SAME
      * one per-frame handler whose first statement returns when nobody is
        travelling;
      * the vessel is a SPAWNED activator placed along the route, never the
        ship moored at the quay (taking that away would leave a hole and strand
        anything scripted to it);
      * the player is carried by Core's WhyWalkRiderPin (MWScript SetPos, which
        fires no onTeleported and, unlike a Lua teleport, does not snap the
        weather at a region border), with a teleport fallback;
      * ending a voyage is a request, finished at the top of the next frame,
        because an object can be teleported once per frame;
      * nothing that is not serialisable goes in the save.

    DIFFERENT
      * WHICH ROUTE is chosen by shipping_stops.match from the guide's position
        and each destination's position and cell name -- docks defeat
        Caravans' one-centre-per-place model;
      * the vessel depends on the route (Immersive Travel's override_mount
        rule, resolved by the importer): a Dunmer ship between the big ports, a
        longboat elsewhere;
      * the voyage ENDS AT THE DESTINATION THE SHIPMASTER SOLD, the travel
        record's own position and rotation -- exactly where vanilla travel
        puts you. Caravans puts the rider down at the last route point, which
        on land is the stop; at sea the last point is in the water;
      * a ship leaves and arrives at walking pace and accelerates in between
        (shipping_db.rampSpeed); a 2400-unit hull rounds corners wider and
        turns slower than a strider (per-vessel turn and turnRate);
      * a save taken at sea COMPLETES the voyage on load instead of aborting
        it. Aborting puts a passenger in the sea; the fare is paid and the
        destination is known, so arriving is the honest outcome. Pressing X
        at sea puts you back on the quay you left if you are less than half
        way, else on the one you are bound for.
]]

local world = require('openmw.world')
local types = require('openmw.types')
local util  = require('openmw.util')
local core  = require('openmw.core')
local I     = require('openmw.interfaces')
local vfs   = require('openmw.vfs')

local db     = require('scripts.WhyWalk.Shipping.shipping_db')
local path   = require('scripts.WhyWalk.Shipping.shipping_path')
local routes = require('scripts.WhyWalk.Shipping.shipping_routes')
local stops  = require('scripts.WhyWalk.Shipping.shipping_stops')
local deck   = require('scripts.WhyWalk.Shipping.shipping_deck')

local EV = {
    REQUEST_TRAVEL = 'WWShipping_RequestTravel',
    QUOTE          = 'WWShipping_Quote',
    REQUEST_QUOTE  = 'WWShipping_RequestQuote',
    STARTED        = 'WWShipping_Started',
    ARRIVED        = 'WWShipping_Arrived',
    ABORTED        = 'WWShipping_Aborted',
    REQUEST_ABORT  = 'WWShipping_RequestAbort',
    GUIDE_LATCHED  = 'WWShipping_GuideLatched',
    FOOTING        = 'WWShipping_Footing',
    RESCUED        = 'WWShipping_Rescued',
    DECK_PINNED    = 'WWShipping_DeckPinned',
}

local DEBUG = false
local TAG = '[WhyWalk Shipping] '

local YAW_SIGN = (util.transform.rotateZ(0.5):getYaw() > 0) and 1 or -1

-- Runtime check of the shipped data. The importer already dropped what it
-- could see; this catches a hand-edited file.
for _, r in ipairs(routes.routes) do
    local why = (#r < 6) and 'empty' or stops.spike(r)
    if why then
        r.dropped = why
        print(TAG .. 'route ignored: ' .. r.from .. ' -> ' .. r.to .. ' (' .. why .. ')')
    end
end
local LIVE = {}
for _, r in ipairs(routes.routes) do
    if not r.dropped then LIVE[#LIVE + 1] = r end
end
local KNOWN = stops.knownNames(LIVE)

local session = nil

-- ---------------------------------------------------------------------------
-- HELPERS
-- ---------------------------------------------------------------------------

local function lowerName(cell)
    local n = cell and cell.name
    if n and n ~= '' then return n:lower() end
    return nil
end

local function cellNameOf(cellId)
    if not cellId or cellId == '' then return nil end
    local c = world.getCellById(cellId)
    return c, lowerName(c)
end

local function recordOf(actor)
    if types.NPC.objectIsInstance(actor) then return types.NPC.record(actor) end
    if types.Creature.objectIsInstance(actor) then return types.Creature.record(actor) end
    return nil
end

local function sellsShips(actor)
    if not types.NPC.objectIsInstance(actor) then return false end
    local rec = types.NPC.record(actor)
    return rec ~= nil and db.isShipmaster(rec.class, actor.recordId)
end

local function meshExists(p) return vfs.fileExists(p) end

local function chargeFare(player, guide, amount)
    if not amount or amount <= 0 then return true end
    local inv = types.Actor.inventory(player)
    local gold = inv:find('gold_001')
    if not gold or gold.count < amount then return false end
    if guide and guide:isValid() then
        gold:split(amount):moveInto(types.Actor.inventory(guide))
    else
        gold:split(amount):remove()
    end
    return true
end

-- A route from the LIVE list by index, for the player to name in a request.
local function routeByIndex(i) return i and LIVE[i] or nil end
local function indexOfRoute(r)
    for i, x in ipairs(LIVE) do if x == r then return i end end
    return nil
end

-- ---------------------------------------------------------------------------
-- THE VESSEL OBJECT
-- ---------------------------------------------------------------------------
-- One activator record per vessel kind, created once and kept in the save.

local vesselRecords = {}

local function vesselRecord(id, v)
    if vesselRecords[id] then return vesselRecords[id] end
    local draft = types.Activator.createRecordDraft({
        name = v.name,
        model = 'meshes/' .. v.mesh:gsub('\\', '/'),
    })
    local record = world.createRecord(draft)
    vesselRecords[id] = record.id
    return record.id
end

local function bodyOrigin(s, z) return z - (s.vessel.bodyOffset or 0) end

-- An empty string for the default exterior worldspace: the position decides
-- the cell. See Caravans' worldspaceOf for the bug that taught this.
local function worldspaceOf(s)
    local c = s.cell
    if c and not c.isExterior then return c end
    return ''
end

local function placeVessel(s, x, y, z, yaw, roll)
    local rot = util.transform.rotateZ(YAW_SIGN * (yaw + (s.vessel.yawOffset or 0)))
    if roll and roll ~= 0 then rot = rot * util.transform.rotateY(roll) end
    local pos = util.vector3(x, y, z)
    s.object:teleport(worldspaceOf(s), pos, rot)
    -- Kept for the deck: the pose the hull was GIVEN, which is the frame the
    -- passenger's offset is measured in. Reading object.rotation back would
    -- give last frame's until the teleport lands.
    s.lastPose, s.pose = s.pose, { pos = pos, rot = rot }
end

local function placeOccupant(obj, cell, x, y, z, yaw, slot)
    local sx, sy, sz = db.slotWorld(x, y, z, yaw, slot)
    obj:teleport(cell, util.vector3(sx, sy, sz), util.transform.rotateZ(YAW_SIGN * yaw))
end

-- ---------------------------------------------------------------------------
-- THE PASSENGER: CORE'S PIN, OR A TELEPORT
-- ---------------------------------------------------------------------------
local PIN_OWNER = {}
local YAW_EPSILON = 1e-4
local PIN_REPORT_AFTER = 60
local pinFrames, pinReported = 0, false

local function reportPin(usingPin)
    if pinReported then return end
    pinFrames = pinFrames + 1
    if usingPin and pinFrames < PIN_REPORT_AFTER then return end
    pinReported = true
    print(TAG .. 'passenger carried by ' .. (usingPin and 'the WhyWalk MWScript pin'
        or 'TELEPORT (every frame fires onTeleported on every player script, and'
           .. ' a teleport across a region border snaps the weather; the pin'
           .. ' needs WhyWalk.omwaddon with WhyWalkRiderPin compiled)'))
end

local function placeRiderAt(obj, cell, pos, yawDelta)
    local pin = I.WhyWalkRiderPin
    if pin and pin.place(PIN_OWNER, obj, pos, yawDelta) then
        reportPin(pin.isBridged ~= nil and pin.isBridged())
        return
    end
    reportPin(false)
    if yawDelta and math.abs(yawDelta) > YAW_EPSILON then
        obj:teleport(cell, pos, util.transform.rotateZ(obj.rotation:getYaw() + yawDelta))
    else
        obj:teleport(cell, pos)
    end
end

local function placeRider(obj, cell, x, y, z, yaw, slot, yawDelta)
    local sx, sy, sz = db.slotWorld(x, y, z, yaw, slot)
    placeRiderAt(obj, cell, util.vector3(sx, sy, sz), yawDelta)
end

local function releaseRider()
    local pin = I.WhyWalkRiderPin
    if pin then pin.release(PIN_OWNER) end
end

-- ---------------------------------------------------------------------------
-- SOUND
-- ---------------------------------------------------------------------------
-- IT loops "Boat Hull" under way. Played on the vessel, so it travels with it;
-- only when the record exists, so a load order without it is silent rather
-- than an error per voyage.
local function soundId(v)
    local id = v.sound
    if id and core.sound and core.sound.records and core.sound.records[id] then return id end
    return nil
end

local function startSound(s)
    local id = soundId(s.vessel)
    if id then
        core.sound.playSound3d(id, s.object, { loop = true, volume = 0.6 })
        s.sound = id
    end
end

local function stopSound(s)
    if s.sound and s.object and s.object:isValid() then
        core.sound.stopSound3d(s.sound, s.object)
    end
    s.sound = nil
end

-- ---------------------------------------------------------------------------
-- ENDING
-- ---------------------------------------------------------------------------

local function endJourney(s, reason, arrived)
    if not s or s.ending then return end
    s.ending = { reason = reason, arrived = arrived }
end

-- Where a passenger is put down: the destination the shipmaster sold, or the
-- quay they left. Each is { cell = Cell|'' , pos = Vector3, yaw = number }.
local function putDown(player, spot)
    if not spot or not spot.pos then return end
    player:teleport(spot.cell or '', spot.pos,
        { rotation = util.transform.rotateZ(spot.yaw or 0), onGround = true })
end

local function finishJourney(s)
    local reason, arrived = s.ending.reason, s.ending.arrived
    session = nil

    releaseRider()
    stopSound(s)

    if s.object and s.object:isValid() then
        s.object:teleport(worldspaceOf(s), util.vector3(0, 0, -30000))
    end

    if s.guide and s.guide:isValid() and s.guideHome then
        s.guide:teleport(s.guideHomeCell or '', s.guideHome,
            util.transform.rotateZ(s.guideHomeYaw or 0))
    end

    if s.player and s.player:isValid() then
        local spot = s.dest
        if not arrived and (s.travelled or 0) < 0.5 * (s.prep and s.prep.total or 1) then
            spot = s.origin
        end
        putDown(s.player, spot)
        if arrived and s.topUpHours and s.topUpHours > 0 then
            world.advanceTime(s.topUpHours)
        end
        s.player:sendEvent(arrived and EV.ARRIVED or EV.ABORTED, {
            displayName = s.displayName, reason = reason,
        })
    end
    if DEBUG then print(TAG .. 'voyage ended: ' .. tostring(reason)) end
end

-- ---------------------------------------------------------------------------
-- QUOTE: WHICH OF THIS SHIPMASTER'S DESTINATIONS HAVE A ROUTE
-- ---------------------------------------------------------------------------

local warned = {}
local function onRequestQuote(data)
    local player, guide = data and data.player, data and data.guide
    if not player or not player:isValid() or not guide or not guide:isValid() then return end
    local byDest, offered = {}, 0
    local rec = recordOf(guide)
    local gcell = guide.cell
    if sellsShips(guide) and rec and gcell and gcell.isExterior then
        local origin = { x = guide.position.x, y = guide.position.y, name = lowerName(gcell) }
        for i, d in ipairs(rec.travelDestinations or {}) do
            offered = offered + 1
            local _, dname = cellNameOf(d.cellId)
            local dest = { x = d.position.x, y = d.position.y, name = dname }
            local r, rev, why = stops.match(LIVE, origin, dest, nil, KNOWN)
            if r then
                local v = db.vesselFor(r.mount, meshExists)
                if v then
                    local toName = rev and r.from or r.to
                    byDest[i] = {
                        route = indexOfRoute(r), reversed = rev,
                        displayName = routes.names[toName] or toName,
                        vessel = v.name,
                        length = path.prepare(r, rev, v.turn).total,
                        names = why.names,
                    }
                end
            end
        end
    end
    if not next(byDest) and not warned[guide.id] then
        warned[guide.id] = true
        print(string.format(TAG .. '%s: no voyage route from here (%d destinations offered)',
            guide.recordId, offered))
    end
    player:sendEvent(EV.QUOTE, { guide = guide, byDest = byDest })
end

-- ---------------------------------------------------------------------------
-- DEPARTURE
-- ---------------------------------------------------------------------------

local function onRequestTravel(data)
    if session then return end
    local player, guide = data and data.player, data and data.guide
    if not player or not player:isValid() or not guide or not guide:isValid() then return end
    local rec = recordOf(guide)
    local d = rec and rec.travelDestinations and rec.travelDestinations[data.destIndex]
    local r = routeByIndex(data.route)
    local function abort(why) player:sendEvent(EV.ABORTED, { reason = why }) end
    if not d or not r or not sellsShips(guide) then return abort('noroute') end

    -- The request names a route; it must still connect THIS guide to THIS
    -- destination. An event is something anyone can send.
    local _, dname = cellNameOf(d.cellId)
    local check, rev = stops.match(LIVE,
        { x = guide.position.x, y = guide.position.y, name = lowerName(guide.cell) },
        { x = d.position.x, y = d.position.y, name = dname }, nil, KNOWN)
    if check ~= r or rev ~= (data.reversed == true) then return abort('noroute') end

    local v, vid = db.vesselFor(r.mount, meshExists)
    if not v then return abort('novehicle') end
    if not chargeFare(player, guide, data.price) then return abort('cannotafford') end

    local prep = path.prepare(r, rev, v.turn)
    local destCell = world.getCellById(d.cellId)
    local object = world.createObject(vesselRecord(vid, v), 1)

    session = {
        player = player, guide = guide,
        guideHome = guide.position, guideHomeYaw = guide.rotation:getYaw(),
        guideHomeCell = guide.cell,
        object = object, vessel = v, vesselId = vid,
        cell = player.cell, route = r, reversed = rev, prep = prep,
        displayName = routes.names[rev and r.from or r.to],
        travelled = 0,
        speed = math.max(100, tonumber(data.speed) or 1600) * (v.speedScale or 1),
        lastFacing = nil, swayAmp = 0, swayT = 0,
        -- The player's own yaw as the "previous heading": the first frame's
        -- delta then turns them to face the bow, and every later one carries
        -- them round with the hull while leaving mouse-look alone.
        riderYawApplied = player.rotation:getYaw(),
        -- Walking the deck: nil keeps the passenger pinned to slot 1.
        deckWalk = data.deckWalk == true,
        vanillaHours = data.vanillaHours or 0,
        startedAt = core.getGameTime(),
        dest = { cell = (destCell and not destCell.isExterior) and destCell or '',
                 cellName = destCell and not destCell.isExterior and destCell.name or '',
                 pos = d.position, yaw = d.rotation and d.rotation:getYaw() or 0 },
        origin = { cell = (player.cell and not player.cell.isExterior) and player.cell or '',
                   cellName = '', pos = player.position, yaw = player.rotation:getYaw() },
    }
    -- The walker's corner profile reads these module-level constants; one
    -- voyage at a time, so the vessel's own values are simply installed.
    path.SPEED.MAX_TURN_RATE = v.turnRate
    path.SPEED.ACCEL = v.accel
    startSound(session)

    player:sendEvent(EV.STARTED, {
        displayName = session.displayName, vessel = v.name,
        object = object, deckWalk = session.deckWalk,
        length = prep.total, seconds = prep.total / session.speed,
    })
    if DEBUG then
        print(string.format(TAG .. '%s -> %s by %s, %.0f units, %s', r.from, r.to,
            vid, prep.total, rev and 'reversed' or 'forward'))
    end
end

local function onRequestAbort()
    if session then endJourney(session, 'player request', false) end
end

-- ---------------------------------------------------------------------------
-- LATCHING THE GUIDE
-- ---------------------------------------------------------------------------
-- Activation is the only way into a travel topic, so it is where the guide is
-- learned. Shipmasters only: Caravans latches its own.
--
-- Sent for EVERY travel seller, with `ships` saying whether it is ours: the
-- player script must forget a shipmaster the moment the player talks to a
-- caravaner, or the caravaner's travel window would be taken for a voyage.
I.Activation.addHandlerForType(types.NPC, function(object, actor)
    if not types.Player.objectIsInstance(actor) then return end
    local rec = types.NPC.record(object)
    local services = rec and rec.servicesOffered
    if not services or services.Travel ~= true then return end
    actor:sendEvent(EV.GUIDE_LATCHED, { actor = object, ships = sellsShips(object) })
end)

-- ---------------------------------------------------------------------------
-- THE VESSEL IS NOT A BOAT ANYONE ELSE MAY TAKE
-- ---------------------------------------------------------------------------
-- WhyWalk Boats claims any ACTIVATOR whose mesh it knows, and the longboat
-- this module sails is `x/Ex_longboat.nif`, which it knows. Activating the
-- hull under way would hand the helm to Boats while this script went on
-- teleporting the same object along the route. Shipping loads after Boats,
-- so its handler runs first (the Activation interface calls the most recently
-- registered handler first) and returning false stops the chain there.
local function isOurVessel(object)
    for _, id in pairs(vesselRecords) do
        if object.recordId:lower() == tostring(id):lower() then return true end
    end
    return false
end
I.Activation.addHandlerForType(types.Activator, function(object)
    if isOurVessel(object) then return false end
end)

-- ---------------------------------------------------------------------------
-- WALKING THE DECK
-- ---------------------------------------------------------------------------
-- The first frame puts the passenger on slot 1, as a pinned voyage does.
-- After that, each frame: the player's offset from where the hull WAS (in the
-- hull's own frame, roll included), carried to where the hull IS NOW. Their
-- walking since last frame is already in their position, so it is kept;
-- shipping_deck decides whether they are aboard to be carried at all.
-- Walking needs Core's MWScript pin. Its fallback, a Lua teleport every
-- frame, lands a frame late: carrying from the position read back then drops
-- the passenger ~200 units behind at 1600 u/s and they fall through the deck
-- (measured 2026-11-12, longboat, no WhyWalk.esp). Without the pin the
-- passenger is kept on slot 1, posed, as with the setting off.
local function canWalk()
    local pin = I.WhyWalkRiderPin
    return pin ~= nil and pin.isBridged ~= nil and pin.isBridged()
end

local function carryOnDeck(s, x, y, bz, bodyYaw, riderDelta, dt)
    local now = core.getSimulationTime()
    local player = s.player
    if not canWalk() then
        s.deckWalk = false
        print(TAG .. 'deck walking needs WhyWalk.esp (the MWScript rider pin);'
            .. ' the passenger stays on the bow deck this voyage')
        player:sendEvent(EV.DECK_PINNED, {})
        placeRider(player, worldspaceOf(s), x, y, bz, bodyYaw, s.vessel.slots[1], riderDelta)
        return
    end
    if not s.deck then
        s.deck = deck.new(now)
        placeRider(player, worldspaceOf(s), x, y, bz, bodyYaw, s.vessel.slots[1], riderDelta)
        return
    end
    local verdict = deck.step(s.deck, dt, now)
    if verdict == 'rescue' then
        placeRider(player, worldspaceOf(s), x, y, bz, bodyYaw, s.vessel.slots[1], riderDelta)
        player:sendEvent(EV.RESCUED, {})
        if DEBUG then print(TAG .. 'passenger hauled back aboard') end
        return
    end
    local from, to = s.lastPose, s.pose
    if verdict ~= 'carry' or not from or not to then
        -- Not aboard: let go of the pin so the engine moves them freely.
        releaseRider()
        return
    end
    placeRiderAt(player, worldspaceOf(s), deck.carry(from, to, player.position), riderDelta)
end

local function onFooting(data)
    local s = session
    if not s or not s.deck or not data then return end
    deck.setFooting(s.deck, { onVessel = data.onVessel == true, swimming = data.swimming == true })
end

-- ---------------------------------------------------------------------------
-- THE PER-FRAME HANDLER
-- ---------------------------------------------------------------------------

local function onUpdate(dt)
    local s = session
    if not s then return end
    if s.ending then return finishJourney(s) end

    if s.loadedArrival then
        -- A save taken at sea, loaded: arrive (see onLoad).
        return endJourney(s, 'loaded at sea', true)
    end
    if not s.player:isValid() or not s.object:isValid() then
        return endJourney(s, 'invalid', false)
    end
    if core.isWorldPaused() or dt <= 0 then return end
    if types.Actor.stats.dynamic.health(s.player).current <= 0 then
        return endJourney(s, 'died', false)
    end

    -- RESTING OR WAITING ABOARD SAILS THE REST OF THE WAY.
    --
    -- The rest menu advances the game clock in one jump, which the walker
    -- (moving by real dt) never sees: the passenger would wake to the same
    -- sea view with the hours gone. Ben's Skyships moves its ship by the
    -- elapsed game time when this happens; a voyage on a fixed route has a
    -- simpler honest answer -- the ship arrived while you slept. Any jump of
    -- more than an hour in one frame is a rest or a wait; the top-up then owes
    -- only what the rest did not already pass.
    local now = core.getGameTime()
    if s.lastGameTime and now - s.lastGameTime > 3600 then
        s.lastGameTime = now
        s.topUpHours = math.max(0, (s.vanillaHours or 0) - (now - (s.startedAt or 0)) / 3600)
        return endJourney(s, 'rested', true)
    end
    s.lastGameTime = now

    local v = s.vessel
    local cruise = path.speedAt(s.prep, s.travelled, s.speed)
    local speed = math.min(cruise, db.rampSpeed(s.travelled, s.prep.total, v.accel, 40))
    s.travelled = s.travelled + speed * dt
    local done = s.travelled >= s.prep.total

    local x, y, z, facing = path.at(s.route, s.prep, s.travelled)
    local bodyYaw = facing or s.lastFacing or 0

    s.swayT = s.swayT + dt
    local turning = 0
    if s.lastFacing and facing then
        local d = path.angleDiff(s.lastFacing, facing)
        turning = d > 1e-4 and 1 or (d < -1e-4 and -1 or 0)
    end
    s.lastFacing = bodyYaw
    s.swayAmp = path.stepSway(s.swayAmp, turning ~= 0 and 1 or 0, path.SWAY.AMPL_CHANGE * 60, dt)
    local roll = path.sway(s.swayT, s.swayAmp, v.sway) * -turning

    local bz = bodyOrigin(s, z)
    placeVessel(s, x, y, bz, bodyYaw, roll)

    local riderDelta = s.riderYawApplied and path.angleDiff(s.riderYawApplied, bodyYaw) or nil
    s.riderYawApplied = bodyYaw
    if s.deckWalk then
        carryOnDeck(s, x, y, bz, bodyYaw, riderDelta, dt)
    else
        placeRider(s.player, worldspaceOf(s), x, y, bz, bodyYaw, v.slots[1], riderDelta)
    end
    if s.guide and s.guide:isValid() and v.guideSlot then
        placeOccupant(s.guide, worldspaceOf(s), x, y, bz, bodyYaw, v.guideSlot)
    end

    if done then
        local elapsedHours = (core.getGameTime() - (s.startedAt or 0)) / 3600
        s.topUpHours = math.max(0, (s.vanillaHours or 0) - elapsedHours)
        endJourney(s, 'arrived', true)
    end
end

-- ---------------------------------------------------------------------------
-- SAVE / LOAD
-- ---------------------------------------------------------------------------

local function spotToSave(spot)
    if not spot then return nil end
    return { cellName = spot.cellName or '', pos = spot.pos, yaw = spot.yaw or 0 }
end

local function onSave()
    local saved = { vesselRecords = vesselRecords }
    local s = session
    if s and not s.ending then
        saved.voyage = {
            player = s.player, guide = s.guide, object = s.object,
            guideHome = s.guideHome, guideHomeYaw = s.guideHomeYaw,
            guideHomeCellName = (s.guideHomeCell and s.guideHomeCell.name) or '',
            dest = spotToSave(s.dest),
            displayName = s.displayName,
            remainingHours = math.max(0, (s.vanillaHours or 0)
                - (core.getGameTime() - (s.startedAt or 0)) / 3600),
        }
    end
    return saved
end

local function onLoad(data)
    vesselRecords = (data and data.vesselRecords) or {}
    session = nil
    releaseRider()
    local v = data and data.voyage
    if not v then return end
    -- Finish it next frame, from the top of onUpdate, where teleports are safe.
    session = {
        loadedArrival = true,
        player = v.player, guide = v.guide, object = v.object,
        guideHome = v.guideHome, guideHomeYaw = v.guideHomeYaw,
        guideHomeCell = v.guideHomeCellName or '',
        dest = v.dest and { cell = v.dest.cellName or '', pos = v.dest.pos, yaw = v.dest.yaw } or nil,
        displayName = v.displayName,
        topUpHours = v.remainingHours,
        travelled = 1, prep = { total = 1 },
        vessel = {}, cell = nil,
    }
end

return {
    eventHandlers = {
        [EV.REQUEST_TRAVEL] = onRequestTravel,
        [EV.REQUEST_ABORT]  = onRequestAbort,
        [EV.REQUEST_QUOTE]  = onRequestQuote,
        [EV.FOOTING]        = onFooting,
    },
    engineHandlers = {
        onUpdate = onUpdate,
        onSave   = onSave,
        onLoad   = onLoad,
    },
}
