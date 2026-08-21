---@omw-context global
--[[
    whywalk_global.lua -- mount orchestration, movement integration, rider pin

    THE ONE PER-FRAME HANDLER IN THE MOD
    ------------------------------------
    onUpdate exists here and nowhere else. Its first statement is:

        if not session then return end

    so when nobody is mounted the entire mod costs one nil check per frame. No
    raycasts, no actor scans, no storage reads, no allocation. For comparison,
    both reference implementations keep three per-frame handlers alive and do
    real work in them (nearby.actors scans, storage reads, control sends)
    whether or not a ride is in progress.

    WHY IT CANNOT BE EVENT-DRIVEN
    -----------------------------
    There is no API to parent one object's transform to another. Checked the
    whole surface: no attach, no setParent, and Actor.setVelocity is not in the
    documented API (Sturdy Steed calls it behind an existence check). So the
    rider has to be placed every frame by somebody. Everything else in WhyWalk
    -- input, targeting, animation, mounting, dismounting -- is event-driven.

    NO MOUNT-SIDE SCRIPT
    --------------------
    There deliberately isn't one, so an unridden creature carries no WhyWalk
    code whatsoever -- not even a dormant handler.

    The obvious job for a mount script would be suppressing the creature's own
    AI while ridden. It turns out not to be needed: this script teleports the
    mount to a computed position and rotation every frame, so whatever its AI
    decides to do is overwritten before it can take effect. The creature cannot
    walk off because it is being placed, not driven.

    It is also the job that is hardest to do well. Actor.setStance is local-on-
    self only, so global cannot call it; and the AI interface offers only
    removePackages/filterPackages, both of which DELETE packages rather than
    suspend them, with no way to restore what was there. A mount script would
    have to destroy the creature's AI to borrow it, then guess at a
    replacement on dismount.

    What would justify adding one back: visible gait animation fighting (the
    creature playing a walk cycle in a direction it is not moving), or ridden
    hostiles continuing to attack. Both are testable; neither is assumed here.
    If it does come back, register it CUSTOM and attach with addScript on mount
    / removeScript on dismount, so the cost stays scoped to an active ride.
]]

local world = require('openmw.world')
local types = require('openmw.types')
local util  = require('openmw.util')
local core  = require('openmw.core')

local shared = require('scripts.WhyWalk.whywalk_shared')

local TUNING = shared.TUNING
local STATE  = shared.STATE

local EV = {
    REQUEST_MOUNT    = 'WhyWalk_RequestMount',
    REQUEST_DISMOUNT = 'WhyWalk_RequestDismount',
    CONTROL          = 'WhyWalk_Control',
    PERSPECTIVE      = 'WhyWalk_Perspective',
    MOUNTED          = 'WhyWalk_Mounted',
    DISMOUNTED       = 'WhyWalk_Dismounted',
}

local DEBUG = false

-- ---------------------------------------------------------------------------
-- SESSION
-- ---------------------------------------------------------------------------
-- nil when nobody is riding. Existence of this table is the early-out.

local session = nil

local function newSession(player, mount, mountType, freeRide)
    return {
        player    = player,
        mount     = mount,
        mountType = mountType,
        profile   = shared.profileFor(mountType),
        freeRide  = freeRide == true,
        firstPerson = false,   -- reported by the player script; see placeRider

        throttle  = 0,      -- -1..1 commanded
        steer     = 0,      -- -1..1 commanded
        gallop    = false,
        speed     = 0,      -- current world units/sec
        yaw       = 0,
        vz        = 0,      -- vertical velocity, jump arc
        airborne  = false,

    }
end

-- ---------------------------------------------------------------------------
-- RIDER PLACEMENT BACKENDS
-- ---------------------------------------------------------------------------

local mwGlobals = nil
local function globalsHandle()
    if mwGlobals ~= nil then return mwGlobals end
    local ok, g = pcall(function()
        return world.mwscript.getGlobalVariables(world.players[1])
    end)
    mwGlobals = (ok and g) or false
    return mwGlobals
end

-- Writes the target into MWScript globals; a compiled MWScript in the ESP
-- reads them and does the SetPos. Devilish warns that a per-frame Lua player
-- teleport loop triggers an engine bug involving nearby NPCs, which is why
-- this is the default path.
local function placeRiderMWScript(pos, yaw)
    local g = globalsHandle()
    if not g then return false end
    local names = TUNING.mwGlobals
    local ok = pcall(function()
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
        -- Degrees, because SetAngle takes degrees.
        g[names.angle] = math.deg(yaw or 0)
    end)
    return ok
end

local function clearRiderMWScript()
    local g = globalsHandle()
    if not g then return end
    pcall(function() g[TUNING.mwGlobals.active] = 0 end)
end

local function placeRiderTeleport(player, pos, yaw, firstPerson)
    -- Body yaw is forced to the mount's ONLY in third person. In first person
    -- the player's yaw IS the look direction, so overwriting it every frame
    -- fights mouse-look and wrenches the view out of your hands.
    if yaw and not firstPerson then
        player:teleport(player.cell or '', pos, util.transform.rotateZ(yaw))
    else
        player:teleport(player.cell or '', pos)
    end
    return true
end

local function placeRider(player, pos, yaw, firstPerson)
    if TUNING.riderBackend == "mwscript" then
        if placeRiderMWScript(pos, yaw) then return end
        -- Fall through rather than leave the rider behind: a missing ESP
        -- should degrade to the working-but-buggier path, not to nothing.
        if DEBUG then print("[WhyWalk] MWScript bridge unavailable, using teleport") end
    end
    placeRiderTeleport(player, pos, yaw, firstPerson)
end

-- ---------------------------------------------------------------------------
-- GEOMETRY
-- ---------------------------------------------------------------------------

-- Which saddle pose applies right now. Third person shows the body, so it
-- uses the true seated position; first person only cares where the HEAD lands,
-- so it uses the lower//further-forward pose (see saddleFP in
-- whywalk_shared.lua for the full reasoning). Profiles without a measured
-- saddleFP get their own saddle back, so this is a no-op for them.
local function saddleFor(s)
    if s.firstPerson then return s.profile.saddleFP or s.profile.saddle end
    return s.profile.saddle
end

local function saddlePosition(mountPos, yaw, saddle)
    local sinY, cosY = math.sin(yaw), math.cos(yaw)
    -- forward is +Y in mount-local space, right is +X
    return mountPos + util.vector3(
        sinY * saddle.forward + cosY * saddle.right,
        cosY * saddle.forward - sinY * saddle.right,
        saddle.up)
end

-- Terrain height instead of a downward raycast. core.land.getHeightAt is a
-- direct heightmap query -- no ray, no collision traversal -- which matters
-- because this runs every frame while mounted. Learned from the Rideable Silt
-- Striders mod, which uses it to floor its flight path.
local function groundZ(pos, cell)
    local ok, h = pcall(core.land.getHeightAt, util.vector3(pos.x, pos.y, 0), cell)
    if ok and h then return h end
    return nil
end

-- ---------------------------------------------------------------------------
-- MOVEMENT
-- ---------------------------------------------------------------------------

local function targetSpeed(s)
    local p = s.profile
    if s.throttle > 0 then
        return s.gallop and p.speed or p.speed * p.walkMul
    elseif s.throttle < 0 then
        return -p.speed * p.revMul
    end
    return 0
end

local function riderState(s)
    if s.airborne then return STATE.JUMP end
    if s.throttle > 0 then return s.gallop and STATE.GALLOP or STATE.WALK end
    if s.throttle < 0 then return STATE.REVERSE end
    return STATE.IDLE
end

local function stepMovement(s, dt)
    local p = s.profile

    -- Steering. Commanded steer is held state from the player script, so this
    -- integrates an intent that was sent once, not re-sent per frame.
    if s.steer ~= 0 then
        s.yaw = s.yaw + s.steer * p.turnRate * dt
    end

    -- Speed easing toward the commanded target. Deliberately simple: hard cuts
    -- suit the animation layer, but raw speed steps look wrong on a mount.
    local want = targetSpeed(s)
    local rate = (want == 0) and 4.0 or 2.0
    s.speed = s.speed + (want - s.speed) * math.min(1, rate * dt)
    if math.abs(s.speed) < 1 then s.speed = 0 end

    local fwd = util.vector3(math.sin(s.yaw), math.cos(s.yaw), 0)
    local pos = s.mount.position + fwd * (s.speed * dt)

    -- Vertical
    if p.flying then
        -- Flyers hold their commanded altitude; no gravity, no ground clamp.
        pos = util.vector3(pos.x, pos.y, s.mount.position.z)
    else
        if s.airborne then
            s.vz = math.max(-p.jump.maxFall, s.vz - p.jump.gravity * dt)
            pos = util.vector3(pos.x, pos.y, pos.z + s.vz * dt)
        end
        local gz = groundZ(pos, s.mount.cell)
        if gz and pos.z <= gz then
            pos = util.vector3(pos.x, pos.y, gz)
            if s.airborne then s.airborne, s.vz = false, 0 end
        end
    end

    return pos
end

-- ---------------------------------------------------------------------------
-- MOUNT / DISMOUNT
-- ---------------------------------------------------------------------------

local function doDismount(reason)
    if not session then return end
    local s = session

    clearRiderMWScript()

    -- Step the rider off to the side, clamped to terrain so they do not land
    -- inside the mount or under the world.
    if s.player and s.player:isValid() and s.mount and s.mount:isValid() then
        local right = util.vector3(math.cos(s.yaw), -math.sin(s.yaw), 0)
        local off = s.mount.position + right * TUNING.dismountClearance
        local gz = groundZ(off, s.mount.cell)
        if gz then off = util.vector3(off.x, off.y, gz + 10) end
        pcall(function() s.player:teleport(s.player.cell or '', off) end)
    end

    if s.player and s.player:isValid() then
        s.player:sendEvent(EV.DISMOUNTED, { reason = reason })
    end

    if DEBUG then print("[WhyWalk] dismount: " .. tostring(reason)) end
    session = nil
end

local function onRequestMount(data)
    if session then return end
    local player, mount = data and data.player, data and data.mount
    if not player or not player:isValid() then return end
    if not mount or not mount:isValid() then return end
    if not types.Creature.objectIsInstance(mount) then return end
    if shared.isBlacklisted(mount.recordId) then return end

    local mountType = data.mountType or shared.getMountType(mount.recordId)
    local freeRide  = data.freeRide == true or mountType == nil
    if freeRide and not TUNING.freeRideEnabled then return end

    session = newSession(player, mount, mountType, freeRide)
    session.yaw = mount.rotation:getYaw()

    player:sendEvent(EV.MOUNTED, {
        mount = mount, mountType = mountType, freeRide = freeRide,
    })

    if DEBUG then
        print(string.format("[WhyWalk] mounted %s type=%s freeRide=%s",
            tostring(mount.recordId), tostring(mountType), tostring(freeRide)))
    end
end

local function onRequestDismount()
    doDismount('player request')
end

local function onPerspective(data)
    if not session then return end
    if data.player and data.player ~= session.player then return end
    session.firstPerson = data.firstPerson == true
end

local function onControl(data)
    if not session then return end
    if data.player and data.player ~= session.player then return end

    if data.jump then
        local p = session.profile
        if not p.flying and not session.airborne then
            session.airborne = true
            session.vz = p.jump.up
        end
        return
    end

    session.throttle = data.throttle or 0
    session.steer    = data.steer or 0
    session.gallop   = data.gallop == true
end

-- ---------------------------------------------------------------------------
-- THE PER-FRAME HANDLER
-- ---------------------------------------------------------------------------

local lastRiderState = nil

local function onUpdate(dt)
    -- Single early-out. Everything below is ride-only.
    if not session then return end

    local s = session

    if not s.mount:isValid() or not s.player:isValid() then
        doDismount('mount or player went invalid')
        return
    end

    local healthOk, health = pcall(types.Actor.stats.dynamic.health, s.mount)
    if healthOk and health and health.current <= 0 then
        doDismount('mount died')
        return
    end

    if core.isWorldPaused() or dt <= 0 then return end

    -- Free ride: no steering, no movement integration. The creature drives
    -- itself under its own AI and we only follow it with the rider.
    if s.freeRide then
        local mountYaw = s.mount.rotation:getYaw()
        local pos = saddlePosition(s.mount.position, mountYaw, saddleFor(s))
        placeRider(s.player, pos, mountYaw, s.firstPerson)
        return
    end

    local pos = stepMovement(s, dt)
    -- FLAGGED, NOT CHANGED -- verify in game before touching.
    -- The mount is placed with rotateZ(-s.yaw) while the rider is placed with
    -- rotateZ(s.yaw) (see the drift-resync branch below). Same yaw, opposite
    -- signs, in the same function: one of the two must be wrong.
    --
    -- Which one is wrong depends on something only a look in game settles.
    -- By the API, +s.yaw is correct for BOTH: stepMovement derives heading as
    -- fwd = (sin yaw, cos yaw), which is the standard Morrowind convention
    -- (0 = +Y, increasing toward +X), and Cod3x documents rotateZ(a) as
    -- rotate(a, vector3(0,0,-1)) -- rotation about -Z, which maps +Y to
    -- exactly that fwd. So rotateZ(s.yaw) is the transform whose forward IS
    -- the travel direction, and the negation here mirrors the mount.
    --
    -- BUT a negation here is also exactly what you would write to compensate
    -- for a creature NIF whose mesh faces -Y, which is not unheard of. If the
    -- mount visibly faces its travel direction as-is, this negation is load
    -- bearing and correcting it to +s.yaw would spin every mount around.
    -- Check a horse and a guar walking away from you before deciding.
    s.mount:teleport(s.mount.cell or '', pos, util.transform.rotateZ(-s.yaw))

    local riderPos = saddlePosition(pos, s.yaw, saddleFor(s))

    -- Hard resync guard: if the rider has drifted far from where it should be
    -- (cell load, physics shove, another mod teleporting the player) snap
    -- rather than easing, which would otherwise take seconds to converge.
    local drift = (s.player.position - riderPos):length()
    if drift > TUNING.maxRiderDrift then
        pcall(function()
            if s.firstPerson then
                s.player:teleport(s.player.cell or '', riderPos)
            else
                s.player:teleport(s.player.cell or '', riderPos,
                                  util.transform.rotateZ(s.yaw))
            end
        end)
    else
        placeRider(s.player, riderPos, s.yaw, s.firstPerson)
    end

    -- Tell the animation layer only when the state actually changes.
    local st = riderState(s)
    if st ~= lastRiderState then
        lastRiderState = st
        s.player:sendEvent('WhyWalk_AnimState', { state = st })
    end
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
        yaw       = session.yaw,
    }
end

local function onLoad(data)
    session = nil
    lastRiderState = nil
    mwGlobals = nil
    if not (data and data.riding) then return end
    if not data.player or not data.player:isValid() then return end
    if not data.mount or not data.mount:isValid() then return end

    session = newSession(data.player, data.mount, data.mountType, data.freeRide)
    session.yaw = data.yaw or data.mount.rotation:getYaw()

    -- Re-announce so the player script and animation controller re-enter their
    -- mounted state; neither persists it across a load by design.
    data.player:sendEvent(EV.MOUNTED, {
        mount = data.mount, mountType = data.mountType, freeRide = data.freeRide,
    })
end

return {
    eventHandlers = {
        [EV.REQUEST_MOUNT]    = onRequestMount,
        [EV.REQUEST_DISMOUNT] = onRequestDismount,
        [EV.CONTROL]          = onControl,
        [EV.PERSPECTIVE]      = onPerspective,
    },
    engineHandlers = {
        onUpdate = onUpdate,
        onSave   = onSave,
        onLoad   = onLoad,
    },
}
