-- ============================================================
-- ForceChoke — PLAYER
--
-- Jobs:
--   1. Hold the player's upper-body "fchoke1" pose while a choke is active
--      (playBlended needs SelfObject, so the player's own pose cannot be
--      driven from global.lua).
--   2. Detect that the player CAST Force Choke, and turn that into either a
--      grab or a throw depending on whether a choke is already running.
--   3. Acquire the target under the crosshair via SharedRay.
--   4. Show messages. global.lua cannot: ui is player-side only.
--
-- CAST DETECTION — why this is not a keybind
-- -----------------------------------------
-- Earlier revisions bound the attack key directly and then re-implemented
-- the magicka charge and the success roll in global.lua. That was wrong on
-- four counts, all of which this file now avoids by letting the ENGINE cast
-- the spell and only reacting once it has:
--
--   * skill progression   - a hand-rolled cast never trains the school.
--                           I.SkillProgression fires only on a successful
--                           cast, so reacting to it trains for free.
--   * the success roll    - the engine already rolls it, exactly, using the
--                           real formula. A failed cast simply never calls
--                           this handler, which IS the "grip slips" outcome.
--   * magicka             - charged by the engine, including on failure.
--   * cast anim + VFX     - the engine plays them, because a real spell was
--                           really cast.
--
-- Both the grab and the throw are genuine casts of the same spell. With a
-- spell readied the attack key IS the cast key, so the controls are what the
-- design asked for; they are just no longer intercepted.
--
-- THE 0.05s DEFERRAL
-- ------------------
-- The crosshair ray is read one timer tick after the cast, not inline. Two
-- independent reasons, and the reference mods hit both:
--   * Banishing calls its variable viewportBugfixDelay -- camera/viewport
--     state is not yet settled at the instant the skill-used handler runs.
--   * SharedRay's cast is async and its result lags a frame, so an inline
--     read returns what was under the crosshair BEFORE the cast.
-- ============================================================

local self   = require('openmw.self')
local core   = require('openmw.core')
local input  = require('openmw.input')
local anim   = require('openmw.animation')
local types  = require('openmw.types')
local ui     = require('openmw.ui')
local async  = require('openmw.async')
local camera = require('openmw.camera')
local I      = require('openmw.interfaces')

local S = require('scripts.forcechoke.shared')
local T = S.TUNING

-- ============================================================
-- STATE
-- ============================================================
local holding      = false  -- is a choke active (per global.lua)?
local posePlaying  = false
local chokeSpellId = nil    -- told to us by global.lua, which owns the record
local lastDropAt   = -1

-- Set at init: true if an .omwaddon in the load order provides the custom
-- marker effect, in which case spellmaker variants work too.
local markerEffectAvailable = false

-- Guard against re-entering our own handler if this file ever calls
-- skillUsed from inside it. Utility Spells uses the identical pattern.
local skipSkillUse = false

local DEDUPE_WINDOW = 0.15

local function now()
    local ok, t = pcall(core.getRealTime)
    if ok and type(t) == "number" then return t end
    return 0
end

-- ============================================================
-- PLAYER POSE
-- ============================================================
local function startPose()
    if posePlaying then return end
    posePlaying = true
    pcall(function()
        I.AnimationController.playBlendedAnimation(
            S.GROUPS.CAST, S.playerPoseOptions(S.GROUPS.CAST))
    end)
end

local function stopPose()
    if not posePlaying then return end
    posePlaying = false
    pcall(function()
        I.AnimationController.playBlendedAnimation(S.GROUPS.CAST, {
            startKey    = S.START_KEY[S.GROUPS.CAST] or "start",
            stopKey     = S.STOP_KEY[S.GROUPS.CAST] or "stop",
            priority    = anim.PRIORITY.Default,
            blendMask   = S.UPPERBODY_BLEND_MASK,
            loops       = 0,
            autoDisable = true,
        })
    end)
end

-- ============================================================
-- REACH
-- ============================================================
-- Vanilla reach rules, matching Banishing: activation distance plus the
-- third-person camera offset, extended by any active Telekinesis. A flat
-- constant would make Telekinesis useless for this spell, which is the kind
-- of quiet inconsistency that makes a spell feel bolted-on.
local function castReach()
    local reach = T.castRange
    pcall(function()
        local base = core.getGMST("iMaxActivateDist") or 192
        local r = base + camera.getThirdPersonDistance()
        local tk = types.Actor.activeEffects(self):getEffect(core.magic.EFFECT_TYPE.Telekinesis)
        if tk and tk.magnitude then
            r = r + tk.magnitude * 22
        end
        -- castRange is a floor, not a cap: the spell should never reach less
        -- far than a plain activation, and Telekinesis only ever adds.
        if r > reach then reach = r end
    end)
    return reach
end

-- SharedRay clips its shared cast to the longest distance anyone asked for.
-- Requesting the boosted reach up front keeps a target detectable at full
-- range instead of being clipped to the service default.
if I.SharedRay and I.SharedRay.requestDistance then
    pcall(I.SharedRay.requestDistance, castReach())
end

-- ============================================================
-- TARGET ACQUISITION
-- ============================================================
local function lookedAtNPC(reach)
    if not (I.SharedRay and I.SharedRay.get) then return nil end
    local result = I.SharedRay.get()
    if not result or not result.hit then return nil end

    local obj = result.hitObject
    -- SharedRay validates hitObject at delivery, but delivery was last frame;
    -- touching an object invalidated since then raises.
    if not obj or not obj:isValid() then return nil end
    if result.distance and result.distance > reach then return nil end

    local isNPC = false
    pcall(function() isNPC = types.NPC.objectIsInstance(obj) end)
    if not isNPC or obj == self.object then return nil end
    return obj
end

-- ============================================================
-- SPELL MATCHING
-- ============================================================
--- Is `spell` a Force Choke? See shared.lua MARKER_EFFECT for why this is
--- effect-based when a plugin supplies the marker and id-based otherwise.
local function isChokeSpell(spell)
    if not spell then return false end
    if markerEffectAvailable then
        for _, effect in pairs(spell.effects or {}) do
            local id = effect.id or (effect.effect and effect.effect.id)
            if id == S.MARKER_EFFECT then return true end
        end
        return false
    end
    return chokeSpellId ~= nil and spell.id == chokeSpellId
end

--- The skill a successful cast of `spell` trains, derived from the effect's
--- own school rather than hardcoded. Force Choke is built on vanilla
--- paralyze, which is Alteration -- an earlier revision assumed Mysticism
--- and would have filtered out every real cast.
local function schoolOf(spell)
    local school = nil
    pcall(function()
        for _, effect in pairs(spell.effects or {}) do
            local id = effect.id or (effect.effect and effect.effect.id)
            local rec = id and core.magic.effects.records[id]
            if rec and rec.school then
                school = rec.school
                break
            end
        end
    end)
    return school
end

-- ============================================================
-- CAST -> GRAB / THROW
-- ============================================================
local function doGrab()
    local reach = castReach()
    local target = lookedAtNPC(reach)
    if not target then
        ui.showMessage("The grip closes on nothing.")
        return
    end
    core.sendGlobalEvent('ForceChoke_CastRequest', {
        player = self.object,
        target = target,
        reach  = reach,
    })
end

local function onChokeCast()
    if holding then
        -- Already gripping: this cast is the squeeze-and-throw. No ray, no
        -- deferral -- the target is the one already held, and global.lua
        -- still owns it.
        core.sendGlobalEvent('ForceChoke_ThrowRequest', { player = self.object })
        return
    end
    -- Fresh grab: defer, then read the crosshair. See header.
    async:newUnsavableSimulationTimer(0.05, doGrab)
end

I.SkillProgression.addSkillUsedHandler(function(skillId, params)
    if skipSkillUse then return end
    if core.isWorldPaused() then return end

    local ok, spell = pcall(types.Actor.getSelectedSpell, self)
    if not ok or not isChokeSpell(spell) then return end

    -- useType alone is ambiguous -- Spellcast_Success and
    -- Armor_HitByOpponent are both 0 -- so it only becomes meaningful once
    -- the skill has been confirmed to be this spell's own school.
    if skillId ~= schoolOf(spell) then return end
    local useTypes = I.SkillProgression.SKILL_USE_TYPES
    if params and params.useType and useTypes
       and params.useType ~= useTypes.Spellcast_Success then
        return
    end

    onChokeCast()
end)

-- ============================================================
-- SHEATHE -> DROP
-- ============================================================
-- Still an input handler, because sheathing is not a cast and so never
-- reaches the skill-used path.
local function requestDrop()
    if not holding then return end
    local t = now()
    if t - lastDropAt < DEDUPE_WINDOW then return end
    lastDropAt = t
    core.sendGlobalEvent('ForceChoke_DropRequest', { player = self.object })
end

-- ============================================================
-- EVENTS FROM GLOBAL
-- ============================================================
local function onHoldStart()
    holding = true
    startPose()
end

local function onHoldEnd()
    holding = false
    stopPose()
end

-- global.lua owns the spell record and tells us its id once it exists.
local function onSpellId(data)
    chokeSpellId = data and data.spellId or nil
end

-- global.lua has no ui module; anything it wants to say arrives here.
local function onNotify(data)
    local msg = data and data.message
    if msg then ui.showMessage(msg) end
end

-- ============================================================
-- REGISTRATION
-- ============================================================
local initialised = false
local function onInit()
    if initialised then return end
    initialised = true

    pcall(function()
        markerEffectAvailable = core.magic.effects.records[S.MARKER_EFFECT] ~= nil
    end)
    if markerEffectAvailable then
        print("[ForceChoke] Marker effect '" .. S.MARKER_EFFECT ..
              "' found: spellmaker variants supported.")
    end

    pcall(function()
        input.registerTriggerHandler('ToggleSpell', async:callback(requestDrop))
    end)
end

-- Legacy/engine input path, for builds where the built-in bindings arrive
-- here rather than through the trigger API. The dedupe window collapses a
-- double delivery. Only ToggleSpell is wired now: Use is no longer
-- intercepted at all, since casting is detected properly upstream.
local function onInputAction(id)
    if id == input.ACTION.ToggleSpell then
        requestDrop()   -- itself a no-op unless holding
    end
end

return {
    engineHandlers = {
        onInit        = onInit,
        onLoad        = onInit,
        onInputAction = onInputAction,
    },
    eventHandlers = {
        ForceChoke_HoldStart = onHoldStart,
        ForceChoke_HoldEnd   = onHoldEnd,
        ForceChoke_SpellId   = onSpellId,
        ForceChoke_Notify    = onNotify,
    },
}
