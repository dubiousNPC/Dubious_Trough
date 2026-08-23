-- BSC_p.lua  (PLAYER script)
--
-- A dial compass driven by a vertical texture atlas.
--
-- PERFORMANCE NOTES, since that was the brief:
--
--   * Every atlas frame is turned into a ui.texture ONCE, at load or when the
--     atlas settings change. ui.texture is never called from onFrame.
--   * onFrame does no table allocation at all. Locals and numbers only.
--   * The element is only :update()d when the heading crosses into a new frame.
--     With 36 frames that is once per 10 degrees of turn, not once per frame.
--   * When the compass is hidden (indoors, HUD off, menu open) onFrame returns
--     after a single boolean test.
--   * The heading itself comes from camera.getYaw(), a scalar read, rather than
--     camera.viewportToWorldVector() which does a matrix transform.
--   * SAMPLE_EVERY gates how often the heading is even read.
--
-- Settings are read from globals rather than storage for the same reason; see
-- BSC_settings.lua.

ui      = require('openmw.ui')
util    = require('openmw.util')
core    = require('openmw.core')
async   = require('openmw.async')
storage = require('openmw.storage')
input   = require('openmw.input')
types   = require('openmw.types')
camera  = require('openmw.camera')
self    = require('openmw.self')
I       = require('openmw.interfaces')
v2      = util.vector2

MODNAME = 'BSCompass'

borderTemplates = require('scripts.bscompass.BSC_border')

generalSection = storage.playerSection('Settings' .. MODNAME .. 'General')
compassSection = storage.playerSection('Settings' .. MODNAME .. 'Compass')

require('scripts.bscompass.BSC_settings')

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------

compassHud = nil
local compassImage        = nil    -- the layout table, poked directly
local tiles               = {}     -- pre-built ui.texture, 1-based
local tileCount           = 0
local currentTile         = -1
local frameCountdown      = 1
local hudActive           = false  -- the single hot-path gate
local currentUiMode       = nil
local shouldRefreshUiVisibility = nil
local saveData            = {}

local DEG_PER_RAD = 180 / math.pi

--------------------------------------------------------------------------------
-- Atlas
--------------------------------------------------------------------------------

-- Builds every frame of the strip up front. This is the whole performance story:
-- pay once here so onFrame never has to allocate.
function rebuildTiles()
	local path  = ATLAS_PATH
	if path == nil or path == '' then path = 'textures/bscompass/BSCompasAtlas.png' end
	local cell  = ATLAS_CELL or 88
	local count = ATLAS_TILES or 36

	tiles = {}
	for i = 0, count - 1 do
		local ok, tex = pcall(ui.texture, {
			path   = path,
			offset = v2(0, i * cell),
			size   = v2(cell, cell),
		})
		tiles[i + 1] = ok and tex or nil
	end
	tileCount = count
	currentTile = -1        -- force the next frame to apply a texture
end

--------------------------------------------------------------------------------
-- Heading
--------------------------------------------------------------------------------

-- Yaw in degrees, normalised to [0, 360). 0 is north, increasing clockwise.
local function headingDegrees()
	local yaw
	if FACING_SOURCE == 'Body' then
		yaw = self.rotation:getYaw()
	else
		yaw = camera.getYaw()
	end
	local deg = yaw * DEG_PER_RAD
	deg = deg % 360
	if deg < 0 then deg = deg + 360 end
	return deg
end

-- Atlas frame for a heading.
--
-- The needle in BSCompasAtlas.png rotates CLOCKWISE by 10 degrees per frame
-- (measured: frame 0 at -91 degrees, frame 9 at 171, frame 18 at 88, frame 27 at 10).
-- A world-fixed marker has to rotate COUNTER-clockwise on screen as the player
-- turns clockwise, so the frame index has to advance as the heading DECREASES.
-- Hence the subtraction. Verified consistent at all four cardinals.
local function tileForHeading(deg)
	local n = tileCount
	if n < 1 then return 0 end
	local step = 360 / n
	local raw = math.floor((deg + (HEADING_OFFSET or 0)) / step + 0.5)
	if INVERT_ROTATION then
		return raw % n
	end
	return (n - raw) % n
end

--------------------------------------------------------------------------------
-- Style
--------------------------------------------------------------------------------

-- Applied without rebuilding the tree, for settings that only touch props.
function applyCompassStyle()
	if not compassHud or not compassImage then return end
	local size = COMPASS_SIZE or 88
	compassImage.props.size  = v2(size, size)
	compassImage.props.color = COMPASS_TINT
	compassImage.props.alpha = COMPASS_ALPHA
	compassHud.layout.props.position = v2(HUD_X_POS, HUD_Y_POS)
	if compassHudBackground then
		compassHudBackground.props.alpha = BACKGROUND_ALPHA
	end
	frameCountdown = 1
	currentTile = -1
	compassHud:update()
end

--------------------------------------------------------------------------------
-- Build
--------------------------------------------------------------------------------

function createCompassHud()
	if compassHud then
		compassHud:destroy()
		compassHud = nil
		compassImage = nil
		compassHudBackground = nil
	end
	if tileCount == 0 then rebuildTiles() end

	local size = COMPASS_SIZE or 88

	compassImage = {
		type = ui.TYPE.Image,
		name = 'compassImage',
		props = {
			resource = tiles[1],
			size     = v2(size, size),
			color    = COMPASS_TINT,
			alpha    = COMPASS_ALPHA,
		},
	}

	local template, paddingTemplate
	local pad = v2(HUD_PADDING or 0, HUD_PADDING or 0)

	if HUD_BACKGROUND or HUD_BORDER then
		compassHudBackground = {
			type = ui.TYPE.Image,
			name = 'compassHudBackground',
			props = {
				resource = ui.texture { path = 'black' },
				relativeSize = v2(1, 1),
				alpha = HUD_BACKGROUND and (BACKGROUND_ALPHA or 0.5) or 0,
			},
		}
		if HUD_BORDER then
			local borderFile = (HUD_BORDER_STYLE == 'thick' or HUD_BORDER_STYLE == 'verythick')
				and 'thick' or 'thin'
			local borderOffset =
				HUD_BORDER_STYLE == 'verythick' and 4
				or HUD_BORDER_STYLE == 'thick' and 3
				or HUD_BORDER_STYLE == 'normal' and 2
				or 1
			local borders = borderTemplates(borderFile, HUD_BORDER_COLOR, borderOffset,
				compassHudBackground, pad)
			template = borders.borders
			paddingTemplate = borders.padding
		else
			template = { content = ui.content {} }
			template.content:add(compassHudBackground)
		end
	else
		template = { content = ui.content {} }
	end

	compassHud = ui.create {
		type = ui.TYPE.Container,
		layer = HUD_LOCK and 'Scene' or 'Modal',
		name = 'compassHud',
		template = template,
		props = { position = v2(HUD_X_POS, HUD_Y_POS) },
		content = ui.content {},
		userData = {},
	}

	-- Drag to reposition, same gesture as TimeHUD and ErnCompass.
	compassHud.layout.events = {
		mousePress = async:callback(function(data, elem)
			if data.button == 1 and not HUD_LOCK then
				elem.userData = elem.userData or {}
				elem.userData.isDragging = true
				elem.userData.lastMousePos = data.position
			end
			compassHud:update()
		end),
		mouseRelease = async:callback(function(_, elem)
			if elem.userData then elem.userData.isDragging = false end
			compassHud:update()
		end),
		mouseMove = async:callback(function(data, elem)
			if elem.userData and elem.userData.isDragging then
				local delta = data.position - elem.userData.lastMousePos
				elem.userData.lastMousePos = data.position
				local newPosition = (compassHud.layout.props.position or v2(0, 0)) + delta
				generalSection:set('HUD_X_POS', math.floor(newPosition.x))
				generalSection:set('HUD_Y_POS', math.floor(newPosition.y))
				compassHud.layout.props.position = newPosition
				compassHud:update()
			end
		end),
	}

	if paddingTemplate then
		compassHud.layout.content:add {
			template = paddingTemplate,
			content = ui.content { compassImage },
		}
	else
		compassHud.layout.content:add(compassImage)
	end

	currentTile = -1
	frameCountdown = 1
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

-- Sets hudActive, which is the only thing onFrame checks in the common case.
function refreshUiVisibility()
	if not compassHud then hudActive = false return end

	local allowed = chargenFinished()
		and I.UI.isHudVisible()
		and (not HUD_EXTERIOR or self.cell.isExterior or self.cell:hasTag('QuasiExterior'))

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

	if compassHud.layout.props.visible ~= visible then
		compassHud.layout.props.visible = visible
		compassHud:update()
	end
	hudActive = visible
end

--------------------------------------------------------------------------------
-- The hot path
--------------------------------------------------------------------------------

local function onFrame()
	if shouldRefreshUiVisibility then
		shouldRefreshUiVisibility = shouldRefreshUiVisibility - 1
		if shouldRefreshUiVisibility <= 0 then
			shouldRefreshUiVisibility = nil
			refreshUiVisibility()
		end
	end

	-- Hidden: one boolean and out. No heading read, no arithmetic, no allocation.
	if not hudActive then return end

	frameCountdown = frameCountdown - 1
	if frameCountdown > 0 then return end
	frameCountdown = SAMPLE_EVERY or 2

	local tile = tileForHeading(headingDegrees())
	if tile == currentTile then return end     -- the usual case while turning

	local tex = tiles[tile + 1]
	if tex == nil then return end
	currentTile = tile
	compassImage.props.resource = tex
	compassHud:update()
end

--------------------------------------------------------------------------------
-- Handlers
--------------------------------------------------------------------------------

function UiModeChanged(data)
	if not compassHud then return end
	currentUiMode = data.newMode
	refreshUiVisibility()
	shouldRefreshUiVisibility = 3
end

local function onLoad(data)
	saveData = data or {}

	local layerId = ui.layers.indexOf('HUD')
	local hudLayerSize = ui.layers[layerId].size
	generalSection:set('HUD_X_POS', math.floor(math.max(-200, math.min(HUD_X_POS, hudLayerSize.x + 200))))
	generalSection:set('HUD_Y_POS', math.floor(math.max(-50, math.min(HUD_Y_POS, hudLayerSize.y - 20))))

	rebuildTiles()
	createCompassHud()
end

-- Click-and-scroll to resize, matching TimeHUD.
if input.triggers['MenuMouseWheelUp'] then
	input.registerTriggerHandler('MenuMouseWheelUp', async:callback(function()
		if compassHud and compassHud.layout.userData and compassHud.layout.userData.isDragging then
			compassSection:set('COMPASS_SIZE', math.min(320, (COMPASS_SIZE or 88) + 4))
		end
	end))
end
if input.triggers['MenuMouseWheelDown'] then
	input.registerTriggerHandler('MenuMouseWheelDown', async:callback(function()
		if compassHud and compassHud.layout.userData and compassHud.layout.userData.isDragging then
			compassSection:set('COMPASS_SIZE', math.max(24, (COMPASS_SIZE or 88) - 4))
		end
	end))
end

input.registerTriggerHandler('ToggleHUD', async:callback(function()
	refreshUiVisibility()
end))

return {
	engineHandlers = {
		onInit  = onLoad,
		onLoad  = onLoad,
		onSave  = function() return saveData end,
		onFrame = onFrame,
	},
	eventHandlers = {
		UiModeChanged = UiModeChanged,
		-- Same event ErnCompass and the HUD transparency mods use, so the two
		-- fade together if you run both.
		HUDTransparencyChange = function(data)
			if compassHud then
				compassHud.layout.props.alpha = data.alpha
				compassHud:update()
			end
		end,
	},
}
