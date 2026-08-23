-- BSC_settings.lua
--
-- Settings for BSCompass. Group layout and key naming follow TimeHUD and
-- LocationHUD so the page sits consistently alongside them.
--
-- Each setting is mirrored into a global of the same name (COMPASS_SIZE,
-- HUD_X_POS, ...) which the main script reads directly. Reading a global in
-- onFrame is a lot cheaper than a storage lookup, which matters here because
-- this HUD samples every frame.

local core    = require('openmw.core')
local ui      = require('openmw.ui')
local util    = require('openmw.util')
local storage = require('openmw.storage')
local async   = require('openmw.async')
local I       = require('openmw.interfaces')

local v2 = util.vector2

MODNAME = MODNAME or 'BSCompass'

--------------------------------------------------------------------------------
-- Renderer selection
--------------------------------------------------------------------------------
-- SuperSettingsRenderers gives much nicer sliders, selects and a colour wheel.
-- If you do not have it installed, set this to false and the page falls back to
-- OpenMW's built-in renderers. Nothing else changes.
local SUPER = true

local R_SLIDER = SUPER and 'SuperSlider6'      or 'number'
local R_SELECT = SUPER and 'SuperSelect3'      or 'select'
local R_COLOR  = SUPER and 'SuperColorPicker4' or 'textLine'

local function sliderArg(min, max, step, unit)
	if SUPER then
		return { min = min, max = max, step = step or 1, unit = unit or '',
		         showResetButton = true, tinyReset = true, width = 200 }
	end
	return { min = min, max = max }
end

local function selectArg(items)
	if SUPER then return { items = items, l10n = 'none', width = 170 } end
	return { disabled = false, l10n = 'none', items = items }
end

local function colorDefault(hex)
	if SUPER then return util.color.hex(hex) end
	return hex
end

--------------------------------------------------------------------------------

local layerId      = ui.layers.indexOf('HUD')
local hudLayerSize = ui.layers[layerId].size

local presetColors = { 'FFFFFF', 'caa560', 'dfc99f', 'eee2c9', 'd4b77f', '81cded', 'c8a2c8' }

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
			description = 'When to show the compass.',
			renderer = R_SELECT,
			default = 'Always',
			argument = selectArg { 'Always', 'Interface Only', 'Hide on Interface', 'Hide on Dialogue Only', 'Never' },
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
			renderer = R_SLIDER,
			integer = true,
			default = math.floor(hudLayerSize.x - 120),
			argument = sliderArg(-200, math.floor(hudLayerSize.x) + 200, 1, 'px'),
		},
		{
			key = 'HUD_Y_POS',
			name = 'Y Position',
			description = '',
			renderer = R_SLIDER,
			integer = true,
			default = 40,
			argument = sliderArg(-50, math.floor(hudLayerSize.y), 1, 'px'),
		},
		{
			key = 'HUD_EXTERIOR',
			name = 'Only display outdoors',
			description = 'A compass is not much use in a tomb. Leaving this on also means\nzero per-frame work while you are inside.',
			renderer = 'checkbox',
			default = true,
		},
	},
}

--------------------------------------------------------------------------------
key = 'Compass'
settingsTemplate[key] = {
	key = 'Settings' .. MODNAME .. key,
	page = MODNAME,
	l10n = 'none',
	name = 'Compass',
	permanentStorage = true,
	order = getOrder(),
	settings = {
		{
			key = 'COMPASS_SIZE',
			name = 'Size',
			description = 'Pixels. The atlas tile is 88, so 88 is 1:1 and anything larger will soften.',
			renderer = R_SLIDER,
			integer = true,
			default = 88,
			argument = sliderArg(24, 320, 1, 'px'),
		},
		{
			key = 'COMPASS_ALPHA',
			name = 'Opacity',
			description = '',
			renderer = R_SLIDER,
			default = 1.0,
			argument = sliderArg(0, 1, 0.05),
		},
		{
			key = 'COMPASS_TINT',
			name = 'Tint',
			description = 'Multiplied over the artwork. White leaves it untouched.',
			renderer = R_COLOR,
			default = colorDefault('FFFFFF'),
			argument = { presetColors = presetColors },
		},
		{
			key = 'FACING_SOURCE',
			name = 'Facing Source',
			description = 'Camera follows where you are looking, including in third person and vanity mode.\nBody follows the character, ignoring the camera.',
			renderer = R_SELECT,
			default = 'Camera',
			argument = selectArg { 'Camera', 'Body' },
		},
		{
			key = 'INVERT_ROTATION',
			name = 'Invert Rotation',
			description = 'Flip if the needle turns the wrong way. Sanity check: face north, then\nturn right. A world-fixed needle should swing LEFT.',
			renderer = 'checkbox',
			default = false,
		},
		{
			key = 'HEADING_OFFSET',
			name = 'Heading Offset',
			description = 'Rotates the artwork. Use if your atlas does not start at north.',
			renderer = R_SLIDER,
			default = 0,
			argument = sliderArg(-180, 180, 1, ' deg'),
		},
		{
			key = 'SAMPLE_EVERY',
			name = 'Sample Every N Frames',
			description = 'How often to check your heading. 1 is every frame.\n2 or 3 is imperceptible while turning and does proportionally less work.\nThis only gates the check; the texture still swaps only when the tile changes.',
			renderer = R_SLIDER,
			integer = true,
			default = 2,
			argument = sliderArg(1, 10, 1, ' frames'),
		},
		{
			key = 'ATLAS_PATH',
			name = 'Atlas Path',
			description = 'VFS path to the compass sheet. Vertical strip, north first.',
			renderer = 'textLine',
			default = 'textures/bscompass/BSCompasAtlas.png',
		},
		{
			key = 'ATLAS_TILES',
			name = 'Atlas Tile Count',
			description = 'Frames in the strip. 36 gives one frame per 10 degrees.',
			renderer = R_SLIDER,
			integer = true,
			default = 36,
			argument = sliderArg(4, 360, 1),
		},
		{
			key = 'ATLAS_CELL',
			name = 'Atlas Tile Size',
			description = 'Width and height of one frame, in pixels.',
			renderer = R_SLIDER,
			integer = true,
			default = 88,
			argument = sliderArg(8, 512, 1, 'px'),
		},
	},
}

--------------------------------------------------------------------------------
key = 'Frame'
settingsTemplate[key] = {
	key = 'Settings' .. MODNAME .. key,
	page = MODNAME,
	l10n = 'none',
	name = 'Frame',
	permanentStorage = true,
	order = getOrder(),
	settings = {
		{
			key = 'HUD_BACKGROUND',
			name = 'Background',
			description = 'Draw a panel behind the compass. Off by default: the artwork already\nhas its own bezel.',
			renderer = 'checkbox',
			default = false,
		},
		{
			key = 'BACKGROUND_ALPHA',
			name = 'Background Opacity',
			description = '',
			renderer = R_SLIDER,
			default = 0.5,
			argument = sliderArg(0, 1, 0.05),
		},
		{
			key = 'HUD_BORDER',
			name = 'Border',
			description = 'Same border styles as TimeHUD, LocationHUD and Quickloot.',
			renderer = 'checkbox',
			default = false,
		},
		{
			key = 'HUD_BORDER_STYLE',
			name = 'Border Style',
			description = '',
			renderer = R_SELECT,
			default = 'thin',
			argument = selectArg { 'thin', 'normal', 'thick', 'verythick' },
		},
		{
			key = 'HUD_BORDER_COLOR',
			name = 'Border Color',
			description = '',
			renderer = R_COLOR,
			default = colorDefault('FFFFFF'),
			argument = { presetColors = presetColors },
		},
		{
			key = 'HUD_PADDING',
			name = 'Padding',
			description = 'Inner spacing in pixels, both axes.',
			renderer = R_SLIDER,
			integer = true,
			default = 4,
			argument = sliderArg(0, 50, 1, 'px'),
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
	name = 'BSCompass',
	description = 'A dial compass driven by a vertical texture atlas.\n'
		.. '- Click and drag to move it.\n'
		.. '- Click and mousewheel to resize.\n'
		.. '- Every frame of the atlas is built once at load, and the texture is only\n'
		.. '  swapped when the heading crosses into a new frame.',
}

--------------------------------------------------------------------------------
-- Mirror into globals
--------------------------------------------------------------------------------

local COLOR_KEYS = { COMPASS_TINT = true, HUD_BORDER_COLOR = true }
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

-- Anything that changes the widget tree, or the atlas itself, needs a rebuild.
-- Everything else can be poked straight into the live element.
local REBUILD = {
	HUD_BORDER = true, HUD_BORDER_STYLE = true, HUD_BORDER_COLOR = true,
	HUD_PADDING = true, HUD_BACKGROUND = true, HUD_LOCK = true,
}
local RETILE = { ATLAS_PATH = true, ATLAS_TILES = true, ATLAS_CELL = true }

for _, template in pairs(settingsTemplate) do
	local section = storage.playerSection(template.key)
	section:subscribe(async:callback(function(_, setting)
		if setting == nil then
			readAllSettings()
		else
			_G[setting] = normalise(setting, section:get(setting))
		end

		if setting == nil or RETILE[setting] then
			if rebuildTiles then rebuildTiles() end
			if createCompassHud then createCompassHud() end
			return
		end
		if REBUILD[setting] then
			if createCompassHud then createCompassHud() end
			return
		end
		if applyCompassStyle then applyCompassStyle() end
	end))
end

return settingsTemplate
