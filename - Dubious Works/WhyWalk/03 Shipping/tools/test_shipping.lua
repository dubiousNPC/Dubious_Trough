-- test_shipping.lua -- route matching, vessels, the voyage profile, the fare
--
--   run from "03 Shipping":  luarun.py tools/test_shipping.lua
--
-- Against the REAL imported routes and a fixture of the REAL vanilla
-- shipmasters (tools/fixture_vanilla.lua, generated from Morrowind, Tribunal
-- and Bloodmoon with an independent Python implementation of the rule).

-- LuaJIT's maths, as OpenMW runs it (see Caravans' test_caravans.lua).
do
    local hostAtan, hostAtan2 = math.atan, math.atan2
    if not hostAtan2 then
        math.atan2 = function(y, x) return hostAtan(y, x) end
        math.atan = function(y) return hostAtan(y) end
    end
end

local path  = dofile('scripts/WhyWalk/Shipping/shipping_path.lua')
local db    = dofile('scripts/WhyWalk/Shipping/shipping_db.lua')
local stops = dofile('scripts/WhyWalk/Shipping/shipping_stops.lua')
local R     = dofile('scripts/WhyWalk/Shipping/shipping_routes.lua')
local FIX   = dofile('tools/fixture_vanilla.lua')

local pass, fail = 0, 0
local function check(name, cond, got)
    if cond then pass = pass + 1
    else fail = fail + 1; print(('  FAIL %s  -> %s'):format(name, tostring(got))) end
end

-- ---------------------------------------------------------------------------
print('route data')
check('140 routes imported', #R.routes == 140, #R.routes)
local badMount, badShape = 0, 0
for _, r in ipairs(R.routes) do
    if not db.MOUNT[r.mount:lower()] then badMount = badMount + 1 end
    if #r % 3 ~= 0 or #r < 6 then badShape = badShape + 1 end
end
check('every route names a vessel the db knows', badMount == 0, badMount)
check('every route is whole x,y,z triples, at least two points', badShape == 0, badShape)
local spikes = 0
for _, r in ipairs(R.routes) do if stops.spike(r) then spikes = spikes + 1 end end
check('no shipped route has a spike', spikes == 0, spikes)

-- the spike test itself: an out-and-back stray point is caught, a long
-- straight open-water leg is not
local spiky = { 0,0,0, 0,1000,0, 0,2000,0, 0,30000,0, 0,2100,0, 0,3100,0 }
check('a stray point that doubles back is a spike', stops.spike(spiky) ~= nil, stops.spike(spiky))
local longLeg = { 0,0,0, 0,1000,0, 0,2000,0, 50,40000,0, 0,41000,0, 0,42000,0 }
check('a long straight leg is not a spike', stops.spike(longLeg) == nil, stops.spike(longLeg))

-- ---------------------------------------------------------------------------
print('matching the vanilla shipmasters')
local known = stops.knownNames(R.routes)
local agree, routed, total = 0, 0, 0
for _, g in ipairs(FIX) do
    for _, d in ipairs(g.dests) do
        total = total + 1
        local r, rev = stops.match(R.routes, g, d, nil, known)
        local e = d.expect
        local same
        if not e then same = r == nil
        else same = r ~= nil and r.from == e.from and r.to == e.to and rev == e.reversed end
        if same then agree = agree + 1 else
            print(('    %s -> %s: got %s, python %s'):format(g.id, tostring(d.name),
                r and (r.from .. '>' .. r.to .. (rev and ' rev' or '')) or 'nil',
                e and (e.from .. '>' .. e.to .. (e.reversed and ' rev' or '')) or 'nil'))
        end
        if r then routed = routed + 1 end
    end
end
check('Lua and Python pick the same route for every vanilla destination', agree == total,
    agree .. '/' .. total)
check('21 of 45 vanilla destinations have a route', routed == 21, routed)

local function find(id)
    for _, g in ipairs(FIX) do if g.id == id then return g end end
end
local function m(id, destName)
    local g = find(id)
    for _, d in ipairs(g.dests) do
        if d.name == destName then return stops.match(R.routes, g, d, nil, known) end
    end
end
local r, rev = m('ano andaram', 'hla oad')
check('Vivec FQ -> Hla Oad sails the Hla Oad route backwards',
    r and r.from == 'hla oad' and r.to == 'vivec, foreign quarter' and rev == true)
r = m('gals arethi', 'tel mora')
check('Sadrith Mora -> Tel Mora is not served by the Sadrith Mora -> Vos ship', r == nil,
    r and (r.from .. '>' .. r.to))
r = m('tonas telvani', 'sadrith mora')
check('Tel Mora -> Sadrith Mora is not served from the Vos quay', r == nil,
    r and (r.from .. '>' .. r.to))
r = m('tonas telvani', 'vos')
check('Tel Mora -> Vos sails its own route', r and r.from == 'tel mora' and r.to == 'vos')
r = m("s'virr", 'fort frostmoth')
check('Khuul -> vanilla Fort Frostmoth has no route (IT data is for a moved Solstheim)', r == nil)

-- names bind only where the name is a route name
local nameless = stops.match(R.routes, { x = 100771, y = 114190, name = nil },
    { x = 141877, y = 38613, name = 'somewhere new' }, nil, known)
check('an unknown cell name falls back to position', nameless and nameless.to == 'sadrith mora',
    nameless and nameless.to)

-- ---------------------------------------------------------------------------
print('vessels')
for _, r in ipairs(R.routes) do
    local v = db.vesselFor(r.mount)
    if not v then check('vessel for ' .. r.mount, false) end
end
local function onlyVanilla(p) return p ~= 'meshes/x/dim_telvcatboat.nif' end
local v, id = db.vesselFor('a_telvboat', onlyVanilla)
check('the Telvanni boat falls back to the longboat when its mesh is missing', id == 'longboat', id)
v, id = db.vesselFor('a_DE_ship', onlyVanilla)
check('a_DE_ship is the Dunmer ship, mixed case and all', id == 'de_ship', id)
check('Rindral Dralor (a Rogue) sells ship travel', db.isShipmaster('Rogue', 'rindral dralor'))
check('a Shipmaster by class sells ship travel', db.isShipmaster('Shipmaster', 'anyone'))
check('a caravaner does not', not db.isShipmaster('Caravaner', 'darvame hleran'))

-- slot geometry: the bow slot of a ship heading east is east of the origin
local x, y = db.slotWorld(0, 0, 0, math.pi / 2, { x = 0, y = 438, z = 0 })
check('slot forward is +Y in the vessel frame', math.abs(x - 438) < 1e-6 and math.abs(y) < 1e-6, x .. ',' .. y)

-- ---------------------------------------------------------------------------
print('the voyage profile, every route, both vessels, 60fps')
-- Walk every route as shipping_global does: cruise from the corner profile,
-- capped by the departure/arrival ramp. The body must never turn faster than
-- the vessel allows (plus the profile's own floor at reversal nodes) and must
-- start and finish slowly.
local worstRate, worstRoute, worstStart, worstEnd, longest = 0, '', 0, 0, 0
for _, r in ipairs(R.routes) do
    local vv = db.vesselFor(r.mount, onlyVanilla)
    path.SPEED.MAX_TURN_RATE = vv.turnRate
    path.SPEED.ACCEL = vv.accel
    local prep = path.prepare(r, false, vv.turn)
    longest = math.max(longest, prep.total)
    local d, dt, last, cruise = 0, 1 / 60, nil, 1600
    local first = nil
    local steps = 0
    while d < prep.total and steps < 200000 do
        steps = steps + 1
        local sp = math.min(path.speedAt(prep, d, cruise), db.rampSpeed(d, prep.total, vv.accel, 40))
        first = first or sp
        d = d + sp * dt
        local _, _, _, f = path.at(r, prep, d)
        if last and f then
            local rate = math.abs(path.angleDiff(last, f)) / dt
            -- A reversal node is left sharp by design and crept through at
            -- the profile's 30 u/s floor; judge the corners that have arcs.
            if rate > worstRate and sp > 31 then worstRate, worstRoute = rate, r.from .. '>' .. r.to end
        end
        last = f
    end
    worstStart = math.max(worstStart, first or 0)
    local endSp = db.rampSpeed(prep.total - 1, prep.total, vv.accel, 40)
    worstEnd = math.max(worstEnd, endSp)
end
check('no ship turns faster than 40 degrees a second at any arc',
    math.deg(worstRate) <= 40.5, string.format('%.1f deg/s on %s', math.deg(worstRate), worstRoute))
check('every voyage leaves the quay at walking pace', worstStart <= 41, worstStart)
check('every voyage arrives at walking pace', worstEnd <= 41, worstEnd)
print(string.format('    worst turn rate %.1f deg/s (%s); longest route %.0f units',
    math.deg(worstRate), worstRoute, longest))

-- ramp properties
check('ramp is symmetric', math.abs(db.rampSpeed(1000, 10000, 250, 0) - db.rampSpeed(9000, 10000, 250, 0)) < 1e-9)
check('ramp never falls below its floor', db.rampSpeed(0, 10000, 250, 40) == 40)

-- ---------------------------------------------------------------------------
print('fare and hours')
local inp = {
    distance = 50000, fTravelMult = 4000, fFatigueBase = 1.25, fFatigueMult = 0.5,
    disposition = 50, followers = 0,
    player = { luck = 40, personality = 40, mercantile = 10, fatigueCurrent = 100, fatigueBase = 100 },
    guide  = { luck = 50, personality = 50, mercantile = 30, fatigueCurrent = 100, fatigueBase = 100 },
}
-- Hand-computed from TravelWindow::addDestination / getBarterOffer:
--   base int(50000/4000) = 12
--   player sum 4 + 8 + 10 = 22, guide 5 + 10 + 30 = 45, fatigue term 1.25
--   pcTerm (50-50+22)*1.25 = 27.5, guideTerm 56.25
--   buy 0.01 * (100 - 0.5*(27.5-56.25)) = 1.14375 -> int(12 * 1.14375) = 13
check('price matches the engine, truncating twice', db.price(inp) == 13, db.price(inp))
inp.distance = 999
check('a short trip costs at least 1', db.price(inp) == 1, db.price(inp))
inp.distance, inp.followers = 50000, 1
check('a follower doubles the base before the barter term', db.price(inp) == 27, db.price(inp))
inp.followers = 0
check('vanilla hours on the straight line', db.vanillaHours(186000, 16000) == 11)

print('walking the deck: who is carried')
do
    local deck = require('scripts.WhyWalk.Shipping.shipping_deck')
    local T = deck.TUNING
    local st = deck.new(0)
    check('before any report the passenger is carried', deck.step(st, 0.1, 0.1) == 'carry')
    deck.setFooting(st, { onVessel = true, swimming = false })
    check('standing on the vessel is carried', deck.step(st, 0.1, 0.2) == 'carry')
    deck.setFooting(st, { onVessel = false, swimming = false })
    check('a jump (off the vessel, not swimming) is carried within the grace',
        deck.step(st, 0.1, 0.2 + T.GRACE - 0.05) == 'carry')
    check('after the grace they are free', deck.step(st, 0.1, 0.2 + T.GRACE + 0.05) == 'free')
    st = deck.new(0)
    deck.setFooting(st, { onVessel = false, swimming = true })
    check('a swimmer is never carried, even inside the grace', deck.step(st, 0.1, 0.1) == 'free')
    local t, v = 0.1, nil
    while t < 10 do t = t + 0.1; v = deck.step(st, 0.1, t); if v == 'rescue' then break end end
    check('a swimmer is hauled back aboard after RESCUE_SWIM', v == 'rescue' and math.abs(t - 0.1 - T.RESCUE_SWIM) < 0.25, t)
    check('after a rescue the passenger is carried until the next report', deck.step(st, 0.1, t + 0.1) == 'carry')
    st = deck.new(0)
    deck.setFooting(st, { onVessel = false, swimming = false })
    t, v = 0, nil
    while t < 20 do t = t + 0.1; v = deck.step(st, 0.1, t); if v == 'rescue' then break end end
    check('adrift but dry: rescued after the grace plus RESCUE_ADRIFT', v == 'rescue'
        and math.abs(t - T.GRACE - T.RESCUE_ADRIFT) < 0.25, t)
    st = deck.new(0)
    deck.setFooting(st, { onVessel = true, swimming = false }); deck.step(st, 0.1, 0.1)
    deck.setFooting(st, { onVessel = false, swimming = true }); deck.step(st, 0.1, 0.2)
    deck.setFooting(st, { onVessel = false, swimming = false })
    check('a swimmer whose swimming flag flickers off is not carried by the jump grace',
        deck.step(st, 0.1, 0.3) == 'free')
    deck.setFooting(st, { onVessel = true, swimming = false })
    check('back on the hull, they are carried again', deck.step(st, 0.1, 0.4) == 'carry')
    deck.setFooting(st, { onVessel = false, swimming = false })
    check('and a later jump gets the grace again', deck.step(st, 0.1, 0.5) == 'carry')
    t = 0.5
    deck.setFooting(st, { onVessel = true, swimming = true })
    check('on the hull but swimming (in the hold, flooded) is not carried', deck.step(st, 0.1, t + 0.1) == 'free')
end

print(('%d passed, %d failed'):format(pass, fail))
if fail > 0 then error('test_shipping failed') end
