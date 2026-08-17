local BaseState = require('states/base_state')
local core = require('openmw.core')
local mwSelf = require('openmw.self')
local I = require('openmw.interfaces')
local util = require('openmw.util')
local nearby = require('openmw.nearby')
local Sensor = require('core/sensor')
local EngineSync = require('core/engine_sync')

local VaultState = BaseState.new("Vault")

-- Hoisted: the profilometer loop below casts one ray per sample step, and
-- rebuilt this identical table on every one of them.
local PROFILE_RAY_OPTS = {
    ignore = mwSelf,
    collisionType = nearby.COLLISION_TYPE.World + nearby.COLLISION_TYPE.HeightMap
}

-- Configuration
local VAULT_BASE_DURATION = 0.45 
local DISTANCE_SCALING = 500.0   

-- [NEW] Physics Safety Config
local PROFILE_STEPS = 5          -- How many raycasts to perform along the trajectory
local PEAK_SAFETY_CLEARANCE = 55.0 -- Height feet must clear the obstacle peak
local AIR_DROP_HEIGHT = 45.0     -- Height above target to release player (Physics takes over)
local MIN_APEX_RISE = 110.0      -- Floor on apex height above the start, so even a low
                                 -- obstacle produces a readable hop rather than a shuffle

-- [SAFETY] Vault-through-geometry guards.
--
-- The profilometer used to start its downward probes at startZ + 150. Any
-- obstacle taller than that meant the ray BEGAN INSIDE the geometry, which
-- reports no usable hit - so highestZ stayed at the start/land height, the
-- apex was computed low, and the arc drove straight through the building.
-- That is the "vaults through static terrain" symptom exactly. Probing from
-- well above fixes the detection.
local PROFILE_SCAN_CEILING = 600.0  -- how far above the player to start each probe
local PROFILE_SCAN_FLOOR = 50.0     -- how far below the player to end it

-- Detecting a tall obstacle is only half the fix: clearing a 400-unit wall
-- would mean launching the player 400 units into the air. Past this rise,
-- the obstacle is not a hurdle and Vault refuses it outright.
local MAX_VAULTABLE_RISE = 150.0

-- A downward profile cannot see an overhang, tunnel mouth or archway - the
-- probes pass through the opening and report the floor. One direct ray along
-- the arc's upper path catches those before committing.
local CLEARANCE_PROBE_Z = 0.65      -- fraction of the apex rise to probe at

-- After a refusal, suppress Vault briefly. Idle/Airborne re-evaluate every
-- frame off the same Sensor data, so without this the state would be
-- entered and rejected repeatedly - and because Vault is in
-- playerAnim.lua's ONE_SHOT_STATES, each entry would retrigger pwvault1.
local BLOCK_DURATION = 0.6
local blockedUntil = 0

-- Internals
local targetPos = nil
local timeInState = 0
local estimatedDuration = 0.5

-- Queried by states/idle.lua and states/airborne.lua before they hand off
-- here, so a refused vault doesn't re-enter (and re-fire its animation)
-- every frame while the player is still facing the same wall.
function VaultState.isBlocked()
    return core.getRealTime() < blockedUntil
end

function VaultState:enter(syncData)
    -- 1. Sanity Check
    if Sensor.data.interaction ~= "Vault" or not Sensor.data.targetPos then
        self.abort = true
        return
    end
    
    local DebugHUD = require('core/debug_hud')
    DebugHUD.update("Vault", Sensor.getDebugString(), "VAULT TRIGGERED")

    local startPos = mwSelf.position
    local rawLandPos = Sensor.data.targetPos
    
    -- [NEW] Strategy: "The Profilometer" & "Air Drop"
    
    -- A. The Profilometer
    -- Scan the path to find the highest point (e.g. top of a convex rock)
    local highestZ = math.max(startPos.z, rawLandPos.z)
    local pathVec = rawLandPos - startPos
    
    for i = 1, PROFILE_STEPS do
        local t = i / (PROFILE_STEPS + 1)
        local scanXY = startPos + (pathVec * t)
        
        -- Raycast down from well ABOVE the player, not from a fixed 150.
        -- See PROFILE_SCAN_CEILING.
        local origin = util.vector3(scanXY.x, scanXY.y, startPos.z + PROFILE_SCAN_CEILING)
        local dest = util.vector3(scanXY.x, scanXY.y, startPos.z - PROFILE_SCAN_FLOOR)
        
        local res = nearby.castRay(origin, dest, PROFILE_RAY_OPTS)
        
        if res.hit and res.hitPos.z > highestZ then
            highestZ = res.hitPos.z
        end
    end

    -- [SAFETY 1] Too tall to be a hurdle - refuse rather than launch the
    -- player over a building or clip through it.
    if (highestZ - startPos.z) > MAX_VAULTABLE_RISE then
        blockedUntil = core.getRealTime() + BLOCK_DURATION
        self.abort = true
        return
    end
    
    -- B. Apex Calculation
    -- Quadratic Bezier: P(t) = (1-t)^2 P0 + 2(1-t)t P1 + t^2 P2
    -- At peak (t=0.5), Height = 0.25*P0 + 0.5*P1 + 0.25*P2
    -- We need Height > (highestZ + Safety)
    -- So: 0.5*P1.z > (highestZ + Safety) - 0.25*P0.z - 0.25*P2.z
    -- P1.z > 2 * (highestZ + Safety) - 0.5*startZ - 0.5*landZ
    
    local requiredPeak = highestZ + PEAK_SAFETY_CLEARANCE
    local apexZ = 2 * requiredPeak - 0.5 * startPos.z - 0.5 * rawLandPos.z
    
    -- Clamp Apex to be at least a minimum jump height relative to start
    apexZ = math.max(apexZ, startPos.z + MIN_APEX_RISE)

    local midPoint = (startPos + rawLandPos) * 0.5
    local apexPos = util.vector3(midPoint.x, midPoint.y, apexZ)

    -- [SAFETY 2] Direct clearance probe along the upper arc. Catches solid
    -- mass a downward profile cannot see (overhangs, archways, anything the
    -- probes passed through on their way to the floor).
    local probeZ = startPos.z + (apexZ - startPos.z) * CLEARANCE_PROBE_Z
    local probeStart = util.vector3(startPos.x, startPos.y, probeZ)
    local probeEnd = util.vector3(rawLandPos.x, rawLandPos.y, probeZ)

    if nearby.castRay(probeStart, probeEnd, PROFILE_RAY_OPTS).hit then
        blockedUntil = core.getRealTime() + BLOCK_DURATION
        self.abort = true
        return
    end

    -- C. The Air Drop (Target Calculation)
    -- Stop the interpolation slightly above the ground to let Engine Physics handle the landing impact
    local safeLandPos = rawLandPos + util.vector3(0, 0, AIR_DROP_HEIGHT)

    -- 3. Duration Calculation
    local dist = (rawLandPos - startPos):length()
    estimatedDuration = math.max(0.25, VAULT_BASE_DURATION + (dist / DISTANCE_SCALING))

    -- 4. Take Control
    I.Controls.overrideMovementControls(true)
    I.Controls.overrideCombatControls(true)
    EngineSync.suspendTeleportDetection(true)

    -- 5. Trigger Global Physics
    core.sendGlobalEvent('FLOW_Vault_Start', {
        actor = mwSelf,
        startPos = startPos,
        apexPos = apexPos,
        landPos = safeLandPos, -- Send the Air Drop position
        duration = estimatedDuration
    })

    timeInState = 0
    self.abort = false
end

function VaultState:exit()
    I.Controls.overrideMovementControls(false)
    I.Controls.overrideCombatControls(false)
    EngineSync.suspendTeleportDetection(false)
    core.sendGlobalEvent('FLOW_Vault_Cancel', { actor = mwSelf })
end

-- The global tween (flow_amf_backend.lua) runs its own independent timer.
-- If this side hits the threshold first, exit() fires FLOW_Vault_Cancel and
-- deletes the tween before it ever reaches progress >= 1.0 - so the player
-- never gets the final teleport onto landPos and the vault visibly comes up
-- short. This grace guarantees the global side lands the move first.
--
-- Both sides now run on onUpdate, so they also agree about pause. They used
-- not to: this side ran on onFrame, which kept counting through menus while
-- the global tween was frozen, and no grace value could have covered that
-- because the two clocks were simply different.
local COMPLETION_GRACE = 0.06

function VaultState:update(dt, syncData, inputData)
    if self.abort then return "Airborne" end
    
    timeInState = timeInState + dt
    
    -- 1. Completion Check
    if timeInState >= estimatedDuration + COMPLETION_GRACE then
        -- Momentum preservation: holding forward hands back to Sprint,
        -- which immediately bounces to Idle on its own if the sprint key
        -- isn't actually held - see states/sprint.lua.
        if inputData.moveVector.y > 0 then
            return "Sprint"
        else
            return "Idle"
        end
    end

    return nil
end

return VaultState