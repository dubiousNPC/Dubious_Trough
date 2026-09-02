---@omw-context local|player
--[[
    bones.lua -- weapon type to attachment bone

    These are the same bones OpenMW's own weapon sheathing uses. That overlap
    is the point -- a sheathed sword should sit where the engine would put it
    -- but it is also the source of the clash this file has to be careful
    about, so occupancy is tracked BY BONE, not by weapon type.

    Why that distinction matters: `Bip01 LongBladeOneHand` is shared by two
    weapon types, and `Bip01 Ammo` by two more. A dedup key of "weapon type"
    therefore lets a second mesh land on a bone that is already taken. See
    `sharedBones()` below and its use in common.lua.
]]

local types = require('openmw.types')

local M = {}

local W = types.Weapon.TYPE

-- AxeOneHand deliberately shares the one-hand long blade bone: the sheathing
-- skeleton does define `Bip01 AxeOneHand`, but it is positioned for a very
-- different silhouette and most axe meshes look wrong on it. Sharing is the
-- right call -- it just has to be accounted for downstream.
local BONE_BY_TYPE = {
    [W.ShortBladeOneHand] = "Bip01 ShortBladeOneHand",
    [W.LongBladeOneHand]  = "Bip01 LongBladeOneHand",
    [W.LongBladeTwoHand]  = "Bip01 LongBladeTwoClose",
    [W.BluntOneHand]      = "Bip01 BluntOneHand",
    [W.BluntTwoClose]     = "Bip01 BluntTwoClose",
    [W.BluntTwoWide]      = "Bip01 BluntTwoWide",
    [W.SpearTwoWide]      = "Bip01 SpearTwoWide",
    [W.AxeOneHand]        = "Bip01 AxeOneHand",
    [W.AxeTwoHand]        = "Bip01 AxeTwoClose",
    [W.MarksmanBow]       = "Bip01 MarksmanBow",
    [W.MarksmanCrossbow]  = "Bip01 MarksmanCrossbow",
    [W.MarksmanThrown]    = "Bip01 MarksmanThrown",
    [W.Arrow]             = "Bip01 Ammo",
    [W.Bolt]              = "Bip01 Ammo",
}

M.SHIELD_BONE        = "Bip01 AttachShield"
M.ATTACH_WEAPON_BONE = "Bip01 AttachWeapon"

function M.boneForWeapon(weaponType)
    return BONE_BY_TYPE[weaponType] or M.ATTACH_WEAPON_BONE
end

---Bones that more than one weapon type maps onto. Computed rather than listed,
---so editing BONE_BY_TYPE cannot leave a stale list behind.
---@return table<string, boolean>
function M.sharedBones()
    local seen, shared = {}, {}
    for _, bone in pairs(BONE_BY_TYPE) do
        if seen[bone] then shared[bone] = true end
        seen[bone] = true
    end
    return shared
end

return M
