---@omw-context global
--[[
    whywalk_global.lua -- mount orchestration and the rider pin

    THE MOUNT SCRIPT

    Registered CUSTOM, attached with addScript on mount and removed on
    dismount, so an unridden creature carries no WhyWalk code whatsoever.
]]

local world = require('openmw.world')
local types = require('openmw.types')
local util  = require('openmw.util')
local core  = require('openmw.core')

local shared = require('scripts.WhyWalk.whywalk_shared')

local TUNING = shared.TUNING

local EV = {
    REQUEST_MOUNT    = 'WhyWalk_RequestMount',
    REQUEST_DISMOUNT = 'WhyWalk_RequestDismount',
    CONTROL          = 'WhyWalk_Control',
    MOUNTED          = 'WhyWalk_Mounted',
    DISMOUNTED       = 'WhyWalk_Dismounted',
    MOUNT_REFUSED    = 'WhyWalk_MountRefused',
    PLAYER_SEATED    = 'WhyWalk_PlayerSeated',
    DISMOUNT_START   = 'WhyWalk_DismountStart',
}

local DEBUG = false

-- ---------------------------------------------------------------------------
-- SESSION
-- ---------------------------------------------------------------------------

local session = nil

local MOUNT_PIN = {}
local riderPinOwner = nil

local function newSession(player, mount, mountType, freeRide)
    return {
        player    = player,
        mount     = mount,
        mountType = mountType,
        profile   = shared.profileFor(mountType),
        freeRide  = freeRide == true,
        riderYawApplied = nil,

        allowInteriors = false,
        lastCell = nil,

    }
end

-- ---------------------------------------------------------------------------
-- RIDER PLACEMENT BACKENDS
-- ---------------------------------------------------------------------------

local mwBridge = nil
local function bridgeReady()
    if mwBridge ~= nil then return mwBridge end

    local g = world.mwscript.getGlobalVariables(world.players[1])

    local probe = TUNING.mwGlobals.yawDelta
    local ok, value = pcall(function() return g[probe] end)
    mwBridge = (ok and value ~= nil) and g or false

    if not mwBridge then
        print("[WhyWalk] MWScript bridge unavailable ('" .. tostring(probe)
              .. "' not found); falling back to the teleport backend. If you"
              .. " have an older WhyWalk.omwaddon, it declares whywalk_angle"
              .. " instead; add the whywalk_yawdelta global and recompile"
              .. " WhyWalkRiderPin to use the MWScript pin.")
    end
    return mwBridge
end

-- Shortest signed arc from a to b, so a heading crossing north hands over
-- a small delta rather than nearly a full turn.
local TWO_PI = math.pi * 2
local function yawDeltaBetween(a, b)
    local d = (b - a) % TWO_PI
    if d > math.pi then d = d - TWO_PI end
    return d
end

local BRIDGE_TRUST_DISTANCE = 96     -- world units; generous, this is one frame of lag

local BRIDGE_FAIL_FRAMES    = 20     -- ~0.3s at 60fps before declaring it dead

local bridgeLive      = nil          -- nil = unproven, true/false = decided
local bridgeLastTarget = nil
local bridgeMisses     = 0

local function bridgeStillLive(player)
    if bridgeLive == false then return false end
    if bridgeLastTarget == nil then return true end   -- nothing to judge yet

    local dx = player.position.x - bridgeLastTarget.x
    local dy = player.position.y - bridgeLastTarget.y
    if dx * dx + dy * dy <= BRIDGE_TRUST_DISTANCE * BRIDGE_TRUST_DISTANCE then
        bridgeLive, bridgeMisses = true, 0
        return true
    end

    bridgeMisses = bridgeMisses + 1
    if bridgeMisses < BRIDGE_FAIL_FRAMES then return true end

    bridgeLive = false
    print("[WhyWalk] The MWScript rider pin is not moving the player: for "
          .. BRIDGE_FAIL_FRAMES .. " frames running the player was more than "
          .. BRIDGE_TRUST_DISTANCE .. " units (horizontally) from the target."
          .. " Check that WhyWalk.esp is enabled in the load order and that no"
          .. " other mod is setting the player's position. Falling back to the"
          .. " Lua teleport pin.")
    return false
end

local function placeRiderMWScript(player, pos, yawDelta)
    local g = bridgeReady()
    if not g then return false end
    if not bridgeStillLive(player) then return false end

    local names = TUNING.mwGlobals

    g[names.active] = 1
    g[names.x] = pos.x
    g[names.y] = pos.y
    g[names.z] = pos.z
    -- Written unconditionally. The perspective gate belongs in the
    -- MWScript, where PCGet3rdPerson is free and always correct:
    --
    --     player->SetPos X px
    --     player->SetPos Y py
    --     player->SetPos Z pz
    --     if ( PCGet3rdPerson == 1 )
    --         player->SetAngle Z pa
    --     endif
    --
    g[names.yawDelta] = math.deg(yawDelta or 0)

    bridgeLastTarget = pos
    return true
end

local function clearRiderMWScript()
    bridgeLastTarget, bridgeMisses = nil, 0
    local g = bridgeReady()
    if not g then return end
    g[TUNING.mwGlobals.active] = 0
end

local YAW_EPSILON = 1e-4

local function placeRiderTeleport(player, pos, yawDelta)
    if yawDelta and math.abs(yawDelta) > YAW_EPSILON then
        local newYaw = player.rotation:getYaw() + yawDelta
        player:teleport(player.cell or '', pos, util.transform.rotateZ(newYaw))
    else
        player:teleport(player.cell or '', pos)
    end
    return true
end

local function placeRider(player, pos, yawDelta)
    if TUNING.riderBackend == "mwscript" then
        if placeRiderMWScript(player, pos, yawDelta) then return end
    end
    placeRiderTeleport(player, pos, yawDelta)
end

-- ---------------------------------------------------------------------------
-- GEOMETRY
-- ---------------------------------------------------------------------------

local function saddlePosition(mountPos, yaw, saddle)
    local sinY, cosY = math.sin(yaw), math.cos(yaw)
    -- forward is +Y in mount-local space, right is +X
    return mountPos + util.vector3(
        sinY * saddle.forward + cosY * saddle.right,
        cosY * saddle.forward - sinY * saddle.right,
        saddle.up)
end


-- ---------------------------------------------------------------------------
-- MOUNT / DISMOUNT
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- INTERIOR GATE
-- ---------------------------------------------------------------------------
local function interiorAllowed(mount, allow)
    if allow then return true end
    local cell = mount and mount.cell
    if not cell then return true end
    return cell.isExterior ~= false
end

-- ---------------------------------------------------------------------------
-- MOUNT SCRIPT
-- ---------------------------------------------------------------------------
local MOUNT_SCRIPT = 'scripts/WhyWalk/whywalk_mount.lua'

local EV_MOUNT = {
    START   = 'WhyWalk_MountStart',
    STOP    = 'WhyWalk_MountStop',
    CONTROL = 'WhyWalk_MountControl',
}

local pendingStart = nil

local function attachMountScript(mount, freeRide, player, profile)
    if freeRide then return end
    if not mount or not mount:isValid() then return end
    if not mount:hasScript(MOUNT_SCRIPT) then
        mount:addScript(MOUNT_SCRIPT)
    end
    pendingStart = {
        mount    = mount,
        player   = player,
        turnRate = profile.turnRate,
    }
end

local function detachMountScript(mount)
    pendingStart = nil
    if not mount or not mount:isValid() then return end
    if not mount:hasScript(MOUNT_SCRIPT) then return end
    mount:sendEvent(EV_MOUNT.STOP, {})
    mount:removeScript(MOUNT_SCRIPT)
end

local function landingPoint(s)
    local yaw   = s.mount.rotation:getYaw()
    local right = util.vector3(math.cos(yaw), -math.sin(yaw), 0)
    return s.mount.position + right * TUNING.dismountClearance
end

local function doDismount(reason, landing)
    if not session then return end
    local s = session

    if riderPinOwner == MOUNT_PIN then riderPinOwner = nil end
    clearRiderMWScript()

    if s.player and s.player:isValid() and s.mount and s.mount:isValid() then
        local off = landing or landingPoint(s)
        s.player:teleport(s.player.cell or '', off, { onGround = true })
    end

    detachMountScript(s.mount)

    if s.player and s.player:isValid() then
        s.player:sendEvent(EV.DISMOUNTED, { reason = reason })
    end

    if DEBUG then print("[WhyWalk] dismount: " .. tostring(reason)) end
    session = nil
end

-- Players Take a Seat currently holds (seated, lying or still getting up),
-- reported by the player script from Take a Seat's own events. Not saved: the
-- player script re-reports after every load.
local seatedPlayers = {}

local function onPlayerSeated(data)
    if not (data and data.player) then return end
    seatedPlayers[data.player.id] = data.seated == true or nil
end

local function onRequestMount(data)
    if session then return end
    local player, mount = data and data.player, data and data.mount
    if not player or not player:isValid() then return end
    if not mount or not mount:isValid() then return end
    if not types.Creature.objectIsInstance(mount) then return end
    if seatedPlayers[player.id] then
        player:sendEvent(EV.MOUNT_REFUSED, { reason = 'seated' })
        return
    end

    -- Barred BEFORE blacklisted: isBlacklisted() is also true for every
    -- compiled `ride = false` creature, and checked first it returned in
    -- silence, so no caller ever got WhyWalk_MountRefused (measured
    -- 2026-11-12: dremora, skeleton, golden saint, 0 of 3 events).
    local record = types.Creature.objectIsInstance(mount)
        and types.Creature.record(mount) or nil
    local barred, why = shared.barredFromRiding(mount.recordId, record)
    if barred then
        player:sendEvent(EV.MOUNT_REFUSED, { reason = 'notamount', detail = why })
        if DEBUG then
            print(string.format("[WhyWalk] %s refused as a mount: %s",
                                tostring(mount.recordId), tostring(why)))
        end
        return
    end
    if shared.isBlacklisted(mount.recordId) then
        player:sendEvent(EV.MOUNT_REFUSED, { reason = 'blacklisted' })
        return
    end

    local mountType = data.mountType or shared.getMountType(mount.recordId)
    local freeRide  = data.freeRide == true or mountType == nil
    if freeRide and not TUNING.freeRideEnabled then return end

    if not interiorAllowed(mount, data.allowInteriors) then
        player:sendEvent(EV.MOUNT_REFUSED, { reason = 'interior' })
        return
    end

    session = newSession(player, mount, mountType, freeRide)

    local saddle, source = shared.chooseSaddle(mount.recordId, mountType, data.measuredUp,
        shared.saddleFromProfile(mount.recordId),
        (not mountType) and shared.saddleFromBoundingBox(mount) or nil)
    session.profile.saddle = saddle
    session.saddleSource = source

    attachMountScript(mount, freeRide, player, session.profile)

    -- Climb on: the player is carried from where they stand to the saddle
    -- over the transition clip (MOUNT TRANSITIONS in whywalk_shared).
    local transition = nil
    if shared.MOUNT_TRANSITION.enabled and data.transition ~= false then
        local target = saddlePosition(mount.position, mount.rotation:getYaw(), saddle)
        local dx, dy = target.x - player.position.x, target.y - player.position.y
        local group, duration = shared.mountTransition(target.z - player.position.z,
            math.sqrt(dx * dx + dy * dy))
        session.transition = {
            kind = 'mount', t = 0, duration = duration,
            from = player.position, yaw = player.rotation:getYaw(),
        }
        session.riderYawApplied = player.rotation:getYaw()
        transition = { group = group, duration = duration }
    end

    player:sendEvent(EV.MOUNTED, {
        mount = mount, mountType = mountType, freeRide = freeRide,
        saddleUp = saddle.up, saddleSource = source, transition = transition,
    })

    if DEBUG then
        print(string.format("[WhyWalk] mounted %s type=%s freeRide=%s",
            tostring(mount.recordId), tostring(mountType), tostring(freeRide)))
    end
end

-- Climb off: carried from the saddle to the ground beside the mount over the
-- dismount clip, then put down exactly where an instant dismount puts you.
local function onRequestDismount(data)
    local s = session
    if not s then return end
    if s.transition and s.transition.kind == 'dismount' then return end
    local T = shared.MOUNT_TRANSITION
    if not (T.enabled and data and data.animated ~= false)
       or not (s.player:isValid() and s.mount:isValid()) then
        return doDismount('player request')
    end
    detachMountScript(s.mount)          -- the mount stops where it is
    local landing = landingPoint(s)
    s.transition = {
        kind = 'dismount', t = 0, duration = T.dismount.duration,
        from = s.player.position, to = landing,
    }
    s.player:sendEvent(EV.DISMOUNT_START, { group = T.dismount.group, duration = T.dismount.duration })
end


local function onControl(data)
    if not session then return end
    if data.player and data.player ~= session.player then return end
    local s = session

    if s.freeRide then return end
    if not s.mount:isValid() then return end

    s.mount:sendEvent(EV_MOUNT.CONTROL, {
        throttle = data.throttle,
        steer    = data.steer,
        gallop   = data.gallop,
        jump     = data.jump,
    })
end

-- ---------------------------------------------------------------------------
-- THE PER-FRAME HANDLER
-- ---------------------------------------------------------------------------

-- THE PIN'S MWSCRIPT GLOBALS ARE IN THE SAVE (2026-11-12).
--
-- `whywalk_active` and the target coordinates are ordinary MWScript globals,
-- so a save taken while anything held the pin stores active = 1, and the
-- compiled WhyWalkRiderPin script goes on SetPos-ing the player to that
-- target after the load, every frame, forever. Nothing on the Lua side can
-- release it: the owner that took the pin is not persisted, so release()
-- from it is a no-op. Measured with WhyWalk Shipping: a save at sea, loaded,
-- reported arrival and teleported the player to Gnaar Mok, and the pin put
-- them straight back over the water 45,551 units away. Caravans' "loading
-- aborts the journey and puts you down" has the same hole.
--
-- So the first frame after a load clears it, unless a ride resumed and took
-- the pin again in the meantime. Not in onLoad itself: the player whose
-- globals these are is not guaranteed to exist yet there.
local clearPinAfterLoad = false

local function onUpdate(dt)
    if clearPinAfterLoad then
        clearPinAfterLoad = false
        if riderPinOwner == nil then clearRiderMWScript() end
    end
    -- Single early-out. Everything below is ride-only.
    if not session then return end

    local s = session

    if not s.mount:isValid() or not s.player:isValid() then
        doDismount('mount or player went invalid')
        return
    end

    local health = types.Actor.stats.dynamic.health(s.mount)
    if health.current <= 0 then
        doDismount('mount died')
        return
    end

    if core.isWorldPaused() or dt <= 0 then return end

    -- TRANSITIONS: the rider is on an arc, not on the saddle.
    local tr = s.transition
    if tr then
        tr.t = tr.t + dt
        local k = math.min(1, tr.t / tr.duration)
        local mountYaw = s.mount.rotation:getYaw()
        local pos
        if tr.kind == 'mount' then
            local target = saddlePosition(s.mount.position, mountYaw, s.profile.saddle)
            pos = shared.mountArc(tr.from, target, k, shared.MOUNT_TRANSITION.arcClearance)
            -- turn toward the mount's heading over the climb
            local want = s.riderYawApplied + yawDeltaBetween(s.riderYawApplied, mountYaw)
                * math.min(1, dt / math.max(dt, tr.duration - tr.t + dt))
            local d = yawDeltaBetween(s.riderYawApplied, want)
            s.riderYawApplied = want
            riderPinOwner = MOUNT_PIN
            placeRider(s.player, util.vector3(pos.x, pos.y, pos.z), d)
            if k >= 1 then s.transition = nil end
            return
        else
            -- mirrored arc: across first, down last
            pos = shared.mountArc(tr.to, tr.from, 1 - k, shared.MOUNT_TRANSITION.arcClearance)
            riderPinOwner = MOUNT_PIN
            placeRider(s.player, util.vector3(pos.x, pos.y, pos.z), 0)
            if k >= 1 then doDismount('player request', tr.to) end
            return
        end
    end

    if pendingStart then
        local st = pendingStart
        pendingStart = nil
        if st.mount:isValid() and st.mount:hasScript(MOUNT_SCRIPT) then
            st.mount:sendEvent(EV_MOUNT.START, {
                player   = st.player,
                turnRate = st.turnRate,
            })
        end
    end

    if s.mount.cell ~= s.lastCell then
        s.lastCell = s.mount.cell
        if not interiorAllowed(s.mount, s.allowInteriors) then
            doDismount('entered an interior with interior riding off')
            return
        end
    end

    local mountPos = s.mount.position
    local mountYaw = s.mount.rotation:getYaw()

    local riderPos = saddlePosition(mountPos, mountYaw, s.profile.saddle)

    local drift = (s.player.position - riderPos):length()
    if drift > TUNING.maxRiderDrift then
        s.player:teleport(s.player.cell or '', riderPos,
                          util.transform.rotateZ(mountYaw))
        s.riderYawApplied = mountYaw
        return
    end

    local d = s.riderYawApplied and yawDeltaBetween(s.riderYawApplied, mountYaw) or 0
    s.riderYawApplied = mountYaw
    riderPinOwner = MOUNT_PIN
    placeRider(s.player, riderPos, d)
end

-- ---------------------------------------------------------------------------
-- SAVE / LOAD
-- ---------------------------------------------------------------------------

local function onSave()
    if not session then return { riding = false } end
    return {
        riding    = true,
        player    = session.player,
        mount     = session.mount,
        mountType = session.mountType,
        freeRide  = session.freeRide,
        allowInteriors = session.allowInteriors,
    }
end

local function onLoad(data)
    clearPinAfterLoad = true
    riderPinOwner = nil
    session = nil
    pendingStart = nil
    mwBridge = nil
    local saved   = data and data.mount
    local resuming = (data and data.riding)
                     and data.player and data.player:isValid()
                     and saved and saved:isValid()

    if not resuming then
        if saved and saved:isValid() then detachMountScript(saved) end
        return
    end

    session = newSession(data.player, data.mount, data.mountType, data.freeRide)
    session.allowInteriors = data.allowInteriors == true
    session.lastCell = data.mount.cell

    attachMountScript(data.mount, data.freeRide, data.player, session.profile)

    data.player:sendEvent(EV.MOUNTED, {
        mount = data.mount, mountType = data.mountType, freeRide = data.freeRide,
    })
end

-- ---------------------------------------------------------------------------
-- THE RIDER PIN, OFFERED TO THE REST OF THE SUITE
-- ---------------------------------------------------------------------------
local RiderPin = {
    ---@return boolean
    isBridged = function()
        return bridgeReady() ~= false and bridgeLive ~= false
    end,

    ---@param owner any
    ---@param player any
    ---@param pos any openmw.util.Vector3
    ---@param yawDelta number|nil radians; nil or ~0 leaves the facing alone
    ---@return boolean claimed
    place = function(owner, player, pos, yawDelta)
        if riderPinOwner ~= nil and riderPinOwner ~= owner then return false end
        riderPinOwner = owner
        placeRider(player, pos, yawDelta)
        return true
    end,

    ---Give the pin up. Safe to call when not holding it.
    release = function(owner)
        if riderPinOwner ~= owner then return end
        riderPinOwner = nil
        clearRiderMWScript()
    end,
}

return {
    interfaceName = 'WhyWalkRiderPin',
    interface = RiderPin,
    eventHandlers = {
        [EV.REQUEST_MOUNT]    = onRequestMount,
        [EV.REQUEST_DISMOUNT] = onRequestDismount,
        [EV.CONTROL]          = onControl,
        [EV.PLAYER_SEATED]    = onPlayerSeated,
    },
    engineHandlers = {
        onUpdate = onUpdate,
        onSave   = onSave,
        onLoad   = onLoad,
    },
}
