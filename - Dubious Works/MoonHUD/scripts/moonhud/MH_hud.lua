-- MH_hud.lua  (PLAYER script)
--
-- On-screen moon phase widget. Structure, drag/scroll handling, border templates
-- and visibility rules follow TimeHUD and LocationHUD so it behaves the same way.
--
-- Reads phases from the MoonTracker interface (MH_tracker.lua), never from the
-- engine directly, so the HUD keeps showing something sensible in interiors.

ui      = require('openmw.ui')
util    = require('openmw.util')
core    = require('openmw.core')
async   = require('openmw.async')
storage = require('openmw.storage')
input   = require('openmw.input')
types   = require('openmw.types')
self    = require('openmw.self')
time    = require('openmw_aux.time')
I       = require('openmw.interfaces')
v2      = util.vector2

MODNAME = 'MoonHUD'

local C = require('scripts.moonhud.MH_constants')
borderTemplates = require('scripts.moonhud.MH_makeborder')

generalSection    = storage.playerSection('Settings' .. MODNAME .. 'General')
appearanceSection = storage.playerSection('Settings' .. MODNAME .. 'Appearance')

require('scripts.moonhud.MH_settings')

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

moonHud        = nil
local moonFlex = nil
local rowFor   = {}          -- moonName -> { icon = elem, text = elem }
local atlasCache = {}
local fadeStartTime = nil
local currentUiMode = nil
local shouldRefreshUiVisibility = nil
local stopTimerFn = nil
local saveData = {}

--------------------------------------------------------------------------------
-- Atlas
--------------------------------------------------------------------------------

-- One ui.texture per (moon, phase index), cut out of the sheet by offset.
-- Cached because ui.texture registers a resource each call.
local function atlasTexture(moonName, phaseIndex)
	local path = ATLAS_PATH
	if path == nil or path == '' then path = C.ATLAS_PATH end
	local cell = ATLAS_CELL or C.ATLAS_CELL
	local row  = C.ATLAS_ROW[moonName] or 0

	local id = path .. '|' .. cell .. '|' .. row .. '|' .. phaseIndex
	if atlasCache[id] then return atlasCache[id] end

	local ok, tex = pcall(ui.texture, {
		path   = path,
		offset = v2(phaseIndex * cell, row * cell),
		size   = v2(cell, cell),
	})
	if not ok then return nil end
	atlasCache[id] = tex
	return tex
end

--------------------------------------------------------------------------------
-- Text
--------------------------------------------------------------------------------

local function phaseLabel(moon)
	if PHASE_NAMING == 'Value' then return tostring(moon.phaseValue) end
	if PHASE_NAMING == 'Simple' then return moon.bucket end
	return moon.displayName
end

local function lineFor(moon)
	local parts = {}
	if SHOW_MOON_NAMES then parts[#parts + 1] = moon.name .. ':' end
	parts[#parts + 1] = phaseLabel(moon)
	local s = table.concat(parts, ' ')
	if SHOW_SOURCE then s = s .. ' [' .. tostring(moon.source) .. ']' end
	return s
end

--------------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------------

local function textElement(name, size)
	return {
		type = ui.TYPE.Text,
		name = name,
		props = {
			text = '',
			textColor = TEXT_COLOR,
			textShadow = true,
			textShadowColor = util.color.rgba(0, 0, 0, 0.9),
			textAlignV = ui.ALIGNMENT.Center,
			textAlignH = ui.ALIGNMENT.Start,
			textSize = size,
		},
	}
end

local MONTH_INDEX = {}
for i, n in ipairs(C.MONTH_NAMES) do MONTH_INDEX[n] = i end

-- Push the settings-driven anchor into the tracker whenever it changes.
local function syncShadeConfig()
	if not I.MoonTracker or not I.MoonTracker.setShadeConfig then return end
	I.MoonTracker.setShadeConfig {
		ANCHOR_MONTH  = MONTH_INDEX[SHADE_ANCHOR_MONTH] or C.SHADE.ANCHOR_MONTH,
		ANCHOR_DAY    = SHADE_ANCHOR_DAY or C.SHADE.ANCHOR_DAY,
		INTERVAL_DAYS = SHADE_INTERVAL or C.SHADE.INTERVAL_DAYS,
	}
end

local function shadeLabel(shade)
	if shade.active then return 'Shade of the Revenant' end
	if shade.daysUntil == 1 then return 'Shade: tomorrow' end
	return 'Shade: ' .. shade.daysUntil .. ' days (' .. shade.dateString .. ')'
end

local function buildRow(moonName)
	local showIcon = DISPLAY_MODE ~= 'Text'
	local showText = DISPLAY_MODE ~= 'Icons'
	local iconSize = ICON_SIZE or 32

	local content = ui.content {}
	local row = {
		type = ui.TYPE.Flex,
		name = 'row' .. moonName,
		props = {
			horizontal = true,
			autoSize = true,
			align = ui.ALIGNMENT.Center,
			arrange = ui.ALIGNMENT.Center,
		},
		content = content,
	}

	local icon, text
	if showIcon then
		icon = {
			type = ui.TYPE.Image,
			name = 'icon' .. moonName,
			props = {
				resource = atlasTexture(moonName, 0),
				size = v2(iconSize, iconSize),
				alpha = 1,
			},
		}
		content:add(icon)
		if showText then
			content:add { name = 'gap', props = { size = v2(ICON_SPACING or 6, 0) } }
		end
	end
	if showText then
		text = textElement('text' .. moonName, FONT_SIZE)
		content:add(text)
	end

	rowFor[moonName] = { icon = icon, text = text }
	return row
end

function createMoonHud()
	syncShadeConfig()
	if moonHud then
		moonHud:destroy()
		moonHud = nil
	end
	rowFor = {}

	local background = {
		type = ui.TYPE.Image,
		name = 'moonHudBackground',
		props = {
			resource = ui.texture { path = 'black' },
			relativeSize = v2(1, 1),
			alpha = BACKGROUND_ALPHA,
		},
	}

	local pad = v2(HUD_PADDING, HUD_PADDING)
	local template, paddingTemplate
	if HUD_BORDER then
		local borderFile = (HUD_BORDER_STYLE == 'thick' or HUD_BORDER_STYLE == 'verythick')
			and 'thick' or 'thin'
		local borderOffset =
			HUD_BORDER_STYLE == 'verythick' and 4
			or HUD_BORDER_STYLE == 'thick' and 3
			or HUD_BORDER_STYLE == 'normal' and 2
			or 1
		local borders = borderTemplates(borderFile, HUD_BORDER_COLOR, borderOffset, background, pad)
		template = borders.borders
		paddingTemplate = borders.padding
	else
		template = { content = ui.content {} }
		template.content:add(background)
		if HUD_PADDING > 0 then
			paddingTemplate = {
				type = ui.TYPE.Container,
				content = ui.content {
					{ props = { size = pad } },
					{ external = { slot = true }, props = { position = pad, relativeSize = v2(1, 1) } },
					{ props = { position = pad, relativePosition = v2(1, 1), size = pad } },
				},
			}
		end
	end

	local anchorPoint = v2(0, 0)
	if TEXT_ALIGNMENT == 'Center' then anchorPoint = v2(0.5, 0)
	elseif TEXT_ALIGNMENT == 'Right' then anchorPoint = v2(1, 0) end

	moonHud = ui.create {
		type = ui.TYPE.Container,
		layer = HUD_LOCK and 'Scene' or 'Modal',
		name = 'moonHud',
		template = template,
		props = {
			position = v2(HUD_X_POS, HUD_Y_POS),
			anchor = anchorPoint,
		},
		content = ui.content {},
		userData = { windowStartPosition = v2(HUD_X_POS, HUD_Y_POS) },
	}

	-- Drag to reposition, exactly as TimeHUD does it.
	moonHud.layout.events = {
		mousePress = async:callback(function(data, elem)
			if data.button == 1 and not HUD_LOCK then
				elem.userData = elem.userData or {}
				elem.userData.isDragging = true
				elem.userData.lastMousePos = data.position
			end
			moonHud:update()
		end),
		mouseRelease = async:callback(function(_, elem)
			if elem.userData then elem.userData.isDragging = false end
			moonHud:update()
		end),
		mouseMove = async:callback(function(data, elem)
			if elem.userData and elem.userData.isDragging then
				local delta = data.position - elem.userData.lastMousePos
				elem.userData.lastMousePos = data.position
				local newPosition = (moonHud.layout.props.position or v2(0, 0)) + delta
				generalSection:set('HUD_X_POS', math.floor(newPosition.x))
				generalSection:set('HUD_Y_POS', math.floor(newPosition.y))
				moonHud.layout.props.position = newPosition
				moonHud:update()
			end
		end),
	}

	local arrange = ui.ALIGNMENT.Start
	if TEXT_ALIGNMENT == 'Center' then arrange = ui.ALIGNMENT.Center
	elseif TEXT_ALIGNMENT == 'Right' then arrange = ui.ALIGNMENT.End end

	moonFlex = {
		type = ui.TYPE.Flex,
		name = 'moonFlex',
		props = {
			horizontal = (LAYOUT == 'Horizontal'),
			autoSize = true,
			arrange = arrange,
		},
		content = ui.content {},
	}

	if SHOW_MASSER then moonFlex.content:add(buildRow('Masser')) end
	if SHOW_MASSER and SHOW_SECUNDA then
		local gapSize = (LAYOUT == 'Horizontal') and v2(ICON_SPACING * 2, 0) or v2(0, 2)
		moonFlex.content:add { name = 'moonGap', props = { size = gapSize } }
	end
	if SHOW_SECUNDA then moonFlex.content:add(buildRow('Secunda')) end

	if SHOW_SHADE then
		if SHOW_MASSER or SHOW_SECUNDA then
			local gapSize = (LAYOUT == 'Horizontal') and v2(ICON_SPACING * 2, 0) or v2(0, 2)
			moonFlex.content:add { name = 'shadeGap', props = { size = gapSize } }
		end
		moonFlex.content:add(buildRow('Shade'))
	end

	if paddingTemplate then
		moonHud.layout.content:add {
			template = paddingTemplate,
			content = ui.content { moonFlex },
		}
	else
		moonHud.layout.content:add(moonFlex)
	end

	updateMoonDisplay(true)
end

--------------------------------------------------------------------------------
-- Update
--------------------------------------------------------------------------------

local lastSignature = nil

function updateMoonDisplay(force)
	if not moonHud then return end
	if not I.MoonTracker then
		refreshUiVisibility()
		return
	end

	local moons = I.MoonTracker.getMoons()
	local shade = I.MoonTracker.getShade and I.MoonTracker.getShade() or nil
	local signature = ''
	for _, name in ipairs(C.MOON_NAMES) do
		local m = moons[name]
		signature = signature .. name .. (m and (m.index .. (m.source or '')) or '-')
	end
	if shade then signature = signature .. '|S' .. shade.daysUntil end
	if not force and signature == lastSignature then
		refreshUiVisibility()
		return
	end
	lastSignature = signature

	for name, elems in pairs(rowFor) do
		local moon = moons[name]
		if name == 'Shade' then
			local visible = shade ~= nil
				and (SHADE_DISPLAY ~= 'Only When Active' or shade.active)
			if elems.icon then
				local cell = (shade and shade.active and SHADE_DISPLAY ~= 'Countdown Only')
					and C.ATLAS_SHADE_ACTIVE or C.ATLAS_SHADE_INACTIVE
				local tex = atlasTexture('Shade', cell)
				if tex then elems.icon.props.resource = tex end
				elems.icon.props.size = v2(ICON_SIZE, ICON_SIZE)
				elems.icon.props.visible = visible
				elems.icon.props.alpha = 1
			end
			if elems.text then
				elems.text.props.text = shade and shadeLabel(shade) or 'Shade: ?'
				elems.text.props.textColor = TEXT_COLOR
				elems.text.props.textSize = FONT_SIZE
				elems.text.props.visible = visible
			end
		elseif moon then
			if elems.icon then
				local tex = atlasTexture(name, moon.index)
				if tex then elems.icon.props.resource = tex end
				elems.icon.props.size = v2(ICON_SIZE, ICON_SIZE)
				if DIM_WITH_ALPHA and moon.alpha ~= nil then
					elems.icon.props.alpha = 0.25 + 0.75 * moon.alpha
				else
					elems.icon.props.alpha = 1
				end
			end
			if elems.text then
				elems.text.props.text = lineFor(moon)
				elems.text.props.textColor = TEXT_COLOR
				elems.text.props.textSize = FONT_SIZE
			end
		elseif elems.text then
			elems.text.props.text = (SHOW_MOON_NAMES and (name .. ': ') or '') .. '?'
		end
	end

	moonHud:update()
	refreshUiVisibility()
end

--------------------------------------------------------------------------------
-- Visibility
--------------------------------------------------------------------------------

local function chargenFinished()
	if saveData.chargenFinished then return true end
	if types.Player.isCharGenFinished and types.Player.isCharGenFinished(self) then
		saveData.chargenFinished = true
		return true
	end
	if types.Player.getBirthSign(self) ~= '' then
		saveData.chargenFinished = true
		return true
	end
	return false
end

local function anyMoonVisible()
	if not I.MoonTracker then return true end
	local moons = I.MoonTracker.getMoons()
	local sawAlpha = false
	for _, m in pairs(moons) do
		if m.alpha ~= nil then
			sawAlpha = true
			if m.alpha > 0.01 then return true end
		end
	end
	-- No alpha data means we are indoors or the cell is inactive; do not hide
	-- on the strength of a guess.
	return not sawAlpha
end

function refreshUiVisibility()
	if not moonHud then return end

	local allowed = chargenFinished()
		and I.UI.isHudVisible()
		and (not HUD_EXTERIOR or self.cell:hasTag('QuasiExterior') or self.cell.isExterior)
		and (not HUD_NIGHT_ONLY or anyMoonVisible())

	local visible
	if not allowed then
		visible = false
	elseif HUD_DISPLAY == 'Always' then
		visible = true
	elseif HUD_DISPLAY == 'Never' then
		visible = false
	elseif HUD_DISPLAY == 'Interface Only' then
		visible = currentUiMode == 'Interface'
	elseif HUD_DISPLAY == 'Hide on Interface' then
		visible = currentUiMode == nil
	else -- Hide on Dialogue Only
		visible = currentUiMode ~= 'Dialogue' and currentUiMode ~= 'Barter'
	end

	if visible and SHOW_MODE == 'On Phase Change' and fadeStartTime == nil then
		visible = false
	end

	moonHud.layout.props.visible = visible
	moonHud:update()
end

--------------------------------------------------------------------------------
-- Handlers
--------------------------------------------------------------------------------

local function onFrame()
	if shouldRefreshUiVisibility then
		shouldRefreshUiVisibility = shouldRefreshUiVisibility - 1
		if shouldRefreshUiVisibility <= 0 then
			shouldRefreshUiVisibility = nil
			refreshUiVisibility()
		end
	end

	if fadeStartTime and moonHud then
		local elapsed = core.getSimulationTime() - fadeStartTime
		if elapsed < HOLD_DURATION then
			moonHud.layout.props.alpha = 1
		elseif elapsed < HOLD_DURATION + FADE_DURATION then
			moonHud.layout.props.alpha = 1 - (elapsed - HOLD_DURATION) / math.max(FADE_DURATION, 0.001)
			moonHud:update()
		else
			moonHud.layout.props.alpha = 0
			fadeStartTime = nil
			refreshUiVisibility()
		end
	end
end

function UiModeChanged(data)
	if not moonHud then return end
	currentUiMode = data.newMode
	refreshUiVisibility()
	shouldRefreshUiVisibility = 3
	if data.oldMode == 'Rest' then updateMoonDisplay(true) end
end

local function onPhaseChanged(data)
	updateMoonDisplay(true)
	if SHOW_MODE == 'On Phase Change' then
		fadeStartTime = core.getSimulationTime()
		if moonHud then moonHud.layout.props.alpha = 1 end
		refreshUiVisibility()
	end
end

local function onLoad(data)
	saveData = data or {}

	local layerId = ui.layers.indexOf('HUD')
	local hudLayerSize = ui.layers[layerId].size
	generalSection:set('HUD_X_POS', math.floor(math.max(-200, math.min(HUD_X_POS, hudLayerSize.x + 200))))
	generalSection:set('HUD_Y_POS', math.floor(math.max(-50, math.min(HUD_Y_POS, hudLayerSize.y - 20))))

	syncShadeConfig()
	createMoonHud()

	if stopTimerFn then stopTimerFn() end
	stopTimerFn = time.runRepeatedly(function() updateMoonDisplay(false) end,
		(UPDATE_INTERVAL or 30) * time.minute, {
			type = time.GameTime,
			initialDelay = 0,
		})
end

-- Click-and-scroll resize, same gesture as TimeHUD.
if input.triggers['MenuMouseWheelUp'] then
	input.registerTriggerHandler('MenuMouseWheelUp', async:callback(function()
		if moonHud and moonHud.layout.userData and moonHud.layout.userData.isDragging then
			if input.isShiftPressed() then
				appearanceSection:set('BACKGROUND_ALPHA', math.min(1, BACKGROUND_ALPHA + 0.1))
			else
				appearanceSection:set('FONT_SIZE', FONT_SIZE + 1)
			end
		end
	end))
end
if input.triggers['MenuMouseWheelDown'] then
	input.registerTriggerHandler('MenuMouseWheelDown', async:callback(function()
		if moonHud and moonHud.layout.userData and moonHud.layout.userData.isDragging then
			if input.isShiftPressed() then
				appearanceSection:set('BACKGROUND_ALPHA', math.max(0, BACKGROUND_ALPHA - 0.1))
			else
				appearanceSection:set('FONT_SIZE', math.max(5, FONT_SIZE - 1))
			end
		end
	end))
end

input.registerTriggerHandler('ToggleHUD', async:callback(function()
	refreshUiVisibility()
end))

return {
	engineHandlers = {
		onInit = onLoad,
		onLoad = onLoad,
		onSave = function() return saveData end,
		onFrame = onFrame,
	},
	eventHandlers = {
		UiModeChanged = UiModeChanged,
		MoonTracker_PhaseChanged = onPhaseChanged,
		MoonTracker_ShadeOfTheRevenant = onPhaseChanged,
	},
}
