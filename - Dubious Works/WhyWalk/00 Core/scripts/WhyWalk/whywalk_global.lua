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
        -- Heading last applied to the RIDER, so the next frame can hand over
        -- only the change. nil until the first placement.
        riderYawApplied = nil,

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

-- Probed once per session, then cached. Whether the ESP's globals exist is a
-- LOAD-TIME property: if they are absent now they are absent forever, so
-- re-testing per frame would both waste work and hide the answer.
--
-- Note what is and is not tested here. Cod3x documents
-- world.mwscript.getGlobalVariables(player) as returning MWScriptVariables
-- with no failure path -- it fetches Morrowind's own global variable table,
-- which exists whether or not this mod's ESP is loaded. So wrapping THAT call
-- detects nothing. The real failure is indexing a name the ESP never defined,
-- which is why the probe reads one of our own names instead.
local mwBridge = nil
local function bridgeReady()
    if mwBridge ~= nil then return mwBridge end

    local g = world.mwscript.getGlobalVariables(world.players[1])

    -- [BUGFIX] The value is now checked, not just whether the index raised.
    --
    -- MWScriptVariables is annotated `table<string, number>`, but engine
    -- wrappers are userdata and need not obey table semantics -- an unknown
    -- name may raise via __index, or may simply come back nil. This probe has
    -- to survive BOTH, and the previous form only caught the first: with a
    -- nil-returning implementation `ok` is true, so the bridge was declared
    -- ready with no ESP loaded and every pin went to a global that does not
    -- exist.
    --
    -- pcall retained deliberately: this is a capability probe, which is one of
    -- the four cases that justify one. The closure is unavoidable -- an index
    -- is not a call, so there is nothing to pass to pcall directly.
    -- Probes yawDelta, NOT active. Deliberate: `whywalk_angle` from the old
    -- ESP carried an ABSOLUTE angle and `whywalk_yawdelta` carries a change,
    -- so a stale plugin that still has the old globals must be rejected
    -- rather than fed deltas it would apply as absolute headings -- which
    -- would snap the rider to near-north every frame. Probing the name that
    -- only the NEW script declares makes an out-of-date ESP fail safe into
    -- the teleport pin.
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

-- BRIDGE LIVENESS -- the globals existing is NOT proof the pin runs.
--
-- Found in game 2026-09-29, and it is the same class of mistake this file's
-- own probe comment warns about one function up: the probe tested something
-- adjacent to the thing that actually has to work.
--
-- A .omwaddon can declare `whywalk_x` and friends and carry the pin script's
-- SOURCE TEXT while containing no compiled bytecode for it. That is exactly
-- what shipped: the SCPT record's SCTX held the script, but SCHD reported
-- scriptDataSize = 0 and numFloats = 0, and OpenMW executes the compiled SCDT,
-- not the text. So the globals resolved, bridgeReady() said yes,
-- placeRiderMWScript wrote four numbers into variables nothing read, returned
-- true -- and placeRider returned before ever reaching the teleport fallback.
-- The rider was silently not pinned at all.
--
-- The fix is to verify the EFFECT rather than the capability. We already know
-- where the rider should be, and next frame we can see where it is. If the pin
-- is live the player tracks the target within a frame; if it is dead the
-- player never moves toward it. A short run of misses is a real failure, not
-- noise, because nothing else is placing the rider in the meantime.
local BRIDGE_TRUST_DISTANCE = 96     -- world units; generous, this is one frame of lag
local BRIDGE_FAIL_FRAMES    = 20     -- ~0.3s at 60fps before declaring it dead

local bridgeLive      = nil          -- nil = unproven, true/false = decided
local bridgeLastTarget = nil
local bridgeMisses     = 0

---Judge last frame's write before issuing this frame's. Returns false once the
---bridge has been proven dead, so placeRider can fall through permanently.
local function bridgeStillLive(player)
    if bridgeLive == false then return false end
    if bridgeLastTarget == nil then return true end   -- nothing to judge yet

    if (player.position - bridgeLastTarget):length() <= BRIDGE_TRUST_DISTANCE then
        bridgeLive, bridgeMisses = true, 0
        return true
    end

    bridgeMisses = bridgeMisses + 1
    if bridgeMisses < BRIDGE_FAIL_FRAMES then return true end

    bridgeLive = false
    -- Unconditional, not behind DEBUG: this is a broken install, the symptom
    -- is "the mod does nothing", and this line is the only thing that names
    -- the cause.
    print("[WhyWalk] The MWScript rider pin is not running; its globals exist"
          .. " but nothing consumes them. The shipped WhyWalk.omwaddon contains"
          .. " the pin script as SOURCE TEXT ONLY, with no compiled bytecode;"
          .. " recompile WhyWalkRiderPin in the OpenMW-CS script editor (open"
          .. " it and save) to fix this properly. Falling back to the Lua"
          .. " teleport pin for now.")
    return false
end

-- Writes the target into MWScript globals; a compiled MWScript in the ESP
-- reads them and does the SetPos. Devilish warns that a per-frame Lua player
-- teleport loop triggers an engine bug involving nearby NPCs, which is why
-- this is the preferred path when it actually works.
--
-- Writes bare: bridgeReady() already established that these names resolve, so
-- an assignment failing here would be a genuine bug worth surfacing rather
-- than absorbing once per frame.
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
    -- Degrees, because SetAngle takes degrees.
    -- Degrees, because SetAngle takes degrees. A DELTA, not an absolute:
    -- the script adds it to the player's current angle and zeroes it, so a
    -- frame with no turn writes nothing and leaves mouse-look alone.
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

-- Yaw is applied as a DELTA, never as an absolute.
--
-- Setting the player's absolute yaw every frame is what produced "camera
-- movement is almost entirely restricted, instantly pulled back to facing".
-- In OpenMW the player's body yaw and the third-person camera yaw are the
-- same number: mouse-look turns the actor. Writing an absolute yaw once per
-- frame therefore overwrites every mouse movement before it can be seen, and
-- the view snaps back to the mount's heading. Riding becomes unsteerable
-- precisely because the player cannot look where they want to go.
--
-- The rider still has to turn WITH the mount, or they end up sitting sideways
-- the moment it corners. Both requirements are satisfied by applying the
-- CHANGE in the mount's heading rather than its value:
--
--     playerYaw = playerYaw + (mountYaw - mountYawLastFrame)
--
-- Mount turns 10 degrees right, rider turns 10 degrees right and stays seated
-- correctly; whatever the player added with the mouse is preserved, because it
-- is already in playerYaw when the delta lands on top of it.
--
-- Zero is a safe "do nothing" sentinel here, unlike p37z's absolute-angle
-- version (RESEARCH 1.13): a delta of zero genuinely means the heading did not
-- change, so skipping the write is exactly right rather than a lost update.
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
        -- Fall through rather than leave the rider behind: a missing or
        -- uncompiled ESP should degrade to the working-but-buggier path,
        -- not to nothing at all.
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

-- Terrain height instead of a downward raycast. core.land.getHeightAt is a
-- direct heightmap query -- no ray, no collision traversal -- which matters
-- because this runs every frame while mounted. Learned from the Rideable Silt
-- Striders mod, which uses it to floor its flight path.
--
-- Cod3x documents the cell argument as one "in their exterior world space",
-- so interiors are the expected failure -- and Cell.isExterior is a documented
-- field, so that case is checkable outright instead of caught. No pcall: if
-- getHeightAt throws on a loaded exterior cell that is a bug worth seeing,
-- not one worth absorbing sixty times a second.
local function groundZ(pos, cell)
    if not (cell and cell.isExterior) then return nil end
    return core.land.getHeightAt(util.vector3(pos.x, pos.y, 0), cell)
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

-- ---------------------------------------------------------------------------
-- MOUNT GAIT SCRIPT
-- ---------------------------------------------------------------------------
-- The creature does not animate itself while ridden. A teleport is not
-- movement, so OpenMW's character controller is never asked to move the
-- creature, never selects a locomotion group, and the actor renders at bind
-- pose: the reported T-pose. See whywalk_mount.lua for the full account.
--
-- Attached on mount and removed on dismount, so an unridden creature carries
-- no script at all. That is the condition this file's own header set for
-- bringing a mount script back, and it is now met.
local MOUNT_SCRIPT = 'scripts/WhyWalk/whywalk_mount.lua'

-- Declared here, assigned where the ride loop lives. Clearing it on mount
-- forces the next onUpdate to treat the current gait as a change, which is
-- how the freshly attached mount script gets its first state.
local lastRiderState

local function attachMountScript(mount, freeRide)
    -- Free ride deliberately skipped. There the creature keeps its own AI and
    -- the engine drives it normally, so it already animates; adding a second
    -- source of locomotion groups would be the gait fighting this file's
    -- header warned about. Only a STEERED mount, which is teleported and
    -- therefore never animated by the controller, needs this.
    if freeRide then return end
    if not mount or not mount:isValid() then return end
    if mount:hasScript(MOUNT_SCRIPT) then return end
    mount:addScript(MOUNT_SCRIPT)
    -- addScript is deferred to next frame, so do NOT sendEvent here: the
    -- handler does not exist yet and the event would be dropped. The caller
    -- clears lastRiderState instead, which makes the next onUpdate treat the
    -- current gait as a change and broadcast it once the script is live.
end

local function detachMountScript(mount)
    if not mount or not mount:isValid() then return end
    if not mount:hasScript(MOUNT_SCRIPT) then return end
    -- Release the held loop before the handler goes away, or the creature
    -- keeps walking on the spot for the rest of its life.
    mount:sendEvent('WhyWalk_MountRelease', {})
    mount:removeScript(MOUNT_SCRIPT)
end

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
        -- Bare: the enclosing guard already established that both objects are
        -- valid, so a failure here would be a real bug rather than an
        -- expected condition.
        s.player:teleport(s.player.cell or '', off)
    end

    detachMountScript(s.mount)

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

    attachMountScript(mount, freeRide)
    lastRiderState = nil

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

lastRiderState = nil

local function onUpdate(dt)
    -- Single early-out. Everything below is ride-only.
    if not session then return end

    local s = session

    if not s.mount:isValid() or not s.player:isValid() then
        doDismount('mount or player went invalid')
        return
    end

    -- Bare: isValid() passed immediately above and the mount was type-checked
    -- as a creature at mount time. A mount that has stopped having health
    -- stats is a genuine bug, and swallowing it every frame would hide it.
    local health = types.Actor.stats.dynamic.health(s.mount)
    if health and health.current <= 0 then
        doDismount('mount died')
        return
    end

    if core.isWorldPaused() or dt <= 0 then return end

    -- Free ride: no steering, no movement integration. The creature drives
    -- itself under its own AI and we only follow it with the rider.
    if s.freeRide then
        local mountYaw = s.mount.rotation:getYaw()
        local pos = saddlePosition(s.mount.position, mountYaw, s.profile.saddle)
        local d = s.riderYawApplied and yawDeltaBetween(s.riderYawApplied, mountYaw) or 0
        s.riderYawApplied = mountYaw
        placeRider(s.player, pos, d)
        return
    end

    local pos = stepMovement(s, dt)
    -- SETTLED IN GAME, 2026-09-29. This was rotateZ(-s.yaw) while the rider
    -- was placed with rotateZ(s.yaw) -- same yaw, opposite signs, one
    -- function apart. The negation was wrong and is the single cause of both
    -- "rider is backwards" and "controls are reversed":
    --
    --   * stepMovement derives heading as fwd = (sin yaw, cos yaw), the
    --     standard Morrowind convention (0 = +Y, increasing toward +X).
    --   * Cod3x documents rotateZ(a) as rotate(a, vector3(0,0,-1)), so
    --     rotateZ(yaw) * (0,1,0) == (sin yaw, cos yaw) == fwd exactly.
    --   * Devilish Guar Riding -- the reference this mod's offsets came from,
    --     and the one that feels correct in game -- derives forward the same
    --     way (forwardVector: rotateZ(yaw):apply(vector3(0,1,0))) and teleports
    --     its mount with rotation = rotateZ(yaw). POSITIVE.
    --
    -- With the negation the mount travelled along fwd(+yaw) while facing
    -- fwd(-yaw): mirrored about the N-S axis. Pressing D increased yaw, so the
    -- mount slid right while visibly turning left, and the correctly-oriented
    -- rider ended up facing the mount's tail.
    s.mount:teleport(s.mount.cell or '', pos, util.transform.rotateZ(s.yaw))

    local riderPos = saddlePosition(pos, s.yaw, s.profile.saddle)

    -- Hard resync guard: if the rider has drifted far from where it should be
    -- (cell load, physics shove, another mod teleporting the player) snap
    -- rather than easing, which would otherwise take seconds to converge.
    local drift = (s.player.position - riderPos):length()
    if drift > TUNING.maxRiderDrift then
        -- Absolute yaw is right HERE and only here. This is a one-off snap
        -- after the rider has been displaced hundreds of units, not a
        -- per-frame pin, so re-seating them square on the mount is the whole
        -- point and there is no mouse-look to preserve across a teleport of
        -- that size. The delta baseline is reset to match.
        s.player:teleport(s.player.cell or '', riderPos,
                          util.transform.rotateZ(s.yaw))
        s.riderYawApplied = s.yaw
    else
        local d = s.riderYawApplied and yawDeltaBetween(s.riderYawApplied, s.yaw) or 0
        s.riderYawApplied = s.yaw
        placeRider(s.player, riderPos, d)
    end

    -- Tell the animation layer only when the state actually changes.
    local st = riderState(s)
    if st ~= lastRiderState then
        lastRiderState = st
        s.player:sendEvent('WhyWalk_AnimState', { state = st })
        -- Same state string drives the creature's own locomotion group. Sent
        -- on CHANGE only, like the rider pose, so a straight-line walk costs
        -- nothing. Free rides have no mount script to receive it.
        if not s.freeRide and s.mount and s.mount:isValid() then
            s.mount:sendEvent('WhyWalk_MountGait', { state = st })
        end
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
    -- Re-probe the bridge after a load: the handle is tied to the previous
    -- game session, and the load order can differ between saves.
    mwBridge = nil
    if not (data and data.riding) then return end
    if not data.player or not data.player:isValid() then return end
    if not data.mount or not data.mount:isValid() then return end

    session = newSession(data.player, data.mount, data.mountType, data.freeRide)
    session.yaw = data.yaw or data.mount.rotation:getYaw()

    -- Re-announce so the player script and animation controller re-enter their
    -- mounted state; neither persists it across a load by design.
    attachMountScript(data.mount, data.freeRide)
    lastRiderState = nil

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
