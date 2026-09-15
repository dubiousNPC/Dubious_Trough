---@omw-context none
--[[
    whywalk_shared.lua -- data + pure helpers for WhyWalk

    Dependency-free by design (---@omw-context none): no openmw.* requires at
    all, so global, player and mount scripts can all require it. Callers inject
    anything engine-shaped (content-file predicates, RNG) rather than this file
    reaching for it.

    Owns: mount classification, rider animation groups, per-type tuning.
    Does NOT own: placement offsets, movement maths, any engine call.

    ###########################################################################
    #  Group names and PLACEHOLDER-marked record IDs need confirming.         #
    #  VERIFIED entries were read out of the shipped ESP/config files.        #
    ###########################################################################
]]

local M = {}

-- ---------------------------------------------------------------------------
-- MOUNT TYPES
-- ---------------------------------------------------------------------------

M.MOUNT_TYPE = {
    HORSE        = "horse",
    GUAR         = "guar",
    BOAR         = "boar",
    NIX          = "nix",
    STRIDENT     = "strident",
    SKYRENDER    = "skyrender",
    KAGOUTI      = "kagouti",
    SILT_STRIDER = "silt_strider",
    NETCH        = "netch",
    GENERIC      = "generic",
}
local T = M.MOUNT_TYPE

M.STATE = {
    IDLE    = "idle",
    WALK    = "walk",
    GALLOP  = "gallop",
    REVERSE = "reverse",
    JUMP    = "jump",
}
local S = M.STATE

-- ---------------------------------------------------------------------------
-- RIDER ANIMATION GROUPS
-- ---------------------------------------------------------------------------
-- Value is a group name, a LIST (pick one at random on state entry), or
-- `false` meaning "this mount has no such state, do NOT fall back to the
-- generic clip". `nil` means unspecified and DOES fall back.
M.RIDE_ANIM = {
    [T.HORSE] = {   -- VERIFIED: Devilish Horse Riding
        [S.IDLE] = "rideh1", [S.WALK] = "rideh2", [S.GALLOP] = "rideh3",
        [S.REVERSE] = "rideh4", [S.JUMP] = "rideh5",
    },
    [T.GUAR] = {    -- VERIFIED: Devilish Guar Riding
        [S.IDLE] = "rideg1", [S.WALK] = "rideg2", [S.GALLOP] = "rideg3",
        [S.REVERSE] = "rideg4", [S.JUMP] = "rideg5",
    },
    [T.BOAR] = {    -- PLACEHOLDER
        [S.IDLE] = { "rideb1", "rideb1_alt" }, [S.WALK] = "rideb2",
        [S.GALLOP] = "rideb3", [S.REVERSE] = "rideb4", [S.JUMP] = "rideb5",
    },
    [T.NIX] = {     -- PLACEHOLDER
        [S.IDLE] = { "riden1", "riden1_alt" }, [S.WALK] = "riden2",
        [S.GALLOP] = "riden3", [S.REVERSE] = "riden4", [S.JUMP] = "riden5",
    },
    [T.STRIDENT] = {-- PLACEHOLDER
        [S.IDLE] = "rides1", [S.WALK] = "rides2",
        [S.GALLOP] = { "rides3", "rides3_alt" },
        [S.REVERSE] = "rides4", [S.JUMP] = "rides5",
    },
    [T.KAGOUTI] = { -- PLACEHOLDER
        [S.IDLE] = "ridek1", [S.WALK] = "ridek2", [S.GALLOP] = "ridek3",
        [S.REVERSE] = "ridek4", [S.JUMP] = "ridek5",
    },
    [T.SKYRENDER] = {   -- PLACEHOLDER, flying: no reverse, no jump
        [S.IDLE] = "ridefly1", [S.WALK] = "ridefly2", [S.GALLOP] = "ridefly3",
        [S.REVERSE] = false, [S.JUMP] = false,
    },
    [T.NETCH] = {       -- PLACEHOLDER, flying
        [S.IDLE] = "ridenetch1", [S.WALK] = "ridenetch2", [S.GALLOP] = "ridenetch3",
        [S.REVERSE] = false, [S.JUMP] = false,
    },
    -- Rider sits rather than straddles. The shipped Rideable Silt Striders mod
    -- uses the vanilla group "vasittingfloor" for exactly this, which is a real
    -- group and a usable stand-in until a bespoke clip exists.
    [T.SILT_STRIDER] = {
        [S.IDLE] = "vasittingfloor", [S.WALK] = "vasittingfloor",
        [S.GALLOP] = "vasittingfloor", [S.REVERSE] = false, [S.JUMP] = false,
    },
}

-- Ships with the mod, so an unresourced or free-ridden creature always has
-- something to play. Callers may disable it (see TUNING.useFallbackAnim).
M.FALLBACK_ANIM = {
    [S.IDLE]    = "ride_generic_idle",
    [S.WALK]    = "ride_generic_walk",
    [S.GALLOP]  = "ride_generic_gallop",
    [S.REVERSE] = "ride_generic_reverse",
    [S.JUMP]    = "ride_generic_jump",
}

-- ---------------------------------------------------------------------------
-- CREATURE -> MOUNT TYPE
-- ---------------------------------------------------------------------------
-- Exact record IDs win over patterns: record names lie often enough that
-- substrings alone misfile mounts. Keys lowercase (Object.recordId always is).
M.MOUNT_TYPE_BY_RECORD = {
    ["ttd_horseride"]        = T.HORSE,      -- VERIFIED: Horse config HORSE_ID
    ["detd_guarride1"]       = T.GUAR,       -- VERIFIED: Guar config GUAR_ID
    ["ttd_boarride"]         = T.BOAR,       -- VERIFIED: Boar Riding.ESP
    ["detd_boarnoride1"]     = T.BOAR,       -- VERIFIED
    ["ttd_nixride"]          = T.NIX,        -- VERIFIED: Nix Riding.ESP
    ["detd_nixnoride"]       = T.NIX,        -- VERIFIED
    ["ttd_stridentride"]     = T.STRIDENT,   -- VERIFIED: Strident Riding.ESP
    ["detd_stridentnoride1"] = T.STRIDENT,   -- VERIFIED
    ["detd_skybug_riding"]   = T.SKYRENDER,  -- VERIFIED: Sky Render Riding.esp

    ["placeholder_kagoutiride"] = T.KAGOUTI,       -- PLACEHOLDER
    ["placeholder_netchride"]   = T.NETCH,         -- PLACEHOLDER
}

-- Ordered fallback for creatures not listed above. ORDER IS SIGNIFICANT where
-- substrings nest ("siltstrider" contains "strider"; "strident" does not, but
-- keeping the long forms first is the safe habit). First match wins.
M.MOUNT_TYPE_PATTERNS = {
    { mount = T.SILT_STRIDER, patterns = { "siltstrider", "silt_strider" } },
    { mount = T.SKYRENDER,    patterns = { "skyrender", "skybug", "sky_render" } },
    { mount = T.STRIDENT,     patterns = { "strident" } },
    { mount = T.KAGOUTI,      patterns = { "kagouti" } },
    { mount = T.NETCH,        patterns = { "netch" } },
    { mount = T.NIX,          patterns = { "nixmount", "nixhound", "nix" } },
    { mount = T.BOAR,         patterns = { "boar" } },
    { mount = T.GUAR,         patterns = { "guar" } },
    { mount = T.HORSE,        patterns = { "horse", "pony", "steed" } },
}

-- Never mountable, even under free ride.
M.BLACKLIST = {
    ["placeholder_questcreature_01"] = true,
}

-- ---------------------------------------------------------------------------
-- PER-TYPE TUNING
-- ---------------------------------------------------------------------------
-- saddle: where the rider sits relative to the mount, in mount-local axes.
--         This is the THIRD PERSON pose -- the body's true seated position.
-- saddleFP: OPTIONAL first person override, same shape. Omit to reuse
--         `saddle` (previous behaviour).
--
--         WHY THE TWO DIFFER. In third person the body is what you see, so
--         `saddle` is simply where the rider belongs. In first person the
--         body is invisible and all that matters is where the HEAD lands,
--         because setFirstPersonOffset is documented as the offset between
--         the character's head and the camera -- offset zero puts the camera
--         at the head. The pinned position is the rider's FEET, so the first
--         person camera ends up roughly saddle.up + head height above the
--         mount origin. At up = 130 that is far above any horse, and the only
--         knob to correct it (FP_OFFSET_V) walks the camera DOWN THROUGH the
--         mount's neck and shoulders -- the reported first person clipping.
--
--         The fix is to move the BODY rather than the camera, which is what
--         Sturdy Steed's SimpleHorseRiding222 MWScript does: it carries two
--         saddle poses per creature and picks between them on PCGet3rdPerson,
--             set sdlFwd3 to 8      set sdlUp3 to 80    ; third person
--             set sdlFwd1 to 12     set sdlUp1 to 47    ; first person
--         i.e. first person sits LOWER (so the head lands at eye level rather
--         than above it) and slightly FURTHER FORWARD (so the view clears the
--         neck instead of looking into it). The ratios below follow that:
--         about 0.6x the height and a small forward nudge. They are a starting
--         point measured off a horse; re-tune per mount.
-- speed:  world units/sec at full gallop; walk/reverse derive from it, so
--         there is one number per mount to tune (Devilish's approach).
-- flying: skips ground clamping entirely.
local DEFAULT_PROFILE = {
    saddle   = { forward = -10, right = 0, up = 130 },
    saddleFP = { forward = -4,  right = 0, up = 78  },
    speed   = 600,
    walkMul = 230 / 520,
    revMul  = 115 / 520,
    turnRate = 2.6,          -- radians/sec at full steer
    flying  = false,
    jump    = { up = 480, gravity = 900, maxFall = 950 },
}

M.PROFILE = {
    -- VERIFIED offsets/speed from Devilish Guar Riding config.lua
    [T.GUAR] = {
        saddle   = { forward = -10, right = 0, up = 130 },
        saddleFP = { forward = -4,  right = 0, up = 78  },
        speed = 600, walkMul = 230 / 520, revMul = 115 / 520,
        turnRate = 2.6, flying = false,
        jump = { up = 480, gravity = 900, maxFall = 950 },
    },
    [T.HORSE] = {
        saddle   = { forward = -10, right = 0, up = 130 },
        saddleFP = { forward = -4,  right = 0, up = 78  },
        speed = 700, walkMul = 230 / 520, revMul = 115 / 520,
        turnRate = 2.4, flying = false,
        jump = { up = 480, gravity = 900, maxFall = 950 },
    },
    -- saddleFP omitted below: these fall back to `saddle`, i.e. exactly the
    -- previous behaviour, until each is measured. Add one per mount as you
    -- tune it rather than shipping guessed numbers for all nine.
    [T.BOAR]     = { saddle = { forward = -8,  right = 0, up = 95  }, speed = 520, turnRate = 3.0 },
    [T.NIX]      = { saddle = { forward = -6,  right = 0, up = 110 }, speed = 640, turnRate = 3.2 },
    [T.STRIDENT] = { saddle = { forward = -12, right = 0, up = 150 }, speed = 760, turnRate = 2.2 },
    [T.KAGOUTI]  = { saddle = { forward = -10, right = 0, up = 120 }, speed = 580, turnRate = 2.8 },
    [T.SKYRENDER]= { saddle = { forward = 0,   right = 0, up = 90  }, speed = 900, turnRate = 1.8, flying = true },
    [T.NETCH]    = { saddle = { forward = 0,   right = 0, up = 200 }, speed = 420, turnRate = 1.2, flying = true },
    -- MEASURED, not estimated: from Immersive Travel's a_siltstrider.json,
    -- whose front passenger slot sits at (0, 80, 1223) relative to the "Body"
    -- niNode. The earlier 1300 here was a guess off a different mod.
    -- Caveat: that data defines THREE passenger slots spread +/-81 on X, plus
    -- a separate guide slot. PROFILE can only express one saddle, so this is
    -- the front seat only -- see whywalk_siltstrider.lua, SCHEMA GAP.
    [T.SILT_STRIDER] = {
        saddle = { forward = 80, right = 0, up = 1223 },
        speed = 400, turnRate = 0.6, flying = false,
    },
}

-- ---------------------------------------------------------------------------
-- TUNING
-- ---------------------------------------------------------------------------
M.TUNING = {
    useFallbackAnim = true,

    -- Free ride: mount any creature with no script added to it. No steering --
    -- the creature keeps its own AI and the rider goes along. Cheapest mode
    -- here: no control bridge, no mount script, no movement integration.
    freeRideEnabled = true,
    freeRideRange   = 400,

    -- Levitation removes rider gravity so it stops fighting placement between
    -- pin updates. It does NOT move the player -- nothing in the OpenMW Lua
    -- API parents one object to another, so the pin is still required.
    --
    -- Applied by modifying the Levitate effect magnitude directly (see
    -- addLevitation in whywalk_player.lua), so there is no spell record and
    -- therefore no id to configure. The former levitationSpellId was a
    -- placeholder that could never resolve; it has been removed rather than
    -- left as a field that does nothing.
    useLevitation      = true,

    -- Preferred rider-placement backend.
    --   "mwscript" : Lua writes globals, a compiled MWScript does SetPos.
    --                Needs the ESP. Devilish uses this and warns that a
    --                per-frame Lua player teleport loop triggers an engine bug
    --                around nearby NPCs.
    --   "teleport" : pure Lua, no ESP needed. Works, but inherits that bug.
    riderBackend = "mwscript",

    -- MWScript global variable names the bridge writes.
    -- MWScript global variable names the bridge writes. `angle` is in DEGREES
    -- (SetAngle takes degrees) and the MWScript must gate applying it on
    -- PCGet3rdPerson -- see placeRiderMWScript in whywalk_global.lua.
    mwGlobals = {
        active = "whywalk_active",
        x = "whywalk_x", y = "whywalk_y", z = "whywalk_z",
        angle = "whywalk_angle",
    },

    dismountClearance = 115,   -- sideways offset when stepping off
    maxRiderDrift     = 700,   -- hard resync distance
    groundProbeUp     = 200,
}

-- ---------------------------------------------------------------------------
-- PURE HELPERS
-- ---------------------------------------------------------------------------

local typeCache = {}

function M.getMountType(recordId)
    if not recordId then return nil end
    local cached = typeCache[recordId]
    if cached ~= nil then return cached or nil end

    local lower, result = recordId:lower(), false
    if not M.BLACKLIST[lower] then
        result = M.MOUNT_TYPE_BY_RECORD[lower] or false
        if not result then
            for _, entry in ipairs(M.MOUNT_TYPE_PATTERNS) do
                for _, p in ipairs(entry.patterns) do
                    if lower:find(p, 1, true) then result = entry.mount; break end
                end
                if result then break end
            end
        end
    end
    typeCache[recordId] = result
    return result or nil
end

function M.isBlacklisted(recordId)
    return recordId ~= nil and M.BLACKLIST[recordId:lower()] == true
end

function M.profileFor(mountType)
    local p = mountType and M.PROFILE[mountType]
    if not p then return DEFAULT_PROFILE end
    -- Fill gaps from the default rather than requiring every profile to spell
    -- out every field.
    return {
        saddle   = p.saddle   or DEFAULT_PROFILE.saddle,
        -- Falls back to this profile's OWN third person saddle, not the
        -- default profile's: a mount with a measured saddle but no measured
        -- first person pose must keep its own geometry, and reverting it to a
        -- generic 78 would be worse than the too-high view it replaces.
        saddleFP = p.saddleFP or p.saddle or DEFAULT_PROFILE.saddle,
        speed    = p.speed    or DEFAULT_PROFILE.speed,
        walkMul  = p.walkMul  or DEFAULT_PROFILE.walkMul,
        revMul   = p.revMul   or DEFAULT_PROFILE.revMul,
        turnRate = p.turnRate or DEFAULT_PROFILE.turnRate,
        flying   = p.flying == true,
        jump     = p.jump     or DEFAULT_PROFILE.jump,
    }
end

-- Resolve one state to a concrete group name, or nil when the mount has none.
-- rng is injected (math.random by default) to keep this file pure.
function M.resolveAnim(mountType, state, rng)
    local set = mountType and M.RIDE_ANIM[mountType]
    if not set and M.TUNING.useFallbackAnim then set = M.FALLBACK_ANIM end
    if not set then return nil end

    local value = set[state]
    if value == false then return nil end          -- explicit "no such state"
    if value == nil and M.TUNING.useFallbackAnim and set ~= M.FALLBACK_ANIM then
        value = M.FALLBACK_ANIM[state]
    end
    if value == nil or value == false then return nil end
    if type(value) ~= "table" then return value end

    local n = #value
    if n == 0 then return nil end
    if n == 1 then return value[1] end
    return value[(rng or math.random)(n)]
end

-- Every jump group name across every type, flattened. Text key handlers must
-- bind to a fixed name at load time, so the animation controller registers one
-- per entry up front; lazy per-play registration cannot work because the
-- handler has to exist before the clip's stop key fires.
function M.allJumpGroups()
    local seen, out = {}, {}
    local function collect(set)
        local v = set and set[S.JUMP]
        if v == nil or v == false then return end
        for _, g in ipairs(type(v) == "table" and v or { v }) do
            if not seen[g] then seen[g] = true; out[#out + 1] = g end
        end
    end
    for _, set in pairs(M.RIDE_ANIM) do collect(set) end
    collect(M.FALLBACK_ANIM)
    return out
end

return M
