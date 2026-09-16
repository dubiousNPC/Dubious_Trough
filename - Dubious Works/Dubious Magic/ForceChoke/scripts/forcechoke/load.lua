---@omw-context load
--[[
    ForceChoke / load.lua

    Declares the magic effect and the two spell records, following the
    Ablution Intervention template.

    WHY THIS FILE REPLACES runtime createRecord
    -------------------------------------------
    Earlier revisions built the spell in global.lua with
    createRecordDraft + world.createRecord, cached the generated id across
    saves, and shipped a handshake event so player.lua could learn what id
    to compare against. All of that existed only because a runtime-created
    record has an id nobody can predict.

    openmw.content removes the problem rather than managing it. Records
    declared here have FIXED ids, exactly as if a content file had created
    them, so every script can just name them. Deleted along with the old
    approach: makeSpell, ensureRecords, the chokeSpellId/holdSpellId
    save-state, and the ForceChoke_SpellId event.

    It also makes the custom effect real. Previous revisions documented
    "forcechoke" as a marker effect that only worked if the user supplied
    their own .omwaddon, because createRecordDraft can make spells but not
    magic effects. content.magicEffects can, so the effect exists
    unconditionally and spellmaker variants work out of the box.
]]--

local content = require('openmw.content')

-- Templated from paralyze: inherits its school (ALTERATION), its resistance
-- handling and its VFX/sound defaults. Only what differs is overridden.
content.magicEffects.records["forcechoke"] = {
    template    = content.magicEffects.records["paralyze"],
    name        = "Force Choke",
    baseCost    = 25,
    description = "Seizes a humanoid at range, holding them helpless. "
               .. "Cast again to hurl them away.",
}

-- The castable spell. Target range so the engine treats it as a ranged cast
-- and the player aims it.
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

-- The paralysis maintained during the hold. Kept separate from the castable
-- spell so refreshing the grip never re-runs the cast's own effects, and so
-- clearHold can identify precisely what it applied.
--
-- Self range: global.lua applies it directly to the victim with
-- activeSpells:add, which bypasses targeting entirely. Cost 0 and
-- isAutocalc false keep it out of any cost calculation; it is never cast.
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
