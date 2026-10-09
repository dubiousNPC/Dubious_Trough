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
    -- HORSE and GUAR are verified against the shipped .kf text keys, not just
    -- against the mods that supply them:
    --   xHorseDBSRide2.kf  -> rideh1 rideh2 rideh3 rideh4 rideh5
    --   xGuarDBSRide1.kf   -> rideg1 rideg2 rideg3 rideg4 rideg5
    -- present in all three skeleton variants (xbase_anim, .1st, kna), each
    -- with matching `: start` / `: stop` keys. Everything below is still a
    -- placeholder: the group names are structurally correct but no .kf in this
    -- package defines them, so playBlended will find nothing and the fallback
    -- set is what actually plays.
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
--         ONE pose, both perspectives, matching Devilish Guar Riding's
--         PLAYER_OFFSET { right = 0, forward = -10, z = 130 } exactly.
--
--         A `saddleFP` first-person override used to live here, lowering the
--         body to ~0.6x height on the theory that the first person camera
--         sits at the head so the body must drop to bring the view down. It
--         was removed after in-game testing: it is the direct cause of the
--         reported "position is too low", and it was never justified by the
--         reference mod. DGR uses a SINGLE offset for both views and is the
--         one that feels right.
--
--         First-person framing is the CAMERA's job here, not the body's.
--         ridingAnim.lua already exposes FP_OFFSET_V / FP_OFFSET_H for it,
--         defaulting to 0. Adjust those if the view needs moving; moving the
--         body instead desynchronises what third person shows from where the
--         rider actually is.
-- turnRate: radians/sec at full steer. Scaled by dt and written to
--         controls.yawChange by whywalk_mount.lua. This is the one movement
--         number still set here, because turn rate is the only part of riding
--         the engine does not already have an opinion about.
-- flying: marks mounts whose locomotion is airborne. Informational now -- the
--         engine picks the locomotion type from the creature's own record.
--
-- WHAT USED TO BE HERE: speed, walkMul, revMul and a jump table (up, gravity,
-- maxFall). All four are gone with the controls port. Speed is the creature's
-- own Speed stat, scaled by the throttle magnitude passed to
-- controls.movement; the jump is the engine's. Shipping the numbers anyway
-- would mean four fields per mount that nothing reads and that would quietly
-- drift away from the behaviour they appear to describe.
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
    -- MEASURED, not estimated: from Immersive Travel's a_siltstrider.json,
    -- whose front passenger slot sits at (0, 80, 1223) relative to the "Body"
    -- niNode. The earlier 1300 here was a guess off a different mod.
    -- Caveat: that data defines THREE passenger slots spread +/-81 on X, plus
    -- a separate guide slot. PROFILE can only express one saddle, so this is
    -- the front seat only -- see SILTSTRIDER_NOTES.md, SCHEMA GAP.
    [T.SILT_STRIDER] = {
        saddle = { forward = 80, right = 0, up = 1223 }, turnRate = 0.6,
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
        yawDelta = "whywalk_yawdelta",
    },

    -- Suppress the ridden creature's own AI while it is being steered.
    --
    -- THIS IS THE ONE SWITCH TO TRY FIRST IF A MOUNT WILL NOT MOVE AT ALL.
    --
    -- The controls port rests on an assumption that could not be tested
    -- outside the game: that self:enableAI(false) disables the AI DECISION
    -- layer only, leaving the character controller free to act on controls
    -- written by script. Cod3x's wording supports it -- "Enables or disables
    -- standard AI" -- and it is the only way to stop the creature's own AI
    -- fighting every steering input.
    --
    -- What the two reference mods prove, separately and not together:
    --   * p37z writes controls on a creature and never disables AI, so
    --     controls demonstrably work with AI ENABLED.
    --   * Devilish Guar Riding calls enableAI(false), but teleports rather
    --     than driving, so it proves nothing about controls.
    --
    -- So if the mount stands still with the controls being written, set this
    -- to false. Steering will work; the creature's AI will also be free to
    -- wander, which looks like the mount drifting or turning on its own. That
    -- combination identifies the cause immediately, which a silent failure
    -- would not.
    suppressMountAI = true,

    dismountClearance = 115,   -- sideways offset when stepping off
    maxRiderDrift     = 700,   -- hard resync distance
    -- groundProbeUp is gone with groundZ. Nothing probes the ground any more;
    -- the engine does.
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

-- ALWAYS returns a FRESH table, including on the fallback path.
--
-- It used to `return DEFAULT_PROFILE` directly, which handed out the shared
-- module-level table by reference. That was harmless only as long as nobody
-- wrote to the result -- and whywalk_global now does exactly that, replacing
-- `profile.saddle` with one derived from an unknown creature's bounding box.
-- With the old form, riding one unrecognised creature would have rewritten the
-- default saddle for every later ride in the session: mount a silt strider
-- once and every subsequent unknown mount seats its rider 1000 units in the
-- air.
--
-- Copying costs one table per mount, which happens on a key press.
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
    -- Fill gaps from the default rather than requiring every profile to spell
    -- out every field.
    --
    -- speed / walkMul / revMul / jump are deliberately NOT carried any more.
    -- The engine owns movement since the controls port: a creature's speed is
    -- its own Speed stat and its jump is the engine's jump. Keeping the fields
    -- would mean shipping four numbers that nothing reads -- see
    -- PROFILE's own note.
    -- The saddle is copied too, for the same reason: PROFILE's tables are
    -- module-level and a caller that adjusts one would change it for every
    -- future mount of that type.
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
-- For a creature PROFILE has never heard of. Every mount added by another mod
-- lands here, and the alternative is dropping the rider at the creature's
-- origin -- which for a quadruped is ground level between its feet.
--
-- WHAT IS SAFE TO READ, AND WHAT IS NOT
--
-- Object:getBoundingBox() returns a util.Box with `center`, `halfSize`,
-- `transform` and `vertices`. Cod3x documents `vertices` as "taking rotation
-- into account", which means the rotation lives in `transform` and `halfSize`
-- is therefore in the BODY's own axes, not the world's.
--
-- That reading matters for only one of the two numbers wanted here, so this
-- function is built to be correct either way:
--
--   * VERTICAL is taken from halfSize.z, which is yaw-invariant under BOTH
--     readings -- creatures rotate about Z only, so no amount of turning
--     changes the box's vertical extent. This is the number that decides
--     whether the rider sits on the creature or inside it, and it is the one
--     that can be trusted.
--
--   * FORWARD is left at zero rather than derived from halfSize.y. Under the
--     body-axes reading halfSize.y is half the body length; under the other it
--     is a yaw-dependent mix of length and width, and at 45 degrees there is
--     no way to separate them. Zero is not a cop-out: the eight measured
--     profiles use forward offsets of -6 to -12 units on bodies 100+ units
--     long, so sitting at the box's centre is within a few units of every
--     hand-tuned value in the table.
--
-- The vertical fraction is the one judgement call. A quadruped's bounding box
-- top is its head or its dorsal fin, not its back, so the saddle sits below
-- the top of the box. 0.72 of the half-height above centre reproduces the
-- guar's measured up = 130 for a body whose box is about 90 units to the
-- shoulder -- but it IS a fit to one animal, which is why the derived value is
-- printed once per new creature. Read it out of the log and promote it into
-- PROFILE to stop guessing.
local SADDLE_TOP_FRACTION = 0.72

local reportedBoxes = {}

---Derive a saddle offset for a creature with no profile entry.
---@param mount any a creature object (any context -- getBoundingBox is on Object)
---@return table|nil saddle `{forward, right, up}`, or nil if the box is unusable
function M.saddleFromBoundingBox(mount)
    if not mount then return nil end

    local box = mount:getBoundingBox()
    -- A box with no vertical extent means the model failed to load or has no
    -- geometry. Guessing an offset from it would put the rider at the
    -- creature's feet with no indication why, so refuse and let the caller
    -- fall back to the default profile.
    if not box or not box.halfSize or not box.center then return nil end
    if not (box.halfSize.z > 0) then return nil end

    -- center is world-space; the offset wanted is relative to the object's
    -- own origin, which for a creature sits at ground level.
    local centreAboveOrigin = box.center.z - mount.position.z
    local up = centreAboveOrigin + box.halfSize.z * SADDLE_TOP_FRACTION

    local saddle = { forward = 0, right = 0, up = up }

    -- Once per record, not per mount and not per frame. This is the only way
    -- the real number ever reaches a human, and a creature ridden repeatedly
    -- should not reprint it.
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

-- ---------------------------------------------------------------------------
-- VESSEL STANCES (WhyWalk Boats)
-- ---------------------------------------------------------------------------
-- The pilot's pose aboard a boat. Played by ridingAnim.lua on
-- WhyWalk_AnimVesselStart / _AnimVesselHelm / _AnimVesselStop, which the
-- Boats module sends. Same shape as Take a Seat's and ErnGlider's _shared
-- tables: group names, key candidates, a validated stance table, and a layer
-- profile built from the injected animation module.

-- xGondola1.kf (all six skeleton folders). Each group is start, loop start,
-- loop stop, stop. The loop keys were authored as "godola1" and renamed by
-- tools/fix_textkeys.py; tools/check_anims.py now rejects a split group.
M.VESSEL_GROUP = {
    GONDOLA       = "gondola1",   -- poling, straight ahead
    GONDOLA_RIGHT = "gondolar",   -- poling, turning to starboard
    GONDOLA_LEFT  = "gondolal",   -- poling, turning to port
}
local VG = M.VESSEL_GROUP

-- Tried in order per group; the first pair the clip actually has is used
-- (animation.getTextKeyTime). "loop start" first, so the pose starts inside
-- its loop rather than replaying the lead-in on every turn change.
M.VESSEL_KEY_CANDIDATES = {
    { start = "loop start", stop = "loop stop" },
    { start = "start",      stop = "stop" },
}

-- base   - straight ahead, or stopped. A LIST means the first group the
--          skeleton has (animation.hasGroup), for packs that may be absent.
-- left   - rudder to port. Optional: absent means base.
-- right  - rudder to starboard. Optional: absent means base.
-- stroke - throttle ahead. Optional; reserved for rowing, see below.
-- back   - throttle astern. Optional; reserved for rowing, see below.
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

    -- Floor sitting where an animation pack provides it, else standing.
    -- "vasittingfloor" is not vanilla (Rideable Silt Striders plays it).
    sit = {
        base = { "vasittingfloor", "idle" },
    },

    -- -----------------------------------------------------------------------
    -- FUTURE: ROWING
    -- -----------------------------------------------------------------------
    -- Reserved for an oared pose set (rowboat; longboat oarsmen). Not
    -- registered: no .kf in this package defines these groups, and a stance
    -- naming a missing group would play nothing. Rowboats use `sit` until it
    -- ships. Expected shape, so the controller needs no change when it does:
    --
    -- rowing = {
    --     base   = "rowidle",    -- oars shipped, drifting
    --     stroke = "rowstroke",  -- throttle ahead
    --     back   = "rowback",    -- throttle astern (backing water)
    --     left   = "rowl",       -- port oar only
    --     right  = "rowr",       -- starboard oar only
    --     paced  = true,         -- STUB: stroke rate follows boat speed;
    --                            -- ridingAnim ignores it for now
    -- },
    --
    -- Then set boats_db.VESSELS.rowboat.pose = 'rowing'. The helm event
    -- already carries `throttle`, and ridingAnim already prefers
    -- stroke/back over base when a stance has them.
}

local VESSEL_FIELDS = { "base", "left", "right", "stroke", "back" }

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
    -- Minimum seconds a pose is held before switching to another, so a
    -- tapped rudder does not flicker between loops (ErnGlider's minPoseTime).
    minPoseTime = 0.3,
}

---Vessel layer: whole body at PRIORITY.Hit -- above Movement, so the legs
---hold the pose while the engine walks the pilot across the water; below
---Weapon, Block, Knockdown and Torch, so fighting and casting still work.
---Not Scripted, which pauses every other animation (RESEARCH 3.2).
---@param anim any the openmw.animation module, injected so this file requires nothing
function M.buildVesselLayer(anim)
    return { priority = anim.PRIORITY.Hit, blendMask = anim.BLEND_MASK.All }
end

---Which stance field a helm state selects: turning wins, then stroke/back,
---then base. Fields a stance lacks fall through to base.
---@param stance table an entry of M.VESSEL_STANCE
---@param turn number -1 port, 0, 1 starboard
---@param throttle number -1 astern, 0, 1 ahead
function M.vesselField(stance, turn, throttle)
    if turn < 0 and stance.left then return "left" end
    if turn > 0 and stance.right then return "right" end
    if throttle > 0 and stance.stroke then return "stroke" end
    if throttle < 0 and stance.back then return "back" end
    return "base"
end

---Resolve a stance field to a concrete group, honouring lists. `hasGroup` is
---injected (animation.hasGroup bound to the actor) to keep this file pure.
---Returns nil only when not even the fallback stance resolves.
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
