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

-- The compiled creature profile: ride height and rideability for 917 CREA
-- records across Morrowind, Tribunal, Bloodmoon, Tamriel Data and OAAB.
-- Generated, and pure data like this file, so requiring it keeps the
-- no-openmw-modules contract that lets every context share this module.
local creatures = require('scripts.WhyWalk.whywalk_creatures')

local M = {}

M.CREATURES = creatures

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
local HORSE_ANIM = {
    [S.IDLE] = "rideh1", [S.WALK] = "rideh2", [S.GALLOP] = "rideh3",
    [S.REVERSE] = "rideh4", [S.JUMP] = "rideh5",
}

M.RIDE_ANIM = {
    [T.HORSE] = HORSE_ANIM,   -- VERIFIED: Devilish Horse Riding
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

M.FALLBACK_ANIM = HORSE_ANIM

-- ---------------------------------------------------------------------------
-- CREATURE -> MOUNT TYPE
-- ---------------------------------------------------------------------------
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

M.BLACKLIST = {
    ["placeholder_questcreature_01"] = true,
}

-- ---------------------------------------------------------------------------
-- PER-TYPE TUNING
-- ---------------------------------------------------------------------------
local DEFAULT_PROFILE = {
    saddle   = { forward = -10, right = 0, up = 130 },
    turnRate = 2.6,
    flying   = false,
}

M.PROFILE = {
    -- Saddle offsets VERIFIED against Devilish Guar Riding config.lua.
    [T.GUAR]     = { saddle = { forward = -10, right = 0, up = 130 },  turnRate = 2.6 },
    [T.HORSE]    = { saddle = { forward = -10, right = 0, up = 130 },  turnRate = 2.4 },
    [T.BOAR]     = { saddle = { forward = -8,  right = 0, up = 95  },  turnRate = 3.0 },
    [T.NIX]      = { saddle = { forward = -6,  right = 0, up = 110 },  turnRate = 3.2 },
    [T.STRIDENT] = { saddle = { forward = -12, right = 0, up = 150 },  turnRate = 2.2 },
    [T.KAGOUTI]  = { saddle = { forward = -10, right = 0, up = 120 },  turnRate = 2.8 },
    [T.SKYRENDER]= { saddle = { forward = 0,   right = 0, up = 90  },  turnRate = 1.8, flying = true },
    [T.NETCH]    = { saddle = { forward = 0,   right = 0, up = 200 },  turnRate = 1.2, flying = true },
    [T.SILT_STRIDER] = {
        saddle = { forward = 80, right = 0, up = 1223 }, turnRate = 0.6,
    },
}

-- ---------------------------------------------------------------------------
-- TUNING
-- ---------------------------------------------------------------------------
M.TUNING = {
    useFallbackAnim = true,

    freeRideEnabled = true,
    freeRideRange   = 400,

    useLevitation      = true,

    riderBackend = "mwscript",

    mwGlobals = {
        active = "whywalk_active",
        x = "whywalk_x", y = "whywalk_y", z = "whywalk_z",
        yawDelta = "whywalk_yawdelta",
    },

    suppressMountAI = true,

    dismountClearance = 115,   -- sideways offset when stepping off
    maxRiderDrift     = 700,   -- hard resync distance
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

---@param recordId string|nil
---@param extra table|nil set of lower-cased ids, e.g. { ["guar"] = true }
function M.isBlacklisted(recordId, extra)
    if recordId == nil then return false end
    local id = recordId:lower()
    if M.BLACKLIST[id] == true then return true end
    if extra ~= nil and extra[id] == true then return true end
    local known = creatures.get(id)
    return known ~= nil and known.ride == false
end

-- ---------------------------------------------------------------------------
-- BIPEDS AND WEAPON CARRIERS ARE NOT MOUNTS
-- ---------------------------------------------------------------------------
--
---@param recordId string|nil
---@param record table|nil the live CreatureRecord, when the caller has one
---@return boolean barred, string|nil why
function M.barredFromRiding(recordId, record)
    if record ~= nil then
        if record.isBiped == true then return true, 'biped' end
        if record.canUseWeapons == true then return true, 'carries weapons' end
    end
    local known = recordId and creatures.get(recordId)
    if known and known.ride == false then
        return true, 'biped or weapon carrier'
    end
    return false, nil
end

---@param recordId string|nil
---@return table|nil saddle `{forward, right, up}`
function M.saddleFromProfile(recordId)
    local known = recordId and creatures.get(recordId)
    if not known or not known.up then return nil end
    return { forward = 0, right = 0, up = known.up }
end

function M.profileFor(mountType)
    local p = mountType and M.PROFILE[mountType]
    if not p then
        return {
            saddle   = {
                forward = DEFAULT_PROFILE.saddle.forward,
                right   = DEFAULT_PROFILE.saddle.right,
                up      = DEFAULT_PROFILE.saddle.up,
            },
            turnRate = DEFAULT_PROFILE.turnRate,
            flying   = DEFAULT_PROFILE.flying,
        }
    end
    local sd = p.saddle or DEFAULT_PROFILE.saddle
    return {
        saddle   = { forward = sd.forward, right = sd.right, up = sd.up },
        turnRate = p.turnRate or DEFAULT_PROFILE.turnRate,
        flying   = p.flying == true,
    }
end

-- ---------------------------------------------------------------------------
-- SADDLE FROM THE BOUNDING BOX
-- ---------------------------------------------------------------------------
local SADDLE_TOP_FRACTION = 0.72

local reportedBoxes = {}

---@param mount any a creature object (any context -- getBoundingBox is on Object)
---@return table|nil saddle `{forward, right, up}`, or nil if the box is unusable
function M.saddleFromBoundingBox(mount)
    if not mount then return nil end

    local box = mount:getBoundingBox()
    if not box or not box.halfSize or not box.center then return nil end
    if not (box.halfSize.z > 0) then return nil end

    local centreAboveOrigin = box.center.z - mount.position.z
    local up = centreAboveOrigin + box.halfSize.z * SADDLE_TOP_FRACTION

    local saddle = { forward = 0, right = 0, up = up }

    local id = mount.recordId
    if id and not reportedBoxes[id] then
        reportedBoxes[id] = true
        print(string.format(
            "[WhyWalk] '%s' has no mount profile; saddle derived from its"
            .. " bounding box as up = %.1f (box half-height %.1f, centre %.1f"
            .. " above origin). To pin it down, add it to"
            .. " whywalk_shared.M.PROFILE with"
            .. " saddle = { forward = 0, right = 0, up = %.0f }.",
            tostring(id), up, box.halfSize.z, centreAboveOrigin, up))
    end

    return saddle
end

---@param mountType string|nil
---@param state string
---@param rng function|nil
---@param hasGroup function|nil `animation.hasGroup` bound to the actor. Without
---       it every candidate is assumed present, which is the old behaviour and
---       is what the pure data tests want.
function M.resolveAnim(mountType, state, rng, hasGroup)
    local set = mountType and M.RIDE_ANIM[mountType]

    if set and set[state] == false then return nil end

    local function pick(value)
        if value == nil or value == false then return nil end
        local list = type(value) == "table" and value or { value }

        local usable
        if hasGroup then
            usable = {}
            for _, g in ipairs(list) do
                if hasGroup(g) then usable[#usable + 1] = g end
            end
        else
            usable = list
        end

        local n = #usable
        if n == 0 then return nil end
        if n == 1 then return usable[1] end
        return usable[(rng or math.random)(n)]
    end

    local group = set and pick(set[state])
    if group then return group end

    if not M.TUNING.useFallbackAnim then return nil end
    return pick(M.FALLBACK_ANIM[state])
end

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

-- ---------------------------------------------------------------------------
-- VESSEL STANCES (WhyWalk Boats)
-- ---------------------------------------------------------------------------
M.VESSEL_GROUP = {
    GONDOLA       = "gondola1",   -- poling, straight ahead
    GONDOLA_RIGHT = "gondolar",   -- poling, turning to starboard
    GONDOLA_LEFT  = "gondolal",   -- poling, turning to port

    -- xRowing1.kf (and xBeastRowing1.kf for the beast skeleton), all six
    -- skeleton folders. Five segments laid end to end in one clip:
    --
    --     0.000- 2.833  rowingidle   oars shipped          (no loop keys)
    --     3.667-10.533  rowing1      pulling ahead         loop 4.167- 9.833
    --    10.833-13.700  rowingr      starboard oar         loop 11.700-13.000
    --    13.733-16.333  rowingl      port oar              loop 14.500-15.833
    --    16.667-19.300  rowslow      pulling ahead, gently loop 17.467-18.800
    --
    ROW_IDLE      = "rowingidle",
    ROW_STROKE    = "rowing1",
    ROW_SLOW      = "rowslow",
    ROW_RIGHT     = "rowingr",
    ROW_LEFT      = "rowingl",
}
local VG = M.VESSEL_GROUP

M.VESSEL_KEY_CANDIDATES = {
    { start = "loop start", stop = "loop stop" },
    { start = "start",      stop = "stop" },
}

-- base   - straight ahead, or stopped. A LIST means the first group the
--          skeleton has (animation.hasGroup), for packs that may be absent.
-- left   - rudder to port. Optional: absent means base.
-- right  - rudder to starboard. Optional: absent means base.
-- stroke - throttle ahead, at speed. Optional: absent means base.
-- slow   - throttle ahead, below hull speed. Optional: absent means stroke.
-- back   - throttle astern. Optional: absent means base.
-- Lower case throughout: OpenMW stores group names lower-cased.
local VESSEL_STANCE_BY_NAME = {
    gondola = {
        base  = VG.GONDOLA,
        left  = VG.GONDOLA_LEFT,
        right = VG.GONDOLA_RIGHT,
    },

    -- Vanilla; always present. Any vessel without a stance of its own.
    stand = {
        base = { "idle" },
    },

    sit = {
        base = { "vasittingfloor", "idle" },
    },

    -- -----------------------------------------------------------------------
    -- RIDING AS A PASSENGER
    -- -----------------------------------------------------------------------
    passenger = {
        base = { "rasit2", "vasittingfloor", "idle" },
    },

    -- -----------------------------------------------------------------------
    -- ROWING
    -- -----------------------------------------------------------------------
    rowing = {
        base   = VG.ROW_IDLE,
        stroke = VG.ROW_STROKE,
        slow   = VG.ROW_SLOW,
        left   = VG.ROW_LEFT,
        right  = VG.ROW_RIGHT,
    },
}

local VESSEL_FIELDS = { "base", "left", "right", "stroke", "slow", "back" }

local function validateVesselStances(byName)
    for name, s in pairs(byName) do
        if type(s) ~= "table" then
            error(("[WhyWalk] vessel stance '%s' is %s, expected table"):format(name, type(s)))
        end
        if s.base == nil then
            error(("[WhyWalk] vessel stance '%s' has no 'base' group"):format(name))
        end
        for _, field in ipairs(VESSEL_FIELDS) do
            local v = s[field]
            if v ~= nil then
                local list = type(v) == "table" and v or { v }
                if #list == 0 then
                    error(("[WhyWalk] vessel stance '%s'.%s is an empty list"):format(name, field))
                end
                for _, g in ipairs(list) do
                    if type(g) ~= "string" or g ~= g:lower() then
                        error(("[WhyWalk] vessel stance '%s'.%s '%s' must be a lower-case group name")
                            :format(name, field, tostring(g)))
                    end
                end
            end
        end
    end
    if not byName.stand then
        error("[WhyWalk] a 'stand' vessel stance is required (the fallback)")
    end
    return byName
end

M.VESSEL_STANCE = validateVesselStances(VESSEL_STANCE_BY_NAME)

M.VESSEL_TUNING = {
    minPoseTime = 0.3,
}

function M.buildVesselLayer(anim)
    local BG, P = anim.BONE_GROUP, anim.PRIORITY
    return {
        priority = {
            [BG.LowerBody] = P.Weapon,
            [BG.Torso]     = P.Hit,
            [BG.LeftArm]   = P.Hit,
            [BG.RightArm]  = P.Hit,
        },
        blendMask = anim.BLEND_MASK.All,
    }
end

---@param stance table an entry of M.VESSEL_STANCE
---@param turn number -1 port, 0, 1 starboard
---@param throttle number -1 astern, 0, 1 ahead
---@param fast boolean|nil at or above hull speed. nil means yes, which keeps
---       every caller that predates the speed band selecting `stroke`.
function M.vesselField(stance, turn, throttle, fast)
    if turn < 0 and stance.left then return "left" end
    if turn > 0 and stance.right then return "right" end
    if throttle > 0 then
        if fast == false and stance.slow then return "slow" end
        if stance.stroke then return "stroke" end
        -- A stance with `slow` but no `stroke` uses it at any speed.
        if stance.slow then return "slow" end
    end
    if throttle < 0 and stance.back then return "back" end
    return "base"
end

function M.resolveVesselGroup(stanceName, field, hasGroup)
    local stance = M.VESSEL_STANCE[stanceName] or M.VESSEL_STANCE.stand
    local value = stance[field] or stance.base
    for _, g in ipairs(type(value) == "table" and value or { value }) do
        if hasGroup(g) then return g end
    end
    if stance ~= M.VESSEL_STANCE.stand then
        return M.resolveVesselGroup("stand", "base", hasGroup)
    end
    return nil
end

return M
