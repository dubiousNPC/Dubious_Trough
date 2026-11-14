---@omw-context player
--[[
    whywalk_player.lua -- input, targeting, rider state

    ZERO per-frame handlers. Both reference implementations (Devilish and
    Sturdy Steed) run three: player onFrame + mount onUpdate + global onUpdate.
    The player-side one exists in both purely to poll held movement keys and
    re-send the same control values every frame.

    WHEN NOT MOUNTED THIS FILE COSTS: nothing. No handler runs until a key is
    pressed or the activate trigger fires.
]]

local self   = require('openmw.self')
local core   = require('openmw.core')
local input  = require('openmw.input')
local types  = require('openmw.types')
local async  = require('openmw.async')
local nearby = require('openmw.nearby')
local util   = require('openmw.util')
local I      = require('openmw.interfaces')
local ui     = require('openmw.ui')
local storage = require('openmw.storage')

local shared = require('scripts.WhyWalk.whywalk_shared')

local TUNING = shared.TUNING

local EV = {
    REQUEST_MOUNT   = 'WhyWalk_RequestMount',
    REQUEST_DISMOUNT= 'WhyWalk_RequestDismount',
    CONTROL         = 'WhyWalk_Control',
    MOUNTED         = 'WhyWalk_Mounted',
    DISMOUNTED      = 'WhyWalk_Dismounted',
    MOUNT_REFUSED   = 'WhyWalk_MountRefused',
    PLAYER_SEATED   = 'WhyWalk_PlayerSeated',
    DISMOUNT_START  = 'WhyWalk_DismountStart',
}

local DEBUG = false

-- ---------------------------------------------------------------------------
-- SETTINGS
-- ---------------------------------------------------------------------------
local L10N_CONTEXT   = "WhyWalk"
local SETTINGS_PAGE  = "WhyWalk"
local SETTINGS_GROUP = "SettingsWhyWalkRiding"

I.Settings.registerPage {
    key         = SETTINGS_PAGE,
    l10n        = L10N_CONTEXT,
    name        = "settings_page_name",
    description = "settings_page_description",
}

I.Settings.registerGroup {
    key              = SETTINGS_GROUP,
    page             = SETTINGS_PAGE,
    l10n             = L10N_CONTEXT,
    name             = "riding_group_name",
    description      = "riding_group_description",
    permanentStorage = true,
    order            = -1,          -- above the camera group
    settings = {
        {
            key         = "ALLOW_INTERIORS",
            name        = "riding_interiors_name",
            description = "riding_interiors_description",
            renderer    = "checkbox",
            default     = false,
        },
        {
            key         = "BLACKLIST_IDS",
            name        = "riding_blacklist_name",
            description = "riding_blacklist_description",
            renderer    = "whywalk_textSet_V1",
            default     = {},
            argument    = { lower = true },
        },
    },
}

local ridingSettings = storage.playerSection(SETTINGS_GROUP)

local function allowInteriors()
    return ridingSettings:get("ALLOW_INTERIORS") == true
end

local function blacklistedIds()
    local set = ridingSettings:get("BLACKLIST_IDS")
    if type(set) ~= "table" then return {} end
    return set
end

-- ---------------------------------------------------------------------------
-- STATE
-- ---------------------------------------------------------------------------

local mounted        = false
local freeRiding     = false
local mountType      = nil
local controlsLocked = false
local levitationAdded = false

local held = { forward = false, back = false, left = false, right = false,
               gallop = false }
local lastSent = nil


-- ---------------------------------------------------------------------------
-- PARKOURWIND FLOW
-- ---------------------------------------------------------------------------
local FLOW_OWNER = 'WhyWalk.Core'
local function flowYield(on)
    local F = I.Flow
    if not (F and F.yield and F.resume) then return end
    if on then F.yield(FLOW_OWNER) else F.resume(FLOW_OWNER) end
end

-- ---------------------------------------------------------------------------
-- CONTROL LOCK
-- ---------------------------------------------------------------------------

local function lockControls()
    if controlsLocked then return end
    I.Controls.overrideMovementControls(true)
    controlsLocked = true
end

local function releaseControls()
    if not controlsLocked then return end
    I.Controls.overrideMovementControls(false)
    controlsLocked = false
end

-- ---------------------------------------------------------------------------
-- LEVITATION
-- ---------------------------------------------------------------------------

local function addLevitation()
    if not TUNING.useLevitation or levitationAdded then return end
    types.Actor.activeEffects(self):modify(1, core.magic.EFFECT_TYPE.Levitate)
    levitationAdded = true
end

local function removeLevitation()
    if not levitationAdded then return end
    types.Actor.activeEffects(self):modify(-1, core.magic.EFFECT_TYPE.Levitate)
    levitationAdded = false
end

-- ---------------------------------------------------------------------------
-- CONTROL INTENT
-- ---------------------------------------------------------------------------

local function intentKey(throttle, steer, gallop)
    return tostring(throttle) .. ":" .. tostring(steer) .. ":" .. tostring(gallop)
end

local function sendControl(force)
    if not mounted or freeRiding then return end

    local throttle = 0
    if held.forward and not held.back then throttle = 1
    elseif held.back and not held.forward then throttle = -1 end

    local steer = 0
    if held.left and not held.right then steer = -1
    elseif held.right and not held.left then steer = 1 end

    local key = intentKey(throttle, steer, held.gallop)
    if not force and key == lastSent then return end
    lastSent = key

    core.sendGlobalEvent(EV.CONTROL, {
        player   = self.object,
        throttle = throttle,
        steer    = steer,
        gallop   = held.gallop,
    })
end

-- ---------------------------------------------------------------------------
-- (PERSPECTIVE REPORTING -- REMOVED)
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- TARGETING
-- ---------------------------------------------------------------------------
-- Reading SharedRay issues no cast: the service already casts once per frame
-- for whoever listens. requestDistance only raises the shared ray length.

if I.SharedRay and I.SharedRay.requestDistance then
    I.SharedRay.requestDistance(TUNING.freeRideRange)
end

local function findMountTarget()
    if not (I.SharedRay and I.SharedRay.get) then return nil end
    local result = I.SharedRay.get()
    if not result or not result.hit then return nil end

    local obj = result.hitObject
    if not obj or not obj:isValid() then return nil end
    if result.distance and result.distance > TUNING.freeRideRange then return nil end
    if not types.Creature.objectIsInstance(obj) then return nil end

    if shared.isBlacklisted(obj.recordId, blacklistedIds()) then
        return nil, "blacklisted"
    end

    local mt = shared.getMountType(obj.recordId)
    if mt then return obj, mt, false end
    if TUNING.freeRideEnabled then return obj, nil, true end
    return nil
end

-- ---------------------------------------------------------------------------
-- MOUNT LIFECYCLE (driven by the global script's confirmation)
-- ---------------------------------------------------------------------------

local function onMounted(data)
    mounted    = true
    freeRiding = data and data.freeRide == true
    mountType  = data and data.mountType or nil

    held.forward, held.back = false, false
    held.left, held.right   = false, false
    held.gallop             = false
    lastSent = nil

    flowYield(true)
    lockControls()
    addLevitation()

    self.object:sendEvent('WhyWalk_AnimMounted', {
        mount = data and data.mount, mountType = mountType, freeRide = freeRiding,
        transition = data and data.transition,
    })

    if not freeRiding then sendControl(true) end
end

local function onDismountStart(data)
    self.object:sendEvent('WhyWalk_AnimDismountStart', data or {})
end

local function onDismounted()
    mounted, freeRiding, mountType = false, false, nil
    held.forward, held.back = false, false
    held.left, held.right   = false, false
    held.gallop             = false
    lastSent = nil

    releaseControls()
    removeLevitation()
    flowYield(false)
    self.object:sendEvent('WhyWalk_AnimDismounted', {})
end

local function onMountRefused(data)
    local reason = data and data.reason
    if reason == 'seated' then
        ui.showMessage(core.l10n(L10N_CONTEXT)('msg_seated_refused'))
    elseif reason == 'interior' then
        ui.showMessage(core.l10n(L10N_CONTEXT)('msg_interior_refused'))
    elseif reason == 'notamount' then
        ui.showMessage(core.l10n(L10N_CONTEXT)('msg_not_a_mount'))
    end
end

-- ---------------------------------------------------------------------------
-- INPUT
-- ---------------------------------------------------------------------------

local function hudHidden()
    return I.UI and I.UI.isHudVisible and not I.UI.isHudVisible()
end

-- ---------------------------------------------------------------------------
-- WHERE THE BACK IS
-- ---------------------------------------------------------------------------
-- The rider sits ON the creature, fliers included. Its collision box says
-- little about where its back is (a clannfear's crest, a netch's tentacles),
-- so the drawn, animated mesh is asked instead: rendering rays straight down
-- at the saddle point and a little fore and aft, and the MIDDLE of the hits
-- on the creature itself. Not the highest: a guar's back rises into its neck
-- and a clannfear's into its crest, and the highest of three read 25-30 high
-- on both (measured 2026-11-12). The global script cannot cast rays, so the height (above
-- the creature's origin) travels in the mount request; nil when nothing was
-- hit, and the tables decide as before. (whywalk_shared.chooseSaddle)
local BACK_PROBE = { -20, 0, 20 }

local function measureBack(target, mt, done)
    if not (nearby.asyncCastRenderingRay and target and target:isValid()) then return done(nil) end
    local o = target.position
    local yaw = target.rotation:getYaw()
    local fwdDir = util.vector3(math.sin(yaw), math.cos(yaw), 0)
    local fwd0 = mt and shared.profileFor(mt).saddle.forward or 0
    local box = target:getBoundingBox()
    local top = box and (box.center.z + box.halfSize.z) or (o.z + 400)
    local hits, i = {}, 0
    local function nextRay()
        i = i + 1
        if i > #BACK_PROBE then
            if #hits == 0 then return done(nil) end
            table.sort(hits)
            return done(hits[math.floor((#hits + 1) / 2)] - o.z)
        end
        local q = o + fwdDir * (fwd0 + BACK_PROBE[i])
        nearby.asyncCastRenderingRay(async:callback(function(r)
            if r and r.hit and r.hitObject == target and r.hitPos then
                hits[#hits + 1] = r.hitPos.z
            end
            nextRay()
        end), util.vector3(q.x, q.y, top + 200), util.vector3(q.x, q.y, o.z - 20), { ignore = self.object })
    end
    nextRay()
end

-- ---------------------------------------------------------------------------
-- TAKE A SEAT (v0.44+): seated or lying, or still getting up
-- ---------------------------------------------------------------------------
-- A press while Take a Seat holds the player is Take a Seat's (it stands you
-- up). The global script is told too, so a mount requested by event from any
-- other mod is refused while seated rather than producing "seated and
-- mounted at once" (Take a Seat docs/tickets/0010).
local function tasBusy()
    local T = I.TakeASeat
    if not (T and T.isBusy) then return false end
    local ok, busy = pcall(T.isBusy)
    return ok and busy == true
end

local lastSeatedSent = nil
local function sendSeated(seated)
    seated = seated == true
    if seated == lastSeatedSent then return end
    lastSeatedSent = seated
    core.sendGlobalEvent(EV.PLAYER_SEATED, { player = self.object, seated = seated })
end

local function requestMount()
    if hudHidden() then return end
    if not mounted and tasBusy() then return end

    if mounted then
        core.sendGlobalEvent(EV.REQUEST_DISMOUNT, { player = self.object })
        return
    end

    local target, mt, free = findMountTarget()
    if not target then
        if mt == "blacklisted" then
            ui.showMessage(core.l10n(L10N_CONTEXT)("msg_blacklisted"))
        end
        return
    end

    measureBack(target, mt, function(measuredUp)
        core.sendGlobalEvent(EV.REQUEST_MOUNT, {
            player = self.object, mount = target, mountType = mt, freeRide = free,
            allowInteriors = allowInteriors(), measuredUp = measuredUp,
        })
    end)
end

input.registerTriggerHandler("Activate", async:callback(requestMount))

local function requestJump()
    if not mounted or hudHidden() then return end
    core.sendGlobalEvent(EV.CONTROL, { player = self.object, jump = true })
end
input.registerTriggerHandler("Jump", async:callback(requestJump))

local KEYMAP = {
    w = "forward", s = "back", a = "left", d = "right",
}

local function onKeyPress(key)
    if not mounted then return end
    if hudHidden() then return end
    local sym = key and key.symbol
    if not sym then return end

    local slot = KEYMAP[sym]
    if slot then
        held[slot] = true
    elseif sym == "x" then
        core.sendGlobalEvent(EV.REQUEST_DISMOUNT, { player = self.object })
        return
    else
    end

    held.gallop = input.isShiftPressed()
    sendControl(false)
end

local function onKeyRelease(key)
    if not mounted then return end
    local sym = key and key.symbol
    if not sym then return end

    local slot = KEYMAP[sym]
    if slot then held[slot] = false end

    held.gallop = input.isShiftPressed()
    sendControl(false)
end

-- ---------------------------------------------------------------------------
-- SAVE / LOAD
-- ---------------------------------------------------------------------------

local function onSave()
    return { controlsLocked = controlsLocked, levitationAdded = levitationAdded }
end

local function onLoad(data)
    mounted, freeRiding, mountType = false, false, nil
    lastSent = nil
    held.forward, held.back = false, false
    held.left, held.right   = false, false
    held.gallop             = false

    controlsLocked  = data and data.controlsLocked == true or false
    levitationAdded = data and data.levitationAdded == true or false
    releaseControls()
    removeLevitation()
    flowYield(false)

    -- The global script re-sends WhyWalk_Mounted after a load if the ride was
    -- still active, which re-enters onMounted above.

    -- A save made seated loads standing (Take a Seat v0.44); tell the global
    -- what is true now rather than what was saved.
    lastSeatedSent = nil
    sendSeated(tasBusy())
end

-- ---------------------------------------------------------------------------
-- COMPETING RIDING MOD DETECTION
-- ---------------------------------------------------------------------------
local RIVAL_MOUNT_EVENTS = {
    "DETD_GuarRiding_Mounted",
    "DETD_HorseRiding_Mounted",
    "SimpleHorseBaseRideAttach",
}

local rivalWarned = false

local function onRivalMount()
    if rivalWarned then return end
    rivalWarned = true
    print("[WhyWalk] Another riding mod (Devilish Horse/Guar Riding, or Sturdy"
          .. " Steed) just started its own ride. WhyWalk replaces those mods"
          .. " rather than layering on them. Running both means two mods"
          .. " pinning one rider and fighting over the camera, which is why"
          .. " the view will not leave first person and the rider sits wrong."
          .. " Disable the other riding mod's .omwscripts, or disable WhyWalk.")
end

return {
    eventHandlers = {
        [EV.MOUNTED]       = onMounted,
        [EV.DISMOUNTED]    = onDismounted,
        [EV.DISMOUNT_START] = onDismountStart,
        [EV.MOUNT_REFUSED] = onMountRefused,
        -- Take a Seat's public events (README "For other mods")
        TakeASeat_Seated        = function() sendSeated(true) end,
        TakeASeat_StandComplete = function() sendSeated(false) end,
        [RIVAL_MOUNT_EVENTS[1]] = onRivalMount,
        [RIVAL_MOUNT_EVENTS[2]] = onRivalMount,
        [RIVAL_MOUNT_EVENTS[3]] = onRivalMount,
    },
    engineHandlers = {
        onKeyPress   = onKeyPress,
        onKeyRelease = onKeyRelease,
        onSave       = onSave,
        onLoad       = onLoad,
        onInit       = function() sendSeated(tasBusy()) end,
    },
}
