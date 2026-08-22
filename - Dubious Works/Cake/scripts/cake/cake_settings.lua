---@omw-context menu
--[[
    cake_settings.lua -- settings page

    Only settings something actually reads. The previous version declared
    eleven keys nothing consumed -- eight OMWFW buff toggles for categories
    CAKE does not have (circlets, glasses, backpacks, cloaks...), plus
    SHOWMESSAGES and EQUIPANIM left over from a design that changed. Dead
    settings are worse than no settings: they imply a feature exists.

    THE SKELETON SETTING
    --------------------
    Bones like `Bip01 mouthDBS` and `Bip01 L hipDBS` come from
    xbase_anim_dbs.nif and are simply absent without it. `auto` probes with
    animation.hasBone and falls back to a vanilla bone, which is right for
    almost everyone. `dbs` skips the probe when the setup is known. `vanilla`
    pins every category to its fallback bone.

    The option list is built from cake_shared.SKELETON rather than typed here,
    so a profile cannot be offered that the player script does not understand.
    That is the exact bug this file previously had: it offered `fashVfx`,
    which stopped existing when the registry was regenerated.

    RENDERER
    --------
    SuperSelect3 is bundled with the mod (scripts/SuperSettingsRenderers/) and
    listed ahead of this file in CAKE.omwscripts, the same way SharedRay and
    AnimRefresh are bundled -- a shared library shipped alongside, not copied
    into this file. It is used only if present: the renderer sets a flag in
    the session-lifetime `InstalledSettingsRenderers` section when it loads,
    and this file falls back to the engine's built-in `select` renderer when
    that flag is missing. So deleting the bundled folder degrades the dropdown
    to arrows and changes nothing else.
]]

local I       = require('openmw.interfaces')
local storage = require('openmw.storage')

local CAKE = require('scripts.cake.cake_shared')

-- ---------------------------------------------------------------------------
-- RENDERER DETECTION
-- ---------------------------------------------------------------------------

-- Written by each SuperSettingsRenderers file as it loads: the exact id
-- ("SuperSelect3") as a boolean, and the family name ("SuperSelect") as the
-- highest version number seen. Reading the family lets a newer bundled copy
-- satisfy this without an edit here.
local MIN_SELECT_VERSION = 3

local function selectRenderer()
    local ok, installed = pcall(storage.playerSection, 'InstalledSettingsRenderers')
    if ok and installed and (installed:get('SuperSelect') or 0) >= MIN_SELECT_VERSION then
        return 'SuperSelect' .. MIN_SELECT_VERSION, true
    end
    return 'select', false
end

local SELECT, HAVE_SUPER = selectRenderer()

-- ---------------------------------------------------------------------------
-- OPTIONS
-- ---------------------------------------------------------------------------

-- Built from the registry, in a stable order. pairs() would reorder the
-- dropdown between launches.
local SKELETON_ORDER = { 'auto', 'dbs', 'vanilla' }

local skeletonItems = {}
for _, key in ipairs(SKELETON_ORDER) do
    if CAKE.SKELETON[key] then skeletonItems[#skeletonItems + 1] = key end
end

local skeletonArgument = {
    items = skeletonItems,
    l10n  = 'CAKE',
}
-- width is a SuperSelect3 argument; the engine renderer ignores unknown keys,
-- but only setting it when it means something keeps the intent readable.
if HAVE_SUPER then skeletonArgument.width = 190 end

-- ---------------------------------------------------------------------------
-- REGISTRATION
-- ---------------------------------------------------------------------------

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
    -- Menu scripts may only register permanent groups, and this one has to be
    -- readable before a save is loaded, so it must stay true.
    permanentStorage = true,
    order            = 1,
    settings = {
        {
            key         = 'SKELETON',
            name        = 'setting_skeleton',
            description = 'setting_skeleton_desc',
            default     = CAKE.DEFAULT_SKELETON,
            renderer    = SELECT,
            argument    = skeletonArgument,
        },
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
        {
            key         = 'EQUIPANIM',
            name        = 'setting_equipanim',
            description = 'setting_equipanim_desc',
            default     = false,
            renderer    = 'checkbox',
        },
    },
})

return
