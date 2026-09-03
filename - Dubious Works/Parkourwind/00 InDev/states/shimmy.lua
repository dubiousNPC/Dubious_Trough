--[[
    states/shimmy.lua

    Lateral movement along a ledge while hanging. Entered from LedgeHang by
    pressing left or right; performs ONE discrete step of STEP_DISTANCE units
    along the wall face, then hands back to LedgeHang. Holding the direction
    simply re-enters for another step, so a held key reads as continuous
    shimmying without this state needing to manage a hold.

    MOVEMENT: per-tick FLOW_SnapTo along a lerp, reusing LedgeHang's own
    positioning mechanism rather than adding a tween type to the backend.
    Gravity is already suspended by LedgeHang's Levitate effect and is NOT
    touched here - this state deliberately does not re-apply or remove it,
    because LedgeHang owns that lifecycle and will still be the state either
    side of this one. If Shimmy ever becomes reachable from somewhere other
    than LedgeHang, that assumption has to be revisited.

    ANIMATION: directional, via Anim.setVariant("left"/"right") - the group
    names live in playerAnim.lua's GROUPS.Shimmy.variants, never here.

    Entry data (target position, wall normal, direction) is pushed in by
    ledge_hang.lua through setStep(), matching the setLandingData /
    setWallNormal pattern used elsewhere.
]]--

local core = require('openmw.core')
local mwSelf = require('openmw.self')
local util = require('openmw.util')
local nearby = require('openmw.nearby')
local I = require('openmw.interfaces')
local types = require('openmw.types')
local BaseState = require('states/base_state')
local Anim = require('playerAnim')
local WallBoostState = require('states/wall_boost')

local ShimmyState = BaseState.new("Shimmy")

-- ==============================================
-- CONFIGURATION
-- ==============================================
local STEP_DISTANCE = 30.0   -- units per step, roughly a hitbox width
local STEP_DURATION = 1.0    -- seconds; matches the one-shot clip length

-- Validation probes for the destination. Without these a shimmy walks the
-- player off the end of a ledge into thin air, or through a corner.
-- Both measured from the LIP, not from the body -- see probeStep. The window
-- straddles the ledge surface so a step up or down a shallow stair still finds
-- it, while a genuine drop-off does not.
local LIP_PROBE_UP = 30.0    -- start the lip probe this far above the lip
local LIP_PROBE_DOWN = 40.0  -- and end it this far below
local BODY_CLEARANCE = 25.0  -- lateral clearance the torso needs to exist

local RAY_OPTS = { ignore = mwSelf }

-- ==============================================
-- ENTRY DATA (set by states/ledge_hang.lua)
-- ==============================================
local pendingDir = 0          -- -1 = left, +1 = right
local pendingWallNormal = nil
local pendingLip = nil        -- lip probeStep found for the destination

-- [BUGFIX] The lip now travels with the step. ledge_hang used to assign it to
-- its own cachedTargetPos and return "Shimmy", but the state manager calls
-- exit() BEFORE enter(), and LedgeHang:exit() nils cachedTargetPos -- so the
-- value was wiped before Shimmy ever started and re-anchoring silently fell
-- back to whatever the sensor happened to report that frame. Handing it back
-- through consumeResultLip() removes that dependency entirely.
function ShimmyState.setStep(dir, wallNormal, lipPos)
    pendingDir = dir
    pendingWallNormal = wallNormal
    pendingLip = lipPos
end

-- Lip and wall normal the last completed step landed on, consumed once by
-- LedgeHang:enter(). Cleared on read so a stale pair cannot re-anchor an
-- unrelated later hang.
--
-- The normal travels with the lip because SensorExt.data.wallNormal may also
-- be nil on the resume frame, and LedgeHang's fallback (-forward from player
-- yaw) slowly drifts from the true wall normal across repeated steps.
local resultLip = nil
local resultNormal = nil

function ShimmyState.consumeResultLip()
    local lip, normal = resultLip, resultNormal
    resultLip, resultNormal = nil, nil
    return lip, normal
end

-- Direction vector along the wall face: the wall normal rotated 90 degrees
-- about Z, flattened. Exposed so ledge_hang can validate a step before
-- committing to the transition.
function ShimmyState.lateralVector(wallNormal)
    local flat = util.vector3(wallNormal.x, wallNormal.y, 0)
    if flat:length() < 0.01 then return nil end
    flat = flat:normalize()
    -- Perpendicular in the XY plane.
    return util.vector3(-flat.y, flat.x, 0)
end

-- Is a step of `dir` actually landable? Checks that the ledge lip continues
-- there and that the body has room. Called by ledge_hang before entering, so a
-- blocked step never starts an animation. Returns the new lip position, or nil.
--
-- TWO positions are required and they are NOT interchangeable:
--   playerPos - the hanging body, used for the lateral clearance sweep
--   lipPos    - the ledge top surface, used for the lip continuation probe
--
-- [BUGFIX] The lip probe used to be built from playerPos, which made the whole
-- feature unreachable. While hanging the player origin sits HANG_OFFSET_Z (125)
-- BELOW the lip and WALL_OFFSET (35) in FRONT of the wall face, so a vertical
-- ray from playerPos.z + 40 topped out ~85 units short of the lip, in open air
-- past the edge. It could never hit, probeStep always returned nil, and
-- ledge_hang never transitioned to Shimmy at all.
--
-- Probing from lipPos instead fixes both axes at once and removes the need to
-- know ledge_hang's offsets here. This mirrors sensor_ext.updateLedgeHang,
-- which succeeds precisely because it probes downward from above and behind
-- the edge rather than from the body.
function ShimmyState.probeStep(playerPos, lipPos, wallNormal, dir)
    if not playerPos or not lipPos then return nil end

    local lateral = ShimmyState.lateralVector(wallNormal)
    if not lateral then return nil end

    local offset = lateral * (STEP_DISTANCE * dir)

    -- 1. Body clearance: is the space beside the hanging body free? This one
    -- genuinely does start at the body, so it stays on playerPos.
    local clearFrom = playerPos
    local clearTo   = playerPos + offset + (lateral * (BODY_CLEARANCE * dir))
    local clearRes  = nearby.castRay(clearFrom, clearTo, RAY_OPTS)
    if clearRes.hit then return nil end

    -- 2. Lip continuation: straight down through where the ledge top should be
    -- one step along. No hit means the ledge has ended.
    local stepLip = lipPos + offset
    local probeTop    = util.vector3(stepLip.x, stepLip.y, stepLip.z + LIP_PROBE_UP)
    local probeBottom = util.vector3(stepLip.x, stepLip.y, stepLip.z - LIP_PROBE_DOWN)
    local lipRes = nearby.castRay(probeTop, probeBottom, RAY_OPTS)
    if not lipRes.hit then return nil end

    -- Reject a "lip" that is really a wall face or a steep slope, the same
    -- 0.7 threshold sensor_ext uses to qualify a ledge.
    if lipRes.hitNormal and lipRes.hitNormal:dot(util.vector3(0, 0, 1)) < 0.7 then
        return nil
    end

    return lipRes.hitPos
end

-- ==============================================
-- INTERNAL STATE
-- ==============================================
local timeInState = 0
local dir = 0
local startPos = nil
local endPos = nil
local wallNormal = nil

-- Currently unused: WallBoost receives the direction directly through
-- setLaunch() in update() below. Kept as a public accessor because a
-- directional read is the obvious thing for a future caller to want.
function ShimmyState.lastDirection()
    return dir
end

-- =============================================================================
-- HANG SUSPENSION
--
-- [BUGFIX] LedgeHangState:exit() calls applyGravityHack(false) and releases
-- both control overrides - it has no idea the state it is handing to is still
-- part of the same hang. So for the whole one-second step the player had
-- gravity back and controls returned, and the hang effectively ended mid-
-- shimmy. That is why a step played its opening frames once and then never
-- re-armed: the player was no longer hanging by the time it finished.
--
-- Shimmy therefore re-asserts the same suspension for its own duration. Both
-- states applying and removing means a one-frame gap across each transition,
-- which is harmless here because Shimmy re-snaps position every tick anyway.
-- =============================================================================
local GRAVITY_MAGNITUDE = 200

-- The two halves of this have DIFFERENT repeat semantics, which is easy to
-- miss because one call does both:
--
--   I.Controls.override*Controls(bool)  - a plain setter, idempotent, a
--                                         repeated call costs nothing.
--   activeEffects:modify(+/-mag, ...)   - CUMULATIVE. Two enables and one
--                                         disable leaves the player levitating
--                                         by 200 permanently.
--
-- So the levitate half is flag-guarded and the control half is not, matching
-- ledge_hang.lua's applyGravityHack. Enter/exit are paired through
-- StateManager.setState today and the magnitude does balance across a
-- traverse, but the guard makes an unpaired call harmless instead of
-- permanent.
local suspensionApplied = false

local function applySuspension(enable)
    if enable ~= suspensionApplied then
        -- No pcall: types.Actor.activeEffects and :modify are documented API
        -- on a live actor, and ledge_hang.lua makes the identical call
        -- unguarded. Swallowing an error here would leave the hang silently
        -- un-suspended, which is worse than seeing the error.
        types.Actor.activeEffects(mwSelf):modify(
            enable and GRAVITY_MAGNITUDE or -GRAVITY_MAGNITUDE,
            core.magic.EFFECT_TYPE.Levitate)
        suspensionApplied = enable
    end

    I.Controls.overrideMovementControls(enable)
    I.Controls.overrideCombatControls(enable)
end

function ShimmyState:enter(syncData)
    timeInState = 0
    dir = pendingDir
    wallNormal = pendingWallNormal

    Anim.setVariant(dir < 0 and "left" or "right")

    startPos = mwSelf.position
    local lateral = ShimmyState.lateralVector(wallNormal)
    endPos = lateral and (startPos + lateral * (STEP_DISTANCE * dir)) or startPos

    -- Held until exit, then handed to LedgeHang.
    resultLip = pendingLip
    resultNormal = wallNormal

    applySuspension(true)

    pendingDir = 0
    pendingWallNormal = nil
    pendingLip = nil
end

function ShimmyState:exit()
    applySuspension(false)
    startPos = nil
    endPos = nil
    dir = 0          -- so lastDirection() cannot report a stale step
end

function ShimmyState:update(dt, syncData, inputData)
    timeInState = timeInState + dt

    -- WallBoost: JUMP alone while shimmying.
    --
    -- This previously also required back to be held. That combination is
    -- close to unusable in practice: the player is already holding a lateral
    -- key to shimmy, and adding back at the same time as jump either fights
    -- the lateral input or ends the step. The launch direction does not need
    -- to come from input anyway - the shimmy already knows which way the
    -- player is facing and travelling, so `dir` picks the animation variant
    -- and the wall normal supplies the push. Nothing about the boost is
    -- ambiguous without the back key.
    if inputData.jump then
        WallBoostState.setLaunch(wallNormal, dir)
        return "WallBoost"
    end

    -- Drop out of the hang entirely.
    if inputData.crouch then
        return "Airborne"
    end

    if not startPos or not endPos then
        return "LedgeHang"
    end

    local t = math.min(1.0, timeInState / STEP_DURATION)
    local pos = startPos + (endPos - startPos) * t

    core.sendGlobalEvent('FLOW_SnapTo', {
        actor = mwSelf,
        position = pos,
        rotation = mwSelf.rotation,
    })

    if t >= 1.0 then
        -- [FIX] Continue IN-STATE when the direction is still held.
        --
        -- This used to return "LedgeHang" and rely on that state bouncing
        -- straight back here. With a key held that meant two full state
        -- changes per second, and each one tore down and restarted the
        -- animation (stopCurrent + playBlended), re-snapped position, and
        -- re-applied the Levitate and control overrides in LedgeHang's
        -- enter/exit. That churn is the choppiness - the step movement
        -- itself was fine.
        --
        -- Looping here keeps one continuous state: no transition, no
        -- teardown, no re-snap. The one-shot clip is re-fired explicitly via
        -- Anim.replay(), since without a state change onStateChange never
        -- runs.
        local held = inputData.moveVector.x
        if math.abs(held) > 0.1 and wallNormal then
            local nextDir = (held > 0) and 1 or -1
            local nextLip = ShimmyState.probeStep(mwSelf.position, resultLip, wallNormal, nextDir)
            if nextLip then
                dir = nextDir
                -- resultLip is what gets handed to LedgeHang on exit, so it
                -- has to track each in-state step, not just the first.
                resultLip = nextLip
                -- [FIX] Chain from the previous step's TARGET, not from the
                -- live position. Reading mwSelf.position back each step let
                -- the small gap between the SnapTo and where the engine
                -- actually settled accumulate; after a few seconds of held
                -- input the accumulated offset desynced the player from the
                -- lip the probe was tracking, and probeStep started
                -- alternating pass/fail - the vibration.
                startPos = endPos or mwSelf.position
                local lateral = ShimmyState.lateralVector(wallNormal)
                endPos = lateral and (startPos + lateral * (STEP_DISTANCE * dir)) or startPos
                timeInState = 0
                Anim.setVariant(dir < 0 and "left" or "right")
                Anim.replay()
                return nil
            end
        end
        return "LedgeHang"
    end

    return nil
end

-- Exposed so ledge_hang.lua doesn't duplicate the constant.
ShimmyState.STEP_DISTANCE = STEP_DISTANCE

return ShimmyState
