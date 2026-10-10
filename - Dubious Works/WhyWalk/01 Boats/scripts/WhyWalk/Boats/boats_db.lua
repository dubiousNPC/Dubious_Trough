---@omw-context none
--[[
    boats_db.lua -- the vessel database for WhyWalk Boats

    Data plus pure lookups. No openmw.* requires, so global and player scripts
    both load it.

    Units are canonical throughout: world units, seconds, radians.
    Positions are in the VESSEL FRAME: x right, y toward the bow, z up, origin
    at the vessel origin. A mesh is tied to that frame by its MODELS entry
    (yawOffset turns the mesh's +Y onto the bow, origin says where the mesh's
    own origin sits in the vessel frame).

    Every movement number is traced in PROVENANCE to data/boats_sources.json,
    which tools/build_boats_sources.py extracts from the reference mods.
    tools/check_db_sources.py fails if a traced number drifts from its source.
    BOATS_DATABASE.md has the full tables and conversions.
]]

local M = {}

local PI = math.pi

-- ---------------------------------------------------------------------------
-- VESSELS
-- ---------------------------------------------------------------------------
-- maxSpeed      u/s     top speed ahead. The pilot's own run speed caps it.
-- reverseSpeed  u/s     top speed astern
-- accel         u/s^2   with the throttle held
-- brake         u/s^2   with the throttle opposing the motion
-- drag          1/s     coasting decay, speed *= exp(-drag * dt)
-- turnRate      rad/s   yaw rate at full rudder and full way
-- turnResponse  1/s     how fast the yaw rate eases toward the rudder
-- pivot         0..1    rudder authority at a standstill (oars can spin a
--                       boat in place; a sail cannot)
-- waterOffset   u       vessel origin above the water surface
-- anchor        vessel frame position of the pilot's feet
-- hull          bow/stern distances, half beam and draft; nil = measure the
--               object's bounding box when the boat is first boarded
-- motion        cosmetic roll (sway) and pitch (rocking)
-- sound         looped on the boat while it is crewed
-- pose          a stance in Core's whywalk_shared.VESSEL_STANCE: 'gondola'
--               (gondola1, turning on gondolar/gondolal), 'rowing'
--               (rowingidle / rowing1 / rowslow, one oar on rowingl and
--               rowingr), 'stand', 'sit'.
--               The rowboat is the only oared hull here. The longboat's pilot
--               stands at the guide slot -- the helmsman's station, per
--               Immersive Travel's mount data -- so it stays 'stand'; its
--               oarsmen are not the player.

M.VESSELS = {
    rowboat = {
        name = 'Rowboat',
        maxSpeed = 144, reverseSpeed = 72, accel = 72, brake = 108, drag = 0.603,
        turnRate = 0.4363, turnResponse = 4.0, pivot = 0.5,
        waterOffset = 2,
        anchor = { x = 0, y = 0, z = 0 },
        hull = nil,
        motion = { roll = 0.028, rollFreq = 0.12, heelMax = 0.084, heelRate = 0.0168,
                   pitch = 0.03491, pitchPeriod = 4 },
        sound = 'Boat Creak',
        pose = 'rowing',
    },

    gondola = {
        name = 'Gondola',
        maxSpeed = 120, reverseSpeed = 60, accel = 48, brake = 72, drag = 0.603,
        turnRate = 0.24, turnResponse = 2.0, pivot = 0.4,
        waterOffset = 40,
        anchor = { x = 0, y = -81.5, z = -38.7 },
        hull = { bow = 354.1, stern = 338.8, halfBeam = 70.5, draft = 42.1 },
        motion = { roll = 0.014, rollFreq = 0.12, heelMax = 0.042, heelRate = 0.0084,
                   pitch = 0.03491, pitchPeriod = 4 },
        sound = 'Boat Creak',
        pose = 'gondola',
    },

    gondola_ornate = {
        name = 'Ornate Gondola',
        maxSpeed = 120, reverseSpeed = 60, accel = 48, brake = 72, drag = 0.603,
        turnRate = 0.24, turnResponse = 2.0, pivot = 0.4,
        waterOffset = 40,
        anchor = { x = 0, y = -81.5, z = -38.7 },
        hull = { bow = 343.1, stern = 361.6, halfBeam = 70.0, draft = 49.6 },
        motion = { roll = 0.014, rollFreq = 0.12, heelMax = 0.042, heelRate = 0.0084,
                   pitch = 0.03491, pitchPeriod = 4 },
        sound = 'Boat Creak',
        pose = 'gondola',
    },

    longboat = {
        name = 'Longboat',
        maxSpeed = 240, reverseSpeed = 120, accel = 96, brake = 144, drag = 0.603,
        turnRate = 0.144, turnResponse = 1.5, pivot = 0.2,
        waterOffset = 74,
        anchor = { x = 67, y = -457, z = -65 },
        hull = { bow = 748.2, stern = 785.8, halfBeam = 259.8, draft = 129.8 },
        motion = { roll = 0.056, rollFreq = 0.12, heelMax = 0.168, heelRate = 0.0336,
                   pitch = 0.01745, pitchPeriod = 6 },
        sound = 'Boat Hull',
        pose = 'stand',
    },

    catboat = {
        name = 'Telvanni Catboat',
        maxSpeed = 240, reverseSpeed = 120, accel = 96, brake = 144, drag = 0.603,
        turnRate = 0.144, turnResponse = 1.5, pivot = 0.2,
        waterOffset = 74,
        anchor = { x = 67, y = -457, z = -65 },
        hull = nil,
        motion = { roll = 0.056, rollFreq = 0.12, heelMax = 0.168, heelRate = 0.0336,
                   pitch = 0.01745, pitchPeriod = 6 },
        sound = 'Boat Hull',
        pose = 'stand',
    },

    fishing_boat = {
        name = 'Fishing Boat',
        maxSpeed = 144, reverseSpeed = 36, accel = 72, brake = 36, drag = 0.3,
        turnRate = 0.1222, turnResponse = 1.5, pivot = 0.0,
        waterOffset = 25,
        anchor = { x = 0, y = 0, z = -11 },
        hull = { bow = 444.7, stern = 319.7, halfBeam = 197.9, draft = 49.7 },
        motion = { roll = 0.042, rollFreq = 0.12, heelMax = 0.126, heelRate = 0.0252,
                   pitch = 0.02618, pitchPeriod = 5 },
        sound = 'Boat Hull',
        pose = 'stand',
    },
}

-- ---------------------------------------------------------------------------
-- PROVENANCE
-- ---------------------------------------------------------------------------
-- 'src:<json path>'          must equal that value in data/boats_sources.json
-- 'src:<json path>|<op>'     after an op: abs, neg, half, x2, x3, x0.6
-- 'derived:<how>'            computed from traced values; the how is checked by eye
-- 'pref:<why>'               a design choice, not a measurement
M.PROVENANCE = {
    rowboat = {
        maxSpeed     = 'src:stormrider.ships.KS_SR_Boat.speedLimit',
        reverseSpeed = 'src:stormrider.ships.KS_SR_Boat.reverseSpeed|abs',
        accel        = 'src:stormrider.ships.SC_NewBoat00.accel',
        brake        = 'derived:accel * 1.5, the Skyships brake/accel ratio (96/64)',
        drag         = 'src:aetheriusOutpost.drag',
        turnRate     = 'src:stormrider.ships.KS_SR_Boat.turnRate',
        turnResponse = 'pref:small hull answers the helm in ~0.25 s',
        pivot        = 'pref:oars can spin a rowboat in place; Stormrider allows no turn at rest',
        waterOffset  = 'src:stormrider.ships.KS_SR_Boat.waterOffset',
        anchor       = 'src:stormrider.ships.KS_SR_Boat.pilotSeat: player at the boat origin, both at z 2',
        hull         = 'pref:vanilla mesh not in the sources; measured from the bounding box in game',
        roll         = 'derived:IT SWAY_AMPL 0.014 * 2, between the gondola (1) and longboat (4)',
        rollFreq     = 'src:immersiveTravel.sway.SWAY_FREQ.raw',
        heelMax      = 'derived:roll * IT SWAY_MAX_AMPL (3)',
        heelRate     = 'derived:roll * IT SWAY_AMPL_CHANGE (0.01) * 60 ticks',
        pitch        = 'src:yourOwnGondola.pitchAmplitude',
        pitchPeriod  = 'src:yourOwnGondola.pitchPeriod',
        sound        = 'pref:Immersive Travel gives small craft Boat Creak',
    },
    gondola = {
        maxSpeed     = 'src:immersiveTravel.mounts.a_gondola_01.speed',
        reverseSpeed = 'pref:half ahead speed',
        accel        = 'derived:maxSpeed * 0.4/s, the Skyships accel/maxSpeed ratio (64/160)',
        brake        = 'derived:accel * 1.5, the Skyships brake/accel ratio',
        drag         = 'src:aetheriusOutpost.drag',
        turnRate     = 'src:immersiveTravel.mounts.a_gondola_01.turnRate',
        turnResponse = 'pref',
        pivot        = 'pref:a single oar turns a gondola slowly at rest',
        waterOffset  = 'src:immersiveTravel.mounts.a_gondola_01.waterOffset',
        anchor       = 'src:meshes.gv_gondola.nif.originInRotFrame: where Your Own Gondola stands the player',
        hull         = 'src:meshes.x/ex_gondola_01_rot.nif.collision',
        roll         = 'src:immersiveTravel.mounts.a_gondola_01.swayAmplitude',
        rollFreq     = 'src:immersiveTravel.sway.SWAY_FREQ.raw',
        heelMax      = 'derived:roll * 3',
        heelRate     = 'derived:roll * 0.6',
        pitch        = 'src:yourOwnGondola.pitchAmplitude',
        pitchPeriod  = 'src:yourOwnGondola.pitchPeriod',
        sound        = 'src:immersiveTravel.mounts.a_gondola_01.sound',
    },
    gondola_ornate = {
        maxSpeed     = 'src:immersiveTravel.mounts.rp_ex_gondola_fancy_tra.speed',
        turnRate     = 'src:immersiveTravel.mounts.rp_ex_gondola_fancy_tra.turnRate',
        waterOffset  = 'src:immersiveTravel.mounts.rp_ex_gondola_fancy_tra.waterOffset',
        roll         = 'src:immersiveTravel.mounts.rp_ex_gondola_fancy_tra.swayAmplitude',
        hull         = 'src:meshes.x/ex_gondola_rpnr_01_rot.nif.collision',
        anchor       = 'derived:same hull as the gondola, so the same standing spot',
        other        = 'derived:as gondola',
    },
    longboat = {
        maxSpeed     = 'src:immersiveTravel.mounts.a_longboat.speed',
        reverseSpeed = 'pref:half ahead speed',
        accel        = 'derived:maxSpeed * 0.4/s',
        brake        = 'derived:accel * 1.5',
        drag         = 'src:aetheriusOutpost.drag',
        turnRate     = 'src:immersiveTravel.mounts.a_longboat.turnRate',
        waterOffset  = 'src:immersiveTravel.mounts.a_longboat.waterOffset',
        anchor       = 'src:immersiveTravel.mounts.a_longboat.guideSlot: the helmsman',
        hull         = 'src:meshes.x/ex_longboat_rot.nif.collision',
        roll         = 'src:immersiveTravel.mounts.a_longboat.swayAmplitude',
        pitch        = 'pref:half the gondola rocking for a heavier hull',
        sound        = 'src:immersiveTravel.mounts.a_longboat.sound',
    },
    catboat = {
        maxSpeed     = 'src:immersiveTravel.mounts.a_telvboat.speed',
        turnRate     = 'src:immersiveTravel.mounts.a_telvboat.turnRate',
        waterOffset  = 'src:immersiveTravel.mounts.a_telvboat.waterOffset',
        anchor       = 'src:immersiveTravel.mounts.a_telvboat.guideSlot',
        roll         = 'src:immersiveTravel.mounts.a_telvboat.swayAmplitude',
        hull         = 'pref:mesh not in the sources; measured in game',
        other        = 'derived:as longboat',
    },
    fishing_boat = {
        maxSpeed     = 'src:stormrider.ships.SC_NewBoat00.baseSpeed',
        accel        = 'src:stormrider.ships.SC_NewBoat00.accel',
        brake        = 'src:stormrider.ships.SC_NewBoat00.decel',
        turnRate     = 'derived:turnRatePerSpeed 0.0611 * speedf 2 at base speed',
        pivot        = 'derived:Stormrider turns ships only while speedf != 0',
        waterOffset  = 'src:stormrider.ships.SC_NewBoat00.waterOffset',
        anchor       = 'derived:pilotSeat z 14 - waterOffset 25',
        hull         = 'derived:meshes.sre/sc_newboat00.nif.collision rotated by pi',
        drag         = 'pref:a sailing hull coasts further than an oared one',
        reverseSpeed = 'pref:no reverse under sail; a pole or oar backs it slowly',
        roll         = 'derived:IT SWAY_AMPL * 3',
    },
}

-- ---------------------------------------------------------------------------
-- MODELS -- which meshes are which vessel, and how they face
-- ---------------------------------------------------------------------------
-- Keyed by normalizeModel(): lower case, forward slashes, no leading meshes/.
-- yawOffset: object yaw = bow heading + yawOffset. Vanilla-orientation meshes
-- have the bow at -Y (Stormrider: object angle = travel - 180), Immersive
-- Travel's _rot copies have it at +Y; the _rot meshes are the vanilla ones
-- turned 180 degrees about the origin (KS_SR_Ship.nif vs Ex_DE_ship_rot.nif
-- negate exactly).
-- origin: where the mesh origin sits in the vessel frame; nil = at the
-- vessel origin.
M.MODELS = {
    ['x/ex_de_rowboat.nif']          = { vessel = 'rowboat',        yawOffset = PI },
    ['x/ex_gondola_01.nif']          = { vessel = 'gondola',        yawOffset = PI },
    ['x/ex_gondola_01_rot.nif']      = { vessel = 'gondola',        yawOffset = 0 },
    ['gv_gondola.nif']               = { vessel = 'gondola',        yawOffset = 0,
                                         origin = { x = 0, y = -81.5, z = -38.7 } },
    ['x/ex_gondola_rpnr_01_rot.nif'] = { vessel = 'gondola_ornate', yawOffset = 0 },
    ['x/ex_longboat.nif']            = { vessel = 'longboat',       yawOffset = PI },
    ['x/ex_longboat_rot.nif']        = { vessel = 'longboat',       yawOffset = 0 },
    ['x/dim_telvcatboat.nif']        = { vessel = 'catboat',        yawOffset = 0 },
    ['sre/sc_newboat00.nif']         = { vessel = 'fishing_boat',   yawOffset = PI },
}

-- ---------------------------------------------------------------------------
-- RECORDS -- activators decided by id, before any model match
-- ---------------------------------------------------------------------------
-- claim = true: take it over even though it carries an MWScript.
-- claim = false: never touch it; another mod drives it.
-- Ids are lower case (Object.recordId always is).
local IMMERSIVE_TRAVEL = 'an Immersive Travel mount; that mod moves it along its routes'
local STORMRIDER = 'Stormrider drives this boat from its own scripts and globals'

M.RECORDS = {
    ['gv_playergond']          = { claim = true,
                                   reason = 'Your Own Gondola; its script only pins the boat to z 0 and rocks it' },
    ['a_gondola_01']           = { claim = false, reason = IMMERSIVE_TRAVEL },
    ['a_longboat']             = { claim = false, reason = IMMERSIVE_TRAVEL },
    ['a_de_ship']              = { claim = false, reason = IMMERSIVE_TRAVEL },
    ['a_telvboat']             = { claim = false, reason = IMMERSIVE_TRAVEL },
    ['a_siltstrider']          = { claim = false, reason = IMMERSIVE_TRAVEL },
    ['c_siltstrider']          = { claim = false, reason = IMMERSIVE_TRAVEL },
    ['a_riverstrider']         = { claim = false, reason = IMMERSIVE_TRAVEL },
    ['dbs_gondola_01_bal']     = { claim = false, reason = IMMERSIVE_TRAVEL },
    ['rp_ex_gondola_fancy_tra'] = { claim = false, reason = IMMERSIVE_TRAVEL },
    ['ks_sr_boat']             = { claim = false, reason = STORMRIDER },
    ['ks_sr_ship']             = { claim = false, reason = STORMRIDER },
    ['sc_o_newboat00']         = { claim = false, reason = STORMRIDER },
    ['sc_o_newship05']         = { claim = false, reason = STORMRIDER },
}

-- ---------------------------------------------------------------------------
-- TUNING
-- ---------------------------------------------------------------------------
M.TUNING = {
    probeInterval    = 0.1,    -- s between hull probes
    probeHeight      = 40,     -- u above the water for the obstacle ray
    obstacleMargin   = 40,     -- u kept between the hull and anything ahead
    bumpRatio        = 0.25,   -- achieved/commanded speed below this is a collision
    bumpTime         = 0.15,   -- s it must persist
    helmEpsilon      = 0.003,  -- rad of heading change before the boat is re-sent
    exitClearance    = 60,     -- u beyond the hull when stepping off
    maxAnchorDrift   = 600,    -- u; further than this the pilot has been moved away
    claimRange       = 400,    -- u from the pilot to a boat they can board
    viewSteerEngage  = 0.105,  -- rad (6 deg)   Sturdy Steed's hysteresis, per Core's README
    viewSteerRelease = 0.026,  -- rad (1.5 deg)
    viewSteerFull    = 0.35,   -- rad of view offset that gives full rudder
    gainMin          = 0.5,    -- closed-loop speed gain bounds
    gainMax          = 2.5,
    gainRate         = 0.5,    -- 1/s
    soundVolume      = 0.6,
    animDeadzone     = 0.2,    -- rudder/throttle below this poses as centred
    -- Speed band for an oared pose, as a fraction of the vessel's maxSpeed.
    -- Two thresholds, not one: the band is crossed on every departure and
    -- every stop, and a single threshold would swap the stroke back and forth
    -- while the hull sat near it. Gap is deliberately wide -- the cost of
    -- being in the "wrong" stroke for a moment is nothing, the cost of
    -- flicker is visible.
    poseFastAbove    = 0.55,   -- below the band, rise above this to drive
    poseSlowBelow    = 0.35,   -- above the band, fall below this to ease off
}

-- ---------------------------------------------------------------------------
-- LOOKUPS
-- ---------------------------------------------------------------------------

function M.normalizeModel(path)
    if type(path) ~= 'string' or path == '' then return nil end
    local p = path:lower():gsub('\\', '/')
    p = p:gsub('^/+', ''):gsub('^meshes/', '')
    return p
end

local function basename(p)
    return p:match('([^/]+)$') or p
end

local byBasename = {}
for key, entry in pairs(M.MODELS) do
    local b = basename(key)
    if byBasename[b] == nil then
        byBasename[b] = entry
    else
        byBasename[b] = false
    end
end

---Model entry for a record's model path; exact relative path first, then a
---unique basename (another mod may ship the same mesh in a different folder).
function M.modelEntry(path)
    local p = M.normalizeModel(path)
    if not p then return nil end
    local exact = M.MODELS[p]
    if exact then return exact end
    local loose = byBasename[basename(p)]
    if loose then return loose end
    return nil
end

function M.recordEntry(recordId)
    if type(recordId) ~= 'string' then return nil end
    return M.RECORDS[recordId:lower()]
end

local BOATLIKE = { 'boat', 'gondola', 'longboat', 'ship', 'raft', 'canoe', 'skiff' }

---True for an unlisted mesh that is probably a boat, so the player can be told
---which path to add to MODELS.
function M.isBoatLikeModel(path)
    local p = M.normalizeModel(path)
    if not p or M.modelEntry(p) then return false end
    local b = basename(p)
    for _, word in ipairs(BOATLIKE) do
        if b:find(word, 1, true) then return true end
    end
    return false
end

local function copy(t)
    if type(t) ~= 'table' then return t end
    local out = {}
    for k, v in pairs(t) do out[k] = copy(v) end
    return out
end

---A FRESH copy of a vessel profile. The session writes measured hull values
---into it; handing out the module table would leak them into every later boat
---(Core's profileFor learned this the hard way).
function M.vessel(vesselId)
    local v = vesselId and M.VESSELS[vesselId]
    if not v then return nil end
    local out = copy(v)
    out.id = vesselId
    return out
end

return M
