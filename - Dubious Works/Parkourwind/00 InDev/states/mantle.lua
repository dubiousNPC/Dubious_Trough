local BaseState = require('states/base_state')
local types = require('openmw.types')
local mwSelf = require('openmw.self')
local util = require('openmw.util')
local I = require('openmw.interfaces')
local core = require('openmw.core') 
local ui = require('openmw.ui')
local camera = require('openmw.camera')
local nearby = require('openmw.nearby')
local Sensor = require('core/sensor') 
local EngineSync = require('core/engine_sync')

local MantleState = BaseState.new("Mantle")

-- Configuration
local MIN_DURATION = 0.35
local CLIMB_SPEED_UNITS_PER_SEC = 200.0 -- Adjust speed scaling
local LANDING_BUFFER = 35.0
local LEDGE_PUSH_IN = 45.0   -- how far PAST the detected ledge edge to finish, so the
                             -- player ends up standing solidly on top instead of
                             -- teetering on the lip where the surface probe hit
local TIMEOUT_MAX = 2.0

-- Camera "Heave" Config
local CAM_PITCH_DIP = 5.0 -- Degrees to look down during effort
local CAM_ROLL_MAG = 2.0  -- Degrees to roll during effort

-- Internal State
local targetPos = nil

-- [FIX] Refusal suppression, mirroring vault.lua's isBlocked().
--
-- Mantle had no equivalent, so once the destination validation started
-- refusing a target, Idle/Airborne re-entered Mantle on the very next frame
-- off the same unchanged Sensor data, aborted again, and thrashed
-- Airborne->Mantle->Airborne indefinitely. Two costs: pwmantle1 is a
-- ONE_SHOT so it re-fired on every entry, and - the reported symptom -
-- LedgeHang's check in airborne.lua only runs on frames where Airborne is
-- actually the active state, so the thrash was stealing every other frame
-- from it. That is why LedgeHang became harder to trigger near obstacles
-- Mantle was quietly refusing.
local BLOCK_DURATION = 0.6
local blockedUntil = 0

function MantleState.isBlocked()
    return core.getRealTime() < blockedUntil
end

local function refuse(state)
    blockedUntil = core.getRealTime() + BLOCK_DURATION
    state.abort = true
end
local timeInState = 0
local totalDuration = 0
local startPitch = 0
local startRoll = 0

-- Helpers
local function applyFatigueCost()
    local encumb = types.Actor.getEncumbrance(mwSelf)
    local cap = types.Actor.getCapacity(mwSelf)
    local ratio = 0
    if cap > 0 then ratio = encumb / cap end
    local cost = 20.0 * (1.0 + ratio)
    local dyn = types.Actor.stats.dynamic.fatigue(mwSelf)
    dyn.current = math.max(0, dyn.current - cost)
end

-- State Interface

function MantleState:enter(syncData)
    -- Sanity check: only enter if the Sensor actually flagged Mantle.
    -- (If you re-enable states/optional/ledge_hang.lua later, add back:
    --  `or Sensor.data.interaction == "LedgeHang"` to allow climbing up from a hang.)
    if Sensor.data.interaction ~= "Mantle" then
        self.abort = true
        return
    end

    local DebugHUD = require('core/debug_hud')
    DebugHUD.update("Mantle", Sensor.getDebugString(), "MANTLE TRIGGERED")
    
    I.Controls.overrideMovementControls(true)
    I.Controls.overrideCombatControls(true)
    EngineSync.suspendTeleportDetection(true)
    
    local startPos = mwSelf.position
    local rawLedge = Sensor.data.targetPos
    
    -- Safety Check: Ensure target exists
    if not rawLedge then
        self.abort = true
        return
    end
    
    -- "High Step" Logic: Ensure we land slightly above the surface to prevent floor clipping,
    -- and carry forward past the lip so the move actually deposits the player
    -- on the surface rather than teetering on its very edge.
    --
    -- Push direction is taken from the player->ledge vector rather than a
    -- hand-rolled facing vector: that's correct regardless of which yaw
    -- sign convention applies, and it's guaranteed to point AT the ledge
    -- (a sign error here would shove the player backwards off it).
    local toLedge = rawLedge - startPos
    local pushDir = util.vector3(toLedge.x, toLedge.y, 0)
    if pushDir:length() > 1.0 then
        pushDir = pushDir:normalize()
    else
        -- Ledge is directly overhead (straight-up climb) - fall back to
        -- the player's own facing, matching core/sensor.lua's convention.
        local yaw = mwSelf.rotation:getYaw()
        pushDir = util.transform.rotateZ(yaw):apply(util.vector3(0, 1, 0))
    end

    targetPos = rawLedge + util.vector3(0, 0, LANDING_BUFFER) + pushDir * LEDGE_PUSH_IN
    
    -- Validate Height
    if targetPos.z <= startPos.z then
        self.abort = true
        return
    end
    
    -- 1. Calculate Duration based on Height
    -- [SAFETY] Destination validation, same rationale as vault.lua's: the
    -- checks above vet the obstacle, nothing vetted where the player ends up.
    -- At the outer edge of sensor range the target is furthest from what
    -- approved it, and indoors a bad target sits on the far side of a wall -
    -- which is how a mantle turns into a clip-through and a fall.
    local DEST_HEAD_PROBE = 60.0
    local DEST_FLOOR_PROBE = 200.0
    local DEST_FLOOR_TOLERANCE = 60.0
    local DEST_RAY_OPTS = {
        ignore = mwSelf,
        collisionType = nearby.COLLISION_TYPE.World + nearby.COLLISION_TYPE.HeightMap
    }

    -- Probe the floor at the LEDGE's own horizontal position, not at
    -- targetPos. targetPos is pushed LEDGE_PUSH_IN (45) past the detected
    -- edge, which on a narrow ledge or a railing overshoots into empty space -
    -- no floor found, refusal, and the "message shows but nothing happens"
    -- symptom. The ledge position is where a surface is known to exist.
    local probeXY = util.vector3(rawLedge.x, rawLedge.y, targetPos.z)
    local destTop = targetPos + util.vector3(0, 0, DEST_HEAD_PROBE)
    local floorRes = nearby.castRay(probeXY + util.vector3(0, 0, DEST_HEAD_PROBE),
                                    probeXY - util.vector3(0, 0, DEST_FLOOR_PROBE),
                                    DEST_RAY_OPTS)
    if not floorRes.hit or (probeXY.z - floorRes.hitPos.z) > DEST_FLOOR_TOLERANCE then
        refuse(self)
        return
    end
    if nearby.castRay(targetPos, destTop, DEST_RAY_OPTS).hit then
        refuse(self)
        return
    end

    local heightDiff = math.abs(targetPos.z - startPos.z)
    totalDuration = math.max(MIN_DURATION, heightDiff / CLIMB_SPEED_UNITS_PER_SEC)
    
    -- 2. Define geometry
    local risePos = util.vector3(startPos.x, startPos.y, targetPos.z)
    
    -- 3. Visuals: Camera & Animation
    startPitch = camera.getPitch()
    startRoll = camera.getRoll()
    
    -- Animation is owned entirely by playerAnim.lua now (called right
    -- after this enter() returns, via state_manager.lua's setState choke
    -- point) - this used to call anim.playBlended('jump', ...) directly,
    -- which raced with playerAnim.lua's own attempt to play whatever's
    -- configured for "Mantle" and silently won or lost depending on
    -- priority. See playerAnim.lua's GROUPS.Mantle entry for the tuning
    -- (speed, priority, blendMask) that used to live here.
    
    -- 4. Execute
    core.sendGlobalEvent('FLOW_Mantle_Start', {
        actor = mwSelf,
        startPos = startPos,
        risePos = risePos,
        targetPos = targetPos,
        cageFrom = 1,   -- phase-gated in the backend: phase 2 only, never the
                         -- vertical rise up the wall face

        duration = totalDuration -- Send explicit duration to sync physics
    })
    
    applyFatigueCost()
    timeInState = 0
    self.abort = false
end

function MantleState:exit()
    I.Controls.overrideMovementControls(false)
    I.Controls.overrideCombatControls(false)
    EngineSync.suspendTeleportDetection(false)
    core.sendGlobalEvent('FLOW_Mantle_Cancel', { actor = mwSelf })
    
    -- Reset Camera
    camera.setExtraPitch(0)
    camera.setExtraRoll(0)
end

function MantleState:update(dt, syncData, inputData)
    if self.abort then return "Airborne" end
    
    timeInState = timeInState + dt
    
    -- 1. Procedural Camera Animation (The "Heave")
    local progress = timeInState / totalDuration
    if progress <= 1.0 then
        -- Sine wave: 0 -> 1 -> 0
        local heave = math.sin(progress * math.pi) 
        
        -- Pitch down (chin tuck) + Roll (exertion)
        local extraPitch = math.rad(CAM_PITCH_DIP * heave)
        local extraRoll = math.rad(CAM_ROLL_MAG * heave * 0.5) -- Slight roll
        
        camera.setExtraPitch(extraPitch)
        camera.setExtraRoll(extraRoll)
    end

    -- 2. Exit Conditions
    -- Same race as Vault: let the global tween land the move before this
    -- side exits and cancels it. Mantle is even more exposed - a
    -- truncated phase 2 leaves the player floating at the wall face
    -- instead of on top of the ledge.
    if timeInState >= totalDuration + 0.06 then
        -- Momentum preservation: holding forward hands back to Sprint,
        -- which immediately bounces to Idle on its own if the sprint key
        -- isn't actually held - see states/sprint.lua.
        if inputData.moveVector.y > 0 then
            return "Sprint"
        else
            return "Idle"
        end
    end
    
    -- Failsafe timeout
    if timeInState > TIMEOUT_MAX then
        return "Airborne"
    end

    return nil
end

return MantleState