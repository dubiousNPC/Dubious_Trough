---@omw-context global
--[[
    Sun's Dusk addon module. NOT registered in an .omwscripts of its own --
    sd_g.lua (GLOBAL context) walks its directory with
    vfs.pathsWithPrefix and require()s every file it finds, so this file runs
    inside that script's environment and inherits its context.

    That is also why the names below are read without ever being declared or
    required here. Sun's Dusk assigns them as GLOBALS on purpose (sd_g.lua
    lines 6-20), and `require` shares the requiring script's environment:

        core  types  util  world  I  animation  async  storage  MODNAME
        saveData  typesActorInventorySelf  typesActorSpellsSelf
        G_eventHandlers  G_onFrameJobs
        log                     -- a global function from constants.lua:124,
                                -- which both sd_p and sd_g require

    Every name in that list was checked against sd_p.lua / sd_g.lua /
    constants.lua rather than assumed; it is exactly the set these three files
    read, no more.

    Requiring them locally here would work but would diverge from every other
    module in that directory, and the G_* job tables have no local equivalent
    at all -- they are the host's scheduler bus.

    Static checkers will report these as undeclared globals. That is correct
    and expected; pass the list above via --globals when sweeping this mod.
]]
--[[
	scarves_settings.lua -- Scarves & Masks settings

	Follows Sun's Dusk's own settings convention exactly, because the module
	relies on it: every key here becomes a GLOBAL of the same name, written by
	readAllSettings() below and kept current by the subscription at the bottom.
	p_scarves.lua reads SCARVES_WARMTH and MASKS_BLIGHT_RES as plain globals,
	the same way p_clean.lua reads NEEDS_CLEAN.

	`l10n = "none"` is Sun's Dusk's convention too: names and descriptions are
	literal text, not keys. Passing prose while an l10n context is set is what
	makes a control render blank.
]]

local settingsTemplate = {}

local RENDERER_SELECT = "SuperSelect2"
local RENDERER_NUMBER = "SuperSlider4"

settingsTemplate.SCARVES = {
	key = "Settings" .. MODNAME .. "SCARVES",
	page = MODNAME .. "SCARVES",
	l10n = "none",
	name = "Scarves and Masks                                                       ",
	permanentStorage = true,
	order = 0,
	settings = {
		{
			key = "SCARVES_ENABLED",
			name = "Scarves provide warmth",
			description = "Requires the Temperature module. With it off, scarves are cosmetic only.",
			renderer = "checkbox",
			default = true,
		},
		{
			key = "SCARVES_WARMTH",
			name = "Scarf warmth",
			description = "How much warmth a worn scarf provides.\nGranted as an ability, the same way a hearthfire's warmth is, so it stacks with fires and clothing rather than replacing them.\nDefault is 4, which takes the edge off a Sheogorad night without making one redundant.",
			renderer = RENDERER_NUMBER,
			default = 4,
			argument = {
				min = 0,
				max = 20,
				step = 1,
				default = 4,
				unit = "",
				minLabel = "None",
				maxLabel = "Toasty",
				labelSize = 13,
				width = 120,
				thickness = 15,
				showDefaultMark = true,
				showResetButton = false,
				bottomRow = true,
			},
		},
		{
			key = "MASKS_ENABLED",
			name = "Masks resist blight",
			description = "With this off, masks are cosmetic only.",
			renderer = "checkbox",
			default = true,
		},
		{
			key = "MASKS_BLIGHT_RES",
			name = "Mask blight resistance",
			description = "Resistance to Blight Disease while a mask is worn.\nSnaps to the nearest 10%, because each step is a separate ability record in the plugin.",
			renderer = RENDERER_NUMBER,
			default = 30,
			argument = {
				min = 0,
				max = 50,
				step = 10,
				default = 30,
				unit = "%",
				minLabel = "None",
				maxLabel = "Sealed",
				labelSize = 13,
				width = 120,
				thickness = 15,
				showDefaultMark = true,
				showResetButton = false,
				bottomRow = true,
			},
		},
	}
}

if world then
	for id, template in pairs(settingsTemplate) do
		I.Settings.registerGroup(template)
	end
else
	I.Settings.registerPage {
		key = MODNAME .. "SCARVES",
		l10n = "none",
		name = "Sun's Dusk: Scarves",
		description = "Configure the warmth scarves provide and the blight resistance masks provide."
	}
end

-- shared across every global settings file so presets can reach any global key
G_globalSettingDefaults = G_globalSettingDefaults or {}

local function readAllSettings()
	for _, template in pairs(settingsTemplate) do
		local settingsSection = storage.globalSection(template.key)
		for i, entry in pairs(template.settings) do
			local newValue = settingsSection:get(entry.key)
			if newValue == nil then
				newValue = entry.default
			end
			_G[entry.key] = newValue
			G_globalSettingDefaults[entry.key] = { section = template.key, default = entry.default }
		end
	end
end

readAllSettings()

------------------------------ Settings Event ------------------------------

for _, template in pairs(settingsTemplate) do
	local sectionName = template.key
	local settingsSection = storage.globalSection(template.key)
	settingsSection:subscribe(async:callback(function (_, setting)
		local oldValue = _G[setting]
		_G[setting] = settingsSection:get(setting)
		for _, func in pairs(G_settingsChangedJobs or {}) do
			func(sectionName, setting, oldValue)
		end
	end))
end
