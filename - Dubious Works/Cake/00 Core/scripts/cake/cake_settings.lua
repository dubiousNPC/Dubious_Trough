---@omw-context menu
-- cake_settings.lua -- the settings page. Every key here is read by cake_player.lua.

local I = require('openmw.interfaces')

I.Settings.registerPage({
    key         = 'CAKE',
    l10n        = 'CAKE',
    name        = 'settings_modName',
    description = 'settings_modDesc',
})

I.Settings.registerGroup({
    key              = 'Settings_cake_main',
    page             = 'CAKE',
    l10n             = 'CAKE',
    name             = 'settings_general',
    -- Menu scripts can only register permanent groups.
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
            key         = 'SHOWFIRSTPERSON',
            name        = 'setting_showfirstperson',
            description = 'setting_showfirstperson_desc',
            default     = false,
            renderer    = 'checkbox',
        },
    },
})

return {}
