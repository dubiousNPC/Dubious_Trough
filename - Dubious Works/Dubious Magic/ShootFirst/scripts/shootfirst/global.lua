-- ============================================================
-- ShootFirst — GLOBAL Script
--
-- A minimal example damaging projectile spell. This mod does not
-- implement any casting/animation/input logic of its own — that is the
-- job of other mods in this ecosystem:
--
--   * Spell Framework Plus (SF+ / `I.MagExp`) is a HARD requirement.
--     It is the framework that actually turns a cast of this spell into
--     a physical projectile with collision, and it is what fires the
--     `MagExp_CastRequest` / `MagExp_OnMagicHit` events this script
--     listens to. Without SF+ loaded, those events never fire and this
--     spell behaves as an inert vanilla spell (see below).
--
--   * OSSC (Oblivion-Style Spell Casting) is an OPTIONAL mod. OSSC owns
--     the hotkey and the per-school/per-range custom animation
--     selection, and it is OSSC itself that requires SF+, not this mod.
--     ShootFirst does not bind any key and does not drive any
--     animation — it only checks whether OSSC is present, for logging.
--
-- Resulting behavior:
--   - OSSC installed:  pressing OSSC's quick-cast key with ShootFirst
--     selected plays whichever animation group the player has assigned
--     to Destruction/Target spells in OSSC's settings (default:
--     "quickcast" — the same group this mod's packaged animation asset
--     targets). OSSC sends `MagExp_CastRequest` at the animation's
--     release key, SF+ launches the real projectile, and this script
--     adds a BeamFX flourish on cast and on impact.
--   - OSSC not installed: nothing above happens, and that's intended —
--     there is no special hotkey to press. The spell is simply cast the
--     normal way (select it, then attack/cast as with any vanilla
--     spell), using the engine's own default spellcasting animation for
--     a Destruction/Target spell. That vanilla-engine cast path never
--     touches SF+ at all, so it also never produces a physical
--     projectile or a BeamFX flourish — it just applies Fire Damage the
--     ordinary way. This is the "fallback animation similar to regular
--     spellcasting" mentioned in the mod's design notes: there is
--     nothing to build for it, it's simply what happens by default.
-- ============================================================

local core  = require('openmw.core')
local world = require('openmw.world')
local types = require('openmw.types')
local util  = require('openmw.util')
local I     = require('openmw.interfaces')

local BeamFXAdapter = require('scripts.shootfirst.beamfx_adapter')

local SPELL_NAME = "Shoot First"
local SPELL_COST = 12
local MAG_MIN    = 8
local MAG_MAX    = 16

-- ============================================================
-- Hard requirement: Spell Framework Plus
-- ============================================================
-- SF+ is not vendored or reimplemented here — it must be enabled and
-- loaded before ShootFirst.omwscripts in the content list. We only
-- check for it and warn loudly; we never try to work around its
-- absence, since the entire point of this script is to be a thin
-- consumer of SF+'s API.
local function requireSpellFrameworkPlus()
    if I.MagExp then return true end
    print("[ShootFirst] ERROR: Spell Framework Plus (I.MagExp) was not found.")
    print("[ShootFirst] ShootFirst requires SPELL_FRAMEWORK_PLUS.omwscripts")
    print("[ShootFirst] to be enabled and loaded before ShootFirst.omwscripts.")
    return false
end

-- ============================================================
-- Soft check: OSSC (informational only — no behavior depends on this)
-- ============================================================
local function logOssc()
    local hasOssc = false
    pcall(function()
        hasOssc = core.contentFiles.has("Oblivion Style Spell Casting OSSC.omwscripts")
    end)
    if hasOssc then
        print("[ShootFirst] OSSC detected: quick-cast animation routing is available.")
    else
        print("[ShootFirst] OSSC not detected: ShootFirst will use standard vanilla")
        print("[ShootFirst] spellcasting (select + cast). This is expected and fine.")
    end
end

-- ============================================================
-- BeamFX producer registration (optional visual layer)
-- ============================================================
local visuals = BeamFXAdapter.new({
    producerId  = "example.shootfirst.beams",
    displayName = "Shoot First",
})

-- ============================================================
-- Dynamic Spell record (created once, id cached across saves)
-- ============================================================
local shootFirstSpellId = nil

local function ensureSpellRecord()
    if shootFirstSpellId and core.magic.spells.records[shootFirstSpellId] then
        return shootFirstSpellId
    end

    local ok, rec = pcall(function()
        local draft = core.magic.spells.createRecordDraft({
            name = SPELL_NAME,
            type = core.magic.SPELL_TYPE.Spell,
            cost = SPELL_COST,
            effects = {
                {
                    id           = "firedamage",
                    range        = core.magic.RANGE.Target,
                    area         = 0,
                    magnitudeMin = MAG_MIN,
                    magnitudeMax = MAG_MAX,
                    duration     = 1,
                },
            },
        })
        return world.createRecord(draft)
    end)

    if ok and rec and rec.id then
        shootFirstSpellId = rec.id
        print("[ShootFirst] Spell record created: " .. shootFirstSpellId)
    else
        print("[ShootFirst] WARNING: failed to create spell record: " .. tostring(rec))
    end

    return shootFirstSpellId
end

local function ensurePlayerHasSpell(player)
    if not shootFirstSpellId then return end
    local ok = pcall(function()
        local spells = types.Actor.spells(player)
        if not spells[shootFirstSpellId] then
            spells:add(shootFirstSpellId)
        end
    end)
    if not ok then
        print("[ShootFirst] WARNING: could not grant spell to player.")
    end
end

-- ============================================================
-- Cast flash: a short BeamFX bolt drawn along the launch direction.
-- Only ever runs for casts that actually went through SF+ (i.e. via
-- OSSC's quick-cast key, or any other mod that calls
-- `core.sendGlobalEvent('MagExp_CastRequest', ...)`), since that is the
-- only path that produces this event at all.
-- ============================================================
local function playCastFlash(attacker, startPos, direction)
    if not visuals:isAvailable() then return end
    if not attacker or not attacker:isValid() then return end
    local dir = direction:normalize()
    visuals:emit({
        cell         = attacker.cell,
        from         = startPos,
        to           = startPos + dir * 140,
        preset       = "fire",
        radius       = 9,
        duration     = 0.16,
        fadeDuration = 0.12,
    })
end

-- ============================================================
-- Impact flash: a tiny bright BeamFX burst at the hit point.
-- ============================================================
local function playImpactFlash(data)
    if not visuals:isAvailable() then return end
    if not data.hitPos then return end

    local cell = nil
    if data.target and data.target:isValid() then
        cell = data.target.cell
    elseif data.attacker and data.attacker:isValid() then
        cell = data.attacker.cell
    end
    if not cell then return end

    local normal = data.hitNormal
    if not normal or normal:length() < 0.01 then
        normal = util.vector3(0, 0, 1)
    else
        normal = normal:normalize()
    end

    visuals:emit({
        cell         = cell,
        from         = data.hitPos,
        to           = data.hitPos + normal * 16,
        preset       = "fire",
        radius       = 16,
        duration     = 0.22,
        fadeDuration = 0.16,
    })
end

-- ============================================================
-- Event: SF+-wide event bus. SF+'s own global script (magexp_global.lua)
-- also listens to this event and performs the actual launchSpell() call
-- itself — we only listen in to add our BeamFX flourish, filtered to
-- our own spell. We never call I.MagExp.launchSpell ourselves; doing so
-- here would double-launch the projectile.
-- ============================================================
local function onCastRequest(data)
    if not data or data.spellId ~= shootFirstSpellId then return end
    if not data.attacker or not data.attacker:isValid() then return end
    if not data.startPos or not data.direction then return end
    playCastFlash(data.attacker, data.startPos, data.direction)
end

-- ============================================================
-- Event: fired by SF+ on every magic impact, globally. Filter to our
-- own spell before doing anything.
-- ============================================================
local function onMagicHit(data)
    if not data or data.spellId ~= shootFirstSpellId then return end
    playImpactFlash(data)
end

-- ============================================================
-- Lifecycle
-- ============================================================
local function onUpdate()
    visuals:update()
end

local function initialize(savedSpellId)
    if savedSpellId then
        shootFirstSpellId = savedSpellId
    end
    if not requireSpellFrameworkPlus() then return end
    logOssc()
    ensureSpellRecord()
    visuals:reset("init")
end

local function onLoad(data)
    initialize(data and data.shootFirstSpellId)
end

local function onNewGame()
    initialize(nil)
end

local function onSave()
    return { shootFirstSpellId = shootFirstSpellId }
end

local function onActorActive(actor)
    local ok, isPlayer = pcall(types.Player.objectIsInstance, actor)
    if ok and isPlayer then
        ensurePlayerHasSpell(actor)
    end
end

return {
    engineHandlers = {
        onUpdate      = onUpdate,
        onLoad        = onLoad,
        onNewGame     = onNewGame,
        onSave        = onSave,
        onActorActive = onActorActive,
    },
    eventHandlers = {
        MagExp_CastRequest = onCastRequest,
        MagExp_OnMagicHit  = onMagicHit,
    },
}
