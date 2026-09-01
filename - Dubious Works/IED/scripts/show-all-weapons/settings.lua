---@omw-context menu
--[[
    settings.lua -- IED settings page

    VIABILITY NOTE
    --------------
    Settings are viable here, but not for free: this mod is two LOCAL scripts
    and nothing else, and a local script running on an NPC CANNOT read a player
    settings section. So every setting an NPC needs has to travel

        MENU (this file, declares)
          -> PLAYER (subscribes, pushes)
            -> GLOBAL (owns the writable global section)
              -> NPC (reads it, read-only)

    which is why adding settings also means adding a MENU script and a GLOBAL
    script. That is the whole cost, and it is the same route CAKE uses for its
    NPC toggle.

    Settings that only affect the player -- there are none here yet -- would
    not need the detour.
]]

local I = require('openmw.interfaces')

I.Settings.registerPage({
    key         = 'IED',
    l10n        = 'IED',
    name        = 'settings_modName',
    description = 'settings_modDesc',
})

I.Settings.registerGroup({
    key              = 'Settings_ied_main',
    page             = 'IED',
    l10n             = 'IED',
    name             = 'settings_general',
    permanentStorage = true,
    order            = 1,
    settings = {
        {
            key         = 'SHOWNPCS',
            name        = 'setting_shownpcs',
            description = 'setting_shownpcs_desc',
            default     = true,
            renderer    = 'checkbox',
        },
        {
            key         = 'SHOWWEAPONS',
            name        = 'setting_showweapons',
            description = 'setting_showweapons_desc',
            default     = true,
            renderer    = 'checkbox',
        },
        {
            key         = 'SHOWSHIELDS',
            name        = 'setting_showshields',
            description = 'setting_showshields_desc',
            default     = true,
            renderer    = 'checkbox',
        },
        {
            key         = 'SHOWAMMO',
            name        = 'setting_showammo',
            description = 'setting_showammo_desc',
            default     = true,
            renderer    = 'checkbox',
        },
        {
            -- The poll is a string compare against a cached signature and does
            -- no record or filesystem work, so this is a much smaller dial
            -- than it looks. Exposed mainly so a very large load order can back
            -- it off.
            key         = 'POLLINTERVAL',
            name        = 'setting_pollinterval',
            description = 'setting_pollinterval_desc',
            default     = 0.5,
            renderer    = 'number',
            argument    = { min = 0.1, max = 5.0 },
        },
    },
})

return
