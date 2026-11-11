---@omw-context load
--[[
    ForceChoke / load.lua

    Declares the magic effect and the two spell records, following the
    Ablution Intervention template.
    
]]--

local content = require('openmw.content')

content.magicEffects.records["forcechoke"] = {
    template    = content.magicEffects.records["paralyze"],
    name        = "Force Choke",
    baseCost    = 25,
    description = "Seizes a humanoid at range, holding them helpless. "
               .. "Cast again to hurl them away.",
}

content.spells.records["forcechoke_spell"] = {
    name       = "Force Choke",
    type       = content.spells.TYPE.Spell,
    cost       = 25,
    isAutocalc = false,
    effects    = {
        {
            id           = "forcechoke",
            range        = content.RANGE.Target,
            area         = 0,
            duration     = 1,
            magnitudeMin = 1,
            magnitudeMax = 1,
        },
    },
}

content.spells.records["forcechoke_hold"] = {
    name       = "Force Choke (Held)",
    type       = content.spells.TYPE.Ability,
    cost       = 0,
    isAutocalc = false,
    effects    = {
        {
            id           = "paralyze",
            range        = content.RANGE.Self,
            area         = 0,
            duration     = 4,
            magnitudeMin = 1,
            magnitudeMax = 1,
        },
    },
}
