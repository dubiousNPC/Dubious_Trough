---@omw-context none
--[[
    shipping_db.lua -- vessels, slot geometry, and the fare

    Pure: no openmw requires, so global and player scripts share it and the
    tools/ tests run it outside the engine.

    PROVENANCE. The slot positions, sway and draft offsets are Immersive
    Travel's (rfuzzo), mounts/a_DE_ship.json and mounts/a_longboat.json,
    converted the same way Caravans converts a_siltstrider.json:

      * IT places the mount at `route point + offset`; here the vessel origin
        is `route z - bodyOffset`, so bodyOffset = -offset.
      * IT ships its own copies of the hulls (`x\Ex_DE_ship_rot.nif`,
        `x\Ex_longboat_rot.nif`). They are the vanilla meshes turned half a
        turn and nothing else -- the render and collision boxes are the vanilla
        ones mirrored through the origin (tools/survey output in the report).
        So this uses the VANILLA mesh with yawOffset = pi and needs no asset
        from Immersive Travel. IT's slot positions are measured in the turned
        frame, where +Y is the bow, which is exactly the frame slotWorld uses:
        they carry over unchanged.
      * The slot HEIGHTS are re-measured in OpenMW 0.52 (deck raycasts against
        the spawned hull; see the report). A pinned passenger has to start each
        frame a few units ABOVE the deck, or they drop through it -- the
        Caravans lesson of 2026-11-03c (slot 1223 against a 1223.1 floor).

    SPEED IS NOT IMPORTED. IT's `speed: 3` is a per-frame step at an assumed
    60fps. The cruise speed is a setting (shipping_player), and the per-vessel
    numbers here only scale it.
]]

local M = {}

local PI = math.pi

-- ---------------------------------------------------------------------------
-- VESSELS
-- ---------------------------------------------------------------------------
-- mesh        VFS path under meshes/
-- yawOffset   object yaw = travel heading + yawOffset (vanilla hulls face -Y)
-- bodyOffset  vessel origin = route z - bodyOffset
-- sway        multiplier on the walker's roll; IT: 3 for the ship, 4 boats
-- speedScale  multiplier on the cruise setting
-- turn        corner rounding for prepare(): a 2400-unit hull cannot take the
--             strider's 1000-unit corners without its stern swinging through
--             the quay, so ships round wider and may leave the line further
-- turnRate    radians/second the body may turn at any point (the walker slows
--             for corners to hold it); a strider is allowed 90 degrees/s
-- accel       u/s^2 for leaving and arriving, and for braking into corners
-- slots       vehicle-local (x right, y bow, z up) from the origin. [1] is the
--             player's; the rest are recorded for passengers to come
-- guideSlot   where the shipmaster stands
-- sound       looped while under way, if the record exists
M.VESSEL = {
    de_ship = {
        name       = 'Ship',
        mesh       = 'x\\Ex_DE_ship.nif',
        yawOffset  = PI,
        bodyOffset = 20,             -- IT a_DE_ship offset -20
        sway       = 3,              -- IT sway
        speedScale = 1.0,
        turn       = { RADIUS = 4000, MAX_DEV = 600, MAX_ARC = math.rad(179) },
        turnRate   = math.rad(25),
        accel      = 250,
        -- IT slots[1] is (0, 438, 257): the bow deck. Heights measured in
        -- OpenMW 0.52 (deck raycast against the spawned hull): floor at 253.9,
        -- 209.1, 208.5, 207.9, 207.9, and 364.7 at the helm. IT's 209 is 0.1
        -- UNDER the main deck and its helm 360 is 4.7 under the quarterdeck,
        -- so the shipmaster was being teleported into the planking every
        -- frame. Each slot is now 3 above what it stands on.
        slots = {
            { x = 0,    y = 438,  z = 257 },
            { x = 0,    y = 29,   z = 212 },
            { x = -181, y = 139,  z = 212 },
            { x = 181,  y = -139, z = 211 },
            { x = 115,  y = -466, z = 211 },
        },
        guideSlot  = { x = -25, y = -823, z = 368 },   -- the helm, aft
        sound      = 'boat hull',
    },
    longboat = {
        name       = 'Longboat',
        mesh       = 'x\\Ex_longboat.nif',
        yawOffset  = PI,
        bodyOffset = -74,            -- IT a_longboat offset 74
        sway       = 4,
        speedScale = 1.0,
        turn       = { RADIUS = 2500, MAX_DEV = 400, MAX_ARC = math.rad(179) },
        turnRate   = math.rad(35),
        accel      = 350,
        -- Heights measured in OpenMW 0.52 (deck raycast against the spawned
        -- hull at each slot): floor at -60.3, -21.2 (a thwart), -21.4 (a
        -- thwart), -40.8; guide -61.0. IT's -63 for the player put them 2.7
        -- units UNDER the floor. Each slot is now 3 above what it stands on.
        slots = {
            { x = 0,    y = 411,  z = -57 },
            { x = -132, y = 67,   z = -18 },
            { x = 160,  y = -145, z = -18 },
            { x = -79,  y = -390, z = -38 },
        },
        guideSlot  = { x = 67, y = -457, z = -58 },
        sound      = 'boat hull',
    },
    -- IT's a_telvboat is `x\dim_telvcatboat.nif`, a mesh from another mod,
    -- and its slot table is a byte-for-byte copy of a_longboat's -- not
    -- measurements of that hull. Recorded so the route assignment is honest;
    -- the runtime falls back to the longboat when the mesh is absent, and
    -- the slots need measuring against the real hull before it is trusted.
    telvboat = {
        name       = 'Telvanni Boat',
        mesh       = 'x\\dim_telvcatboat.nif',
        fallback   = 'longboat',
        unmeasured = true,
        yawOffset  = PI,
        bodyOffset = -74,
        sway       = 4,
        speedScale = 1.0,
        turn       = { RADIUS = 2500, MAX_DEV = 400, MAX_ARC = math.rad(179) },
        turnRate   = math.rad(35),
        accel      = 350,
        slots = {
            { x = 0,    y = 411,  z = -63 },
        },
        guideSlot  = { x = 67, y = -457, z = -65 },
        sound      = 'boat hull',
    },
}

-- Immersive Travel's mount ids, as the route file records them.
M.MOUNT = {
    a_de_ship  = 'de_ship',
    a_longboat = 'longboat',
    a_telvboat = 'telvboat',
}

---The vessel definition for a route's IT mount id, following `fallback` when
---`exists(mesh)` says the mesh is not installed. `exists` is passed in so this
---stays pure; nil means "assume present".
---@return table|nil vessel, string|nil id
function M.vesselFor(mountId, exists)
    local id = mountId and M.MOUNT[mountId:lower()] or 'longboat'
    local seen = {}
    while id and not seen[id] do
        seen[id] = true
        local v = M.VESSEL[id]
        if not v then return nil, nil end
        if not exists or exists('meshes/' .. v.mesh:gsub('\\', '/'):lower()) then
            return v, id
        end
        id = v.fallback
    end
    return nil, nil
end

-- ---------------------------------------------------------------------------
-- WHO SELLS SHIP TRAVEL
-- ---------------------------------------------------------------------------
-- Immersive Travel's rule (main.lua): the NPC's CLASS names the service, and
-- `override_npc` adds named NPCs of other classes. The vanilla one that
-- matters is Rindral Dralor, a Rogue who sails from Molag Mar.
--
-- IT's list also has "nireli faris", which matches nobody: the vanilla id is
-- `nireli farys`, and she is a Shipmaster by class anyway. Both spellings are
-- kept so a mod that adds the misspelt id is still served.
M.SERVICE = {
    classes = { shipmaster = true },
    npcs = { ['rindral dralor'] = true, ['daynas darys'] = true,
             ['nireli faris'] = true, ['nireli farys'] = true },
}

---Does this guide sell SHIP travel? `classId` and `recordId` as the engine
---reports them; compared case-insensitively.
function M.isShipmaster(classId, recordId)
    if classId and M.SERVICE.classes[classId:lower()] then return true end
    return recordId ~= nil and M.SERVICE.npcs[recordId:lower()] == true
end

-- ---------------------------------------------------------------------------
-- SLOT GEOMETRY
-- ---------------------------------------------------------------------------

---A vehicle-local slot rotated into world space and added to the origin.
---Forward is (sin yaw, cos yaw), right is (cos yaw, -sin yaw): the same as
---Core, Boats and Caravans.
---@return number x, number y, number z
function M.slotWorld(originX, originY, originZ, yaw, slot)
    local s, c = math.sin(yaw), math.cos(yaw)
    return originX + slot.x * c + slot.y * s,
           originY - slot.x * s + slot.y * c,
           originZ + slot.z
end

-- ---------------------------------------------------------------------------
-- DEPARTURE AND ARRIVAL SPEED
-- ---------------------------------------------------------------------------
-- The walker's speed profile slows for corners but starts and ends a journey
-- at cruising speed, which a strider can carry and a ship cannot: leaving a
-- quay at 1600 u/s from a standstill is a teleport with extra steps.

---Speed allowed by the start and end of the route alone.
---@param d number distance travelled
---@param total number route length
---@param accel number u/s^2
---@param floor number lowest speed, so a journey always starts and finishes
function M.rampSpeed(d, total, accel, floor)
    local up = math.sqrt(2 * accel * math.max(0, d))
    local down = math.sqrt(2 * accel * math.max(0, total - d))
    return math.max(floor, math.min(up, down))
end

-- ---------------------------------------------------------------------------
-- FARE AND TIME
-- ---------------------------------------------------------------------------
-- OpenMW's own travel price, to the gold piece: TravelWindow::addDestination
-- (mwgui/travelwindow.cpp) and MechanicsManager::getBarterOffer
-- (mwmechanics/mechanicsmanagerimp.cpp), 0.52 source.
--
-- NOT the formula Caravans and Immersive Travel use. Theirs takes the barter
-- term on the unrounded distance and rounds UP; the engine truncates twice --
-- `int(d / fTravelMult)` first, then `int(price * buyTerm)` -- and measures
-- d in 3D. Checked in OpenMW 0.52 against Gals Arethi's own travel window in
-- Sadrith Mora: the engine showed 44 / 58 / 26 / 52 gold, the Caravans
-- formula gave 46 / 60 / 28 / 53 for the same four destinations, and this
-- gives the engine's numbers.

local function weightedSum(a)
    return math.min(10, 0.1 * (a.luck or 0))
         + math.min(10, 0.2 * (a.personality or 0))
         + math.min(100, a.mercantile or 0)
end
M.weightedSum = weightedSum

local function fatigueTerm(a, fFatigueBase, fFatigueMult)
    local base = a.fatigueBase or 0
    local normalized = base > 0 and math.min(1, (a.fatigueCurrent or 0) / base) or 1
    return fFatigueBase - fFatigueMult * (1 - normalized)
end
M.fatigueTerm = fatigueTerm

function M.buyTerm(inp)
    local pcTerm = (inp.disposition - 50 + weightedSum(inp.player))
        * fatigueTerm(inp.player, inp.fFatigueBase, inp.fFatigueMult)
    local guideTerm = weightedSum(inp.guide)
        * fatigueTerm(inp.guide, inp.fFatigueBase, inp.fFatigueMult)
    return 0.01 * (100 - 0.5 * (pcTerm - guideTerm))
end

local function trunc(x) return x >= 0 and math.floor(x) or math.ceil(x) end

---Fare in gold. `distance` is the 3D player-to-destination distance, as the
---engine measures it.
function M.price(inp)
    local mult = inp.fTravelMult
    local base = (mult and mult ~= 0) and trunc(inp.distance / mult) or trunc(inp.distance)
    base = base * (1 + (inp.followers or 0))
    base = math.max(1, base)
    return math.max(1, trunc(base * M.buyTerm(inp)))
end

---Hours vanilla travel would charge: `int(distance / fTravelTimeMult)` on the
---STRAIGHT distance, as the engine does.
---
---Caravans charges by route length instead, and on land that is a few per cent
---more. At sea it is not: a ship goes round the coast, and Ebonheart to Sadrith
---Mora is 447,000 units of route against 186,000 straight -- 27 hours against
---11 at the default fTravelTimeMult. Charging that would make the voyage
---two and a half times dearer in time than the
---ticket the same shipmaster sells in vanilla, so ships charge vanilla's hours.
function M.vanillaHours(distance, fTravelTimeMult)
    if not fTravelTimeMult or fTravelTimeMult <= 0 then return 0 end
    return math.floor(distance / fTravelTimeMult)
end

return M
