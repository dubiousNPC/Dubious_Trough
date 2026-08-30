---@omw-context player
--[[
    cake_anim.lua -- optional equipping gestures

    Off by default. cake_player.lua requires this file only when the EQUIPANIM
    setting is on, and the require is pcall'd, so deleting the file is a
    supported way to opt out permanently.

    BLEND_MASK, NOT BONE_GROUP
    --------------------------
    The previous version built its mask from BONE_GROUP and was wrong. The two
    enums look interchangeable and are not:

        BONE_GROUP   LowerBody 1  Torso 2  LeftArm 3  RightArm 4   (an index)
        BLEND_MASK   LowerBody 1  Torso 2  LeftArm 4  RightArm 8   (a bitmask)

    `BONE_GROUP.Torso + BONE_GROUP.LeftArm + BONE_GROUP.RightArm` is 9, which
    as a blend mask reads LowerBody + RightArm -- the legs and one arm, almost
    the inverse of what was intended. `blendMask` wants BLEND_MASK, and
    BLEND_MASK.UpperBody (14) is already the torso-plus-both-arms constant, so
    no summing is needed at all.

    PRIORITY
    --------
    These are short cosmetic gestures, so they run at PRIORITY.Weapon on the
    upper body. PRIORITY.Scripted would pause every non-Scripted animation
    globally, freezing the walk cycle while the player puts on a mask.

    ANIMATION GROUPS
    ----------------
    The group names are placeholders; nothing ships them. Playing a group the
    skeleton does not define is a silent no-op, so this file is inert until
    real animations exist. When adding them, read the text keys out of the KF
    binary rather than assuming: a group keyed `loop start`/`loop stop` will
    not answer to `start`/`stop`, and the stuck or absent pose that results
    reads as a scripting bug when it is a naming one.
]]

local self = require('openmw.self')
local anim = require('openmw.animation')

local CAKE = require('scripts.cake.cake_shared')

local M = {}

-- Torso plus both arms, as a single named constant.
local UPPER_BODY = anim.BLEND_MASK.UpperBody

-- Category -> animation group. Keys must be real categories; the previous
-- version listed circlets, glasses, earrings, backpacks and cloaks, none of
-- which CAKE has, so every lookup missed. Validated below rather than trusted.
M.GROUPS = {
    masks    = 'cake_wear_face',
    smokes   = 'cake_wear_face',
    eyewear  = 'cake_wear_face',
    scarves  = 'cake_wear_neck',
    belts    = 'cake_wear_waist',
    bags     = 'cake_wear_waist',
    lanterns = 'cake_wear_waist',
}

for categoryName in pairs(M.GROUPS) do
    if not CAKE.CATEGORIES[categoryName] then
        error("cake_anim: '" .. categoryName .. "' is not a CAKE category")
    end
end

---Play the gesture for a category, if one is defined and the actor has it.
---@param categoryName string
---@return boolean played
function M.playEquip(categoryName)
    local group = M.GROUPS[categoryName]
    if not group then return false end

    -- Playing a group the actor's skeleton does not define is a no-op, not an
    -- error, so there is nothing here for a pcall to catch.
    anim.playBlended(self, group, {
        priority    = anim.PRIORITY.Weapon,
        blendMask   = UPPER_BODY,
        startKey    = 'start',
        stopKey     = 'stop',
        loops       = 0,
        autoDisable = true,
    })
    return true
end

---Cancel a gesture early, for a category swapped mid-animation.
function M.cancelEquip(categoryName)
    local group = M.GROUPS[categoryName]
    if not group then return end
    -- cancel lives on openmw.animation and takes the actor; it is not on
    -- I.AnimationController. Cancelling a group that is not playing is a no-op.
    anim.cancel(self, group)
end

return M
