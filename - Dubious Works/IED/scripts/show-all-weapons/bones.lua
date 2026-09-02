---@omw-context local|player
--[[
    bones.lua -- weapon type to attachment bone

    Two skeletons are supported, selected by the "Sheath bones" setting.

    STANDARD  the bones OpenMW's own weapon sheathing uses. That overlap is
              the point -- a sheathed sword should sit where the engine would
              put it.
    SEM       the extra bones added by semaroBones.nif, "Sem"-suffixed and
              positioned for sheathed gear rather than reused from the
              sheathing rig.

    SEM IS AN OVERRIDE LAYER, NOT A SECOND TABLE. Anything without a Sem entry
    falls through to the standard bone, so adding a weapon type is one edit and
    the file stays honest about which bones that skeleton actually adds.

    VERIFIED against semaroBones.nif, whose Bip01 list contains exactly 13 Sem
    bones. Three consequences, each a silent failure in earlier drafts because
    attachVfx tests hasBone and a miss reads as "nothing to show":
      * There is no `Bip01 AmmoSem`. Arrow/Bolt must NOT be given one.
      * The Sem shield bone is `Bip01 AttachShieldSem`, not `AttachShield`.
      * That skeleton also lacks plain `Bip01 Ammo`, so ammo cannot display on
        it either way. A property of the skeleton, not of this file.

    Occupancy is tracked BY BONE, not by weapon type: common.lua keys its
    `boneTaken` set on the resolved bone name, so a bone shared by two weapon
    types cannot take a second mesh. On STANDARD, `Bip01 LongBladeOneHand`
    carries both long blades and one-hand axes; on SEM, axes get their own bone
    and that collision disappears -- which is why sharedBones() takes the
    skeleton as an argument.

    NOTE: sharedBones() is currently unused. common.lua achieves the same thing
    with boneTaken, which needs no precomputed list. It is kept because a caller
    wanting to reason about collisions before attaching is a plausible need, but
    an earlier version of this comment claimed common.lua called it, and it did
    not. Delete it if that stays true.

    Why that distinction matters: `Bip01 LongBladeOneHand` is shared by two
    weapon types, and `Bip01 Ammo` by two more. A dedup key of "weapon type"
    therefore lets a second mesh land on a bone that is already taken. See
    `sharedBones()` below and its use in common.lua.
]]

local types = require('openmw.types')

local M = {}

local W = types.Weapon.TYPE

-- AxeOneHand shares the one-hand long blade bone HERE only: the sheathing
-- skeleton does define `Bip01 AxeOneHand`, but it is positioned for a very
-- different silhouette and most axe meshes look wrong on it. The Sem skeleton
-- has no such problem, which is why it overrides that row.
local BONE_BY_TYPE = {
    [W.ShortBladeOneHand] = "Bip01 ShortBladeOneHand",
    [W.LongBladeOneHand]  = "Bip01 LongBladeOneHand",
    [W.LongBladeTwoHand]  = "Bip01 LongBladeTwoClose",
    [W.BluntOneHand]      = "Bip01 BluntOneHand",
    [W.BluntTwoClose]     = "Bip01 BluntTwoClose",
    [W.BluntTwoWide]      = "Bip01 BluntTwoWide",
    [W.SpearTwoWide]      = "Bip01 SpearTwoWide",
    [W.AxeOneHand]        = "Bip01 LongBladeOneHand",
    [W.AxeTwoHand]        = "Bip01 AxeTwoClose",
    [W.MarksmanBow]       = "Bip01 MarksmanBow",
    [W.MarksmanCrossbow]  = "Bip01 MarksmanCrossbow",
    [W.MarksmanThrown]    = "Bip01 MarksmanThrown",
    [W.Arrow]             = "Bip01 Ammo",
    [W.Bolt]              = "Bip01 Ammo",
}

-- Only the 12 weapon bones semaroBones.nif actually defines. Deliberately no
-- Arrow/Bolt row -- see the header.
local SEM_OVERRIDE = {
    [W.ShortBladeOneHand] = "Bip01 ShortBladeOneHandSem",
    [W.LongBladeOneHand]  = "Bip01 LongBladeOneHandSem",
    [W.LongBladeTwoHand]  = "Bip01 LongBladeTwoCloseSem",
    [W.BluntOneHand]      = "Bip01 BluntOneHandSem",
    [W.BluntTwoClose]     = "Bip01 BluntTwoCloseSem",
    [W.BluntTwoWide]      = "Bip01 BluntTwoWideSem",
    [W.SpearTwoWide]      = "Bip01 SpearTwoWideSem",
    [W.AxeOneHand]        = "Bip01 AxeOneHandSem",
    [W.AxeTwoHand]        = "Bip01 AxeTwoCloseSem",
    [W.MarksmanBow]       = "Bip01 MarksmanBowSem",
    [W.MarksmanCrossbow]  = "Bip01 MarksmanCrossbowSem",
    [W.MarksmanThrown]    = "Bip01 MarksmanThrownSem",
}

M.SHIELD_BONE        = "Bip01 AttachShield"
M.SHIELD_BONE_SEM    = "Bip01 AttachShieldSem"
M.ATTACH_WEAPON_BONE = "Bip01 AttachWeapon"

-- Presence of this bone means the actor has the Sem skeleton. Any of the
-- twelve would serve; this one is least likely to be added piecemeal by an
-- unrelated skeleton replacer.
M.SEM_PROBE_BONE = "Bip01 LongBladeOneHandSem"

---@param weaponType number
---@param useSem boolean|nil
function M.boneForWeapon(weaponType, useSem)
    if useSem then
        local sem = SEM_OVERRIDE[weaponType]
        if sem then return sem end
    end
    return BONE_BY_TYPE[weaponType] or M.ATTACH_WEAPON_BONE
end

---@param useSem boolean|nil
function M.shieldBone(useSem)
    return useSem and M.SHIELD_BONE_SEM or M.SHIELD_BONE
end

---Bones that more than one weapon type maps onto, for the ACTIVE skeleton.
---Computed rather than listed, so editing either table cannot leave a stale
---list behind -- and computed per-skeleton, because the collisions differ.
---@param useSem boolean|nil
---@return table<string, boolean>
function M.sharedBones(useSem)
    local seen, shared = {}, {}
    for weaponType in pairs(BONE_BY_TYPE) do
        local bone = M.boneForWeapon(weaponType, useSem)
        if seen[bone] then shared[bone] = true end
        seen[bone] = true
    end
    return shared
end

return M
