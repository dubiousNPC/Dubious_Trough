local core = require('openmw.core')
local ui = require('openmw.ui')
local input = require('openmw.input')
local self = require('openmw.self')
local I = require('openmw.interfaces')

-- Import Modules
local EngineSync = require('core/engine_sync')
local StateManager = require('core/state_manager')
local InputManager = require('core/input')
local Sensor = require('core/sensor')
local SensorExt = require('core/optional/sensor_ext')
local DebugHUD = require('core/debug_hud')
local Anim = require('playerAnim')
local Settings = require('settings')
local H3 = require('core/h3lp_compat')

-- Import States
local IdleState = require('states/idle')
local AirborneState = require('states/airborne')
local SprintState = require('states/sprint')
local MantleState = require('states/mantle')
local VaultState = require('states/vault')
local LedgeHangState = require('states/ledge_hang')
local RollState = require('states/roll')
local ShimmyState = require('states/shimmy')
local WallBoostState = require('states/wall_boost')
-- WallJump has been removed entirely - it never worked as intended and
-- was the source of the repeating on-screen message and the T-pose (its
-- configured animation group had no matching clip, and its one-shot
-- playBlended masked out vanilla's own animation with nothing to
-- replace it).
-- WallRun is optional and not loaded by default.
-- See states/optional/README.md to bring it back.

local REGISTERED_STATES = {
    IdleState,
    AirborneState,
    SprintState,
    MantleState,
    VaultState,
    LedgeHangState,
    RollState,
    ShimmyState,
    WallBoostState
}

-- =================================================================
-- DEBUG HUD THROTTLE
-- =================================================================
-- The HUD used to be hardcoded on and updated OUTSIDE the idle throttle,
-- so every frame it built several strings and forced a UI redraw even
-- while the rest of the pipeline was correctly throttled. It also made
-- the sensor resolve object names (getObjectName -> pcall + record
-- lookup) purely to feed a debug string. It's now off by default, and
-- when on it refreshes at a readable 10Hz rather than every frame.
local DEBUG_HUD_INTERVAL = 0.1
local debugTick = H3.every(DEBUG_HUD_INTERVAL)
local debugWasEnabled = false

-- =================================================================
-- PERFORMANCE THROTTLE
-- =================================================================
-- The full pipeline (Sensor raycasts, SensorExt's LedgeHang fallback,
-- StateManager.update) only runs at full rate while the active state is
-- something other than Idle - which is exactly what holding Sprint (or
-- being mid-action) gives you. While genuinely idle, it only runs on this
-- throttled tick instead. EngineSync/InputManager stay untouched every
-- frame regardless - they're cheap (no raycasts) and keep isGrounded/
-- velocity/input state accurate for whenever the throttled tick does fire.
--
-- inputData.jump and inputData.sprint are level-triggered (true for as
-- long as the key is held), so a throttled tick can't miss a press
-- outright - but it could still delay noticing one by up to
-- IDLE_THROTTLE_INTERVAL, which is exactly the moment reactivity matters
-- most (the player just pressed jump at a ledge from a standing start).
-- InputManager.intents.jumpPressed/sprintPressed are cheap edge triggers
-- (a couple of boolean comparisons, no raycasts) that force an
-- unthrottled tick on the exact frame the key goes down, so the full
-- pipeline still only runs at the throttled rate while genuinely idle,
-- but never adds latency to the moment the player actually acts.
local IDLE_THROTTLE_INTERVAL = 0.15
local idleTick = H3.every(IDLE_THROTTLE_INTERVAL)

local function onInit()
    print("[FLOW] Cold Init...")
    EngineSync.init()
    StateManager.init(REGISTERED_STATES)
    -- HUD is created lazily by DebugHUD.update() only when the debug
    -- setting is on; nothing to create here.
end

-- Runs once all of the player's local scripts have loaded, which is the
-- documented-safe point to touch I.SharedRay: if another mod bundles a
-- newer SharedRay_v2.lua, the version race between copies has already
-- resolved by the time onActive fires.
local function onActive()
    Sensor.registerSharedRay()
end

local function onUpdate(dt)
    if StateManager.getActiveStateName() == "None" then
        EngineSync.init()
        StateManager.init(REGISTERED_STATES)
        -- One-shot console probe: reports which configured animation groups
        -- actually exist on this actor. Runs here rather than in onInit
        -- because the player's animation object is reliably present by the
        -- first frame.
        Anim.verifyGroups()
        if StateManager.getActiveStateName() == "None" then return end
    end

    if not Settings.modEnabled() then return end
    if Settings.disableInInteriors() and self.cell and not self.cell.isExterior then return end

    EngineSync.update(dt)
    InputManager.update()

    local isIdle = StateManager.getActiveStateName() == "Idle"
    local justActed = InputManager.intents.jumpPressed or InputManager.intents.sprintPressed
    if not isIdle or idleTick() or justActed then
        Sensor.update(dt, InputManager.intents, EngineSync.data)
        SensorExt.updateLedgeHang(dt, InputManager.intents, EngineSync.data)
        StateManager.update(dt, EngineSync.data, InputManager.intents)
    end

    local debugOn = Settings.debugMode()
    if debugOn then
        if debugTick() then
            -- Third line: roll tap count and arm state, so an arming
            -- failure is visible instead of silent.
            DebugHUD.update(
                StateManager.getActiveStateName(),
                Sensor.getDebugString(),
                AirborneState.getRollDebug()
            )
        end
    elseif debugWasEnabled then
        -- Turned off mid-session - tear the HUD down rather than leaving
        -- a frozen readout on screen.
        DebugHUD.destroy()
    end
    debugWasEnabled = debugOn
end

return {
    engineHandlers = {
        onInit = onInit,
        onActive = onActive,
        -- onUpdate, NOT onFrame. onUpdate is paused-aware; onFrame runs even
        -- while the world is paused. Two reasons this matters:
        --
        -- 1. CORRECTNESS. global/flow_amf_backend.lua drives the Vault and
        --    Mantle tweens from its own onUpdate. With this side on onFrame
        --    the two halves disagreed about pause: pausing mid-vault froze
        --    the global tween while this side's timer kept counting, so
        --    VaultState:update hit its duration, exited, and fired
        --    FLOW_Vault_Cancel on a tween that never reached progress >= 1.0
        --    - the "vault comes up short" failure COMPLETION_GRACE exists to
        --    prevent, which no grace value could have fixed because the two
        --    clocks were simply different.
        --
        -- 2. COST. Menus, inventory, dialogue and barter are a large share of
        --    real playtime, and none of the sensor raycasts, engine calls or
        --    state ticks need to happen during them.
        --
        -- Nothing here needs to run while paused: FLOW writes no per-frame
        -- controls (that is what would justify onFrame, and is why
        -- surfAnimations keeps its control writes there). core/input.lua's
        -- I.UI.getMode() guard still covers UI modes that do NOT pause.
        --
        -- dt is now simulation time rather than frame time, so state timers
        -- respect the game's time scaling.
        onUpdate = onUpdate
    }
}
