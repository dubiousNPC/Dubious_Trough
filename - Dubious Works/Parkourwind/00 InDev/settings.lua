local async = require("openmw.async")
local I = require("openmw.interfaces")
local storage = require("openmw.storage")

local MOD_ID = "FLOW_AMF"
local SETTINGS_KEY = "Settings" .. MOD_ID


-- =============================================================================
-- REGISTRATION
--
-- Registered under pcall. This is the ONE place in FLOW where that is
-- justified, and only because the failure it guards is unrecoverable rather
-- than diagnostic: a rejected settings entry takes the entire page out of the
-- Scripts menu, including the Debug HUD toggle needed to diagnose anything
-- else. Both calls report their own failure to the console, so nothing is
-- silently swallowed - the error is surfaced AND the rest of the page
-- survives. Every other pcall in the mod has been removed.
--
-- The whole page vanished from the Scripts menu twice: once because the
-- custom renderer was registered after the group that named it, and again
-- for a cause that could not be pinned down without a log. Either way the
-- failure mode is the same and unacceptable - one bad entry takes down every
-- setting on the page, including the Debug HUD toggle needed to diagnose
-- anything else.
--
-- The core group therefore contains ONLY plain checkboxes with literal
-- defaults: no custom renderer, no engine constants, nothing that can be nil
-- on some build. It is the group that must never fail.
--
-- The sprint keybind that used to sit in a second group is gone entirely,
-- along with its custom menu-context renderer - see main.lua's throttle note.
-- =============================================================================

local pageOk = pcall(I.Settings.registerPage, {
    key = MOD_ID,
    l10n = MOD_ID,
    name = "FLOW Movement",
    description = "Advanced Movement Framework Configuration"
})
if not pageOk then
    print("[FLOW] settings page failed to register")
end

local coreOk = pcall(I.Settings.registerGroup, {
    key = SETTINGS_KEY,
    page = MOD_ID,
    l10n = MOD_ID,
    name = "SettingsFLOW_AMF",
    permanentStorage = false,
    settings = {
        {
            key = "modEnabled",
            name = "Enable FLOW",
            description = "Master switch. When off, FLOW does nothing at all - no raycasts, no state tracking, pure vanilla movement.",
            default = true, renderer = "checkbox"
        },
        {
            key = "disableInInteriors",
            name = "Disable Indoors",
            description = "When on, FLOW is inactive while inside interior cells (still works in the open world).",
            default = false, renderer = "checkbox"
        },
        {
            key = "debugMode",
            name = "Debug HUD",
            description = "Shows the live state/sensor readout on screen, and prints roll/animation diagnostics to the console. Off by default.",
            default = false, renderer = "checkbox"
        },
    }
})
if not coreOk then
    print("[FLOW] CORE settings group failed to register - this should not happen")
end

local section = storage.playerSection(SETTINGS_KEY)

-- =============================================================================
-- READ CACHE
--
-- main.lua checks modEnabled() and disableInInteriors() on EVERY frame before
-- doing anything else, and section:get() is a storage lookup that crosses into
-- the engine. That's two boundary crossings per frame, forever, for values
-- that only change when the player opens the settings menu.
--
-- Cache reads and let the storage subscription invalidate them.
--
-- The callback deliberately ignores its arguments and clears the whole
-- cache. Selectively dropping a single changed key would be marginally
-- cheaper, but it depends on the exact callback signature, and the proven
-- pattern in the wild (SourceMovement's config.lua) uses an argument-less
-- refresh. With ~12 entries, rebuilding all of them lazily on the next
-- read costs nothing, and it can't go stale if the signature differs.
local cache = {}

section:subscribe(async:callback(function()
    cache = {}
end))

local function get(key, default)
    local v = cache[key]
    if v == nil then
        v = section:get(key)
        if v == nil then v = default end
        -- Note: false caches correctly here - only nil counts as "not
        -- cached", and false ~= nil in Lua.
        cache[key] = v
    end
    return v
end

return {
    modEnabled = function() return get("modEnabled", true) end,
    disableInInteriors = function() return get("disableInInteriors", false) end,
    debugMode = function() return get("debugMode", false) end,
}