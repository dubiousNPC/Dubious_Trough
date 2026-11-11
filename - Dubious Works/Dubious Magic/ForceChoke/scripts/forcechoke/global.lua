---@omw-context global
--[[
    ForceChoke / global.lua   (orchestrator)

    Owns the state machine and everything global-only: stat writes,
    paralysis, teleports.

      IDLE    --(player casts Force Choke at an NPC)--> HOLDING
      HOLDING --(sheathe spell)-----------------------> IDLE
      HOLDING --(player casts it again)--> THROWN --> land --> IDLE
      HOLDING --(cast fails)-------------------------> HOLDING

]]--

local core  = require('openmw.core')
local types = require('openmw.types')
local util  = require('openmw.util')

local S = require('scripts.forcechoke.shared')
local T = S.TUNING

-- ============================================================
-- TARGET SCRIPT ATTACHMENT
-- ============================================================
local TARGET_SCRIPT = 'scripts/forcechoke/target.lua'

local state

local function attachTarget(target)
    if target:hasScript(TARGET_SCRIPT) then
        target:sendEvent('ForceChoke_Grab')
    else
        target:addScript(TARGET_SCRIPT, { grab = true })
    end
end

local function onDetachRequest(data)
    local actor = data and data.actor
    if not (actor and actor:isValid()) then return end
    if state.active and actor == state.target then return end
    if actor:hasScript(TARGET_SCRIPT) then
        actor:removeScript(TARGET_SCRIPT)
    end
end

-- ============================================================
-- STATE
-- ============================================================
state = {
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
    target:sendEvent('ForceChoke_Damage', { fatigue = amount })
end

local function damageHealth(target, amount)
    target:sendEvent('ForceChoke_Damage', { health = amount })
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
    attachTarget(target)
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

    local away = target.position - player.position
    away = util.vector3(away.x, away.y, 0)
    if away:length() < 1 then
        away = player.rotation * util.vector3(0, 1, 0)
        away = util.vector3(away.x, away.y, 0)
    end
    away = away:normalize()

    state.thrown = true
    clearHold(target)   -- a paralyzed actor should not stay rigid mid-flight
    target:sendEvent('ForceChoke_Throw', {
        dir       = util.vector3(away.x, away.y, T.throwVerticalFactor):normalize(),
        magnitude = T.throwSpeed,
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
local function onCastRequest(data)
    if not data then return end

    local player, target = data.player, data.target
    if not (player and player:isValid() and target and target:isValid()) then return end
    if not types.Player.objectIsInstance(player) then return end

    -- NPCs only, per the design. Also excludes the caster and corpses.
    if not types.NPC.objectIsInstance(target) then return end
    if target == player then return end
    if types.Actor.stats.dynamic.health(target).current <= 0 then return end

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
        ForceChoke_Detach       = onDetachRequest,
    },
}
