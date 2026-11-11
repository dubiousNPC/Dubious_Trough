---@omw-context player
--[[
    ForceChoke / player.lua

    Jobs:
      1. Hold the player's upper-body "fchoke1" pose while a choke is active.
      2. Detect that the player CAST Force Choke, and turn that into a grab or
         a throw depending on whether a grip is already running.
      3. Acquire the target under the crosshair via SharedRay.
      4. Show messages -- global.lua has no ui module.

]]--

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
local P = require('scripts.forcechoke.poses')
local T = S.TUNING

-- ============================================================
-- STATE
-- ============================================================
local holding     = false
local posePlaying = false
local lastDropAt  = -1

local DEDUPE_WINDOW = 0.15

-- ============================================================
-- PLAYER POSE
-- ============================================================
local function startPose()
    if posePlaying then return end
    if not anim.hasGroup(self, S.GROUPS.CAST) then return end
    anim.playBlended(self, S.GROUPS.CAST, P.playerPoseOptions())
    posePlaying = true
end

local function stopPose()
    if not posePlaying then return end
    posePlaying = false
    anim.cancel(self, S.GROUPS.CAST)
end

-- ============================================================
-- REACH
-- ============================================================
local function castReach()
    local reach = (core.getGMST("iMaxActivateDist") or 192)
                + camera.getThirdPersonDistance()

    local tk = types.Actor.activeEffects(self):getEffect(core.magic.EFFECT_TYPE.Telekinesis)
    if tk then
        reach = reach + tk.magnitude * 22
    end

    if reach < T.castRange then reach = T.castRange end
    return reach
end

-- ============================================================
-- TARGET ACQUISITION
-- ============================================================
local function lookedAtNPC(reach)
    local result = I.SharedRay.getUnclipped()
    if not result or not result.hit then return nil end

    local obj = result.hitObject
    if not obj or not obj:isValid() then return nil end
    if result.distance and result.distance > reach then return nil end
    if not types.NPC.objectIsInstance(obj) then return nil end
    if obj == self.object then return nil end
    return obj
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

local school = core.magic.effects.records[S.EFFECT_ID].school

I.SkillProgression.addSkillUsedHandler(function(skillId, params)
    if skillId ~= school then return end
    if params.useType ~= I.SkillProgression.SKILL_USE_TYPES.Spellcast_Success then return end

    local spell = types.Player.getSelectedSpell(self)
    if not spell then return end

    local match = false
    for _, eff in ipairs(spell.effects) do
        if eff.id == S.EFFECT_ID then
            match = true
            break
        end
    end
    if not match then return end

    if holding then
        core.sendGlobalEvent('ForceChoke_ThrowRequest', { player = self.object })
        return
    end

    async:newUnsavableSimulationTimer(0.05, doGrab)
end)

-- ============================================================
-- SHEATHE -> DROP
-- ============================================================
local function requestDrop()
    if not holding then return end
    local t = core.getRealTime()
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

local function onNotify(data)
    if data and data.message then ui.showMessage(data.message) end
end

-- ============================================================
-- CONSOLE
-- ============================================================
local function onConsoleCommand(mode, command)
    local cmd = command:lower():gsub("^lua%s+", ""):gsub("^%s+", ""):gsub("%s+$", "")
    if cmd ~= "forcechoke_give" then return end
    types.Player.spells(self):add(S.SPELL_ID)
    ui.printToConsole("You have learned the spell Force Choke.", ui.CONSOLE_COLOR.Success)
end

-- ============================================================
-- REGISTRATION
-- ============================================================
local registered = false
local function onInit()
    I.SharedRay.requestDistance(T.maxReach)
    if registered then return end
    registered = true
    input.registerTriggerHandler('ToggleSpell', async:callback(requestDrop))
end

local function onInputAction(id)
    if id == input.ACTION.ToggleSpell then
        requestDrop()   -- itself a no-op unless holding
    end
end

return {
    engineHandlers = {
        onInit           = onInit,
        onLoad           = onInit,
        onInputAction    = onInputAction,
        onConsoleCommand = onConsoleCommand,
    },
    eventHandlers = {
        ForceChoke_HoldStart = onHoldStart,
        ForceChoke_HoldEnd   = onHoldEnd,
        ForceChoke_Notify    = onNotify,
    },
}
