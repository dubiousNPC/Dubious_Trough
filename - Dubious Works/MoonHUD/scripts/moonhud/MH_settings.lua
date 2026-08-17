-- MH_settings.lua
--
-- Settings groups for MoonHUD. Layout, naming and behaviour follow TimeHUD and
-- LocationHUD so the three sit consistently in the settings menu: every setting
-- those two expose is present here, plus a Moons group for this mod's own options.
--
-- Reading convention is theirs too: each setting is mirrored into a global of the
-- same name (FONT_SIZE, HUD_X_POS, ...) so the HUD script can read them directly.

local core    = require('openmw.core')
local ui      = require('openmw.ui')
local util    = require('openmw.util')
local storage = require('openmw.storage')
local async   = require('openmw.async')
local I       = require('openmw.interfaces')

local v2 = util.vector2

MODNAME = MODNAME or 'MoonHUD'

-- TimeHUD and LocationHUD ship a "SuperColorPicker2" settings renderer. If you have
-- either installed you can set this to 'SuperColorPicker2' for a colour wheel.
-- Left as 'textLine' so MoonHUD has no dependencies: enter a plain hex string.
local COLOR_RENDERER = 'textLine'
local function colorDefault(hex)
	return (COLOR_RENDERER == 'textLine') and hex or util.color.hex(hex)
end

local layerId       = ui.layers.indexOf('HUD')
local hudLayerSize  = ui.layers[layerId].size

local function gmstColor(tag, fallbackHex)
	local result = core.getGMST(tag)
	if not result then return fallbackHex end
	local rgb = {}
	for c in string.gmatch(result, '(%d+)') do rgb[#rgb + 1] = tonumber(c) end
	if #rgb ~= 3 then return fallbackHex end
	return string.format('%02X%02X%02X', rgb[1], rgb[2], rgb[3])
end

local presetColors = {
	'caa560', -- FontColor_color_normal
	'dfc99f', -- FontColor_color_normal_over
	'eee2c9', -- light text
	'd4b77f', -- golden mix
	'd8d2e8', -- Secunda white
	'e0ba98', -- Masser amber
	'81cded', -- blue
}

local orderCounter = 0
local function getOrder() orderCounter = orderCounter + 1 return orderCounter end

local settingsTemplate = {}
local key

--------------------------------------------------------------------------------
key = 'General'
settingsTemplate[key] = {
	key = 'Settings' .. MODNAME .. key,
	page = MODNAME,
	l10n = 'none',
	name = 'General',
	permanentStorage = true,
	order = getOrder(),
	settings = {
		{
			key = 'HUD_DISPLAY',
			name = 'HUD Display',
			description = 'When to display the widget. "Interface Only" shows it while menus are open.',
			renderer = 'select',
			default = 'Always',
			argument = {
				disabled = false, l10n = 'none',
				items = { 'Always', 'Interface Only', 'Hide on Interface', 'Hide on Dialogue Only', 'Never' },
			},
		},
		{
			key = 'HUD_LOCK',
			name = 'Lock Position',
			description = 'Stops click-and-drag repositioning.',
			renderer = 'checkbox',
			default = false,
		},
		{
			key = 'HUD_X_POS',
			name = 'X Position',
			description = '',
			renderer = 'number',
			integer = true,
			default = 12,
		},
		{
			key = 'HUD_Y_POS',
			name = 'Y Position',
			description = '',
			renderer = 'number',
			integer = true,
			default = math.floor(hudLayerSize.y - 170),
		},
		{
			key = 'HUD_EXTERIOR',
			name = 'Only display outdoors',
			description = 'Hide the widget in interiors. The tracker keeps running either way.',
			renderer = 'checkbox',
			default = false,
		},
		{
			key = 'HUD_NIGHT_ONLY',
			name = 'Only display when a moon is up',
			description = 'Hide the widget while both moons are below the horizon or invisible.\nNeeds an active exterior cell to know.',
			renderer = 'checkbox',
			default = false,
		},
		{
			key = 'SHOW_MODE',
			name = 'Visibility Mode',
			description = 'Persistent keeps the widget on screen.\nOn Phase Change shows it briefly when a moon changes phase, then fades.',
			renderer = 'select',
			default = 'Persistent',
			argument = {
				disabled = false, l10n = 'none',
				items = { 'Persistent', 'On Phase Change' },
			},
		},
		{
			key = 'HOLD_DURATION',
			name = 'Hold Duration',
			description = 'Seconds to stay fully visible before fading. "On Phase Change" mode only.',
			renderer = 'number',
			default = 5,
			argument = { min = 0, max = 60 },
		},
		{
			key = 'FADE_DURATION',
			name = 'Fade Duration',
			description = 'Seconds spent fading out. "On Phase Change" mode only.',
			renderer = 'number',
			default = 2,
			argument = { min = 0, max = 60 },
		},
	},
}

--------------------------------------------------------------------------------
key = 'Appearance'
settingsTemplate[key] = {
	key = 'Settings' .. MODNAME .. key,
	page = MODNAME,
	l10n = 'none',
	name = 'Appearance',
	permanentStorage = true,
	order = getOrder(),
	settings = {
		{
			key = 'FONT_SIZE',
			name = 'Font Size',
			description = 'Default is 20.',
			renderer = 'number',
			default = 20,
			argument = { min = 5, max = 200 },
		},
		{
			key = 'TEXT_COLOR',
			name = 'Text Color',
			description = 'Hex, no #. Try caa560, dfc99f, eee2c9.',
			renderer = COLOR_RENDERER,
			default = colorDefault(gmstColor('FontColor_color_normal', 'caa560')),
			argument = { presetColors = presetColors },
		},
		{
			key = 'BACKGROUND_ALPHA',
			name = 'Background Opacity',
			description = '0 to 1. Default 0.5.',
			renderer = 'number',
			default = 0.5,
			argument = { min = 0, max = 1 },
		},
		{
			key = 'TEXT_ALIGNMENT',
			name = 'Alignment',
			description = 'Also sets which corner the widget grows from.',
			renderer = 'select',
			default = 'Left',
			argument = {
				disabled = false, l10n = 'none',
				items = { 'Left', 'Center', 'Right' },
			},
		},
	},
}

--------------------------------------------------------------------------------
key = 'Moons'
settingsTemplate[key] = {
	key = 'Settings' .. MODNAME .. key,
	page = MODNAME,
	l10n = 'none',
	name = 'Moons',
	permanentStorage = true,
	order = getOrder(),
	settings = {
		{
			key = 'DISPLAY_MODE',
			name = 'Display Mode',
			description = 'Icons are drawn from a texture atlas (textures/moonhud/moon_atlas.png):\n8 phase cells across, Masser on the top row, Secunda on the bottom.',
			renderer = 'select',
			default = 'Icons + Text',
			argument = {
				disabled = false, l10n = 'none',
				items = { 'Text', 'Icons', 'Icons + Text' },
			},
		},
		{
			key = 'LAYOUT',
			name = 'Layout',
			description = 'Stack the two moons vertically or place them side by side.',
			renderer = 'select',
			default = 'Vertical',
			argument = {
				disabled = false, l10n = 'none',
				items = { 'Vertical', 'Horizontal' },
			},
		},
		{
			key = 'ICON_SIZE',
			name = 'Icon Size',
			description = 'Pixels. The atlas cell is 64, so 64 is 1:1 and anything larger will soften.',
			renderer = 'number',
			integer = true,
			default = 32,
			argument = { min = 8, max = 256 },
		},
		{
			key = 'ICON_SPACING',
			name = 'Icon Spacing',
			description = 'Pixels between an icon and its label.',
			renderer = 'number',
			integer = true,
			default = 6,
			argument = { min = 0, max = 64 },
		},
		{
			key = 'ATLAS_PATH',
			name = 'Atlas Path',
			description = 'VFS path to the phase sheet. Leave as-is to use the bundled one.',
			renderer = 'textLine',
			default = 'textures/moonhud/moonhud_atlas_1.png',
		},
		{
			key = 'ATLAS_CELL',
			name = 'Atlas Cell Size',
			description = 'Width and height in pixels of one phase cell in the sheet.',
			renderer = 'number',
			integer = true,
			default = 64,
			argument = { min = 4, max = 512 },
		},
		{
			key = 'SHOW_MASSER',
			name = 'Show Masser',
			description = '',
			renderer = 'checkbox',
			default = true,
		},
		{
			key = 'SHOW_SECUNDA',
			name = 'Show Secunda',
			description = '',
			renderer = 'checkbox',
			default = true,
		},
		{
			key = 'SHOW_MOON_NAMES',
			name = 'Show Moon Names',
			description = 'Prefix each line with "Masser" / "Secunda".',
			renderer = 'checkbox',
			default = true,
		},
		{
			key = 'PHASE_NAMING',
			name = 'Phase Names',
			description = 'Descriptive: Waning Gibbous.\nSimple: Gibbous (the five values MWScript could see).\nValue: the raw 0-4 phaseValue.',
			renderer = 'select',
			default = 'Descriptive',
			argument = {
				disabled = false, l10n = 'none',
				items = { 'Descriptive', 'Simple', 'Value' },
			},
		},
		{
			key = 'DIM_WITH_ALPHA',
			name = 'Dim with sky visibility',
			description = 'Fade each icon in step with how visible that moon actually is in the sky.',
			renderer = 'checkbox',
			default = false,
		},
		{
			key = 'SHOW_SOURCE',
			name = 'Show data source (debug)',
			description = 'Appends engine / projected / formula / fixture so you can see which tier answered.',
			renderer = 'checkbox',
			default = false,
		},
		{
			key = 'SHOW_SHADE',
			name = 'Show Shade of the Revenant',
			description = 'Adds a third line: every eighth day from 27 Last Seed.\nSequence is 27 Last Seed, 4 Hearthfire, 12, 20, 28, 6 Frostfall...\nDate-driven, so it works indoors too.',
			renderer = 'checkbox',
			default = true,
		},
		{
			key = 'SHADE_DISPLAY',
			name = 'Shade Display',
			description = 'Always: a countdown, plus a highlight on the day itself.\nOnly When Active: the line appears only on a Shade day.\nCountdown Only: never highlights, just the number of days.',
			renderer = 'select',
			default = 'Always',
			argument = {
				disabled = false, l10n = 'none',
				items = { 'Always', 'Only When Active', 'Countdown Only' },
			},
		},
		{
			key = 'SHADE_ANCHOR_MONTH',
			name = 'Shade Anchor Month',
			description = 'The month the cycle is counted from. Default Last Seed.',
			renderer = 'select',
			default = 'Last Seed',
			argument = {
				disabled = false, l10n = 'none',
				items = { 'Morning Star', "Sun's Dawn", 'First Seed', "Rain's Hand",
				          'Second Seed', 'Mid Year', "Sun's Height", 'Last Seed',
				          'Hearthfire', 'Frost Fall', "Sun's Dusk", 'Evening Star' },
			},
		},
		{
			key = 'SHADE_ANCHOR_DAY',
			name = 'Shade Anchor Day',
			description = 'Day of that month. Default 27.',
			renderer = 'number',
			integer = true,
			default = 27,
			argument = { min = 1, max = 31 },
		},
		{
			key = 'SHADE_INTERVAL',
			name = 'Shade Interval',
			description = 'Days between occurrences. Default 8.',
			renderer = 'number',
			integer = true,
			default = 8,
			argument = { min = 1, max = 365 },
		},
		{
			key = 'UPDATE_INTERVAL',
			name = 'Update Interval',
			description = 'In-game minutes between refreshes. Phases only move once every three days, so this can be lazy.',
			renderer = 'number',
			integer = true,
			default = 30,
			argument = { min = 1, max = 240 },
		},
	},
}

--------------------------------------------------------------------------------
key = 'Border'
settingsTemplate[key] = {
	key = 'Settings' .. MODNAME .. key,
	page = MODNAME,
	l10n = 'none',
	name = 'Border',
	permanentStorage = true,
	order = getOrder(),
	settings = {
		{
			key = 'HUD_BORDER',
			name = 'Border',
			description = 'Draw a border along the edges of the background.',
			renderer = 'checkbox',
			default = true,
		},
		{
			key = 'HUD_BORDER_STYLE',
			name = 'Border Style',
			description = 'Same styles as TimeHUD, LocationHUD and Quickloot.',
			renderer = 'select',
			default = 'thin',
			argument = {
				disabled = false, l10n = 'none',
				items = { 'thin', 'normal', 'thick', 'verythick' },
			},
		},
		{
			key = 'HUD_BORDER_COLOR',
			name = 'Border Color',
			description = 'Hex, no #.',
			renderer = COLOR_RENDERER,
			default = colorDefault('FFFFFF'),
			argument = { presetColors = presetColors },
		},
		{
			key = 'HUD_PADDING',
			name = 'Padding',
			description = 'Inner spacing in pixels, applied on both axes. Default 4.',
			renderer = 'number',
			integer = true,
			default = 4,
			argument = { min = 0, max = 50 },
		},
	},
}

--------------------------------------------------------------------------------
-- Registration
--------------------------------------------------------------------------------

for _, template in pairs(settingsTemplate) do
	I.Settings.registerGroup(template)
end

I.Settings.registerPage {
	key = MODNAME,
	l10n = 'none',
	name = 'MoonHUD',
	description = 'Shows the phase of Masser and Secunda.\n'
		.. '- Click and drag to move it.\n'
		.. '- Click and mousewheel to resize, Shift+mousewheel for background opacity.\n'
		.. '- Icons come from a texture atlas; see the Moons tab to point at your own.',
}

--------------------------------------------------------------------------------
-- Mirror into globals, and react to changes
--------------------------------------------------------------------------------

-- Colours are stored as hex strings under the textLine renderer and as real
-- colour objects under SuperColorPicker2. Normalise on read.
local COLOR_KEYS = { TEXT_COLOR = true, HUD_BORDER_COLOR = true }
local function normalise(k, v)
	if COLOR_KEYS[k] and type(v) == 'string' then
		local ok, c = pcall(util.color.hex, (v:gsub('^#', '')))
		if ok then return c end
		return util.color.rgb(1, 1, 1)
	end
	return v
end

local function readAllSettings()
	for _, template in pairs(settingsTemplate) do
		local section = storage.playerSection(template.key)
		for _, entry in pairs(template.settings) do
			local val = section:get(entry.key)
			if val == nil then val = entry.default end
			_G[entry.key] = normalise(entry.key, val)
		end
	end
end

readAllSettings()

for _, template in pairs(settingsTemplate) do
	local section = storage.playerSection(template.key)
	section:subscribe(async:callback(function(_, setting)
		if setting == nil then
			readAllSettings()
		else
			_G[setting] = normalise(setting, section:get(setting))
		end

		-- Anything that changes the widget tree has to rebuild it.
		local REBUILD = {
			HUD_BORDER = true, HUD_BORDER_STYLE = true, HUD_BORDER_COLOR = true,
			HUD_PADDING = true, DISPLAY_MODE = true, LAYOUT = true,
			SHOW_MASSER = true, SHOW_SECUNDA = true, TEXT_ALIGNMENT = true,
			ATLAS_PATH = true, ATLAS_CELL = true, ICON_SIZE = true,
			ICON_SPACING = true, SHOW_MOON_NAMES = true, SHOW_SHADE = true,
		}
		if setting == nil or REBUILD[setting] then
			if createMoonHud then createMoonHud() end
			return
		end

		if updateMoonDisplay then updateMoonDisplay(true) end
	end))
end

return settingsTemplate
