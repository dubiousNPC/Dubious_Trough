---@omw-context global
--[[
    caravans_global.lua -- the journey: vehicle, route walker, occupants

    ONE PER-FRAME HANDLER, and its first statement returns when nobody is
    travelling. Same discipline as Core and Boats: a parked caravan costs one
    nil check per frame.

    WHAT RUNS HERE AND WHY

    The vehicle is placed along the route (caravans_path.lua says why it must
    be), the player is placed in its front slot, and the guide in its guide
    slot. All three are teleports, which only a global script can do to the
    player, so the whole journey loop lives here.

    THE VEHICLE IS A SPAWNED OBJECT, NOT THE ONE AT THE STOP

    The silt striders standing at travel stops are world objects placed by the
    level designer, and taking one away for the duration of a journey would
    leave a hole at the stop and strand anything scripted to it. Ben's
    Rideable Silt Striders spawns its own instead, with
    createRecordDraft/createRecord/createObject, and SILTSTRIDER_NOTES lists
    that technique as the thing worth taking from it. This does the same.

    IT PREFERS A CREATURE RECORD, AND FALLS BACK TO AN ACTIVATOR

    Ben's mod spawns an ACTIVATOR with the strider mesh. That moves fine, but
    an activator has no animation controller, so its legs never move -- which
    is exactly the "animated movement" this module is for. So this looks for
    an existing silt strider CREATURE record to clone, and only falls back to
    an activator if the load order has none.

    The search is by mesh, not by record id: `c_siltstrider` is Immersive
    Travel's id, not a vanilla one, and guessing ids across unknown load
    orders is how a mod ends up working on one install and not another.
]]

local world = require('openmw.world')
local types = require('openmw.types')
local util  = require('openmw.util')
local core  = require('openmw.core')
local I     = require('openmw.interfaces')

local db     = require('scripts.WhyWalk.Caravans.caravans_db')
local path   = require('scripts.WhyWalk.Caravans.caravans_path')
local routes = require('scripts.WhyWalk.Caravans.caravans_routes')

local EV = {
    REQUEST_TRAVEL = 'WWCaravans_RequestTravel',
    QUOTE          = 'WWCaravans_Quote',
    REQUEST_QUOTE  = 'WWCaravans_RequestQuote',
    STARTED        = 'WWCaravans_Started',
    ARRIVED        = 'WWCaravans_Arrived',
    ABORTED        = 'WWCaravans_Aborted',
    REQUEST_ABORT  = 'WWCaravans_RequestAbort',
}

local EV_VEHICLE = {
    START = 'WWCaravans_VehicleStart',
    STOP  = 'WWCaravans_VehicleStop',
}

local VEHICLE_SCRIPT = 'scripts/WhyWalk/Caravans/caravans_vehicle.lua'

local DEBUG = false

-- Sign of the engine's yaw convention, probed once rather than assumed. Boats
-- does the same, and for the same reason: getting this wrong cost a round
-- trip in 2026-09-29 when the mount drove one way and faced the other.
local YAW_SIGN = (util.transform.rotateZ(0.5):getYaw() > 0) and 1 or -1

-- ---------------------------------------------------------------------------
-- SESSION
-- ---------------------------------------------------------------------------
-- nil when nobody is travelling. Existence of this table is the early-out.

local session = nil

-- ---------------------------------------------------------------------------
-- THE FARE
-- ---------------------------------------------------------------------------

---Move `amount` gold from the player to the guide, as the engine's own travel
---does. Returns true when it was paid in full.
---
---The price was computed player-side (it needs no world access and the menu
---has to show it), but the TRANSFER happens here: inventory moves between two
---actors are a global operation, and a client that could skip the charge
---would be a client that travels free.
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

-- ---------------------------------------------------------------------------
-- ROUTE LOOKUP
-- ---------------------------------------------------------------------------

---Find the route between two places, in either direction.
---
---The source ships one direction per pair and not always the one wanted --
---there is a `balmora_vivec` and no `vivec_balmora`, and two of its files are
---empty. So a miss retries the reverse and the walker traverses backwards.
---@return table|nil points, boolean reversed
local function findRoute(fromKey, toKey)
    local from = routes.routes[fromKey]
    if from and from[toKey] then return from[toKey], false end
    local back = routes.routes[toKey]
    if back and back[fromKey] then return back[fromKey], true end
    return nil, false
end

---Every destination reachable from `fromKey`, as a set of lower-cased keys.
---Used by the player script to decide which of the guide's own travel
---destinations this module can animate.
local function destinationsFrom(fromKey)
    local out = {}
    local fwd = routes.routes[fromKey]
    if fwd then
        for to in pairs(fwd) do out[to] = true end
    end
    for from, dests in pairs(routes.routes) do
        if dests[fromKey] then out[from] = true end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- THE VEHICLE OBJECT
-- ---------------------------------------------------------------------------

-- Record ids this module created, so a reload reuses them instead of adding
-- another record per journey. Persisted in the save.
local vehicleRecordId = nil
local spawnedIsCreature = false

---A creature record whose mesh looks like the wanted one, or nil.
---
---Matched on the model path rather than the record id, deliberately: the ids
---differ between load orders (`c_siltstrider` comes from Immersive Travel)
---while the mesh is the mesh.
local function findCreatureTemplate(meshNeedle)
    local needle = meshNeedle:lower():gsub('\\', '/')
    for _, record in pairs(types.Creature.records) do
        local model = record.model
        if model and model:lower():gsub('\\', '/'):find(needle, 1, true) then
            return record
        end
    end
    return nil
end

---Create (once) and return the record id to spawn the vehicle from.
---@return string|nil recordId, boolean isCreature
local function vehicleRecord(v)
    if vehicleRecordId then return vehicleRecordId, spawnedIsCreature end

    local template = findCreatureTemplate(v.mesh)
    if template then
        -- A creature, so the gait can actually play. Cloned from a real
        -- record so every stat and flag it needs is already right; only the
        -- name is blanked, because this object is scenery the player rides,
        -- not something to target.
        local draft = types.Creature.createRecordDraft({
            template = template,
            name = v.name,
        })
        local record = world.createRecord(draft)
        vehicleRecordId, spawnedIsCreature = record.id, true
        if DEBUG then
            print('[WhyWalk Caravans] vehicle record from creature template '
                  .. tostring(template.id))
        end
        return vehicleRecordId, true
    end

    -- No strider creature in this load order. An activator still moves and
    -- still carries the player; it simply cannot animate, so the journey
    -- looks like Ben's rather than like this module's intent.
    local draft = types.Activator.createRecordDraft({
        name = v.name,
        model = 'meshes/' .. v.mesh:gsub('\\', '/'),
    })
    local record = world.createRecord(draft)
    vehicleRecordId, spawnedIsCreature = record.id, false
    print('[WhyWalk Caravans] no silt strider CREATURE record found in this'
          .. ' load order; falling back to an activator. The vehicle will'
          .. ' move but its legs will not animate. Installing a mod that adds'
          .. ' a rideable strider creature restores the animation.')
    return vehicleRecordId, false
end

-- ---------------------------------------------------------------------------
-- PLACEMENT
-- ---------------------------------------------------------------------------

local function placeVehicle(s, x, y, z, yaw, roll)
    local rot = util.transform.rotateZ(YAW_SIGN * yaw)
    if roll and roll ~= 0 then rot = rot * util.transform.rotateY(roll) end
    s.vehicle:teleport(s.cell, util.vector3(x, y, z), rot)
end

---Put an occupant in a vehicle-local slot.
local function placeOccupant(obj, cell, x, y, z, yaw, slot)
    local sx, sy, sz = db.slotWorld(x, y, z, yaw, slot)
    obj:teleport(cell, util.vector3(sx, sy, sz),
                 util.transform.rotateZ(YAW_SIGN * yaw))
end

-- ---------------------------------------------------------------------------
-- JOURNEY
-- ---------------------------------------------------------------------------

local function detachVehicleScript(vehicle)
    if not vehicle or not vehicle:isValid() then return end
    if not vehicle:hasScript(VEHICLE_SCRIPT) then return end
    -- Stop before removing, or the creature keeps its AI disabled and its
    -- gait looping with nothing holding the group name -- the same shape as
    -- Boats' abandoned hull sound.
    vehicle:sendEvent(EV_VEHICLE.STOP, {})
    vehicle:removeScript(VEHICLE_SCRIPT)
end

---End the journey, wherever it is. `arrived` distinguishes a completed
---journey from an abort, because only the first should charge time.
local function endJourney(s, reason, arrived)
    session = nil

    detachVehicleScript(s.vehicle)

    -- Park the vehicle far below the world rather than deleting it: the
    -- record is reused for the next journey and Ben's mod parks the same way.
    if s.vehicle and s.vehicle:isValid() then
        s.vehicle:teleport(s.cell, util.vector3(0, 0, -30000))
    end

    if s.guide and s.guide:isValid() and s.guideHome then
        s.guide:teleport(s.guideHomeCell or s.cell, s.guideHome)
        s.guide:sendEvent('WWCaravans_GuideReleased', {})
    end

    if s.player and s.player:isValid() then
        -- Put the player down at the last route point, on the ground. The
        -- route's final point is at BODY height, so the body offset comes
        -- off and `onGround` lets the engine find the actual floor -- the
        -- same reasoning as Boats' dismount, which stopped using a heightmap
        -- because a heightmap knows nothing about what is placed on it.
        local px, py, pz = s.lastX, s.lastY, s.lastZ
        if px then
            s.player:teleport(s.cell,
                util.vector3(px, py, pz - (s.vehicleDef.bodyOffset or 0)),
                { onGround = true })
        end

        if arrived and s.topUpHours and s.topUpHours > 0 then
            -- Charge the remainder of vanilla's travel time. The journey
            -- already consumed real time, and the clock ran with it, so only
            -- the difference is owed -- see the note at start-up.
            world.advanceTime(s.topUpHours)
        end

        s.player:sendEvent(arrived and EV.ARRIVED or EV.ABORTED, {
            destination = s.toKey,
            displayName = routes.names[s.toKey] or s.toKey,
            reason = reason,
        })
    end

    if DEBUG then
        print('[WhyWalk Caravans] journey ended: ' .. tostring(reason))
    end
end

local function onRequestTravel(data)
    if session then return end
    local player = data and data.player
    local guide  = data and data.guide
    if not player or not player:isValid() then return end

    local fromKey = data.from and data.from:lower()
    local toKey   = data.to and data.to:lower()
    if not fromKey or not toKey then return end

    local points, reversed = findRoute(fromKey, toKey)
    if not points then
        player:sendEvent(EV.ABORTED, { reason = 'noroute', destination = toKey })
        return
    end

    local serviceDef = db.SERVICE[(data.service or 'caravaner'):lower()]
    local v = serviceDef and db.VEHICLE[serviceDef.vehicle]
    if not v then
        player:sendEvent(EV.ABORTED, { reason = 'novehicle', destination = toKey })
        return
    end

    local recordId = vehicleRecord(v)
    if not recordId then
        player:sendEvent(EV.ABORTED, { reason = 'novehicle', destination = toKey })
        return
    end

    -- Charged BEFORE anything is spawned or moved, so a player who cannot
    -- afford it ends the request here rather than mid-journey. The menu
    -- already checked, but the menu's gold count is a frame old and the
    -- request is an event anyone could send.
    if not chargeFare(player, guide, data.price) then
        player:sendEvent(EV.ABORTED, { reason = 'cannotafford', destination = toKey })
        return
    end

    local prep = path.prepare(points, reversed)
    local cell = player.cell

    local vehicle = world.createObject(recordId, 1)

    session = {
        player = player,
        guide = guide,
        guideHome = guide and guide:isValid() and guide.position or nil,
        guideHomeCell = guide and guide:isValid() and guide.cell or nil,
        vehicle = vehicle,
        vehicleDef = v,
        cell = cell,
        points = points,
        prep = prep,
        fromKey = fromKey,
        toKey = toKey,
        travelled = 0,
        heading = nil,
        swayAmp = 0,
        swayT = 0,
        -- Vanilla would have advanced the clock by this much for this
        -- distance. The journey itself passes real time, and the clock runs
        -- during it, so the balance is settled on arrival rather than now:
        -- jumping the sun at the start would be worse than either.
        vanillaHours = data.vanillaHours or 0,
        startedAt = core.getGameTime(),
        -- Where the vehicle last was, so endJourney can put the player down
        -- even if the journey is aborted mid-route.
        lastX = nil, lastY = nil, lastZ = nil,
        -- The player's setting wins over the profile default, clamped to
        -- something that still looks like travel.
        speed = math.max(100, tonumber(data.speed) or v.speed),
    }

    -- addScript lands next frame, so the start event is deferred to the first
    -- onUpdate that sees the script attached. Sending it now would drop it,
    -- and with it enableAI(false) and the gait.
    vehicle:addScript(VEHICLE_SCRIPT)
    session.pendingStart = true

    player:sendEvent(EV.STARTED, {
        from = fromKey, to = toKey,
        displayName = routes.names[toKey] or toKey,
        length = prep.total,
        seconds = prep.total / v.speed,
    })

    if DEBUG then
        print(string.format('[WhyWalk Caravans] %s -> %s, %.0f units, %s',
            fromKey, toKey, prep.total, reversed and 'reversed' or 'forward'))
    end
end

local function onRequestAbort()
    if not session then return end
    endJourney(session, 'player request', false)
end

-- Answers the player script's question "which of this guide's destinations
-- can you animate, and how far is each?" The player script owns the menu and
-- the price; this owns the route data.
local function onRequestQuote(data)
    local player = data and data.player
    if not player or not player:isValid() then return end
    local fromKey = data.from and data.from:lower()
    if not fromKey then return end

    local reachable = destinationsFrom(fromKey)
    local out = {}
    for toKey in pairs(reachable) do
        local points, reversed = findRoute(fromKey, toKey)
        if points then
            local prep = path.prepare(points, reversed)
            out[toKey] = {
                key = toKey,
                displayName = routes.names[toKey] or toKey,
                length = prep.total,
            }
        end
    end
    player:sendEvent(EV.QUOTE, { from = fromKey, routes = out })
end

-- ---------------------------------------------------------------------------
-- LATCHING THE GUIDE
-- ---------------------------------------------------------------------------
-- UiModeChanged carries { oldMode, newMode } and no target, so the player
-- script cannot learn WHO it is talking to from the mode change alone. It is
-- latched at activation instead, which is sound because activating an NPC is
-- the only way to reach their travel topic.
--
-- I.Activation.addHandlerForType is global-context, which is why this lives
-- here and not with the menu. Returning nothing lets the activation proceed
-- normally -- this observes, it does not intercept.
I.Activation.addHandlerForType(types.NPC, function(object, actor)
    if not types.Player.objectIsInstance(actor) then return end
    local rec = types.NPC.record(object)
    local services = rec and rec.servicesOffered
    if not services or services.Travel ~= true then return end
    actor:sendEvent('WWCaravans_GuideLatched', { actor = object })
end)

-- ---------------------------------------------------------------------------
-- THE PER-FRAME HANDLER
-- ---------------------------------------------------------------------------

local function onUpdate(dt)
    local s = session
    if not s then return end

    if not s.player:isValid() or not s.vehicle:isValid() then
        return endJourney(s, 'invalid', false)
    end
    if core.isWorldPaused() or dt <= 0 then return end

    local health = types.Actor.stats.dynamic.health(s.player)
    if health and health.current <= 0 then
        return endJourney(s, 'died', false)
    end

    if s.pendingStart and s.vehicle:hasScript(VEHICLE_SCRIPT) then
        s.pendingStart = nil
        s.vehicle:sendEvent(EV_VEHICLE.START, { vehicle = 'siltstrider' })
    end

    s.travelled = s.travelled + s.speed * dt
    local done = s.travelled >= s.prep.total

    local x, y, z, yaw = path.at(s.points, s.prep, s.travelled)

    -- Ease the body toward the route heading. The polyline turns in steps, so
    -- applying the heading raw would snap the whole strider at every waypoint.
    s.heading = path.easeHeading(s.heading, yaw, s.vehicleDef.turnRate, dt)

    -- Sway: lean into the turn, eased rather than snapped. For a strider the
    -- multiplier is 1, which is deliberately almost imperceptible.
    s.swayT = s.swayT + dt
    local turning = 0
    if yaw and s.heading then
        local diff = path.angleDiff(s.heading, yaw)
        turning = diff > 0.02 and 1 or (diff < -0.02 and -1 or 0)
    end
    s.swayAmp = path.stepSway(s.swayAmp, turning ~= 0 and 1 or 0,
                              path.SWAY.AMPL_CHANGE * 60, dt)
    local roll = path.sway(s.swayT, s.swayAmp, s.vehicleDef.sway) * -turning

    s.lastX, s.lastY, s.lastZ = x, y, z
    placeVehicle(s, x, y, z, s.heading or yaw or 0, roll)

    local bodyYaw = s.heading or yaw or 0
    local slots = s.vehicleDef.slots
    if slots and slots[1] then
        placeOccupant(s.player, s.cell, x, y, z - s.vehicleDef.bodyOffset,
                      bodyYaw, slots[1])
    end
    if s.guide and s.guide:isValid() and s.vehicleDef.guideSlot then
        placeOccupant(s.guide, s.cell, x, y, z - s.vehicleDef.bodyOffset,
                      bodyYaw, s.vehicleDef.guideSlot)
    end

    if done then
        -- Settle the clock: vanilla's travel time less whatever the journey
        -- itself consumed, never negative.
        local elapsed = core.getGameTime() - (s.startedAt or 0)
        local elapsedHours = elapsed / 3600
        s.topUpHours = math.max(0, (s.vanillaHours or 0) - elapsedHours)
        endJourney(s, 'arrived', true)
    end
end

-- ---------------------------------------------------------------------------
-- SAVE / LOAD
-- ---------------------------------------------------------------------------

local function onSave()
    -- The journey is NOT resumed across a load, so only the created record id
    -- is kept -- otherwise every load would mint another record.
    --
    -- A route position, a spawned object and two teleported actors would all
    -- have to agree after a load, and the failure mode if they do not is a
    -- player stranded 1200 units in the air. Aborting is the honest option
    -- and it is what the player would do anyway.
    --
    -- THE GUIDE IS THE EXCEPTION and has to be saved.
    --
    -- A journey takes the caravaner off their post and carries them in the
    -- guide slot. Aborting on load releases the vehicle, but without this the
    -- guide would be left standing wherever the route had got to -- off their
    -- post for the rest of the save, and no longer where anyone looking to
    -- travel would find them. Their home is recorded so the load path can put
    -- them back whether or not the journey is resumed.
    local saved = {
        vehicleRecordId = vehicleRecordId,
        spawnedIsCreature = spawnedIsCreature,
    }
    local s = session
    if s and s.guide and s.guide:isValid() and s.guideHome then
        saved.guide = s.guide
        saved.guideHome = s.guideHome
        saved.guideHomeCell = s.guideHomeCell
    end
    return saved
end

local function onLoad(data)
    vehicleRecordId = data and data.vehicleRecordId or nil
    spawnedIsCreature = data and data.spawnedIsCreature == true

    local s = session
    session = nil
    if s then
        -- The save was written mid-journey. Release the vehicle so it is not
        -- left with its AI off and its gait looping forever.
        detachVehicleScript(s.vehicle)
        if s.vehicle and s.vehicle:isValid() then
            s.vehicle:teleport(s.cell, util.vector3(0, 0, -30000))
        end
    end

    -- Put the guide back on their post, from the saved position rather than
    -- from the session -- the session may not exist on this side of the load
    -- at all, which is the whole reason this is persisted.
    local guide = data and data.guide
    local home = data and data.guideHome
    if guide and guide:isValid() and home then
        guide:teleport(data.guideHomeCell or guide.cell, home)
        guide:sendEvent('WWCaravans_GuideReleased', {})
    end
end

return {
    eventHandlers = {
        [EV.REQUEST_TRAVEL] = onRequestTravel,
        [EV.REQUEST_ABORT]  = onRequestAbort,
        [EV.REQUEST_QUOTE]  = onRequestQuote,
    },
    engineHandlers = {
        onUpdate = onUpdate,
        onSave   = onSave,
        onLoad   = onLoad,
    },
}
