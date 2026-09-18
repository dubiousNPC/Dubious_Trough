---@omw-context runtime
--[[
    Runs in TWO contexts, which is why it is `runtime` and not `global`:
    sd_g.lua (GLOBAL) scans scripts/SunsDusk/settings/ and requires it there,
    where `world` is set and registerGroup runs; the module's player script
    requires it by name, where `world` is nil and registerPage runs.
]]
--[[
    Sun's Dusk addon module. NOT registered in an .omwscripts of its own --
    sd_g.lua walks its directory with vfs.pathsWithPrefix and require()s every file
    it finds, so this file runs inside that script's environment and inherits
    its context. Declaring it in a manifest as well is FATAL: OpenMW allows a
    script path exactly one set of flags, and a second declaration aborts the
    game before the main menu.

    That is also why the names below are read without ever being declared or
    required here. Sun's Dusk assigns them as GLOBALS on purpose (sd_p.lua
    lines 6-20), and `require` shares the requiring script's environment:

        core  types  util  world  I  animation  async  storage  MODNAME
        saveData  typesActorInventorySelf  typesActorSpellsSelf
        G_eventHandlers  G_onFrameJobs  G_onFrameJobsSluggish
        G_onLoadJobs  G_UiModeChangedJobs  G_settingsChangedJobs
        log                     -- a global function from constants.lua:124

    Every name was checked against sd_p.lua / sd_g.lua / constants.lua rather
    than assumed. Requiring them locally would work but would diverge from
    every other module in that directory, and the G_* job tables have no local
    equivalent at all -- they are the host's scheduler bus.

    Static checkers will report these as undeclared globals. That is correct
    and expected; pass the list above via --globals when sweeping this mod.
]]
--[[
	goggles_settings.lua -- Glasses, Goggles & Eyepatches settings

	Follows Sun's Dusk's settings convention exactly, because the module relies
	on it: every key here becomes a GLOBAL of the same name, written by
	readAllSettings() and kept current by the subscription at the bottom.
	p_goggles.lua reads GOGGLES_ENABLED as a plain global, the same way
	p_clean.lua reads NEEDS_CLEAN.

	`l10n = "none"` is Sun's Dusk's convention too: names and descriptions are
	literal text, not keys. Passing prose while an l10n context is set is what
	makes a control render blank.

	ONE setting, not three. The boon is a flat 1 point of Luck, so there is no
	magnitude to configure and no slider. A control that can only hold one
	value is worse than no control.
]]

local settingsTemplate = {}

settingsTemplate.GOGGLES = {
	key = "Settings" .. MODNAME .. "GOGGLES",
	page = MODNAME .. "GOGGLES",
	l10n = "none",
	name = "Glasses, Goggles and Eyepatches                                        ",
	permanentStorage = true,
	order = 0,
	settings = {
		{
			key = "GOGGLES_ENABLED",
			name = "Eyewear grants a small boon",
			description = "One point of Luck while worn. With this off, eyewear is cosmetic only.",
			renderer = "checkbox",
			default = true,
		},
	},
}

-- `world` is set only in GLOBAL context, and sd_g.lua's settings loop is the
-- global one. The PAGE has to be registered from a non-global context, which
-- is why p_goggles.lua requires this file as well.
if world then
	for _, template in pairs(settingsTemplate) do
		I.Settings.registerGroup(template)
	end
else
	for _, template in pairs(settingsTemplate) do
		I.Settings.registerPage({
			key = template.page,
			l10n = "none",
			name = template.name,
			description = "Cosmetic eyewear from the CAKE item set.",
		})
	end
end

local function readAllSettings()
	for _, template in pairs(settingsTemplate) do
		local settingsSection = storage.globalSection(template.key)
		for _, entry in pairs(template.settings) do
			local newValue = settingsSection:get(entry.key)
			if newValue == nil then
				newValue = entry.default
			end
			_G[entry.key] = newValue
		end
	end
end

readAllSettings()

for _, template in pairs(settingsTemplate) do
	storage.globalSection(template.key):subscribe(async:callback(function(section, setting)
		readAllSettings()
		for _, func in pairs(G_settingsChangedJobs or {}) do
			func(section, setting)
		end
	end))
end
