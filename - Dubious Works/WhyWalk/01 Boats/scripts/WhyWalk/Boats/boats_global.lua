---@omw-context global
--[[
    boats_global.lua -- boarding, the boat transform, and leaving

    The pilot is moved by the engine (boats_player.lua writes their controls
    while they walk on the water). This file places the BOAT under them every
    frame: Your Own Gondola's arrangement, with the heading the pilot script
    integrates instead of the pilot's own facing.

    One onUpdate, and its first statement returns when nobody is aboard. While
    aboard it does one teleport: there is no API to parent one object to
    another (RESEARCH 1.11), so this is the floor.

    Boats are taken over, not authored. A static or scripted boat is hidden
    and an inert activator copy put in its place; an unscripted activator is
    used as it stands. Copies persist in the save like any created object.
]]

local world = require('openmw.world')
local types = require('openmw.types')
local util  = require('openmw.util')
local core  = require('openmw.core')
local I     = require('openmw.interfaces')

local db   = require('scripts.WhyWalk.Boats.boats_db')
local phys = require('scripts.WhyWalk.Boats.boats_physics')

local T = db.TUNING

local EV = {
    REQUEST_BOARD = 'WWBoats_RequestBoard',
    REQUEST_LEAVE = 'WWBoats_RequestLeave',
    HELM          = 'WWBoats_Helm',
    PILOT_STATE   = 'WWBoats_PilotState',
    BOARDED       = 'WWBoats_Boarded',
    LEFT          = 'WWBoats_Left',
    REFUSED       = 'WWBoats_Refused',
    ASK_LEAVE     = 'WWBoats_AskLeave',
}

local DEBUG = false

-- rotateZ's sign convention is not documented (RESEARCH 3.7). Read it off the
-- transform itself instead of guessing: an object teleported with rotation R
-- reports R:getYaw(), so this is the sign that round-trips.
local YAW_SIGN = (util.transform.rotateZ(0.5):getYaw() > 0) and 1 or -1

local TWO_PI = 2 * math.pi

local session = nil

-- Created activator record per mesh, and the set of those record ids, so a
-- copy is recognised as ours when activated again. Persisted.
local copyRecordByModel = {}
local copyRecordIds = {}

-- Reported by the pilot's player script, which owns the settings and hears
-- Core WhyWalk's mount events; a global script can read neither.
local riderMounted = false
local motionPreferred = true

local reported = {}
local function reportOnce(key, message)
    if reported[key] then return end
    reported[key] = true
    print('[WhyWalk Boats] ' .. message)
end

-- ---------------------------------------------------------------------------
-- RECORDS AND MODELS
-- ---------------------------------------------------------------------------

local function recordOf(object)
    if types.Static.objectIsInstance(object) then
        return types.Static.record(object), 'static'
    end
    if types.Activator.objectIsInstance(object) then
        return types.Activator.record(object), 'activator'
    end
    return nil, nil
end

-- A plain nil when the object is not a boat this module may take; otherwise
-- (entry, record, kind, modelKey). `why` explains a refusal.
local function classify(object)
    local record, kind = recordOf(object)
    if not record then return nil, 'notboat' end

    local listed = db.recordEntry(object.recordId)
    if listed and not listed.claim then
        reportOnce('foreign:' .. object.recordId,
            "'" .. object.recordId .. "' is " .. listed.reason .. '; WhyWalk Boats leaves it alone.')
        return nil, 'foreign'
    end

    local modelKey = db.normalizeModel(record.model)
    local entry = db.modelEntry(record.model)
    if not entry then
        if db.isBoatLikeModel(record.model) then
            reportOnce('unknown:' .. tostring(modelKey),
                "'" .. object.recordId .. "' looks like a boat but its mesh '" .. tostring(modelKey)
                .. "' is not in boats_db.MODELS. Add it there with its vessel and yawOffset to make it pilotable.")
        end
        return nil, 'notboat'
    end

    local ours = copyRecordIds[object.recordId] == true
    local scripted = kind == 'activator' and record.mwscript ~= nil and record.mwscript ~= ''
    if scripted and not ours and not (listed and listed.claim) then
        reportOnce('scripted:' .. object.recordId,
            "'" .. object.recordId .. "' carries the script '" .. tostring(record.mwscript)
            .. "', so another mod may be driving it. Add it to boats_db.RECORDS with claim = true to take it over.")
        return nil, 'foreign'
    end
    return entry, record, kind, modelKey, ours, scripted
end

-- ---------------------------------------------------------------------------
-- THE COPY
-- ---------------------------------------------------------------------------

-- createRecord prefixes `model` with meshes\ (api-findings), so the draft gets
-- the plugin-relative path, never record.model round-tripped. The result is
-- checked: if the engine stored something else, the copy would be invisible,
-- and this line is the only place that would say why.
local function copyRecordFor(modelKey, displayName)
    local existing = copyRecordByModel[modelKey]
    if existing then return existing end

    local draft = types.Activator.createRecordDraft({ name = displayName, model = modelKey })
    local record = world.createRecord(draft)
    local stored = db.normalizeModel(record.model)
    if stored ~= modelKey then
        print("[WhyWalk Boats] createRecord stored the model as '" .. tostring(record.model)
              .. "' for '" .. modelKey .. "'. The copy will not render; this answers the open"
              .. ' question about model prefixing on this OpenMW build.')
    end
    copyRecordByModel[modelKey] = record.id
    copyRecordIds[record.id] = true
    return record.id
end

local function takeOver(original, modelKey, displayName)
    local recordId = copyRecordFor(modelKey, displayName)
    local boat = world.createObject(recordId, 1)
    if original.scale ~= 1 then boat:setScale(original.scale) end
    boat:teleport(original.cell, original.position, original.rotation)
    original.enabled = false
    return boat
end

-- ---------------------------------------------------------------------------
-- HULL FROM THE BOUNDING BOX (vessels the database has no measurement for)
-- ---------------------------------------------------------------------------
-- Horizontal extents depend on how the box is axis-aligned (Core's
-- saddleFromBoundingBox note), so the long side is taken as the length and the
-- short side as the beam: right for a boat at any heading within a few units,
-- conservative at 45 degrees. The draft uses only the vertical extent, which
-- no yaw changes.
local function hullFromBox(object, waterLevel, modelKey)
    local box = object:getBoundingBox()
    if not box or not box.halfSize or not (box.halfSize.z > 0) then return nil end
    local hx, hy = box.halfSize.x, box.halfSize.y
    local hull = {
        bow = math.max(hx, hy), stern = math.max(hx, hy),
        halfBeam = math.min(hx, hy),
        draft = math.max(0, waterLevel - (box.center.z - box.halfSize.z)),
    }
    reportOnce('hull:' .. tostring(modelKey), string.format(
        "'%s' has no hull measurement; using its bounding box: bow/stern %.0f, half beam %.0f, draft %.0f."
        .. ' Put these in its boats_db.VESSELS entry to stop measuring.',
        tostring(modelKey), hull.bow, hull.halfBeam, hull.draft))
    return hull
end

-- ---------------------------------------------------------------------------
-- PLACEMENT
-- ---------------------------------------------------------------------------

local function boatPosition(s, pilotPos)
    local ax, ay = phys.toWorld(s.anchor.x, s.anchor.y, s.heading)
    local ox, oy = phys.toWorld(s.origin.x, s.origin.y, s.heading)
    return util.vector3(pilotPos.x - ax + ox, pilotPos.y - ay + oy,
                        s.waterLevel + s.waterOffset + s.origin.z)
end

local function boatRotation(s, roll, pitch)
    local r = util.transform.rotateZ(YAW_SIGN * (s.heading + s.yawOffset))
    if roll ~= 0 or pitch ~= 0 then
        r = r * util.transform.rotateY(roll) * util.transform.rotateX(pitch)
    end
    return r
end

local function pilotStation(s, boatPos)
    local ox, oy = phys.toWorld(s.origin.x, s.origin.y, s.heading)
    local ax, ay = phys.toWorld(s.anchor.x, s.anchor.y, s.heading)
    return util.vector3(boatPos.x - ox + ax, boatPos.y - oy + ay,
                        s.waterLevel + s.waterOffset + s.anchor.z)
end

-- ---------------------------------------------------------------------------
-- SOUND
-- ---------------------------------------------------------------------------

local function soundAvailable(id)
    if not id then return false end
    local records = core.sound.records
    if records == nil then return true end
    return records[id] ~= nil
end

local function startSound(s)
    if not soundAvailable(s.sound) then return end
    core.sound.playSound3d(s.sound, s.boat, { loop = true, volume = T.soundVolume })
end

local function stopSound(s)
    if not s.sound or not s.boat:isValid() then return end
    if core.sound.isSoundPlaying(s.sound, s.boat) then
        core.sound.stopSound3d(s.sound, s.boat)
    end
end

-- ---------------------------------------------------------------------------
-- BOARD / LEAVE
-- ---------------------------------------------------------------------------

local function refuse(player, reason)
    player:sendEvent(EV.REFUSED, { reason = reason })
end

local function newSession(player, boat, vessel, entry, modelKey, heading, waterLevel, motionOn)
    return {
        player = player, boat = boat, vessel = vessel, vesselId = vessel.id,
        modelKey = modelKey, heading = heading, turnSign = 0,
        yawOffset = entry.yawOffset or 0,
        origin = entry.origin or { x = 0, y = 0, z = 0 },
        anchor = vessel.anchor,
        waterLevel = waterLevel, waterOffset = vessel.waterOffset,
        motion = vessel.motion, motionOn = motionOn ~= false,
        sound = vessel.sound,
        t = 0, heel = 0,
        lastCell = player.cell, lastPilotPos = player.position,
    }
end

local function announce(s)
    s.player:sendEvent(EV.BOARDED, {
        boat = s.boat, vesselId = s.vesselId, modelKey = s.modelKey,
        heading = s.heading, hull = s.vessel.hull, anchor = s.anchor,
        waterLevel = s.waterLevel, waterOffset = s.waterOffset,
    })
end

local function board(player, target, motionOn)
    if session then return refuse(player, 'busy') end
    if not types.Player.objectIsInstance(player) then return end
    if riderMounted then return refuse(player, 'mounted') end
    if not target or not target:isValid() or not target.enabled then return end

    local entry, recordOrWhy, kind, modelKey, ours, scripted = classify(target)
    if not entry then
        if recordOrWhy == 'foreign' then refuse(player, 'foreign') end
        return
    end

    local cell = target.cell
    if not cell or cell ~= player.cell and not (cell.isExterior and player.cell.isExterior) then return end
    if not cell.hasWater then return refuse(player, 'nowater') end
    local waterLevel = cell.waterLevel or 0

    local box = target:getBoundingBox()
    local reach = T.claimRange + math.max(box.halfSize.x, box.halfSize.y)
    local dx, dy = player.position.x - box.center.x, player.position.y - box.center.y
    if dx * dx + dy * dy > reach * reach then return refuse(player, 'far') end

    if cell.isExterior then
        local land = core.land.getHeightAt(target.position, cell)
        if land > waterLevel - 10 then return refuse(player, 'beached') end
    end

    local vessel = db.vessel(entry.vessel)
    local originZ = entry.origin and entry.origin.z or 0

    -- Respect the level designer: a boat already floating within reach of the
    -- database height keeps the height it was placed at.
    local placedOffset = target.position.z - waterLevel - originZ
    if math.abs(placedOffset - vessel.waterOffset) <= 40 then
        vessel.waterOffset = placedOffset
    end
    vessel.hull = vessel.hull or hullFromBox(target, waterLevel, modelKey)
        or { bow = 150, stern = 150, halfBeam = 60, draft = 30 }

    local heading = (target.rotation:getYaw() - (entry.yawOffset or 0)) % TWO_PI

    local boat = target
    if kind == 'static' or (scripted and not ours) then
        boat = takeOver(target, modelKey, vessel.name)
    end

    session = newSession(player, boat, vessel, entry, modelKey, heading, waterLevel, motionOn)
    -- From the TARGET's transform: a copy's own teleport lands next frame.
    local station = pilotStation(session, target.position) + util.vector3(0, 0, 2)
    player:teleport(player.cell, station, util.transform.rotateZ(YAW_SIGN * heading))
    session.lastPilotPos = station

    startSound(session)
    announce(session)

    if DEBUG then
        print(string.format('[WhyWalk Boats] boarded %s (%s) heading %.2f water %.1f offset %.1f',
            tostring(target.recordId), vessel.id, heading, waterLevel, session.waterOffset))
    end
end

-- Leaves the boat level where it last was. Placed from the last pilot position
-- in the boat's own cell, never the pilot's current one: a pilot who left
-- through a door is already in an interior.
local function endSession(reason, handOff)
    local s = session
    if not s then return end
    session = nil

    if s.boat:isValid() then
        s.boat:teleport(s.boat.cell, boatPosition(s, s.lastPilotPos), boatRotation(s, 0, 0))
    end
    stopSound(s)
    if s.player:isValid() then
        s.player:sendEvent(EV.LEFT, { reason = reason, handOff = handOff == true })
    end
    if DEBUG then print('[WhyWalk Boats] left: ' .. tostring(reason)) end
end

-- ---------------------------------------------------------------------------
-- EVENTS
-- ---------------------------------------------------------------------------

local function onRequestBoard(data)
    if not data or not data.player or not data.player:isValid() then return end
    board(data.player, data.target, motionPreferred)
end

local function onRequestLeave(data)
    local s = session
    if not s or not data or data.player ~= s.player then return end
    if data.exit and not data.handOff then
        s.player:teleport(s.player.cell, data.exit, { onGround = true })
    end
    endSession(data.reason or 'player', data.handOff)
end

local function onHelm(data)
    local s = session
    if not s or not data or data.player ~= s.player then return end
    s.heading = data.heading
    s.turnSign = data.turn or 0
end

local function onPilotState(data)
    if not data then return end
    if data.mounted ~= nil then riderMounted = data.mounted == true end
    if data.motion ~= nil then motionPreferred = data.motion == true end
end

-- Activators come through activation; statics cannot be activated, so the
-- player script raycasts for those and sends REQUEST_BOARD.
I.Activation.addHandlerForType(types.Activator, function(object, actor)
    if not types.Player.objectIsInstance(actor) then return end
    if session and object == session.boat then
        actor:sendEvent(EV.ASK_LEAVE, {})
        return false
    end
    if not classify(object) then return end
    board(actor, object, motionPreferred)
    return false
end)

-- ---------------------------------------------------------------------------
-- THE PER-FRAME HANDLER
-- ---------------------------------------------------------------------------

local function onUpdate(dt)
    local s = session
    if not s then return end

    if not s.boat:isValid() or not s.player:isValid() then
        session = nil
        if s.player:isValid() then s.player:sendEvent(EV.LEFT, { reason = 'invalid' }) end
        return
    end
    local health = types.Actor.stats.dynamic.health(s.player)
    if health.current <= 0 then return endSession('died') end
    if core.isWorldPaused() or dt <= 0 then return end

    local pilot = s.player
    local cell = pilot.cell
    if cell ~= s.lastCell then
        if not (cell and cell.isExterior and s.lastCell and s.lastCell.isExterior) then
            return endSession('cell')
        end
        s.lastCell = cell
    end

    local pilotPos = pilot.position
    if (pilotPos - s.lastPilotPos):length() > T.maxAnchorDrift then
        return endSession('moved')
    end
    s.lastPilotPos = pilotPos

    local roll, pitch = 0, 0
    if s.motionOn then
        s.t = s.t + dt
        s.heel = phys.stepHeel(s.heel, s.turnSign, s.motion, dt)
        roll, pitch = phys.motion(s.t, s.heel, s.motion)
    end
    s.boat:teleport(cell, boatPosition(s, pilotPos), boatRotation(s, roll, pitch))
end

-- ---------------------------------------------------------------------------
-- SAVE / LOAD
-- ---------------------------------------------------------------------------

local function onSave()
    local saved = { copyRecordByModel = copyRecordByModel, copyRecordIds = copyRecordIds }
    local s = session
    if s then
        saved.session = {
            player = s.player, boat = s.boat, vesselId = s.vesselId, modelKey = s.modelKey,
            heading = s.heading, waterLevel = s.waterLevel, waterOffset = s.waterOffset,
            hull = s.vessel.hull, motionOn = s.motionOn,
        }
    end
    return saved
end

local function onLoad(data)
    session, riderMounted = nil, false
    copyRecordByModel = data and data.copyRecordByModel or {}
    copyRecordIds = data and data.copyRecordIds or {}

    local saved = data and data.session
    if not saved or not saved.player or not saved.player:isValid()
        or not saved.boat or not saved.boat:isValid() then
        return
    end
    local entry = db.modelEntry(saved.modelKey)
    local vessel = db.vessel(saved.vesselId)
    if not entry or not vessel then return end
    vessel.waterOffset = saved.waterOffset
    vessel.hull = saved.hull or vessel.hull

    session = newSession(saved.player, saved.boat, vessel, entry, saved.modelKey,
                         saved.heading, saved.waterLevel, saved.motionOn)
    startSound(session)
    -- The player scripts do not persist a voyage; this re-enters it, after
    -- their own onLoad has released whatever the save recorded.
    announce(session)
end

return {
    eventHandlers = {
        [EV.REQUEST_BOARD] = onRequestBoard,
        [EV.REQUEST_LEAVE] = onRequestLeave,
        [EV.HELM]          = onHelm,
        [EV.PILOT_STATE]   = onPilotState,
    },
    engineHandlers = {
        onUpdate = onUpdate,
        onSave   = onSave,
        onLoad   = onLoad,
    },
}
