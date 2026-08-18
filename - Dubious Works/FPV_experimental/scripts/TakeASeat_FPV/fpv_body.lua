---@omw-context player
--[[
    fpv_body.lua -- EXPERIMENTAL first person body view for Take a Seat

    Shows your character's seated animation while you are in first person.

    THIS IS AN ADD-ON, NOT PART OF TAKE A SEAT.
    It attaches purely by listening for the events Take a Seat broadcasts:

        TakeASeat_Seated { furniture, seatType, animGroup }
        TakeASeat_Stood  {}

    Take a Seat has no knowledge of this file and works identically without it.
    Remove this package and nothing there changes. That separation is the whole
    point of shipping it apart: the technique below is still unproven, and the
    base mod should not carry unproven camera code.

    -----------------------------------------------------------------------
    HOW IT WORKS, AND WHY NOT THE OBVIOUS WAY
    -----------------------------------------------------------------------
    True first person renders an arms-only rig. There is no body to show and no
    way to render both rigs at once, so a "first person body" is necessarily a
    third person mode with the camera pulled onto the head.

    Immersive FPV does this with camera.MODE.Static, which stops the engine
    tracking the player entirely -- forcing it to hand-drive position, yaw,
    pitch and roll every frame and, because Lua cannot read a bone's world
    transform (animation.hasBone is the only bone API), to SIMULATE where the
    head is from movement state. That simulation is ~86 tuning constants deep
    and is where its clipping and jarring come from.

    MODE.Preview is documented as "third person mode, but player character
    doesn't turn to the view direction", which is exactly what a seated pose
    wants: the body stays facing forward while the camera orbits freely. The
    engine keeps handling mouse look, so nothing is driven per frame. Sitting
    is what makes this viable -- the anchor never moves, so there is no head to
    chase.

    NO PER-FRAME HANDLER. Entry, exit and retuning are all events or one-shot
    timers.

    -----------------------------------------------------------------------
    KNOWN ISSUES
    -----------------------------------------------------------------------
    * Without a head-hiding mesh you may see the inside of your own head.
      Immersive FPV solves this with an invisible-helm item, which needs an
      ESP; this ships none, so DISTANCE exists to pull back until the skull
      clears.
    * The framing numbers are guesses. The camera tracks STANDING head height
      while you are seated at seat level, which is why the vertical default is
      a large negative number rather than zero.
    * Off by default.
]]

local self    = require('openmw.self')
local camera  = require('openmw.camera')
local util    = require('openmw.util')
local storage = require('openmw.storage')
local async   = require('openmw.async')
local I       = require('openmw.interfaces')

local DEBUG = false

local SETTINGS_PAGE  = "TakeASeatFPV"
local SETTINGS_GROUP = "SettingsTakeASeatFPVBody"

-- Own tag, distinct from any Take a Seat holds. The built-in camera control
-- toggles are reference counted per tag, so sharing one would mean releasing
-- one hold released the other's too.
local CAMERA_TAG = "TakeASeatFPVBody"

-- ---------------------------------------------------------------------------
-- SETTINGS
-- ---------------------------------------------------------------------------
-- SuperSettingsRenderers ships a real slider ("SuperSlider6"). Optional: it
-- advertises itself in a session-lifetime storage section, so its presence is
-- checked without requiring anything from it. The family key is checked rather
-- than the exact id, so a future SuperSlider7 is picked up unchanged.

local installedRenderers = storage.playerSection("InstalledSettingsRenderers")

local function sliderAvailable()
    local ok, version = pcall(function() return installedRenderers:get("SuperSlider") end)
    return ok and type(version) == "number" and version >= 6
end

local HAS_SLIDER = sliderAvailable()

local function numberSetting(key, name, description, default, min, max)
    if HAS_SLIDER then
        return {
            key = key, name = name, description = description,
            renderer = "SuperSlider6", default = default,
            argument = {
                min = min, max = max, step = 1,
                default = default,           -- needed here too for the default mark
                showDefaultMark = true,
                showResetButton = true,
                tinyReset       = true,
                minLabel = tostring(min), maxLabel = tostring(max),
                unit = "u", width = 220,
            },
        }
    end
    return {
        key = key, name = name, description = description,
        renderer = "number", integer = true, default = default,
        argument = { min = min, max = max },
    }
end

I.Settings.registerPage {
    key         = SETTINGS_PAGE,
    l10n        = "none",
    name        = "Take a Seat - First Person Body",
    description = "Experimental. Shows your body while seated in first person.",
}

I.Settings.registerGroup {
    key              = SETTINGS_GROUP,
    page             = SETTINGS_PAGE,
    l10n             = "none",
    name             = "First person body",
    description      = "Switches to a head-mounted third person view while seated,"
                    .. " so the sitting animation is visible.",
    permanentStorage = true,
    order            = 0,
    settings = {
        {
            key         = "ENABLED",
            name        = "Show body when seated in first person",
            description = "You may see the inside of your own head; raise the"
                       .. " distance below if so.",
            renderer    = "checkbox",
            default     = false,
        },
        numberSetting("DISTANCE", "Distance from head",
            "0 sits exactly on the head. Raise it until your own head stops"
         .. " clipping into view.", 0, 0, 120),
        numberSetting("EYE_V", "Eye height offset",
            "Negative lowers the view. Seated poses need a large negative value,"
         .. " because the camera tracks standing head height.", -60, -250, 150),
        numberSetting("EYE_H", "Eye lateral offset",
            "Positive shifts right.", 0, -150, 150),
    },
}

local settings = storage.playerSection(SETTINGS_GROUP)

-- ---------------------------------------------------------------------------
-- STATE
-- ---------------------------------------------------------------------------

local seated   = false
local active   = false
local saved    = nil
local token    = 0

-- ---------------------------------------------------------------------------
-- BUILT-IN CAMERA CONTROL
-- ---------------------------------------------------------------------------
-- Setting a mode and an offset is not enough. The built-in camera script
-- re-derives all of it every frame, so each piece must be stood down by tag or
-- the view collapses back to ordinary third person with a mangled offset:
--
--   modeControl              resolves the camera back to a PRIMARY mode, and
--                            getPrimaryMode returns only FirstPerson or
--                            ThirdPerson -- Preview is transient, so without
--                            this the mode is undone almost immediately.
--   thirdPersonOffsetControl re-derives the focal offset, discarding ours.
--   zoom                     moves the base distance out from under us.
--   standingPreview          swings into preview on its own when idle, which
--                            is exactly a seated player's state.
--   headBobbing              built-in bob, very visible at distance 0.

local function setBuiltinControls(disabled)
    if not I.Camera then return end
    local fns = disabled
        and { I.Camera.disableModeControl, I.Camera.disableThirdPersonOffsetControl,
              I.Camera.disableZoom, I.Camera.disableStandingPreview,
              I.Camera.disableHeadBobbing }
        or  { I.Camera.enableModeControl, I.Camera.enableThirdPersonOffsetControl,
              I.Camera.enableZoom, I.Camera.enableStandingPreview,
              I.Camera.enableHeadBobbing }
    for _, fn in ipairs(fns) do
        if fn then pcall(fn, CAMERA_TAG) end
    end
end

-- ---------------------------------------------------------------------------
-- FRAMING
-- ---------------------------------------------------------------------------

local function applyFraming()
    local dist = settings:get("DISTANCE") or 0
    -- Both distances: the base is what zoom and the built-in modifiers work
    -- from, the preferred is the engine-level request.
    if I.Camera and I.Camera.setBaseThirdPersonDistance then
        pcall(I.Camera.setBaseThirdPersonDistance, dist)
    end
    pcall(camera.setPreferredThirdPersonDistance, dist)
    pcall(camera.setFocalPreferredOffset, util.vector2(
        settings:get("EYE_H") or 0,
        settings:get("EYE_V") or -60))

    -- setFocalPreferredOffset smooth-transitions by default every time the
    -- preferred offset changes, so instantTransition must come AFTER it.
    -- Calling it first skips a transition that has not started and does
    -- nothing, leaving the offset to ease in over time.
    pcall(camera.instantTransition)
end

-- Entering Preview is not instantaneous: the mode transition re-derives the
-- focal offset as it completes, landing after a same-frame write and silently
-- discarding it. That is why the framing used to stick when a slider was
-- nudged (mode long settled) but revert to head height on every fresh sit.
-- So apply immediately AND re-apply across the transition. The exact settle
-- time is unknown, hence a short schedule rather than one guessed delay.
local REAPPLY_DELAYS = { 0.05, 0.15, 0.35 }

local function scheduleFraming()
    token = token + 1
    local myToken = token
    applyFraming()
    for _, delay in ipairs(REAPPLY_DELAYS) do
        async:newUnsavableSimulationTimer(delay, function()
            -- Guarded so a pending re-apply cannot stamp a seated offset onto
            -- a player who already stood up.
            if active and myToken == token then applyFraming() end
        end)
    end
end

local function debugReport()
    if not DEBUG then return end
    async:newUnsavableSimulationTimer(0.4, function()
        if not active then return end
        local okPref, pref = pcall(camera.getFocalPreferredOffset)
        local okTrk,  trk  = pcall(camera.getTrackedPosition)
        local okPos,  pos  = pcall(camera.getPosition)
        print(string.format("[fpvbody] mode=%s preferred=(%.1f, %.1f) requested=(%.1f, %.1f)",
            tostring(camera.getMode()),
            okPref and pref.x or 0, okPref and pref.y or 0,
            settings:get("EYE_H") or 0, settings:get("EYE_V") or -60))
        if okTrk and okPos then
            print(string.format("[fpvbody] tracked=(%.1f,%.1f,%.1f) camera=(%.1f,%.1f,%.1f) dZ=%.1f",
                trk.x, trk.y, trk.z, pos.x, pos.y, pos.z, pos.z - trk.z))
        end
    end)
end

-- ---------------------------------------------------------------------------
-- ENTER / EXIT
-- ---------------------------------------------------------------------------

local function exitBody()
    if not active then return end
    active = false
    token  = token + 1        -- cancel pending re-applies

    if saved then
        if I.Camera and I.Camera.setBaseThirdPersonDistance then
            pcall(I.Camera.setBaseThirdPersonDistance, saved.baseDistance)
        end
        pcall(camera.setPreferredThirdPersonDistance, saved.distance)
        pcall(camera.setFocalPreferredOffset, util.vector2(saved.offsetX, saved.offsetY))
    end

    -- Release the built-in controls BEFORE restoring the mode, so the mode
    -- change is handled normally rather than while control is suppressed.
    setBuiltinControls(false)

    if camera.getMode() ~= camera.MODE.FirstPerson then
        camera.setMode(camera.MODE.FirstPerson)
        camera.instantTransition()
    end
    saved = nil
end

local function enterBody()
    if active or not seated then return end
    if not settings:get("ENABLED") then return end
    -- Only meaningful coming FROM first person; in third person the body is
    -- already visible.
    if camera.getMode() ~= camera.MODE.FirstPerson then return end

    local okDist, dist = pcall(camera.getThirdPersonDistance)
    local okOff,  off  = pcall(camera.getFocalPreferredOffset)
    local okBase, base = false, nil
    if I.Camera and I.Camera.getBaseThirdPersonDistance then
        okBase, base = pcall(I.Camera.getBaseThirdPersonDistance)
    end
    saved = {
        distance     = okDist and dist or 192,
        baseDistance = okBase and base or 192,
        offsetX      = okOff and off.x or 0,
        offsetY      = okOff and off.y or 0,
    }

    setBuiltinControls(true)
    camera.setMode(camera.MODE.Preview)
    active = true
    scheduleFraming()
    debugReport()
end

-- ---------------------------------------------------------------------------
-- WIRING
-- ---------------------------------------------------------------------------

-- Live retune, so the sliders can be dialled in against the actual view
-- instead of standing up and sitting down again.
settings:subscribe(async:callback(function()
    if not seated then return end
    if active then
        if settings:get("ENABLED") then applyFraming() else exitBody() end
    else
        enterBody()
    end
end))

-- A perspective toggle while the body view is up means the player asked to
-- leave it. AnimRefresh is bundled with Take a Seat and notifies after the
-- switch settles; without it this simply never fires and the view persists
-- until standing, which is harmless.
if I.AnimRefresh and I.AnimRefresh.subscribe then
    I.AnimRefresh.subscribe("TakeASeatFPVBody", function()
        if active and camera.getMode() ~= camera.MODE.Preview then
            active = false
            saved  = nil
            token  = token + 1
            setBuiltinControls(false)
        end
    end)
end

local function onSeated()
    seated = true
    enterBody()
end

local function onStood()
    seated = false
    exitBody()
end

local function onLoad()
    seated = false
    active = false
    saved  = nil
    token  = token + 1
    setBuiltinControls(false)
end

return {
    eventHandlers = {
        TakeASeat_Seated = onSeated,
        TakeASeat_Stood  = onStood,
    },
    engineHandlers = {
        onLoad = onLoad,
    },
}
