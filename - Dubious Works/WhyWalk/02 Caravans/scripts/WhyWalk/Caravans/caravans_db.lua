---@omw-context none
--[[
    caravans_db.lua -- vehicle data, slot geometry, and the travel price

    Pure: no openmw requires, so global, player and local scripts share it.
    Everything the engine has to supply (GMSTs, actor stats) is passed in.

    PROVENANCE. Every number here is measured, not invented, and the source is
    named per field. Measurements come from Immersive Travel (rfuzzo)
    mounts/a_siltstrider.json and services/Caravaner.json, which
    SILTSTRIDER_NOTES.md recommends taking wholesale:

        "Take from [R]: mount measurements, the MountData schema, sway
         constants, the route point sets, the pricing formula."

    WHY THIS IS NOT whywalk_shared.PROFILE

    SILTSTRIDER_NOTES.md, IMPLEMENTATION NOTE:

        "A silt strider is a vehicle, not a mount, and the difference matters.
         It has a guide NPC, multiple passengers, a fixed route, and no player
         steering on-route. That is a different mode from 'mount a creature
         and steer it', and shoehorning it into PROFILE/saddle would distort
         both."

    So this is a VEHICLE table with `slots` rather than one `saddle`, and it
    lives in its own module. Core's PROFILE keeps its single-saddle shape and
    is not touched.
]]

local M = {}

-- ---------------------------------------------------------------------------
-- VEHICLES
-- ---------------------------------------------------------------------------
-- slots      ride positions, vehicle-local (x right, y forward, z up),
--            relative to the vehicle's own origin. The FIRST slot is the
--            player's; the rest are passengers nobody occupies yet.
-- guideSlot  where the caravaner stands, with the animation group [R] gives
--            it. A second occupant that is not the player -- which
--            SILTSTRIDER_NOTES lists as a schema gap in Core's PROFILE.
-- bodyOffset how far BELOW a route point the vehicle origin sits. The route
--            is authored through the body, not the feet.
-- sway       multiplier on the shared sway constants. 1 for a strider, which
--            is the lowest of any mount in [R]'s pack and deliberately almost
--            imperceptible; its boats run 3-4.
-- gait       the vehicle's own locomotion group, played by
--            caravans_vehicle.lua. [R] calls this forwardAnimation.
-- speed      world units/second along the route. NOT from [R]: its `speed: 3`
--            is a per-frame step at an assumed 60fps, which
--            SILTSTRIDER_NOTES (COMPATIBILITY) is explicit does not transfer.
--            See the note on SPEED below.
-- turnRate   radians/second the body eases toward the route heading. [R]'s
--            `turnspeed: 30` is degrees per frame step, so likewise re-derived.

M.VEHICLE = {
    siltstrider = {
        name = "Silt Strider",

        -- src: mounts/a_siltstrider.json
        mesh       = "r\\Siltstrider.nif",
        gait       = "runforward",          -- src: forwardAnimation "runForward"
        sway       = 1,                     -- src: sway
        bodyOffset = 1220,                  -- src: offset -1220

        -- src: slots[]. Three passenger positions spread +/-81 on X, which is
        -- the multi-slot problem SILTSTRIDER_NOTES says PROFILE cannot
        -- express. The front seat (0, 80, 1223) is the player's.
        slots = {
            { x = 0,   y = 80, z = 1223 },
            { x = -81, y = 30, z = 1230 },
            { x = 81,  y = 40, z = 1230 },
        },

        -- src: guideSlot, animationGroup "idle5"
        guideSlot = { x = 0, y = 10, z = 1223, anim = "idle5" },

        -- src: hiddenSlot -- where to park an actor that should exist but not
        -- be seen. Unused so far; recorded because the schema gap note calls
        -- it out and it costs one line.
        hiddenSlot = { x = 0, y = 0, z = 1000 },

        -- src: sound Silt_1/2/3, loopSound false
        sounds = { "Silt_1", "Silt_2", "Silt_3" },
        loopSound = false,

        -- SPEED AND TURN RATE ARE TUNED HERE, NOT IMPORTED.
        --
        -- [R] moves in per-frame steps and multiplies by dt*60 to fake frame
        -- independence (omw_speed.lua: `speed * currentDt * OMW_TARGET_FPS`).
        -- Its 3 and 30 are meaningless without that, so these are chosen
        -- against the measured route lengths instead: the 47 imported routes
        -- average 99,000 units and the longest (Vivec->Seyda Neen) is
        -- 204,000. At 1400 u/s that is a 70-second mean journey and 2.4
        -- minutes at worst, which is long enough to feel like travel and
        -- short enough that nobody reaches for the skip.
        speed    = 1400,
        turnRate = 0.9,
    },
}

-- ---------------------------------------------------------------------------
-- SERVICES
-- ---------------------------------------------------------------------------
-- Which vehicle a service class drives, and the ground offset [R] records for
-- it. `routeKey` is the folder its route files came from, kept so the importer
-- and the runtime agree on one name.

M.SERVICE = {
    caravaner = {
        vehicle      = "siltstrider",
        routeKey     = "Caravaner",
        groundOffset = 1025,       -- src: services/Caravaner.json ground_offset
    },
}

---Resolve a vehicle definition, or nil.
function M.vehicle(id) return id and M.VEHICLE[id] or nil end

---The vehicle a service drives, or nil.
function M.vehicleForService(serviceId)
    local s = serviceId and M.SERVICE[serviceId]
    return s and M.VEHICLE[s.vehicle] or nil
end

-- ---------------------------------------------------------------------------
-- SLOT GEOMETRY
-- ---------------------------------------------------------------------------

---A vehicle-local slot offset rotated into world space and added to the
---vehicle's origin. Yaw convention matches Core and Boats: forward is
---(sin yaw, cos yaw), right is (cos yaw, -sin yaw).
---@return number x, number y, number z
function M.slotWorld(originX, originY, originZ, yaw, slot)
    local s, c = math.sin(yaw), math.cos(yaw)
    return originX + slot.x * c + slot.y * s,
           originY - slot.x * s + slot.y * c,
           originZ + slot.z
end

-- ---------------------------------------------------------------------------
-- PRICE
-- ---------------------------------------------------------------------------
-- OpenMW's own travel price, reimplemented. [R] accumulated it from the engine
-- source and cites both files; SILTSTRIDER_NOTES recommends it over Ben's
-- hardcoded per-route gold because "it is the engine's actual maths":
--
--   mwgui/travelwindow.cpp        the distance/fTravelMult and follower terms
--   mwmechanics/mechanicsmanagerimp.cpp   getBarterOffer's buy term
--
-- Pure, so every term is testable: the caller supplies the GMSTs and both
-- actors' stats rather than this module reaching for them.

---@class CaravanPriceInputs
---@field distance number straight-line player->destination distance (2D)
---@field fTravelMult number GMST; 0 or nil is treated as 1, as the engine does
---@field fFatigueBase number GMST
---@field fFatigueMult number GMST
---@field disposition number guide's disposition toward the player
---@field followers number count of followers travelling too
---@field player table { luck, personality, mercantile, fatigueCurrent, fatigueBase }
---@field guide table same shape

---The weighted skill/attribute sum the engine uses for both parties.
---Each term is independently capped, which is why this is not one expression.
local function weightedSum(a)
    local luck = math.min(10, 0.1 * (a.luck or 0))
    local pers = math.min(10, 0.2 * (a.personality or 0))
    local merc = math.min(100, a.mercantile or 0)
    return luck + pers + merc
end
M.weightedSum = weightedSum

---fFatigueBase - fFatigueMult * (1 - normalisedFatigue).
---A zero fatigue base would divide by zero; the engine cannot produce one but
---a mod-added actor can, so it reads as fully rested rather than throwing.
local function fatigueTerm(a, fFatigueBase, fFatigueMult)
    local base = a.fatigueBase or 0
    local normalized = base > 0 and math.min(1, (a.fatigueCurrent or 0) / base) or 1
    return fFatigueBase - fFatigueMult * (1 - normalized)
end
M.fatigueTerm = fatigueTerm

---The barter buy term: below 1 when the guide likes you, above when they do not.
function M.buyTerm(inp)
    local pcTerm = (inp.disposition - 50 + weightedSum(inp.player))
        * fatigueTerm(inp.player, inp.fFatigueBase, inp.fFatigueMult)
    local guideTerm = weightedSum(inp.guide)
        * fatigueTerm(inp.guide, inp.fFatigueBase, inp.fFatigueMult)
    return 0.01 * (100 - 0.5 * (pcTerm - guideTerm))
end

---Fare in gold, minimum 1.
---@param inp CaravanPriceInputs
function M.price(inp)
    local mult = inp.fTravelMult
    if mult == nil or mult == 0 then mult = 1 end
    local base = (1 + (inp.followers or 0)) * (inp.distance / mult)
    return math.max(1, math.ceil(base * M.buyTerm(inp)))
end

---Hours the engine would have charged for this journey, from the ROUTE length
---rather than the straight line.
---
---The engine uses `static_cast<int>(distance / fTravelTimeMult)` on the direct
---distance. Using the route instead is deliberate: the strider walks the
---route, so the route is the distance actually covered, and it is always the
---longer of the two.
function M.vanillaHours(routeLength, fTravelTimeMult)
    if not fTravelTimeMult or fTravelTimeMult <= 0 then return 0 end
    return math.floor(routeLength / fTravelTimeMult)
end

return M
