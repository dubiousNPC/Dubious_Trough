---@omw-context global
--[[
    whywalk_global.lua -- mount orchestration and the rider pin

    WHAT THIS FILE NO LONGER DOES

    It used to integrate the mount's movement: speed easing, a steering
    integrator, a hand-written jump arc with its own gravity constant, a
    heightmap ground clamp, and a per-frame teleport of the creature to the
    result. All of that is gone. whywalk_mount.lua now writes the creature's
    `controls` and OpenMW's character controller moves it, which is how every
    other creature in the game moves.

    Deleted with it: stepMovement, targetSpeed, riderState's airborne branch,
    groundZ, and the interior-floor workaround that existed only because
    groundZ cannot see interiors. Roughly 120 lines, and four bugs that lived
    in them -- the T-pose, the missing collision, the interior fall-through
    and the jitter. See whywalk_mount.lua for the full account.

    WHAT IT STILL DOES, AND WHY IT STILL HAS A PER-FRAME HANDLER

    The rider. There is no API to parent one object's transform to another --
    checked the whole surface: no attach, no setParent, and Actor.setVelocity
    is not in the documented API. So the player has to be placed on the mount
    every frame by somebody, and only a global script can teleport the player.

    That is now the ONLY work onUpdate does, and its first statement is still:

        if not session then return end

    so when nobody is mounted the whole file costs one nil check per frame.

    The mount's position and heading are now READ from the creature rather than
    computed. That is not merely simpler -- it is the only correct source, now
    that the engine is free to stop the creature against a wall, slow it on a
    slope or shove it aside. A computed position would describe where the
    creature was told to go, which is no longer where it is.

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
        -- Heading last applied to the RIDER, so the next frame can hand over
        -- only the change. nil until the first placement.
        riderYawApplied = nil,

        -- Carried from the mount request. The setting lives in player-side
        -- storage, which a global script cannot read, so its value rides along
        -- with the request and is remembered for the cell-change check.
        allowInteriors = false,
        -- Last cell seen, so a cell change can be detected. The mount walks
        -- through load doors now that the engine moves it.
        lastCell = nil,

        -- No throttle/steer/speed/yaw/vz/airborne any more. The commanded
        -- intent lives in whywalk_mount.lua, which is the thing that acts on
        -- it, and the resulting position and heading are read back off the
        -- creature. Keeping a second copy here was how the two drifted apart.
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

-- riderState USED TO LIVE HERE. It is now whywalk_mount.lua's job, and the
-- reason is a context restriction worth recording.
--
-- The rider's pose should follow what the creature actually does, not what the
-- player commanded -- a mount pressed into a wall is not walking. Deriving
-- that needs two readings:
--
--     types.Actor.getCurrentSpeed(mount)   -- @param openmw.Object, fine here
--     types.Actor.isOnGround(mount)        -- "Can be called only from a
--                                             local script", @param LObject
--
-- The second one is not available to a global script, which rules out doing
-- this here. whywalk_mount.lua is LOCAL on the creature and has both, plus the
-- commanded throttle for the forward/reverse distinction, so it derives the
-- state and sends WhyWalk_AnimState to the player on CHANGE only. Same event,
-- same consumer (ridingAnim.lua) -- just raised where the facts are.

-- ---------------------------------------------------------------------------
-- MOUNT / DISMOUNT
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- INTERIOR GATE
-- ---------------------------------------------------------------------------
-- Cell.isExterior is a documented field, so this is a plain read with no
-- probing. A nil cell (an object mid-teleport) is treated as an exterior:
-- refusing to ride because a cell handle was briefly unavailable would be a
-- worse failure than allowing it.
local function interiorAllowed(mount, allow)
    if allow then return true end
    local cell = mount and mount.cell
    if not cell then return true end
    return cell.isExterior ~= false
end

-- ---------------------------------------------------------------------------
-- MOUNT SCRIPT
-- ---------------------------------------------------------------------------
-- The creature is DRIVEN by whywalk_mount.lua, which writes its `controls` and
-- lets the engine move it. Attached on mount and removed on dismount, so an
-- unridden creature carries no script at all.
local MOUNT_SCRIPT = 'scripts/WhyWalk/whywalk_mount.lua'

local EV_MOUNT = {
    START   = 'WhyWalk_MountStart',
    STOP    = 'WhyWalk_MountStop',
    CONTROL = 'WhyWalk_MountControl',
}

-- Pending MountStart, because addScript is deferred to the next frame.
--
-- This replaces the old lastRiderState-clearing trick. Sending MountStart from
-- attachMountScript would land before the handler exists and be dropped
-- silently -- and MountStart is now load-bearing (it disables the creature's
-- AI), not just a first animation nudge. So the send is deferred to the first
-- onUpdate that sees the script attached.
local pendingStart = nil

local function attachMountScript(mount, freeRide, player, profile)
    -- Free ride deliberately skipped: the creature keeps its own AI and the
    -- engine drives it normally. Disabling its AI there would strand it.
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
    -- MountStop re-enables the creature's standard AI. It MUST arrive before
    -- the script goes away, or the creature is left with AI off and the last
    -- controls still written -- a statue, or something walking into a wall
    -- until the cell unloads.
    mount:sendEvent(EV_MOUNT.STOP, {})
    mount:removeScript(MOUNT_SCRIPT)
end

local function doDismount(reason)
    if not session then return end
    local s = session

    clearRiderMWScript()

    -- Step the rider off to the side. The ground clamp that used to be here is
    -- gone with groundZ, and nothing replaces it: teleport takes an `onGround`
    -- option, so the engine drops the player onto whatever is actually below
    -- them -- floor, bridge, stairs -- instead of a heightmap value that was
    -- wrong indoors and wrong on anything placed.
    if s.player and s.player:isValid() and s.mount and s.mount:isValid() then
        local yaw   = s.mount.rotation:getYaw()
        local right = util.vector3(math.cos(yaw), -math.sin(yaw), 0)
        local off   = s.mount.position + right * TUNING.dismountClearance
        -- Bare: the enclosing guard already established that both objects are
        -- valid, so a failure here would be a real bug rather than an
        -- expected condition.
        s.player:teleport(s.player.cell or '', off, { onGround = true })
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

    -- INTERIOR GATE. The player script owns the setting and sends its value
    -- with the request, because I.Settings and openmw.storage are player-side
    -- and a global script cannot read either.
    --
    -- Default is to refuse. Riding indoors is not broken any more -- the engine
    -- handles interiors like anywhere else -- but Morrowind's interiors are
    -- built to human scale, and a mounted player clips doorframes and ceilings
    -- with the rider's head. Opt-in rather than opt-out.
    if not interiorAllowed(mount, data.allowInteriors) then
        player:sendEvent(EV.MOUNT_REFUSED, { reason = 'interior' })
        return
    end

    session = newSession(player, mount, mountType, freeRide)

    -- UNKNOWN CREATURE: derive the saddle from its bounding box.
    --
    -- mountType is nil for any creature PROFILE has never heard of, which is
    -- every mount added by another mod. profileFor falls back to the default
    -- saddle in that case -- up = 130, a guar's height -- which puts a rider
    -- inside a boar and under a silt strider.
    --
    -- The box is the only measurement available without the mod author telling
    -- us anything, and it scales: see M.saddleFromBoundingBox for exactly which
    -- parts of it are safe to read. A nil result means the box was unusable, so
    -- the default stands.
    if not mountType then
        local derived = shared.saddleFromBoundingBox(mount)
        if derived then session.profile.saddle = derived end
    end

    attachMountScript(mount, freeRide, player, session.profile)

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


-- Intent is RELAYED, not stored. The mount script is what acts on it, and a
-- second copy here was how the commanded state and the actual state drifted
-- apart. The player script sends on change only, so this fires on input edges
-- rather than per frame.
local function onControl(data)
    if not session then return end
    if data.player and data.player ~= session.player then return end
    local s = session

    -- Free ride has no mount script: the creature drives itself and steering
    -- input has nowhere to go.
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
-- All it does now is place the rider. The mount moves itself.

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

    -- The deferred MountStart. addScript lands a frame late, so this is the
    -- earliest point the handler is guaranteed to exist. Sending it from
    -- attachMountScript would drop it, and with it the enableAI(false) that
    -- stops the creature wandering off under its own AI.
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

    -- Cell change while riding. The mount walks through load doors now that
    -- the engine moves it, so the rider has to follow into the new cell --
    -- and an interior arrival is where the setting gets enforced a second
    -- time, since the first check only covered mounting.
    if s.mount.cell ~= s.lastCell then
        s.lastCell = s.mount.cell
        if not interiorAllowed(s.mount, s.allowInteriors) then
            doDismount('entered an interior with interior riding off')
            return
        end
    end

    -- READ, not computed. The engine owns where the creature is and which way
    -- it faces; a computed value would describe where it was told to go, which
    -- after a wall, a slope or a shove is not where it is. This is the whole
    -- point of the port.
    local mountPos = s.mount.position
    local mountYaw = s.mount.rotation:getYaw()

    local riderPos = saddlePosition(mountPos, mountYaw, s.profile.saddle)

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
                          util.transform.rotateZ(mountYaw))
        s.riderYawApplied = mountYaw
        return
    end

    -- Yaw handed over as a DELTA so mouse-look survives. See the long note at
    -- placeRiderTeleport; unchanged by the port, because the rider pin is the
    -- one part of this file the port did not touch.
    local d = s.riderYawApplied and yawDeltaBetween(s.riderYawApplied, mountYaw) or 0
    s.riderYawApplied = mountYaw
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
        -- yaw is NOT saved any more: the creature carries its own rotation
        -- through a save, and reading it back is both shorter and correct.
        -- The saved copy could only ever disagree with the creature.
        allowInteriors = session.allowInteriors,
    }
end

local function onLoad(data)
    session = nil
    pendingStart = nil
    -- Re-probe the bridge after a load: the handle is tied to the previous
    -- game session, and the load order can differ between saves.
    mwBridge = nil
    -- whywalk_mount.lua is attached with addScript, so it PERSISTS on the
    -- creature in the save -- unlike the player scripts, which the manifest
    -- re-creates. So the decision "are we resuming this ride?" has to be made
    -- before any early return, or a load that does not resume leaves the
    -- script bound to that creature for the rest of the save.
    --
    -- This matters more since the controls port than it did before. The script
    -- holds the creature's standard AI DISABLED while a ride is live. Its own
    -- onLoad re-enables AI and clears the controls, so a creature is never
    -- left frozen either way -- but a stranded script would keep an onUpdate
    -- alive on a creature nobody is riding.
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

    -- Re-announce so the player script and animation controller re-enter their
    -- mounted state; neither persists it across a load by design. The mount
    -- script's MountStart is deferred to the first onUpdate as usual, which
    -- also re-disables the creature's AI after its own onLoad re-enabled it.
    attachMountScript(data.mount, data.freeRide, data.player, session.profile)

    data.player:sendEvent(EV.MOUNTED, {
        mount = data.mount, mountType = data.mountType, freeRide = data.freeRide,
    })
end

return {
    eventHandlers = {
        [EV.REQUEST_MOUNT]    = onRequestMount,
        [EV.REQUEST_DISMOUNT] = onRequestDismount,
        [EV.CONTROL]          = onControl,
    },
    engineHandlers = {
        onUpdate = onUpdate,
        onSave   = onSave,
        onLoad   = onLoad,
    },
}
