-- ============================================================
-- ForceChoke — GLOBAL (orchestrator)
--
-- Owns the state machine and everything that is global-only:
-- record creation, stat writes, paralysis, teleports.
--
--   IDLE --(player casts Force Choke at an NPC)--> HOLDING
--   HOLDING --(sheathe-spell key)--> drop      --> IDLE
--   HOLDING --(player casts it again)--> THROWN --> land --> IDLE
--   HOLDING --(cast fails)--> HOLDING (engine already spent the magicka)
--
-- NO FRAMEWORK DEPENDENCY
-- -----------------------
-- ForceChoke once required Spell Framework Plus, which owned the projectile,
-- the collision, the cast's magicka and the hit event this file listened to.
-- That dependency is gone, and so is the hand-rolled replacement for it:
--
--   projectile + collision -> nothing. There is no bolt. The target is
--                             whatever the player is looking at, read from
--                             SharedRay in player.lua and sent here as
--                             ForceChoke_CastRequest.
--   magicka + success roll -> the ENGINE. player.lua reacts to a real cast
--                             via I.SkillProgression instead of intercepting
--                             a key, so magicka, the success roll, the cast
--                             animation, the VFX and skill progression are
--                             all vanilla behaviour. Nothing in this file
--                             charges or rolls anything any more.
--   hit event              -> onCastRequest().
--
-- The trade is honest: an instant hitscan grab instead of a travelling bolt.
-- For a telekinetic grip that arguably reads better anyway, and it removes a
-- hard dependency plus a load-order requirement.
-- ============================================================

local core    = require('openmw.core')
local world   = require('openmw.world')
local types   = require('openmw.types')
local util    = require('openmw.util')
local I       = require('openmw.interfaces')

local S = require('scripts.forcechoke.shared')
local T = S.TUNING

-- ============================================================
-- RECORDS
-- ============================================================
-- Two records, created once and cached across saves:
--   chokeSpellId  - the castable spell. Paralyze/Target, so the engine
--                   derives sensible cast and hit VFX from the paralyze
--                   mgef, and trains Alteration (paralyze's school).
--   holdSpellId   - the paralysis actually maintained during the hold.
--                   Separate from the castable spell so refreshing the
--                   hold never re-triggers the cast's own effects.
local chokeSpellId = nil
local holdSpellId  = nil

local function makeSpell(name, cost, duration)
    local ok, rec = pcall(function()
        return world.createRecord(core.magic.spells.createRecordDraft({
            name = name,
            type = core.magic.SPELL_TYPE.Spell,
            cost = cost,
            effects = {
                {
                    id           = "paralyze",
                    range        = core.magic.RANGE.Target,
                    area         = 0,
                    magnitudeMin = 1,
                    magnitudeMax = 1,
                    duration     = duration,
                },
            },
        }))
    end)
    if ok and rec and rec.id then return rec.id end
    print("[ForceChoke] WARNING: could not create record '" .. name .. "': " .. tostring(rec))
    return nil
end

local function ensureRecords()
    if not (chokeSpellId and core.magic.spells.records[chokeSpellId]) then
        chokeSpellId = makeSpell(S.SPELL_NAME, S.SPELL_COST, 1)
        if chokeSpellId then print("[ForceChoke] Spell record: " .. chokeSpellId) end
    end
    if not (holdSpellId and core.magic.spells.records[holdSpellId]) then
        holdSpellId = makeSpell(S.HOLD_SPELL_NAME, 0, T.holdParalyzeSeconds)
    end
end

local function grantSpell(player)
    if not chokeSpellId then return end
    pcall(function()
        local spells = types.Actor.spells(player)
        if not spells[chokeSpellId] then spells:add(chokeSpellId) end
    end)
    -- The record is created here, so player.lua cannot know its id until told.
    -- Without it the selected-spell check can never match and casting is dead.
    pcall(function()
        player:sendEvent('ForceChoke_SpellId', { spellId = chokeSpellId })
    end)
end

-- ============================================================
-- STATE
-- ============================================================
local state = {
    active     = false,
    player     = nil,
    target     = nil,
    lastRefresh = 0,
    thrown     = false,
}

-- Global scripts have no `ui` module, so messages are handed to player.lua.
-- This used to send 'Ui_ShowMessage' -- an SF+ INTERNAL convention, handled
-- in magexp_player.lua. When SF+ was dropped nothing was left listening and
-- every message this mod produced was silently discarded.
local function notify(player, msg)
    if player and player:isValid() then
        pcall(function() player:sendEvent('ForceChoke_Notify', { message = msg }) end)
    end
end

-- ============================================================
-- PARALYSIS
-- ============================================================
local function applyHold(target)
    if not holdSpellId then return end
    pcall(function()
        types.Actor.activeSpells(target):add({
            id                = holdSpellId,
            effects           = { 0 },
            name              = S.HOLD_SPELL_NAME,
            caster            = state.player,
            ignoreResistances = true,
            ignoreReflect     = true,
        })
    end)
end

-- Remove every instance of the hold paralysis we applied. Anything we
-- cannot remove expires on its own within holdParalyzeSeconds, so a
-- failure here degrades to a short stun rather than a permanent one.
local function clearHold(target)
    if not (target and target:isValid() and holdSpellId) then return end
    pcall(function()
        local active = types.Actor.activeSpells(target)
        local doomed = {}
        for _, spell in pairs(active) do
            if spell.id == holdSpellId and spell.temporary then
                doomed[#doomed + 1] = spell.activeSpellId
            end
        end
        -- Collected first, removed second: mutating the list while
        -- iterating it is asking for a skipped entry.
        for _, id in ipairs(doomed) do
            pcall(function() active:remove(id) end)
        end
    end)
end

-- ============================================================
-- STAT DAMAGE
-- ============================================================
local function damageFatigue(target, amount)
    pcall(function()
        local f = types.Actor.stats.dynamic.fatigue(target)
        f.current = math.max(0, f.current - amount)
    end)
end

local function damageHealth(target, amount)
    pcall(function()
        local h = types.Actor.stats.dynamic.health(target)
        h.current = h.current - amount
    end)
end

-- ============================================================
-- CAST COST / SUCCESS  --  DELIBERATELY ABSENT
-- ============================================================
-- There is no castChance(), no gmst() helper and no attemptCast() here any
-- more. An earlier revision reproduced Morrowind's cast formula
--   (2*skill - cost + 0.2*willpower + 0.1*luck) * fatigueTerm
-- and charged magicka by hand. All of it is now the engine's job:
-- player.lua only hears about a cast that already SUCCEEDED, which means
-- magicka is spent, the roll is the real one, and the school is trained.
--
-- The old code also hardcoded Mysticism as the school. Force Choke is built
-- on vanilla paralyze, which is ALTERATION, so the roll was reading the
-- wrong skill entirely. player.lua now derives the school from the effect
-- record instead of naming it.
--
-- A failed cast never reaches this file. That is the "grip slips" outcome,
-- delivered by the engine's own failure sound and message.

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
    state.active = false
    state.thrown = false
    state.target = nil
    state.player = nil
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

--- Sheathe-spell key: collapse the target, damage fatigue, done.
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

    -- The pose is left on the target deliberately: fchokedrop settles
    -- into its collapsed frame and is cleared when the actor next
    -- gets grabbed, or on load. Clearing it here would snap them
    -- upright the instant they hit the floor.
    state.active = false
    state.target = nil
    state.player = nil
end

--- Second successful cast while holding: fling the target away.
local function onThrowRequest()
    if not state.active or state.thrown then return end
    local player, target = state.player, state.target
    if not (player and player:isValid() and target and target:isValid()) then
        endChoke()
        return
    end

    -- No affordability or success check here: this handler is only reached
    -- because the engine already resolved a successful cast. A failed one
    -- never gets this far, and the hold survives so the player can try
    -- again -- which is exactly the intended "grip slips" behaviour.

    -- Away from the player, flattened then re-lifted so the throw
    -- always carries upward regardless of where the player is looking.
    local away = target.position - player.position
    away = util.vector3(away.x, away.y, 0)
    if away:length() < 1 then
        away = util.vector3(math.cos(player.rotation:getYaw()),
                            math.sin(player.rotation:getYaw()), 0)
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
    pcall(function()
        data.actor:teleport(data.actor.cell, data.nextPos, { rotation = data.rotation })
    end)
    data.actor:sendEvent('ForceChoke_StepDone')
end

--- Landed: the heavier fatigue hit plus the extra health damage.
local function onLanded(data)
    local target = data and data.actor
    if target and target:isValid() then
        damageFatigue(target, T.throwFatigueDamage)
        damageHealth(target, T.throwHealthDamage)
    end
    state.active = false
    state.thrown = false
    state.target = nil
    state.player = nil
end

-- ============================================================
-- CAST -> GRAB
-- ============================================================
--- Raised by player.lua once the engine has resolved a SUCCESSFUL cast of
--- Force Choke and the deferred crosshair read found an NPC. Everything
--- security-relevant is re-checked here regardless, because a global handler
--- must not trust an event payload.
local function onCastRequest(data)
    if state.active then return end
    if not data then return end

    local player, target = data.player, data.target
    if not (player and player:isValid() and target and target:isValid()) then return end
    if not types.Player.objectIsInstance(player) then return end

    -- NPCs only, per the design. Also excludes the caster and corpses.
    local isNPC = false
    pcall(function() isNPC = types.NPC.objectIsInstance(target) end)
    if not isNPC or target == player then return end
    if types.Actor.stats.dynamic.health(target).current <= 0 then return end

    -- Range is re-derived rather than trusted: the payload could be stale by
    -- a frame, and player.lua measures from the CAMERA while the grip is
    -- maintained from the PLAYER. The reach it used is accepted as an upper
    -- bound (Telekinesis legitimately extends it) but clamped, so a forged
    -- or stale payload cannot grant unlimited range.
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
-- Throttled to holdRefreshInterval (1s) rather than running every
-- frame: this only refreshes a multi-second paralysis and checks a
-- distance, neither of which needs frame resolution.
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
local function init(saved)
    if saved then
        chokeSpellId = saved.chokeSpellId
        holdSpellId  = saved.holdSpellId
    end
    state.active = false
    state.thrown = false
    state.target = nil
    state.player = nil
    ensureRecords()
end

return {
    engineHandlers = {
        onUpdate  = onUpdate,
        onNewGame = function() init(nil) end,
        onLoad    = function(data) init(data) end,
        onSave    = function()
            return { chokeSpellId = chokeSpellId, holdSpellId = holdSpellId }
        end,
        onActorActive = function(actor)
            local ok, isPlayer = pcall(types.Player.objectIsInstance, actor)
            if ok and isPlayer then grantSpell(actor) end
        end,
    },
    eventHandlers = {
        ForceChoke_CastRequest    = onCastRequest,
        ForceChoke_DropRequest    = onDropRequest,
        ForceChoke_ThrowRequest   = onThrowRequest,
        ForceChoke_ThrowStep      = onThrowStep,
        ForceChoke_Landed         = onLanded,
    },
}
