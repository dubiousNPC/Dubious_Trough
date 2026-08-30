local BaseState = require('states/base_state')
local core = require('openmw.core')
local I = require('openmw.interfaces')
local input = require('openmw.input')
local async = require('openmw.async')
local types = require('openmw.types')
local util = require('openmw.util')
local nearby = require('openmw.nearby')
local mwSelf = require('openmw.self')
local Settings = require('settings')
local Sensor = require('core/sensor')
local SensorExt = require('core/optional/sensor_ext')
local RollState = require('states/roll')
local InputManager = require('core/input')
local VaultState = require('states/vault')
local MantleState = require('states/mantle')

local AirborneState = BaseState.new("Airborne")

-- ==============================================
-- LANDING ROLL
-- ==============================================
-- Sequence: airborne -> hold forward -> tap Jump -> armed, with a Fortify
-- Agility bonus, until touchdown -> land and roll -> back to running.
--
-- ONE mid-air tap, matching surfAnimations. The jump press that launches the
-- jump does not count: Idle is still the active state on that frame, so
-- isActive is false and the handler ignores it. That is the same filtering
-- surfAnimations gets from its animation.isPlaying("jump") gate, and it is
-- what makes the gesture read as "jump, then tap" rather than needing a
-- tracked sequence.
--
-- INPUT: an engine trigger handler, not polled state. Every previous
-- version reconstructed press/release edges by comparing
-- input.isActionPressed(ACTION.Jump) against the last frame's value, and it
-- was never reliable - a tap completed inside a single frame is simply
-- invisible to polling, and the release half of each cycle fought the
-- jump-HELD gate that Vault/Mantle/LedgeHang depend on.
--
-- input.registerTriggerHandler receives the engine's own input event
-- instead, so no press can be dropped between frames and nothing needs to
-- be reconstructed. This is the method ErnGlider/surfAnimations uses for
-- the same gesture; its handler body is gated on being mid-jump, which is
-- also proof the Jump trigger does fire while airborne.
--
-- Costs nothing per frame - the handler runs only when the key is actually
-- pressed.
--
-- The arm does NOT expire: the gesture behaves identically on a short hop
-- and a long fall.
--
-- Arming lives here rather than in roll.lua because state_manager plays a
-- state's animation on ENTRY - entering Roll while still in the air would
-- fire pwroll1 mid-fall. Roll is therefore still entered at touchdown; only
-- the arming and the Fortify happen up here.
--
-- Cost while airborne is a few boolean/number comparisons per frame and
-- nothing at all while grounded. No raycasts, no allocations.
local AGILITY_BONUS = 70

-- How far below hand height the ledge lip may still be and count as
-- grabbable. Pure forgiveness margin - at 0 the grab can never move the
-- player downward at all, which reads as slightly too strict in play.
-- How far ABOVE the eventual hang position the player may already be and
-- still be allowed to grab. The gate exists only to stop a grab yanking the
-- player back DOWN onto a ledge they have already cleared - it is not meant
-- to be a height requirement.
--
-- [FIX] The previous form compared the lip against hand height
-- (position.z + GRAB_HEIGHT - 20), i.e. it demanded the lip sit more than 115
-- units above the feet. That is far stricter than the "don't get pulled down"
-- rule it was standing in for, and it silently rejected perfectly good
-- chest-and-head-height ledges. Comparing against the hang position instead
-- expresses the actual intent.
local LEDGE_MAX_DROP = 50

-- Mirrors HANG_OFFSET_Z in states/ledge_hang.lua: how far below the lip the
-- grab actually places the player. If that changes, change this too.
local LEDGE_HANG_DROP = 125

-- Forward stick/key threshold at the moment of the tap, mirroring
-- surfAnimations' deadzone treatment of pself.controls.movement.
local FORWARD_DEADZONE = 0.1

-- Height window for arming the roll. Borrowed from AcrobaticsEnhanced, which
-- gates its own roll the same way and states the reason plainly: an arm with
-- no height check "kills the double-tap-jump-early exploit" only if the press
-- has to happen NEAR THE GROUND. FLOW's arm never expires, so without this a
-- single press at the apex of any fall armed the whole descent - no timing
-- skill involved at all.
--
-- A height window is also better than the 1-second timer it effectively
-- replaces: a timer punishes long falls (press too early, lose the attempt),
-- whereas a height gate behaves identically at any fall height because it is
-- measured against the geometry the player is actually approaching.
--
-- Cost is one downward raycast PER PRESS, not per frame.
local ROLL_HEIGHT_WINDOW = 256.0
local ROLL_HEIGHT_PROBE = 5000.0

local function heightAboveGround()
    local p = mwSelf.position
    local ok, res = pcall(function()
        return nearby.castRay(p, util.vector3(p.x, p.y, p.z - ROLL_HEIGHT_PROBE), {
            ignore = mwSelf,
            collisionType = nearby.COLLISION_TYPE.World + nearby.COLLISION_TYPE.HeightMap,
        })
    end)
    if ok and res and res.hit and res.hitPos then
        return p.z - res.hitPos.z
    end
    return nil
end

local armed = false
local armTimer = 0
local isActive = false          -- is Airborne the current state? gates the
                                 -- module-scope trigger handler, which fires
                                 -- regardless of which state is running
local agilityApplied = false

-- NOTE: activeEffects:modify() on a fortify effect is cosmetic on its own -
-- the OpenMW docs are explicit that fortify-attribute active effects "have
-- no practical effect of their own, and must be paired with explicitly
-- modifying the target stat". So the stat modifier is the part that does
-- the work; the activeEffects entry exists so it also reads as a real
-- Fortify Agility in the magic menu rather than an unexplained stat jump.
local function applyAgility(enable)
    if enable == agilityApplied then return end
    local sign = enable and 1 or -1

    local attr = types.Actor.stats.attributes.agility(mwSelf)
    attr.modifier = attr.modifier + (sign * AGILITY_BONUS)

    local fx = types.Actor.activeEffects(mwSelf)
    if fx then
        fx:modify(sign * AGILITY_BONUS, core.magic.EFFECT_TYPE.FortifyAttribute, 'agility')
    end

    agilityApplied = enable
end

-- =============================================================================
-- JUMP TRIGGER HANDLER
--
-- Registered once at module scope and fires for every Jump input event, in
-- any state - hence the isActive gate. A single mid-air tap with forward
-- held arms the roll.
--
-- Note this needs NO release edge, which is why it also fixes the conflict
-- the polled version had: completing the old gesture meant letting go of
-- jump, and Vault/LedgeHang/Mantle are gated on jump being HELD. The player
-- can now hold jump throughout and keep all three available.
--
-- DIRECTION READ: uses InputManager's cached moveVector, NOT a live
-- mwSelf.controls.movement read. This handler runs via async:callback at an
-- unspecified point relative to onUpdate, so a direct controls read can catch
-- the value before the engine has populated it for this frame - which
-- presented as "holding forward makes the roll fail", the exact opposite of
-- what the gate intends. InputManager samples once per frame at a known
-- point, so the cached value is at worst one frame old and always coherent.
--
-- surfAnimations reads controls.movement live and gets away with it because
-- its FORWARD branch deliberately does nothing - a bad read there just falls
-- through to its glider default. FLOW needs the read to be correct to arm at
-- all, so it cannot rely on the same assumption.
-- =============================================================================
input.registerTriggerHandler("Jump", async:callback(function()
    -- Input triggers can still fire while the world is paused, but main.lua
    -- now runs on onUpdate, which does not. Without this guard a Jump press
    -- in a menu could bank taps against a stale isActive/moveVector snapshot
    -- and pre-arm a roll from outside gameplay.
    if core.isWorldPaused then return end
    if not isActive or armed then return end

    -- Forward must be held at the tap.
    if InputManager.intents.moveVector.y <= FORWARD_DEADZONE then return end

    -- Height gate: only counts near the ground. See ROLL_HEIGHT_WINDOW.
    local h = heightAboveGround()
    if not h or h > ROLL_HEIGHT_WINDOW then
        if Settings.debugMode() then
            print(string.format("[FLOW][roll] tap REJECTED h=%s window=%.0f",
                h and string.format("%.0f", h) or "nil", ROLL_HEIGHT_WINDOW))
        end
        return
    end

    if Settings.debugMode() then
        print(string.format("[FLOW][roll] ARMED h=%.0f", h))
    end
    armed = true
    armTimer = 0
    applyAgility(true)
end))

-- =============================================================================
-- LANDING FAST PATH (vanilla 'jump' text keys)
--
-- syncData.isGrounded is still the authority for landing - it drives seven
-- call sites across the mod and is known to work. This handler is purely an
-- EARLIER signal: the engine fires the jump group's land/stop text key on
-- the exact frame the animation says the feet are down, which can precede
-- the polled isGrounded flip.
--
-- Deliberately additive rather than a replacement. The exact text-key names
-- in a given animation set are not guaranteed ('jump: land' vs 'jump: stop'
-- vs neither, and replacer .kf files vary), and if landing detection
-- depended solely on a key that never fires, the player would be stranded
-- in Airborne permanently. Suffix-matched so it tolerates both spellings;
-- if it never fires, behaviour is exactly what it was before.
-- =============================================================================
local landedSignal = false

if I.AnimationController and I.AnimationController.addTextKeyHandler then
    pcall(function()
        I.AnimationController.addTextKeyHandler('jump', function(groupname, key)
            -- Naive suffix matching on 'stop' is wrong: the vanilla jump
            -- group also emits 'jump: loop stop', which fires when the
            -- falling loop ends and is NOT reliably touchdown. Accept the
            -- land key, and the final stop key, but never the loop's.
            if string.sub(key, -4) == 'land' then
                landedSignal = true
            elseif string.sub(key, -4) == 'stop' and string.sub(key, -9) ~= 'loop stop' then
                landedSignal = true
            end
        end)
    end)
end

-- Only called when the debug HUD is on, so the string build costs nothing
-- in a normal session.
function AirborneState.getRollDebug()
    if armed then
        return string.format("ROLL: ARMED %.2f%s", armTimer,
            landedSignal and " LANDKEY" or "")
    end
    return string.format("ROLL: idle fwd=%.2f", InputManager.intents.moveVector.y)
end


function AirborneState:enter(syncData)
    isActive = true
    -- Fresh airborne period starts unarmed.
    armed = false
    armTimer = 0
    landedSignal = false
end

-- Safety net: the Fortify is normally removed on landing or on timeout, but
-- if this state is left by any other route (death, forced reset, a hand-off
-- to Vault/Mantle/LedgeHang mid-arm) the bonus must not be left stranded on
-- the actor.
function AirborneState:exit()
    isActive = false
    applyAgility(false)
end

function AirborneState:update(dt, syncData, inputData)
    -- 1. Obstacle Interaction (Mid-Air) - jump-gated, matching Idle
    if inputData.jump then
        if Sensor.data.interaction == "Vault" and not VaultState.isBlocked() then
            return "Vault"
        end

        -- B. Ledge Hang (High/Overhead obstacles)
        if SensorExt.data.interaction == "LedgeHang" and SensorExt.data.targetPos then
            -- Geometry check, replacing the old smoothed-velocity gate
            -- ("only grab if vertical velocity < 150"). That was asking
            -- "am I rising fast?" as a proxy for the question it actually
            -- cared about: "is this lip still above me, or have I already
            -- gone past it?" Position answers that exactly and with no
            -- smoothing lag - and the lip position is already sitting in
            -- SensorExt.data from the scan that just reported the hang.
            --
            -- The rule is simply: refuse only if grabbing would drop the
            -- player more than LEDGE_MAX_DROP. See that constant for why an
            -- earlier hand-height form was far too strict.
            -- Where the grab would put us, versus where we are now.
            local hangZ = SensorExt.data.targetPos.z - LEDGE_HANG_DROP
            if mwSelf.position.z <= hangZ + LEDGE_MAX_DROP then
                return "LedgeHang"
            end
        end

        -- C. Mantling (Medium obstacles)
        if Sensor.data.interaction == "Mantle" and not MantleState.isBlocked() then
            return "Mantle"
        end
    end

    -- Touchdown. isGrounded remains the authority for leaving this state;
    -- the animation key is honoured ONLY when a roll is armed, i.e. as a
    -- latency shortcut for the one transition where a frame matters. Scoped
    -- this way, a text key that fires at the wrong moment (a replacer .kf
    -- with different keys, an unexpected 'stop') can at worst start a roll a
    -- little early - it can never pull the player out of the air into Idle.
    local touchedDown = syncData.isGrounded or (landedSignal and armed)

    -- 1b. Airborne bookkeeping. Tap counting itself happens in the trigger
    -- handler above, not here - this only tracks the pre-impact health
    -- sample and ages the debug timer.
    if not touchedDown then
        if armed then
            armTimer = armTimer + dt   -- debug readout only; the arm never expires
        end
    end

    -- 2. Landing Logic
    if touchedDown then
        landedSignal = false
        if armed then
            applyAgility(false)
            armed = false
            if Settings.debugMode() then print("[FLOW][roll] landing -> Roll") end
            RollState.setLandingData()
            return "Roll"
        end

        applyAgility(false)

        if inputData.sprint and inputData.moveVector.y > 0 then
            return "Sprint"
        end
        return "Idle"
    end

    return nil
end

return AirborneState