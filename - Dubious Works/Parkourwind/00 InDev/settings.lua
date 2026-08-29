local async = require("openmw.async")
local I = require("openmw.interfaces")
local storage = require("openmw.storage")
local input = require("openmw.input")
local ui = require("openmw.ui")

local MOD_ID = "FLOW_AMF"
local SETTINGS_KEY = "Settings" .. MOD_ID

I.Settings.registerPage {
    key = MOD_ID,
    l10n = MOD_ID,
    name = "FLOW Movement",
    description = "Advanced Movement Framework Configuration"
}

I.Settings.registerGroup {
    key = SETTINGS_KEY,
    page = MOD_ID,
    l10n = MOD_ID,
    name = "SettingsFLOW_AMF",
    permanentStorage = false,
    settings = {
        {
            key = "sprintKeyCode",
            name = "activateInput_name",
            description = "activateInput_desc",
            -- NEW key name: the old 'activateInput' held an action-binding
            -- string, so a stale entry would otherwise linger and read back as
            -- a keycode. Users rebind once on update.
            default = input.KEY.LeftAlt,
            renderer = "FLOW_AMF/keyBinding"
        },
        -- [NEW] Master enable/disable
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
            description = "Shows the live state/sensor readout on screen. Off by default - the HUD redraws and allocates strings every frame, and also forces the sensor to resolve object names it otherwise wouldn't need. Leave off unless diagnosing something.",
            default = false, renderer = "checkbox"
        },
    }
}

-- Raw-keycode renderer. See the note in core/input.lua: FLOW no longer
-- publishes into the engine's shared action-binding registry, so it needs its
-- own widget for the sprint key. Same approach AcrobaticsEnhanced, Questman
-- and Character Panel settled on.
I.Settings.registerRenderer('FLOW_AMF/keyBinding', function(value, set)
    local name = value and input.getKeyName(value) or 'Not set'
    return {
        template = I.MWUI.templates.box,
        content = ui.content{
            {
                template = I.MWUI.templates.padding,
                content = ui.content{
                    {
                        template = I.MWUI.templates.textEditLine,
                        props = { text = name },
                        events = {
                            keyPress = async:callback(function(e)
                                if e.code == input.KEY.Escape then return end
                                set(e.code)
                            end),
                        },
                    },
                },
            },
        },
    }
end)

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
    sprintKeyCode = function() return get("sprintKeyCode", input.KEY.LeftAlt) end
}