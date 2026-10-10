---@omw-context player
--[[
    boats_player.lua -- the pilot: helm input, the boat's motion, the bumper

    The pilot walks on the water (Water Walking, record-free) and is MOVED BY
    THE ENGINE through their own controls, the way Your Own Gondola moves its
    player. That is what gives collision with docks, rocks and shore for free;
    the boat is only placed under the pilot by boats_global.lua.

    The boat has its own heading, integrated here with Skyships' feel: speed
    builds and coasts, the yaw rate eases toward the rudder, and the hull
    probes ahead so it slows before land or an obstacle instead of hitting it.
    The pilot looks around freely; the boat's velocity is re-expressed as
    movement/sideMovement relative to wherever the pilot faces.

    One onUpdate, live only while piloting. It has to restate the controls
    every frame (RESEARCH 1.18), so this is the floor; the probes inside it
    run at 10 Hz.
]]

local self    = require('openmw.self')
local core    = require('openmw.core')
local input   = require('openmw.input')
local types   = require('openmw.types')
local async   = require('openmw.async')
local util    = require('openmw.util')
local nearby  = require('openmw.nearby')
local camera  = require('openmw.camera')
local storage = require('openmw.storage')
local ui      = require('openmw.ui')
local I       = require('openmw.interfaces')

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

-- The pilot's pose is Core's: ridingAnim.lua plays whywalk_shared.VESSEL_STANCE.
local ANIM = {
    START = 'WhyWalk_AnimVesselStart',
    HELM  = 'WhyWalk_AnimVesselHelm',
    STOP  = 'WhyWalk_AnimVesselStop',
}

local DEBUG = false
local TWO_PI = 2 * math.pi

-- ---------------------------------------------------------------------------
-- SETTINGS
-- ---------------------------------------------------------------------------
-- A group on Core WhyWalk's page, which Core's whywalk_player.lua registers;
-- this module loads after Core, so the page exists.

local L10N = 'WhyWalkBoats'
local GROUP = 'SettingsWhyWalkBoats'

I.Settings.registerGroup {
    key = GROUP, page = 'WhyWalk', l10n = L10N,
    name = 'boats_group_name', description = 'boats_group_description',
    permanentStorage = true, order = 1,
    settings = {
        { key = 'STEERING', renderer = 'select', default = 'rudder',
          name = 'steering_name', description = 'steering_description',
          argument = { l10n = L10N, items = { 'rudder', 'view' } } },
        { key = 'TURN_VIEW_WITH_BOAT', renderer = 'checkbox', default = true,
          name = 'turn_view_name', description = 'turn_view_description' },
        { key = 'BOAT_MOTION', renderer = 'checkbox', default = true,
          name = 'motion_name', description = 'motion_description' },
        { key = 'CLAIM_SCENERY', renderer = 'checkbox', default = true,
          name = 'claim_name', description = 'claim_description' },
        { key = 'SHOW_HELP', renderer = 'checkbox', default = true,
          name = 'help_name', description = 'help_description' },
        { key = 'MUTE_WATER_STEPS', renderer = 'checkbox', default = true,
          name = 'mute_name', description = 'mute_description' },
    },
}

local settings = storage.playerSection(GROUP)
local l10n = core.l10n(L10N)

-- ---------------------------------------------------------------------------
-- STATE
-- ---------------------------------------------------------------------------

local piloting = false
local coreMounted = false
local handingOff = false

local boat, vessel, anchor, waterLevel = nil, nil, nil, 0
local heading, speed, yawRate = 0, 0, 0
local gains = { [false] = 1, [true] = 1 }
local capAhead, capAstern = nil, nil
local probeTimer = 0
local viewEngaged = false
local steering, turnView, muteSteps = 'rudder', true, true

local lastPos, lastAsked, lastDirX, lastDirY, settle = nil, 0, 0, 0, 0
local lastRunning = false
local bumpTime = 0
local lastSentHeading, lastSentTurn = nil, nil
local animTurn, animThrottle = 0, 0
-- Speed band for the pose: true at or above hull speed. Hysteresis, because
-- this crosses its threshold every time the boat accelerates and a single
-- threshold would swap the stroke back and forth around it.
local animFast = false

local held = { forward = 0, back = 0, left = 0, right = 0 }

local controlsLocked = false
local waterWalkAdded = false

local WATER_STEPS = { 'FootWaterLeft', 'FootWaterRight' }

-- ---------------------------------------------------------------------------
-- OWNED STATE: control lock and water walking
-- ---------------------------------------------------------------------------
-- Same handshake as Core's lock and levitation: one call each way, recorded
-- in the save, undone on load.

local function lockControls()
    if controlsLocked then return end
    I.Controls.overrideMovementControls(true)
    controlsLocked = true
end

local function releaseControls()
    if not controlsLocked then return end
    I.Controls.overrideMovementControls(false)
    controlsLocked = false
end

local function addWaterWalking()
    if waterWalkAdded then return end
    types.Actor.activeEffects(self):modify(1, core.magic.EFFECT_TYPE.WaterWalking)
    waterWalkAdded = true
end

local function removeWaterWalking()
    if not waterWalkAdded then return end
    types.Actor.activeEffects(self):modify(-1, core.magic.EFFECT_TYPE.WaterWalking)
    waterWalkAdded = false
end

local function sendPilotState()
    core.sendGlobalEvent(EV.PILOT_STATE, {
        mounted = coreMounted, motion = settings:get('BOAT_MOTION') ~= false,
    })
end

settings:subscribe(async:callback(function()
    sendPilotState()
    steering = settings:get('STEERING') or 'rudder'
    turnView = settings:get('TURN_VIEW_WITH_BOAT') ~= false
    muteSteps = settings:get('MUTE_WATER_STEPS') ~= false
end))

-- ---------------------------------------------------------------------------
-- INPUT
-- ---------------------------------------------------------------------------
-- Action handlers rather than keys: they follow the player's bindings and the
-- gamepad, and fire on change (RESEARCH 1.12). Values may be analogue.

local function amount(value)
    if type(value) == 'number' then return value end
    return value and 1 or 0
end

input.registerActionHandler('MoveForward',  async:callback(function(v) held.forward = amount(v) end))
input.registerActionHandler('MoveBackward', async:callback(function(v) held.back    = amount(v) end))
input.registerActionHandler('MoveLeft',     async:callback(function(v) held.left    = amount(v) end))
input.registerActionHandler('MoveRight',    async:callback(function(v) held.right   = amount(v) end))

local function seedHeld()
    held.forward = input.isActionPressed(input.ACTION.MoveForward) and 1 or 0
    held.back    = input.isActionPressed(input.ACTION.MoveBackward) and 1 or 0
    held.left    = input.isActionPressed(input.ACTION.MoveLeft) and 1 or 0
    held.right   = input.isActionPressed(input.ACTION.MoveRight) and 1 or 0
end

local function hudHidden()
    return I.UI and I.UI.isHudVisible and not I.UI.isHudVisible()
end

-- ---------------------------------------------------------------------------
-- BOARDING A STATIC (activators arrive through activation in the global)
-- ---------------------------------------------------------------------------

local function lookedAt()
    if I.SharedRay and I.SharedRay.get then
        local result = I.SharedRay.get()
        if not result or not result.hit then return nil end
        if result.distance and result.distance > T.claimRange then return nil end
        return result.hitObject
    end
    local from = camera.getPosition()
    local to = from + camera.viewportToWorldVector(util.vector2(0.5, 0.5)) * (T.claimRange + 200)
    local result = nearby.castRenderingRay(from, to, { ignore = self })
    return result.hit and result.hitObject or nil
end

local function onActivate()
    if piloting or coreMounted or hudHidden() then return end
    if settings:get('CLAIM_SCENERY') == false then return end
    local target = lookedAt()
    if not target or not target:isValid() then return end
    if not types.Static.objectIsInstance(target) then return end
    if not db.modelEntry(types.Static.record(target).model) then return end
    core.sendGlobalEvent(EV.REQUEST_BOARD, { player = self.object, target = target })
end

input.registerTriggerHandler('Activate', async:callback(onActivate))

if I.SharedRay and I.SharedRay.requestDistance then
    I.SharedRay.requestDistance(T.claimRange)
end

-- ---------------------------------------------------------------------------
-- LEAVING
-- ---------------------------------------------------------------------------

local function vesselOrigin(pos)
    local ax, ay = phys.toWorld(anchor.x, anchor.y, heading)
    return pos.x - ax, pos.y - ay
end

-- Port, starboard, bow, stern: the first with something to stand on above the
-- water wins, the side the pilot is looking toward first. With nothing to
-- stand on, the pilot goes over the side into the water.
local function exitPoint()
    local hull = vessel.hull
    local clear = T.exitClearance
    local cx, cy = vesselOrigin(self.position)
    local starboard = { x = hull.halfBeam + clear, y = anchor.y }
    local port      = { x = -(hull.halfBeam + clear), y = anchor.y }
    local order = { starboard, port, { x = 0, y = hull.bow + clear }, { x = 0, y = -(hull.stern + clear) } }
    if phys.angleDiff(heading, self.rotation:getYaw()) < 0 then
        order[1], order[2] = port, starboard
    end

    local ignore = { self.object, boat }
    for _, c in ipairs(order) do
        local wx, wy = phys.toWorld(c.x, c.y, heading)
        local x, y = cx + wx, cy + wy
        local hit = nearby.castRay(util.vector3(x, y, waterLevel + 400),
                                   util.vector3(x, y, waterLevel - 60), { ignore = ignore })
        if hit.hit and hit.hitPos.z >= waterLevel - 2 and hit.hitPos.z <= waterLevel + 300 then
            return hit.hitPos + util.vector3(0, 0, 4), true
        end
    end
    local wx, wy = phys.toWorld(order[1].x, order[1].y, heading)
    return util.vector3(cx + wx, cy + wy, waterLevel + 2), false
end

local function leave()
    if not piloting then return end
    local exit, dry = exitPoint()
    if not dry then ui.showMessage(l10n('msg_into_water')) end
    core.sendGlobalEvent(EV.REQUEST_LEAVE, { player = self.object, exit = exit })
end

-- ---------------------------------------------------------------------------
-- THE BUMPER
-- ---------------------------------------------------------------------------
-- Look-ahead from Skyships (terrain sampled ahead of the hull), applied as a
-- speed cap: the hull may only go as fast as it can still stop before what is
-- in front of it. A ray at probe height catches docks and walls, one below
-- the waterline catches rocks under the surface, and the heightmap catches
-- shoals and beaches.

local function obstacleCap(direction)
    local hull = vessel.hull
    local reachToEnd = direction > 0 and (hull.bow - anchor.y) or (hull.stern + anchor.y)
    local lookAhead = (speed * speed) / (2 * vessel.brake) + T.obstacleMargin * 2
    local fx, fy = phys.forward(heading)
    fx, fy = fx * direction, fy * direction
    local pos = self.position
    local ignore = { self.object, boat }

    local nearest = nil
    local function consider(distanceFromEnd)
        if nearest == nil or distanceFromEnd < nearest then nearest = distanceFromEnd end
    end

    local depths = { waterLevel + T.probeHeight }
    if hull.draft > 20 then depths[2] = waterLevel - math.min(hull.draft * 0.6, 60) end
    local span = reachToEnd + lookAhead
    for _, z in ipairs(depths) do
        local from = util.vector3(pos.x, pos.y, z)
        local to = util.vector3(pos.x + fx * span, pos.y + fy * span, z)
        local hit = nearby.castRay(from, to, { ignore = ignore })
        if hit.hit then
            local along = (hit.hitPos.x - pos.x) * fx + (hit.hitPos.y - pos.y) * fy
            consider(along - reachToEnd)
        end
    end

    local cell = self.cell
    if cell and cell.isExterior then
        local keel = waterLevel - hull.draft
        for _, d in ipairs({ 0, lookAhead * 0.5, lookAhead }) do
            local s = reachToEnd + d
            local h = core.land.getHeightAt(util.vector3(pos.x + fx * s, pos.y + fy * s, 0), cell)
            if h > keel then
                consider(d)
                break
            end
        end
    end

    if nearest == nil then return nil end
    return phys.stoppingCap(nearest, vessel.brake, T.obstacleMargin)
end

-- ---------------------------------------------------------------------------
-- BOARD / LEAVE EVENTS
-- ---------------------------------------------------------------------------

local function onBoarded(data)
    vessel = db.vessel(data.vesselId)
    if not vessel then return end
    vessel.hull = data.hull or vessel.hull
    vessel.waterOffset = data.waterOffset or vessel.waterOffset

    piloting, handingOff = true, false
    boat = data.boat
    anchor = data.anchor or vessel.anchor
    waterLevel = data.waterLevel or 0
    heading = data.heading or 0
    speed, yawRate = 0, 0
    gains[false], gains[true] = 1, 1
    capAhead, capAstern, probeTimer = nil, nil, 0
    viewEngaged = false
    lastPos, lastAsked, settle, bumpTime = nil, 0, 3, 0
    lastSentHeading, lastSentTurn = heading, 0
    steering = settings:get('STEERING') or 'rudder'
    turnView = settings:get('TURN_VIEW_WITH_BOAT') ~= false
    muteSteps = settings:get('MUTE_WATER_STEPS') ~= false

    seedHeld()
    lockControls()
    addWaterWalking()
    animTurn, animThrottle, animFast = 0, 0, false
    self.object:sendEvent(ANIM.START, { stance = vessel.pose })

    if settings:get('SHOW_HELP') ~= false then
        ui.showMessage(l10n('msg_help'))
    end
    if DEBUG then print('[WhyWalk Boats] piloting ' .. vessel.id) end
end

-- Once per game: the speed gain settles far from 1 only if OpenMW maps
-- movement controls to speed differently from boats_physics.controlsFor's
-- model. The boat still sails right (that is what the gain is for), but the
-- model is then wrong and should be corrected.
local gainReported = false
local function reportGain()
    if gainReported then return end
    for running, gain in pairs(gains) do
        if math.abs(gain - 1) > 0.25 then
            gainReported = true
            print(string.format('[WhyWalk Boats] %s speed gain settled at %.2f: the engine maps movement'
                .. ' controls to speed differently from boats_physics.controlsFor. Sailing is'
                .. ' corrected by the gain; please report this number.', running and 'running' or 'walking', gain))
            return
        end
    end
end

local function onLeft(data)
    if not piloting then return end
    reportGain()
    piloting = false
    boat, vessel = nil, nil
    -- On a hand-off Core WhyWalk has already taken the movement override;
    -- releasing it here would undo Core's lock.
    if (data and data.handOff) or handingOff then
        controlsLocked = false
    else
        releaseControls()
    end
    handingOff = false
    removeWaterWalking()
    self.object:sendEvent(ANIM.STOP, {})
end

local REFUSAL_MESSAGES = {
    beached = 'msg_beached', nowater = 'msg_nowater', far = 'msg_far',
    mounted = 'msg_mounted', foreign = 'msg_foreign',
}

local function onRefused(data)
    local key = data and REFUSAL_MESSAGES[data.reason]
    if key then ui.showMessage(l10n(key)) end
end

-- Core WhyWalk mounted the pilot on a creature (from the boat, or anywhere).
-- Core now owns the movement override, so leaving must not release it.
local function onCoreMounted()
    coreMounted = true
    sendPilotState()
    if piloting then
        handingOff = true
        core.sendGlobalEvent(EV.REQUEST_LEAVE, { player = self.object, handOff = true, reason = 'mounted' })
    end
end

local function onCoreDismounted()
    coreMounted = false
    sendPilotState()
end

-- ---------------------------------------------------------------------------
-- THE PER-FRAME HANDLER
-- ---------------------------------------------------------------------------

local function onUpdate(dt)
    if not piloting then return end
    if dt <= 0 then return end

    local controls = self.controls
    local pilotYaw = self.rotation:getYaw()
    local pos = self.position

    local throttle = phys.clamp(held.forward - held.back, -1, 1)
    local rudder
    if steering == 'view' then
        rudder, viewEngaged = phys.viewRudder(heading, pilotYaw, viewEngaged, T)
    else
        rudder = phys.clamp(held.right - held.left, -1, 1)
    end

    -- The pose follows the pilot's hands -- the rudder and throttle they are
    -- giving -- not the hull's response, and only on a change of sign.
    --
    -- The one thing taken from the hull is the SPEED BAND, which an oared
    -- stance uses to pick a gentle stroke over a driving one. That is the
    -- hull's business rather than the pilot's hands: the oars are what made
    -- the boat fast, so the stroke should match the way it is actually
    -- moving, not the key being held.
    local dz = T.animDeadzone
    local turnSign = (rudder > dz and 1) or (rudder < -dz and -1) or 0
    local throttleSign = (throttle > dz and 1) or (throttle < -dz and -1) or 0
    local fast = animFast
    local way = vessel.maxSpeed > 0 and math.abs(speed) / vessel.maxSpeed or 0
    if fast and way < T.poseSlowBelow then
        fast = false
    elseif not fast and way > T.poseFastAbove then
        fast = true
    end
    if turnSign ~= animTurn or throttleSign ~= animThrottle or fast ~= animFast then
        animTurn, animThrottle, animFast = turnSign, throttleSign, fast
        self.object:sendEvent(ANIM.HELM, {
            turn = turnSign, throttle = throttleSign, fast = fast,
        })
    end

    probeTimer = probeTimer - dt
    if probeTimer <= 0 then
        probeTimer = T.probeInterval
        capAhead = (speed >= 0 or throttle > 0) and obstacleCap(1) or nil
        capAstern = (speed <= 0 or throttle < 0) and obstacleCap(-1) or nil
    end

    -- How far the engine actually carried the pilot along last frame's
    -- command. Far short means something stopped them the bumper did not
    -- foresee; otherwise it trims the speed gain (boats_physics.stepGain).
    local achieved = nil
    if settle > 0 then
        settle = settle - 1
    elseif lastPos and lastAsked > 30 then
        achieved = ((pos.x - lastPos.x) * lastDirX + (pos.y - lastPos.y) * lastDirY) / dt
        if achieved < T.bumpRatio * lastAsked then
            bumpTime = bumpTime + dt
            if bumpTime >= T.bumpTime then speed, yawRate, bumpTime = 0, 0, 0 end
            achieved = nil
        else
            bumpTime = 0
        end
    end

    -- Faster than the pilot walks means running, and running drains fatigue
    -- (rowing is work). Near exhaustion the boat is held to walking pace, so
    -- a long crossing ends slow rather than with the pilot knocked down.
    local walk = types.Actor.getWalkSpeed(self)
    local ahead, astern = capAhead, capAstern
    local fatigue = types.Actor.stats.dynamic.fatigue(self)
    if fatigue.current < math.max(5, 0.1 * fatigue.base) then
        ahead = math.min(ahead or walk, walk)
        astern = math.min(astern or walk, walk)
    end

    speed = phys.stepSpeed(speed, throttle, vessel, dt, ahead, astern)
    yawRate = phys.stepYawRate(yawRate, rudder, speed, vessel, dt)
    local turned = yawRate * dt
    heading = (heading + turned) % TWO_PI

    -- The pilot stands at the anchor, so a turn about the hull's middle moves
    -- them sideways: v = forward * speed + omega x r.
    local fx, fy = phys.forward(heading)
    local rx, ry = phys.toWorld(anchor.x, anchor.y, heading)
    local vx = fx * speed + yawRate * ry
    local vy = fy * speed - yawRate * rx

    local run = types.Actor.getRunSpeed(self)
    local _, _, running = phys.controlsFor(vx, vy, pilotYaw, walk, run, 1)
    if achieved and lastRunning == running then
        gains[running] = phys.stepGain(gains[running], lastAsked, achieved, dt, T)
    end
    local mv, side, _, asked = phys.controlsFor(vx, vy, pilotYaw, walk, run, gains[running])

    controls.movement = mv
    controls.sideMovement = side
    controls.run = running
    if turnView and steering ~= 'view' and turned ~= 0 then
        controls.yawChange = controls.yawChange + turned
    end

    local norm = math.sqrt(vx * vx + vy * vy)
    lastPos, lastAsked, lastRunning = pos, asked, running
    if norm > 1e-3 then lastDirX, lastDirY = vx / norm, vy / norm end

    local heelSign = (yawRate > 0.01 and 1) or (yawRate < -0.01 and -1) or 0
    if heelSign ~= lastSentTurn or math.abs(phys.angleDiff(lastSentHeading, heading)) > T.helmEpsilon then
        lastSentHeading, lastSentTurn = heading, heelSign
        core.sendGlobalEvent(EV.HELM, { player = self.object, heading = heading, turn = heelSign })
    end

    -- Walking on water splashes; Your Own Gondola stops these sounds every
    -- frame for the same reason.
    if muteSteps then
        for _, id in ipairs(WATER_STEPS) do
            if core.sound.isSoundPlaying(id, self) then core.sound.stopSound3d(id, self) end
        end
    end
end

local function onKeyPress(key)
    if not piloting or hudHidden() then return end
    if key.symbol == 'x' then leave() end
end

-- ---------------------------------------------------------------------------
-- SAVE / LOAD
-- ---------------------------------------------------------------------------

local function onSave()
    return { controlsLocked = controlsLocked, waterWalkAdded = waterWalkAdded }
end

local function onLoad(data)
    piloting, handingOff, coreMounted = false, false, false
    boat, vessel = nil, nil
    controlsLocked = data and data.controlsLocked == true or false
    waterWalkAdded = data and data.waterWalkAdded == true or false
    releaseControls()
    removeWaterWalking()
    sendPilotState()
    -- boats_global re-sends WWBoats_Boarded if the save was made afloat.
end

local function onInit()
    sendPilotState()
end

return {
    eventHandlers = {
        [EV.BOARDED]  = onBoarded,
        [EV.LEFT]     = onLeft,
        [EV.REFUSED]  = onRefused,
        [EV.ASK_LEAVE] = leave,
        WhyWalk_Mounted    = onCoreMounted,
        WhyWalk_Dismounted = onCoreDismounted,
    },
    engineHandlers = {
        onUpdate   = onUpdate,
        onKeyPress = onKeyPress,
        onSave     = onSave,
        onLoad     = onLoad,
        onInit     = onInit,
    },
}
