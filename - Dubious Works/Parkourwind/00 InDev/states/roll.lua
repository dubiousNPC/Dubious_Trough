--[[
    states/roll.lua

    Landing roll. While airborne and holding forward, double-tap Jump (two
    full press+release cycles inside a one-second budget). That arms a
    one-second window and applies a Fortify Agility bonus; touch down inside
    the window and the landing becomes a recovery roll. A brief Acrobatics
    spike lets the ENGINE compute reduced fall damage (and suppress fall
    knockdown) rather than healing anything back afterwards.

    This is the "Roll" state the original states-not-finished/air.lua draft
    referenced but never built.

    ENTRY is owned by states/airborne.lua, not by this file - see the
    "LANDING ROLL" block there. The arming, the tap counting and the Fortify
    all live up there; this state is entered only at touchdown, because
    state_manager plays a state's animation on ENTRY and entering while
    airborne would fire pwroll1 mid-fall.

    Exits to Idle; the engine's own run state carries momentum forward, so no
    separate sprint hand-off is needed.

    ANIMATION: "pwroll1", start/stop keys, registered in playerAnim.lua's
    GROUPS and ONE_SHOT_STATES. This file never calls the animation API
    itself - core/state_manager.lua's setState() choke point drives it.

    NO RAYCASTS, no teleports, no temporary objects, no engine overrides.
    This state only reads stats and adjusts health.
]]--

local BaseState = require('states/base_state')
local types = require('openmw.types')
local mwSelf = require('openmw.self')

local RollState = BaseState.new("Roll")

-- ==============================================
-- CONFIGURATION
-- ==============================================
local ROLL_DURATION = 0.45      -- recovery window before handing back to
                                 -- Idle. Long enough to read as a
                                 -- deliberate action, short enough not to
                                 -- feel like a stun.

-- ACROBATICS SPIKE, replacing the old health-refund model.
--
-- Previously this watched for the engine's fall damage to land and then healed
-- part of it back. That worked, but it had two problems: it healed damage from
-- ANY source that arrived inside the watch window, and it fought the engine
-- instead of using it.
--
-- AcrobaticsEnhanced solves the same problem by spiking acrobatics.modifier
-- for the landing frame and letting the ENGINE compute reduced damage from the
-- higher skill. Nothing is healed, nothing is predicted, and the engine also
-- suppresses fall KNOCKDOWN off the same skill value - a free second benefit
-- the refund model could never give.
--
-- Spiking .modifier never touches .base, so this is leveling-safe.
local ACRO_SPIKE = 60

-- How long to hold the spike. It only needs to cover the landing frame the
-- engine evaluates damage on; the rest is margin. Kept short deliberately -
-- AcrobaticsEnhanced notes that a SAVE taken while a spike is held bakes it
-- into the savefile permanently, so the exposure window should be minimal.
local SPIKE_HOLD = 0.20

-- ==============================================
-- ENTRY DATA (set by states/airborne.lua)
-- ==============================================
-- Kept for call-site compatibility with states/airborne.lua. The spike model
-- needs no pre-impact health sample, so the argument is now ignored.
function RollState.setLandingData(_)
end

-- ==============================================
-- INTERNAL STATE
-- ==============================================
local GROUND_GRACE = 0.20   -- how long to wait for isGrounded to catch up
                             -- with the animation's land key before giving
                             -- up and treating this as a genuine mid-air
                             -- entry

local timeInState = 0
local groundConfirmed = false
local spikeApplied = false

-- The spike must be OFF before the state can be left by any route, or the
-- bonus is stranded on the actor - the same failure mode as a leaked Levitate.
local function applySpike(enable)
    if enable == spikeApplied then return end
    local skill = types.NPC.stats.skills.acrobatics(mwSelf)
    skill.modifier = skill.modifier + (enable and ACRO_SPIKE or -ACRO_SPIKE)
    spikeApplied = enable
end

function RollState:enter(syncData)
    timeInState = 0
    groundConfirmed = syncData and syncData.isGrounded or false

    -- Applied immediately on entry: the engine evaluates fall damage on the
    -- landing frame, so the higher skill has to already be in place.
    applySpike(true)
end

function RollState:exit()
    applySpike(false)
end

function RollState:update(dt, syncData, inputData)
    timeInState = timeInState + dt

    -- 1. Drop the spike as soon as the landing frame has passed. Held any
    -- longer it is just a free buff, and a save taken while it is active
    -- would write it permanently into the savefile.
    if spikeApplied and timeInState >= SPIKE_HOLD then
        applySpike(false)
    end

    -- 2. Interrupt: if the ground vanishes again (rolled off a ledge),
    -- don't hold the player in a recovery animation mid-air.
    --
    -- GRACE: airborne.lua can enter this state off the vanilla jump group's
    -- land/stop text key, which fires slightly BEFORE the polled isGrounded
    -- flips. Without a grace window this check saw "not grounded" on frame
    -- one, bailed straight back to Airborne, and state_manager's stopCurrent
    -- cancelled pwroll1 before it was visible - the state would appear in
    -- the console with no animation. Only start honouring the check once the
    -- ground has actually been confirmed at least once.
    if syncData.isGrounded then
        groundConfirmed = true
    elseif groundConfirmed or timeInState > GROUND_GRACE then
        return "Airborne"
    end

    -- 3. Recovery window over - momentum preservation, matching the
    -- Vault/Mantle convention. Movement itself is engine-driven, so simply
    -- returning to Idle preserves whatever the player was doing.
    if timeInState >= ROLL_DURATION then
        if inputData.moveVector.y > 0 then
            return "Idle"
        end
        return "Idle"
    end

    return nil
end

return RollState
