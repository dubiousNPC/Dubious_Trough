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
local stops  = require('scripts.WhyWalk.Caravans.caravans_stops')

-- Centres first, from every file, so one bad file cannot move a stop; then
-- the files whose ends are not at their stops are dropped (caravans_stops.lua
-- says why). Printed every load: a dropped route is a data fault worth seeing.
local STOP_CENTRES = stops.centres(routes.routes)
for _, d in ipairs(stops.validate(routes.routes, STOP_CENTRES)) do
    print('[WhyWalk Caravans] route dropped, reverse used instead: ' .. d)
end

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

---The vehicle's ORIGIN for a route point: bodyOffset BELOW it.
---
---The route is authored through the rider's body, not the strider's feet, so
---the vehicle origin sits `bodyOffset` lower and every slot height is measured
---up from there (slot z 1223 against bodyOffset 1220 puts a rider 3 units
---above the route point, which is why the route can be walked directly).
---
---ONE function because the first version did not have one. `placeVehicle` was
---handed the route point and the occupants were handed `z - bodyOffset`
---separately, so the strider stood a full 1220 units too high with its feet at
---the rider's waist and everything aboard hovering. Two call sites deriving
---the same origin independently is how they came to disagree.
local function bodyOrigin(s, z)
    return z - (s.vehicleDef.bodyOffset or 0)
end

local function placeVehicle(s, x, y, z, yaw, roll)
    local rot = util.transform.rotateZ(YAW_SIGN * yaw)
    if roll and roll ~= 0 then rot = rot * util.transform.rotateY(roll) end
    s.vehicle:teleport(s.cell, util.vector3(x, y, z), rot)
end

---Put an occupant in a vehicle-local slot, facing the way the vehicle faces.
---
---For the GUIDE only. The player gets `placeRider` below, because teleporting
---an absolute rotation onto the player every frame is what locks their camera.
local function placeOccupant(obj, cell, x, y, z, yaw, slot)
    local sx, sy, sz = db.slotWorld(x, y, z, yaw, slot)
    obj:teleport(cell, util.vector3(sx, sy, sz),
                 util.transform.rotateZ(YAW_SIGN * yaw))
end

-- ---------------------------------------------------------------------------
-- THE PLAYER'S YAW IS A DELTA, NOT A HEADING
-- ---------------------------------------------------------------------------
-- A passenger teleported with `rotateZ(heading)` every frame cannot look
-- around: in third person the body yaw and the camera yaw are the same number,
-- so rewriting the body every frame overwrites whatever the mouse just did.
-- The camera ends up welded to the strider's nose, which is the reported bug.
--
-- Core solved this for the rider pin and the fix carries over unchanged
-- (whywalk_global.lua, placeRiderTeleport):
--
--     playerYaw = playerYaw + (heading - headingLastFrame)
--
-- The body still turns with the strider, so the passenger does not end up
-- sitting sideways through a corner, and the mouse offset survives because it
-- is already in playerYaw when the delta lands on top of it.
--
-- Zero is a safe "do nothing" here, unlike an absolute angle: a delta of zero
-- means the heading genuinely did not change, so skipping the write is right
-- rather than a lost update. Omitting the rotation argument entirely keeps the
-- current rotation (TeleportOptions.rotation: "if missing, then the current
-- rotation is used"), which is exactly what a zero delta should do.
local YAW_EPSILON = 1e-4

-- ---------------------------------------------------------------------------
-- AND IT GOES THROUGH CORE'S PIN, NOT THROUGH TELEPORT
-- ---------------------------------------------------------------------------
-- A teleport fires `onTeleported` on EVERY player script in the load order.
-- Pinning the player with one each frame therefore delivers sixty a second to
-- every other mod, and the 2026-10-29 log shows three of them breaking under
-- it: VvardenfellDirector logged "teleport; normal camera restored" 4116
-- times -- once per frame for the whole of every journey, which is the
-- reported first-person lock -- DetailDevil's `onTeleported` handler raised
-- three times, all three inside a journey, and queued VFX cleanup errored.
--
-- Core already solved this. Its MWScript bridge moves the player with
-- `SetPos`, which is not a teleport and fires no handler; the comment at
-- placeRiderMWScript records Devilish's warning about the per-frame Lua
-- teleport loop, which is the same hazard found from the other end.
--
-- So the pin is Core's, published as the WhyWalkRiderPin interface. Its
-- stale-ESP probe, its liveness check and its automatic fall-through to a
-- teleport all come with it, which matters: if the bridge is not live in a
-- given install, this is exactly the old behaviour and nothing is lost.
--
-- Core absent, or the pin held by a mount: fall back to the teleport here.
-- Being carried is better than being left behind.
local PIN_OWNER = {}

local function teleportRider(obj, cell, pos, yawDelta)
    if yawDelta and math.abs(yawDelta) > YAW_EPSILON then
        obj:teleport(cell, pos,
                     util.transform.rotateZ(obj.rotation:getYaw() + yawDelta))
    else
        obj:teleport(cell, pos)
    end
end

-- WHICH PATH IS IN USE IS LOGGED, ONCE PER SESSION.
--
-- Because the claim that SetPos avoids the onTeleported storm is reasoning,
-- not something confirmed in a running game, and the last time this module
-- shipped on reasoning alone it was wrong. The line below plus a grep for
-- another mod's per-frame teleport chatter settles it in one trip.
--
-- It also catches the likelier disappointment: Core's MWScript pin needs a
-- WhyWalk.omwaddon whose WhyWalkRiderPin script has actually been COMPILED,
-- and the shipped one carries the script as source text with no bytecode.
-- Where that has not been fixed the pin falls through to a teleport inside
-- Core, this still says "teleport", and nothing about the storm changes.
-- NOT on the first frame. Core proves the bridge by watching whether the
-- player actually tracks the target, and it allows 20 frames of misses before
-- declaring it dead, so `isBridged()` answers "unproven, assume yes" until
-- then. Reporting immediately would print the optimistic answer and then
-- quietly fall back, which is worse than not reporting at all.
local PIN_REPORT_AFTER = 60      -- ~1s at 60fps; Core decides within 20
local pinFrames = 0
local pinPathReported = false

local function reportPinPath(usingPin)
    if pinPathReported then return end
    pinFrames = pinFrames + 1
    -- A straight fall-through is decided at once: there is no bridge to prove.
    if usingPin and pinFrames < PIN_REPORT_AFTER then return end
    pinPathReported = true
    if not usingPin then
        print('[WhyWalk Caravans] rider carried by TELEPORT. Every frame of a'
              .. ' journey fires onTeleported on every player script in the'
              .. ' load order, which some mods react to; if your camera locks'
              .. ' during a ride, that is why. The WhyWalk MWScript pin avoids'
              .. ' it, and needs WhyWalk.omwaddon with the WhyWalkRiderPin'
              .. ' script compiled (open and save it in OpenMW-CS).')
    elseif DEBUG then
        print('[WhyWalk Caravans] rider carried by the WhyWalk MWScript pin')
    end
end

local function placeRider(obj, cell, x, y, z, yaw, slot, yawDelta)
    local sx, sy, sz = db.slotWorld(x, y, z, yaw, slot)
    local pos = util.vector3(sx, sy, sz)
    local pin = I.WhyWalkRiderPin
    if pin and pin.place(PIN_OWNER, obj, pos, yawDelta) then
        -- `place` succeeds either way: Core uses the bridge when it is live
        -- and teleports when it is not, so ask which it actually did.
        reportPinPath(pin.isBridged ~= nil and pin.isBridged())
        return
    end
    reportPinPath(false)
    teleportRider(obj, cell, pos, yawDelta)
end

local function releaseRider()
    local pin = I.WhyWalkRiderPin
    if pin then pin.release(PIN_OWNER) end
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

-- ---------------------------------------------------------------------------
-- ENDING A JOURNEY TAKES A FRAME OF ITS OWN
-- ---------------------------------------------------------------------------
-- An object can be teleported ONCE per frame. A second call on an object whose
-- first teleport has not landed yet raises
--
--     Object is either removed or already in the process of teleporting
--
-- and that is a hard error, not a warning: it aborts the whole handler.
--
-- Teardown used to run inline at the end of onUpdate, in the same frame that
-- had just placed all three bodies, so the first thing it did -- parking the
-- vehicle -- threw every single time:
--
--     [C]: in function 'teleport'
--     caravans_global.lua:290: in function 'endJourney'
--     caravans_global.lua:567: in function <...:498>
--
-- `session = nil` runs first, so onUpdate went quiet afterwards and the error
-- appeared once per journey rather than once per frame. Everything after the
-- throw never ran, which is the whole of the reported fault from one line:
-- the vehicle was never parked (a second strider standing at the stop), the
-- guide was never released, the player was never put on the ground, and no
-- ARRIVED event ever reached the player script -- so no dismount, no message,
-- and the seated pose stayed on. Stuck aboard, exactly as described.
--
-- It is not enough to skip the placement on the last frame, because the abort
-- path (pressing X) arrives as an event, which the engine may deliver in a
-- frame where onUpdate has already placed everything.
--
-- So ending is a REQUEST. `endJourney` records why and returns; `finishJourney`
-- does the work from the top of the next onUpdate, before anything has moved.
-- One frame of latency, and no call site can get the ordering wrong.

---Ask for the journey to end. Safe to call from anywhere, including from
---inside onUpdate after the bodies have been placed.
local function endJourney(s, reason, arrived)
    if not s or s.ending then return end
    s.ending = { reason = reason, arrived = arrived }
end

---Do the teardown. Called only from the top of onUpdate, where nothing has
---been teleported yet this frame.
local function finishJourney(s)
    local reason  = s.ending.reason
    local arrived = s.ending.arrived
    session = nil

    -- Before the dismount teleport: the pin would otherwise keep writing the
    -- player back to the saddle every frame after the journey had ended.
    releaseRider()

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
                util.vector3(px, py, bodyOrigin(s, pz)),
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
--
-- Places are resolved by POSITION (caravans_stops.lua): the guide's own for
-- the origin, each record destination's for the target. byDest is indexed
-- like the record's travelDestinations, so the player script pairs them by
-- index and never compares names or cell ids.
local warnedGuide = {}
local function onRequestQuote(data)
    local player = data and data.player
    local guide = data and data.guide
    if not player or not player:isValid() then return end
    if not guide or not guide:isValid() then return end

    local fromKey = guide.cell.isExterior
        and stops.at(STOP_CENTRES, guide.position.x, guide.position.y) or nil
    local byDest = {}
    local dests = fromKey and types.NPC.record(guide).travelDestinations or {}
    for i, dest in ipairs(dests) do
        local p = dest.position
        local toKey = stops.at(STOP_CENTRES, p.x, p.y)
        local points, reversed
        if toKey and toKey ~= fromKey then
            points, reversed = findRoute(fromKey, toKey)
        end
        if points then
            byDest[i] = {
                key = toKey,
                displayName = routes.names[toKey] or toKey,
                length = path.prepare(points, reversed).total,
            }
        end
    end

    -- Once per guide, so a guide this module cannot animate is explained in
    -- the log instead of silently getting the vanilla window.
    if not next(byDest) and not warnedGuide[guide.id] then
        warnedGuide[guide.id] = true
        print(string.format(
            '[WhyWalk Caravans] %s: no animated route (%s); vanilla travel used',
            guide.recordId,
            fromKey and ('origin ' .. fromKey .. ', no destination has a route')
                or 'not at a known stop'))
    end
    player:sendEvent(EV.QUOTE, { guide = guide, from = fromKey, byDest = byDest })
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

    -- FIRST, before anything is placed. See the note above endJourney: the
    -- teardown teleports all three bodies and cannot share a frame with the
    -- placement that also teleports them.
    --
    -- Ahead of the pause check too. A journey asked to end while the world is
    -- paused should still end; nothing here depends on time passing.
    if s.ending then return finishJourney(s) end

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

    local bodyYaw = s.heading or yaw or 0
    -- ONE origin for the vehicle and everything riding on it. See bodyOrigin.
    local bz = bodyOrigin(s, z)
    placeVehicle(s, x, y, bz, bodyYaw, roll)

    -- The player's share of the turn, as a change rather than a heading, so
    -- mouse-look survives. nil on the first frame: there is no previous
    -- heading to difference against, and the boarding teleport already seated
    -- them square.
    local riderDelta = s.riderYawApplied
        and path.angleDiff(s.riderYawApplied, bodyYaw) or nil
    s.riderYawApplied = bodyYaw

    local slots = s.vehicleDef.slots
    if slots and slots[1] then
        placeRider(s.player, s.cell, x, y, bz, bodyYaw, slots[1], riderDelta)
    end
    if s.guide and s.guide:isValid() and s.vehicleDef.guideSlot then
        placeOccupant(s.guide, s.cell, x, y, bz, bodyYaw, s.vehicleDef.guideSlot)
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
        -- The save was written mid-journey. Release the pin first, or the
        -- MWScript bridge keeps pinning the player to a route this side of
        -- the load does not resume.
        releaseRider()
        -- Release the vehicle so it is not left with its AI off and its gait
        -- looping forever.
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
