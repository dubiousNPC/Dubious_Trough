---@omw-context global
--[[
    ForceChoke / global.lua   (orchestrator)

    Owns the state machine and everything global-only: stat writes,
    paralysis, teleports.

      IDLE    --(player casts Force Choke at an NPC)--> HOLDING
      HOLDING --(sheathe spell)-----------------------> IDLE
      HOLDING --(player casts it again)--> THROWN --> land --> IDLE
      HOLDING --(cast fails)-------------------------> HOLDING

    Record creation is NOT here. load.lua declares the effect and both spells
    through openmw.content with fixed ids, so this file names them directly.
    Gone with the old runtime-record approach: makeSpell, ensureRecords, the
    cached ids in save state, and the ForceChoke_SpellId handshake event.

    Magicka and the success roll are NOT here either. player.lua reacts to a
    cast the engine already resolved successfully, so a failed cast never
    reaches this file -- that is the "grip slips" outcome, delivered by the
    engine's own failure sound.
]]--

local core  = require('openmw.core')
local types = require('openmw.types')
local util  = require('openmw.util')

local S = require('scripts.forcechoke.shared')
local T = S.TUNING

-- ============================================================
-- STATE
-- ============================================================
local state = {
    active      = false,
    player      = nil,
    target      = nil,
    lastRefresh = 0,
    thrown      = false,
}

local function clearState()
    state.active = false
    state.thrown = false
    state.target = nil
    state.player = nil
end

-- Global scripts have no `ui` module, so messages are handed to player.lua.
-- This used to send 'Ui_ShowMessage', which was an SF+ INTERNAL convention
-- handled in magexp_player.lua. Once the SF+ dependency was dropped nothing
-- was left listening and every message this mod produced was discarded.
local function notify(player, msg)
    if player and player:isValid() then
        player:sendEvent('ForceChoke_Notify', { message = msg })
    end
end

-- ============================================================
-- PARALYSIS
-- ============================================================
local function applyHold(target)
    types.Actor.activeSpells(target):add({
        id                = S.HOLD_SPELL_ID,
        effects           = { 0 },
        caster            = state.player,
        ignoreResistances = true,
        ignoreReflect     = true,
    })
end

--- Remove every instance of the hold paralysis this mod applied.
local function clearHold(target)
    if not (target and target:isValid()) then return end

    local active = types.Actor.activeSpells(target)
    local doomed = {}
    for _, spell in pairs(active) do
        if spell.id == S.HOLD_SPELL_ID and spell.temporary then
            doomed[#doomed + 1] = spell.activeSpellId
        end
    end
    -- Collected first, removed second: mutating the list while iterating it
    -- is how an entry gets skipped.
    for _, id in ipairs(doomed) do
        active:remove(id)
    end
end

-- ============================================================
-- STAT DAMAGE
-- ============================================================
local function damageFatigue(target, amount)
    local f = types.Actor.stats.dynamic.fatigue(target)
    f.current = math.max(0, f.current - amount)
end

local function damageHealth(target, amount)
    local h = types.Actor.stats.dynamic.health(target)
    h.current = h.current - amount
end

-- ============================================================
-- STATE TRANSITIONS
-- ============================================================
local function endChoke()
    if state.target and state.target:isValid() then
        clearHold(state.target)
        state.target:sendEvent('ForceChoke_Clear')
    end
    if state.player and state.player:isValid() then
        state.player:sendEvent('ForceChoke_HoldEnd')
    end
    clearState()
end

local function beginChoke(player, target)
    if state.active then endChoke() end

    state.active      = true
    state.thrown      = false
    state.player      = player
    state.target      = target
    state.lastRefresh = core.getSimulationTime()

    applyHold(target)
    target:sendEvent('ForceChoke_Grab')
    player:sendEvent('ForceChoke_HoldStart')
end

--- Sheathe-spell: collapse the target, damage fatigue, done.
local function onDropRequest()
    if not state.active or state.thrown then return end

    local target = state.target
    if target and target:isValid() then
        clearHold(target)
        damageFatigue(target, T.dropFatigueDamage)
        target:sendEvent('ForceChoke_Drop')
    end
    if state.player and state.player:isValid() then
        state.player:sendEvent('ForceChoke_HoldEnd')
    end

    -- The DROP pose is left running deliberately: it settles on its collapsed
    -- frame and is replaced when the actor is next grabbed, or cleared on
    -- load. Sending Clear here would snap them upright on landing.
    clearState()
end

--- A second successful cast while holding: fling the target away.
local function onThrowRequest()
    if not state.active or state.thrown then return end

    local player, target = state.player, state.target
    if not (player and player:isValid() and target and target:isValid()) then
        endChoke()
        return
    end

    -- Away from the player, flattened, then re-lifted so the throw always
    -- carries upward regardless of where the player is looking.
    local away = target.position - player.position
    away = util.vector3(away.x, away.y, 0)
    if away:length() < 1 then
        -- Standing exactly on top of the target: fall back to facing.
        --
        -- Previously this was util.vector3(math.cos(yaw), math.sin(yaw), 0),
        -- which is wrong on two counts -- OpenMW's yaw is a compass bearing
        -- (0 = +Y) so the components are swapped, and the sign convention is
        -- not the trig one either. Rotating the unit forward vector asks the
        -- engine for its own answer and cannot drift from it.
        away = player.rotation * util.vector3(0, 1, 0)
        away = util.vector3(away.x, away.y, 0)
    end
    away = away:normalize()

    state.thrown = true
    clearHold(target)   -- a paralyzed actor should not stay rigid mid-flight
    target:sendEvent('ForceChoke_Throw', {
        dir       = util.vector3(away.x, away.y, T.throwVerticalFactor):normalize(),
        magnitude = T.throwMagnitude,
    })
    player:sendEvent('ForceChoke_HoldEnd')
end

--- One integration step of the throw: only global scripts may teleport.
local function onThrowStep(data)
    if not (data and data.actor and data.actor:isValid()) then return end
    data.actor:teleport(data.actor.cell, data.nextPos, { rotation = data.rotation })
    data.actor:sendEvent('ForceChoke_StepDone')
end

--- Landed, or died mid-flight. Either way the throw is over.
local function onLanded(data)
    local target = data and data.actor
    if target and target:isValid() and not (data and data.died) then
        damageFatigue(target, T.throwFatigueDamage)
        damageHealth(target, T.throwHealthDamage)
    end
    clearState()
end

-- ============================================================
-- CAST -> GRAB
-- ============================================================
--- Raised by player.lua once the engine resolved a SUCCESSFUL cast and the
--- deferred crosshair read found an NPC. Everything security-relevant is
--- re-checked here regardless: a global handler must not trust a payload.
local function onCastRequest(data)
    if not data then return end

    local player, target = data.player, data.target
    if not (player and player:isValid() and target and target:isValid()) then return end
    if not types.Player.objectIsInstance(player) then return end

    -- NPCs only, per the design. Also excludes the caster and corpses.
    if not types.NPC.objectIsInstance(target) then return end
    if target == player then return end
    if types.Actor.stats.dynamic.health(target).current <= 0 then return end

    -- Range is re-derived rather than trusted: the payload could be stale by
    -- a frame, and player.lua measures from the CAMERA while the grip is
    -- maintained from the PLAYER. The reported reach is accepted as an upper
    -- bound -- Telekinesis legitimately extends it -- but clamped, so a stale
    -- or forged payload cannot grant unlimited range.
    local reach = math.min(tonumber(data.reach) or T.castRange, T.maxReach)
    if reach < T.castRange then reach = T.castRange end
    if (target.position - player.position):length() > reach then
        notify(player, "The grip closes on nothing.")
        return
    end

    beginChoke(player, target)
end

-- ============================================================
-- MAINTENANCE
-- ============================================================
-- Throttled to holdRefreshInterval rather than running every frame: this only
-- refreshes a multi-second paralysis and checks a distance, neither of which
-- needs frame resolution.
local function onUpdate()
    if not state.active or state.thrown then return end

    local t = core.getSimulationTime()
    if t - state.lastRefresh < T.holdRefreshInterval then return end
    state.lastRefresh = t

    local player, target = state.player, state.target
    if not (player and player:isValid() and target and target:isValid()) then
        endChoke()
        return
    end
    if types.Actor.stats.dynamic.health(target).current <= 0 then
        endChoke()
        return
    end
    if (target.position - player.position):length() > T.maxHoldRange then
        onDropRequest()
        return
    end

    applyHold(target)
end

-- ============================================================
-- LIFECYCLE
-- ============================================================
-- No onSave/onLoad payload: there is nothing left worth persisting now that
-- record ids are fixed. A choke in progress is deliberately NOT restored --
-- target.lua's own onLoad cancels every ForceChoke pose, so the actor comes
-- back free rather than stranded in a Scripted-priority hold.
local function onPlayerAdded(player)
    local spells = types.Actor.spells(player)
    if not spells[S.SPELL_ID] then
        spells:add(S.SPELL_ID)
    end
end

return {
    engineHandlers = {
        onUpdate      = onUpdate,
        onPlayerAdded = onPlayerAdded,
        onLoad        = clearState,
        onNewGame     = clearState,
    },
    eventHandlers = {
        ForceChoke_CastRequest  = onCastRequest,
        ForceChoke_DropRequest  = onDropRequest,
        ForceChoke_ThrowRequest = onThrowRequest,
        ForceChoke_ThrowStep    = onThrowStep,
        ForceChoke_Landed       = onLanded,
    },
}
