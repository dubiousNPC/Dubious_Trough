-- test_caravans.lua -- the route walker, the price, and the imported data
--
--   run from "02 Caravans":  luarun.py tools/test_caravans.lua
--
-- Against the REAL imported routes, not a mock. The 2026-10-22 fallback bug
-- got through because the previous suite's mock skeleton happened to contain
-- every group it asked for, so these assertions read the shipped data file.

local path = dofile('scripts/WhyWalk/Caravans/caravans_path.lua')
local db   = dofile('scripts/WhyWalk/Caravans/caravans_db.lua')
local R    = dofile('scripts/WhyWalk/Caravans/caravans_routes.lua')

local pass, fail = 0, 0
local function check(name, cond, got)
    if cond then
        pass = pass + 1
        print(('  ok   %s'):format(name))
    else
        fail = fail + 1
        print(('  FAIL %s  -> %s'):format(name, tostring(got)))
    end
end
local function near(a, b, eps) return math.abs(a - b) <= (eps or 1e-6) end

-- ---------------------------------------------------------------------------
-- THE IMPORTED DATA
-- ---------------------------------------------------------------------------

local routeCount, pointCount = 0, 0
local badShape, emptyRoute, unnamed = {}, {}, {}
for origin, dests in pairs(R.routes) do
    if not R.names[origin] then unnamed[#unnamed + 1] = origin end
    for dest, arr in pairs(dests) do
        routeCount = routeCount + 1
        pointCount = pointCount + #arr / 3
        if #arr % 3 ~= 0 then badShape[#badShape + 1] = origin .. '->' .. dest end
        if #arr == 0 then emptyRoute[#emptyRoute + 1] = origin .. '->' .. dest end
        if not R.names[dest] then unnamed[#unnamed + 1] = dest end
    end
end

check('routes were imported', routeCount == 47, routeCount)
check('point count matches the import report', pointCount == 2150, pointCount)
check('every route is a whole number of x,y,z triples',
      #badShape == 0, table.concat(badShape, ', '))
-- The source ships two EMPTY Caravaner files (Necrom_Sailen, Sailen_Bosmora).
-- SILTSTRIDER_NOTES warns they would "teleport the strider to origin"; the
-- importer drops them, and this is the assertion that keeps them dropped.
check('no empty route survived the import',
      #emptyRoute == 0, table.concat(emptyRoute, ', '))
check('every place key has a display name',
      #unnamed == 0, table.concat(unnamed, ', '))

-- Lower-case keys throughout, because the source mixes Title Case with one
-- all-lower-case file (balmora_vivec) and the runtime folds cell names.
local badCase = {}
for origin, dests in pairs(R.routes) do
    if origin ~= origin:lower() then badCase[#badCase + 1] = origin end
    for dest in pairs(dests) do
        if dest ~= dest:lower() then badCase[#badCase + 1] = dest end
    end
end
check('every route key is lower-cased', #badCase == 0, table.concat(badCase, ', '))

-- ---------------------------------------------------------------------------
-- MEASURING
-- ---------------------------------------------------------------------------

local pts = R.routes['balmora']['ald-ruhn']
check('the reference route is present', pts ~= nil and #pts > 0)

local fwd = path.prepare(pts, false)
local rev = path.prepare(pts, true)

check('point count is length/3', path.count(pts) == #pts / 3, path.count(pts))
check('cum starts at zero', fwd.cum[1] == 0, fwd.cum[1])
check('cum is monotonic', (function()
    for i = 2, fwd.n do
        if fwd.cum[i] < fwd.cum[i - 1] then return false end
    end
    return true
end)())
check('total equals the last cumulative length',
      near(fwd.total, fwd.cum[fwd.n]), fwd.total)
-- Measured in 3D: this route climbs from z 1315 to z 2630, and a 2D
-- measurement would finish the uphill legs early.
check('length is measured in 3D, not 2D', fwd.total > 137000, fwd.total)
check('reversing does not change the length', near(fwd.total, rev.total),
      rev.total)

-- ---------------------------------------------------------------------------
-- WALKING
-- ---------------------------------------------------------------------------

local sx, sy, sz = path.at(pts, fwd, 0)
local ex, ey, ez = path.at(pts, fwd, fwd.total)
check('distance 0 is the first point',
      sx == pts[1] and sy == pts[2] and sz == pts[3], sx)
check('the full length is the last point',
      ex == pts[#pts - 2] and ey == pts[#pts - 1] and ez == pts[#pts], ex)

-- Clamping, not wrapping. A route that silently restarted would loop a
-- passenger forever.
local bx, by, bz = path.at(pts, fwd, -5000)
check('before the start clamps to the first point',
      bx == sx and by == sy and bz == sz, bx)
local ax, ay, az = path.at(pts, fwd, fwd.total + 50000)
check('past the end clamps to the last point',
      ax == ex and ay == ey and az == ez, ax)

-- Reversed walking is the forward route backwards.
local rsx, rsy, rsz = path.at(pts, rev, 0)
check('reversed start is the forward end',
      rsx == ex and rsy == ey and rsz == ez, rsx)
local rex, rey, rez = path.at(pts, rev, rev.total)
check('reversed end is the forward start',
      rex == sx and rey == sy and rez == sz, rex)

-- Arc length, not point index: walking half the length must land near the
-- geometric middle, which a point-index walker would not.
local hx, hy = path.at(pts, fwd, fwd.total / 2)
local dStart = math.sqrt((hx - sx) ^ 2 + (hy - sy) ^ 2)
local dEnd = math.sqrt((hx - ex) ^ 2 + (hy - ey) ^ 2)
check('half the arc length is roughly equidistant from both ends',
      math.abs(dStart - dEnd) < fwd.total * 0.25,
      ('%.0f vs %.0f'):format(dStart, dEnd))

-- Stepping in even increments must cover the route monotonically and reach
-- the end exactly once.
local lastD, steps, monotonic = -1, 0, true
for d = 0, fwd.total, fwd.total / 200 do
    local x, y = path.at(pts, fwd, d)
    if d <= lastD then monotonic = false end
    lastD = d
    steps = steps + 1
    if x ~= x or y ~= y then monotonic = false end    -- NaN guard
end
check('200 even steps walk the route without NaN', monotonic and steps >= 200, steps)

-- Every imported route must be walkable end to end. This is the assertion
-- that would have caught a malformed import.
local unwalkable = {}
for origin, dests in pairs(R.routes) do
    for dest, arr in pairs(dests) do
        local p = path.prepare(arr, false)
        if not (p.total > 0) then
            unwalkable[#unwalkable + 1] = origin .. '->' .. dest
        else
            local x, y, z, yaw = path.at(arr, p, p.total / 2)
            if x ~= x or y ~= y or z ~= z or yaw == nil then
                unwalkable[#unwalkable + 1] = origin .. '->' .. dest
            end
        end
    end
end
check('all 47 routes are walkable with a defined heading at the midpoint',
      #unwalkable == 0, table.concat(unwalkable, ', '))

-- ---------------------------------------------------------------------------
-- HEADING
-- ---------------------------------------------------------------------------
-- Morrowind's convention, matching Core and Boats: forward = (sin yaw, cos yaw),
-- so 0 is +Y and it increases toward +X.

check('due north is 0', near(path.headingOf(0, 100), 0, 1e-9),
      path.headingOf(0, 100))
check('due east is pi/2', near(path.headingOf(100, 0), math.pi / 2, 1e-9),
      path.headingOf(100, 0))
check('due south is pi', near(path.headingOf(0, -100), math.pi, 1e-9),
      path.headingOf(0, -100))
check('due west is 3pi/2', near(path.headingOf(-100, 0), 3 * math.pi / 2, 1e-9),
      path.headingOf(-100, 0))
check('a zero vector has no heading', path.headingOf(0, 0) == nil)

check('angleDiff takes the short way across north',
      near(path.angleDiff(0.1, 2 * math.pi - 0.1), -0.2, 1e-9),
      path.angleDiff(0.1, 2 * math.pi - 0.1))

-- Easing: a step must not overshoot, must converge, and must cross north the
-- short way.
local h = 0.0
for _ = 1, 200 do h = path.easeHeading(h, math.pi / 2, 0.9, 1 / 60) end
check('easing converges on the target', near(h, math.pi / 2, 1e-6), h)

-- Crossing north the short way: from just past 0 toward just before 2pi, the
-- shortest path is BACKWARDS through 0. One step must therefore DECREASE the
-- heading (0.05 -> 0.035), and only after it passes 0 does it wrap to just
-- under 2pi. An earlier version of this test asserted the wrap after a single
-- step, which the easing rightly refused to do.
local oneStep = path.easeHeading(0.05, 2 * math.pi - 0.05, 0.9, 1 / 60)
check('one step toward a heading just across north goes backwards',
      oneStep < 0.05, oneStep)
local crossing = 0.05
for _ = 1, 20 do
    crossing = path.easeHeading(crossing, 2 * math.pi - 0.05, 0.9, 1 / 60)
end
-- THE RESULT IS AN ANGLE, NOT A NUMBER IN A RANGE.
--
-- This pair used to read `crossing > math.pi` and
-- `near(crossing, 2*pi - 0.05)`, which asserted the NORMALISED value -- and
-- so made the normalisation a requirement. That normalisation is what
-- performed a 20-degree turn as a 340-degree turn the other way, because the
-- value handed to the engine jumped a full turn as it crossed north. The test
-- helped the bug survive by insisting on the thing that caused it.
--
-- Compared as an angle now, which is all that was ever meant.
check('continuing to ease arrives at the target heading',
      math.abs(path.angleDiff(crossing, 2 * math.pi - 0.05)) < 1e-6,
      crossing)
check('having gone the SHORT way, backwards through north',
      crossing < 0.05, crossing)

-- AND THE VALUE MUST BE CONTINUOUS, which is the property the engine needs.
-- No step may jump by anything like a full turn, however many times the
-- heading crosses north.
---Turn continuously one way for `steps` frames and report the worst single
---raw step and where the heading ended up.
local function spin(sign, steps)
    local h, worst = 0.0, 0
    for _ = 1, steps do
        -- A target always a radian ahead in the chosen direction, so the ease
        -- is saturated and the heading turns at the full rate throughout.
        local next_ = path.easeHeading(h, h + sign * 1.0, 2.0, 1 / 60)
        local jump = math.abs(next_ - h)
        if jump > worst then worst = jump end
        h = next_
    end
    return worst, h
end

for _, sign in ipairs({ 1, -1 }) do
    -- 700 frames at 2 rad/s is about 23 radians: north is crossed three or
    -- four times, which is where the old normalisation did its damage.
    local worst, ended = spin(sign, 700)
    check(('turning %s, no single step jumps anything like a full turn')
              :format(sign > 0 and 'one way' or 'the other'),
          worst < 0.1, ('worst raw step %.4f rad'):format(worst))
    check(('turning %s, the heading accumulates past a full turn')
              :format(sign > 0 and 'one way' or 'the other'),
          math.abs(ended) > 2 * math.pi, ('ended at %.2f rad'):format(ended))
    check(('turning %s, it ends on the side it was turning toward')
              :format(sign > 0 and 'one way' or 'the other'),
          (sign > 0) == (ended > 0), ended)
end
check('a nil current heading snaps to the target',
      path.easeHeading(nil, 1.23, 0.9, 1 / 60) == 1.23)
check('a nil target holds the current heading',
      path.easeHeading(1.23, nil, 0.9, 1 / 60) == 1.23)

-- A single step must never exceed rate*dt.
local before = 0.0
local after = path.easeHeading(before, math.pi, 0.9, 1 / 60)
check('one step is capped at rate * dt',
      near(after, 0.9 / 60, 1e-9), after)

-- ---------------------------------------------------------------------------
-- DEGENERATE ROUTES
-- ---------------------------------------------------------------------------
-- The source has duplicated consecutive points, which would divide by zero in
-- the segment interpolation if it were not guarded.

local dup = { 0, 0, 0, 0, 0, 0, 100, 0, 0 }
local dp = path.prepare(dup, false)
check('a duplicated point does not break measurement', near(dp.total, 100), dp.total)
local dx = path.at(dup, dp, 0)
check('a zero-length first segment interpolates without dividing by zero',
      dx == 0, dx)

local single = { 42, 43, 44 }
local sp = path.prepare(single, false)
check('a one-point route has zero length', sp.total == 0, sp.total)
local ox, oy, oz, oyaw = path.at(single, sp, 0)
check('a one-point route returns that point', ox == 42 and oy == 43 and oz == 44, ox)
check('a one-point route has no heading', oyaw == nil, oyaw)

-- ---------------------------------------------------------------------------
-- SWAY
-- ---------------------------------------------------------------------------

check('sway amplitude eases up toward its target',
      path.stepSway(0, 1, 0.6, 1 / 60) > 0)
check('sway amplitude does not overshoot its target',
      path.stepSway(0.99, 1, 600, 1 / 60) == 1,
      path.stepSway(0.99, 1, 600, 1 / 60))
check('sway amplitude does not undershoot going down',
      path.stepSway(0.01, 0, 600, 1 / 60) == 0,
      path.stepSway(0.01, 0, 600, 1 / 60))

-- For a strider sway is 1, which [R] intends to be almost imperceptible: the
-- base amplitude is 0.014 radians, which is well under a degree.
local maxSway = 0
for t = 0, 60, 0.05 do
    local v = math.abs(path.sway(t, 1, 1))
    if v > maxSway then maxSway = v end
end
check('a strider leans less than a degree at full amplitude',
      maxSway < math.rad(1), math.deg(maxSway))
check('a boat-grade sway multiplier leans more than a strider',
      math.abs(path.sway(2.1, 1, 4)) > math.abs(path.sway(2.1, 1, 1)))

-- ---------------------------------------------------------------------------
-- SLOT GEOMETRY
-- ---------------------------------------------------------------------------

local v = db.vehicle('siltstrider')
check('the strider vehicle is defined', v ~= nil)
check('it has three passenger slots', #v.slots == 3, #v.slots)
-- Y IS FORWARD, so the larger y is the seat further up the strider. The
-- driver has to be in front of the passenger: [R]'s data has it the other way
-- round and caravans_db deliberately swaps the two y values, so this asserts
-- the ORDER rather than the imported numbers. Swapping them back fails here.
check('the player sits on the centreline at the measured height',
      v.slots[1].x == 0 and v.slots[1].z == 1223,
      ('x=%s z=%s'):format(v.slots[1].x, v.slots[1].z))
check('the guide sits on the centreline at the same height',
      v.guideSlot.x == 0 and v.guideSlot.z == v.slots[1].z,
      ('x=%s z=%s'):format(v.guideSlot.x, v.guideSlot.z))
check('the DRIVER is in front of the player, not behind them',
      v.guideSlot.y > v.slots[1].y,
      ('guide y=%s player y=%s'):format(v.guideSlot.y, v.slots[1].y))
check('the two spare passenger seats are behind the driver',
      v.slots[2].y < v.guideSlot.y and v.slots[3].y < v.guideSlot.y,
      ('%s %s vs %s'):format(v.slots[2].y, v.slots[3].y, v.guideSlot.y))
check('the guide slot carries its animation group',
      v.guideSlot.anim == 'idle5', v.guideSlot.anim)
check('the body offset is the measured 1220', v.bodyOffset == 1220, v.bodyOffset)
check('the gait group is lower-cased for hasGroup',
      v.gait == v.gait:lower(), v.gait)

-- Facing north, a slot's local offsets must land unrotated.
local wx, wy, wz = db.slotWorld(1000, 2000, 50, 0, { x = 10, y = 20, z = 30 })
check('slot offsets apply unrotated when facing north',
      near(wx, 1010) and near(wy, 2020) and near(wz, 80),
      ('%.1f,%.1f,%.1f'):format(wx, wy, wz))

-- Facing east (yaw pi/2), vehicle-forward becomes world +X.
wx, wy, wz = db.slotWorld(0, 0, 0, math.pi / 2, { x = 0, y = 100, z = 0 })
check('facing east, forward becomes world +X',
      near(wx, 100, 1e-6) and near(wy, 0, 1e-6),
      ('%.3f,%.3f'):format(wx, wy))

-- Right must be 90 degrees clockwise of forward, or the guide sits where a
-- passenger should. This is the sign error that cost a round trip in Core.
wx, wy = db.slotWorld(0, 0, 0, 0, { x = 100, y = 0, z = 0 })
check('facing north, right is world +X', near(wx, 100, 1e-6) and near(wy, 0, 1e-6),
      ('%.3f,%.3f'):format(wx, wy))

-- ---------------------------------------------------------------------------
-- PRICE
-- ---------------------------------------------------------------------------
-- The engine's own formula, reimplemented from the source [R] cites.

local function inputs(over)
    local base = {
        distance = 100000,
        fTravelMult = 4000,
        fFatigueBase = 1.25,
        fFatigueMult = 0.5,
        disposition = 50,
        followers = 0,
        player = { luck = 50, personality = 50, mercantile = 30,
                   fatigueCurrent = 100, fatigueBase = 100 },
        guide = { luck = 50, personality = 50, mercantile = 30,
                  fatigueCurrent = 100, fatigueBase = 100 },
    }
    for k, val in pairs(over or {}) do base[k] = val end
    return base
end

check('a fare is at least 1 gold',
      db.price(inputs({ distance = 1 })) >= 1, db.price(inputs({ distance = 1 })))
check('a fare is a whole number',
      db.price(inputs()) % 1 == 0, db.price(inputs()))
check('a longer journey costs more',
      db.price(inputs({ distance = 200000 })) > db.price(inputs({ distance = 100000 })))
check('followers each cost a fare',
      db.price(inputs({ followers = 1 })) > db.price(inputs({ followers = 0 })))
check('two followers cost more than one',
      db.price(inputs({ followers = 2 })) > db.price(inputs({ followers = 1 })))

-- fTravelMult of 0 is treated as 1, as the engine does, rather than dividing
-- by zero.
check('fTravelMult of zero does not divide by zero',
      db.price(inputs({ fTravelMult = 0 })) > 0,
      db.price(inputs({ fTravelMult = 0 })))
-- A nil override cannot be expressed through the `inputs` helper, because
-- `pairs` over { fTravelMult = nil } yields no key at all and the base value
-- survives. Built explicitly instead -- the point of the assertion is that a
-- GMST the engine did not supply behaves as 1 rather than dividing by zero.
local nilMult = inputs()
nilMult.fTravelMult = nil
local oneMult = inputs({ fTravelMult = 1 })
check('a nil fTravelMult is treated as 1, like a zero one',
      db.price(nilMult) == db.price(oneMult),
      ('%d vs %d'):format(db.price(nilMult), db.price(oneMult)))

-- Disposition: a guide who likes you charges less.
check('higher disposition is cheaper',
      db.price(inputs({ disposition = 100 })) < db.price(inputs({ disposition = 0 })))

-- Mercantile: the player's haggling helps, the guide's hurts.
local cheapPlayer = inputs()
cheapPlayer.player = { luck = 50, personality = 50, mercantile = 100,
                       fatigueCurrent = 100, fatigueBase = 100 }
check("the player's mercantile lowers the fare",
      db.price(cheapPlayer) < db.price(inputs()))

local sharpGuide = inputs()
sharpGuide.guide = { luck = 50, personality = 50, mercantile = 100,
                     fatigueCurrent = 100, fatigueBase = 100 }
check("the guide's mercantile raises the fare",
      db.price(sharpGuide) > db.price(inputs()))

-- The weighted sum caps each term independently, which is why it is not one
-- expression: luck caps at 10, personality at 10, mercantile at 100.
check('luck is capped at 10',
      near(db.weightedSum({ luck = 10000, personality = 0, mercantile = 0 }), 10),
      db.weightedSum({ luck = 10000, personality = 0, mercantile = 0 }))
check('personality is capped at 10',
      near(db.weightedSum({ luck = 0, personality = 10000, mercantile = 0 }), 10),
      db.weightedSum({ luck = 0, personality = 10000, mercantile = 0 }))
check('mercantile is capped at 100',
      near(db.weightedSum({ luck = 0, personality = 0, mercantile = 10000 }), 100),
      db.weightedSum({ luck = 0, personality = 0, mercantile = 10000 }))
check('the three caps sum to 120',
      near(db.weightedSum({ luck = 1e6, personality = 1e6, mercantile = 1e6 }), 120))

-- Fatigue: a zero base would divide by zero. The engine cannot produce one,
-- a mod-added actor can, and it must read as rested rather than throw.
check('a zero fatigue base reads as fully rested',
      near(db.fatigueTerm({ fatigueCurrent = 0, fatigueBase = 0 }, 1.25, 0.5), 1.25),
      db.fatigueTerm({ fatigueCurrent = 0, fatigueBase = 0 }, 1.25, 0.5))
check('full fatigue gives the base term',
      near(db.fatigueTerm({ fatigueCurrent = 100, fatigueBase = 100 }, 1.25, 0.5), 1.25))
check('empty fatigue subtracts the whole multiplier',
      near(db.fatigueTerm({ fatigueCurrent = 0, fatigueBase = 100 }, 1.25, 0.5), 0.75))

-- ---------------------------------------------------------------------------
-- TRAVEL TIME
-- ---------------------------------------------------------------------------

check('vanilla hours are whole', db.vanillaHours(137132, 16000) % 1 == 0)
check('vanilla hours floor, as the engine casts to int',
      db.vanillaHours(137132, 16000) == math.floor(137132 / 16000),
      db.vanillaHours(137132, 16000))
check('a zero fTravelTimeMult yields no hours rather than infinity',
      db.vanillaHours(137132, 0) == 0, db.vanillaHours(137132, 0))
check('a nil fTravelTimeMult yields no hours',
      db.vanillaHours(137132, nil) == 0)
check('a longer route costs more hours',
      db.vanillaHours(200000, 16000) > db.vanillaHours(100000, 16000))

-- ---------------------------------------------------------------------------
-- JOURNEY DURATION AT THE SHIPPED SPEED
-- ---------------------------------------------------------------------------
-- The speed was chosen against the measured routes, so if either changes this
-- is the assertion that notices.

local longest, longestName = 0, nil
local sum, n = 0, 0
for origin, dests in pairs(R.routes) do
    for dest, arr in pairs(dests) do
        local p = path.prepare(arr, false)
        sum, n = sum + p.total, n + 1
        if p.total > longest then longest, longestName = p.total, origin .. '->' .. dest end
    end
end
local meanSeconds = (sum / n) / v.speed
local worstSeconds = longest / v.speed
print(('\n  mean journey %.0fs, longest %.0fs (%s) at %d u/s')
      :format(meanSeconds, worstSeconds, longestName, v.speed))
check('the mean journey is between 30 seconds and 3 minutes',
      meanSeconds > 30 and meanSeconds < 180, meanSeconds)
check('the longest journey is under 4 minutes',
      worstSeconds < 240, worstSeconds)

-- ---------------------------------------------------------------------------
-- A STRAY POINT IN THE MIDDLE OF A ROUTE
-- ---------------------------------------------------------------------------
-- `vivec -> seyda neen` passes both endpoint checks and is still unusable: at
-- point 29 of 37 it turns 178 degrees, runs 73,468 units out and comes
-- straight back. In game the strider changed direction halfway and trudged
-- away for the best part of two minutes, which reads as being stuck.
--
-- This section is against the REAL shipped data, which is the only place the
-- fault exists -- a synthetic spike would prove the arithmetic and nothing
-- about whether the threshold is in the right place.

local stops = dofile('scripts/WhyWalk/Caravans/caravans_stops.lua')

-- Arithmetic first, on a shape chosen by hand so the expected answer is
-- obvious: five 100-unit steps and one 1000-unit jump.
do
    local p = {}
    local function push(x, y, z) p[#p + 1] = x; p[#p + 1] = y; p[#p + 1] = z end
    for i = 0, 5 do push(i * 100, 0, 0) end
    push(1500, 0, 0)                       -- the stray point: a 1000 jump
    local ratio, longest, at = stops.segmentOutlier(p)
    check('segmentOutlier finds the longest segment', near(longest, 1000, 1e-6), longest)
    check('and reports which segment it is', at == 6, at)
    check('and the ratio against the median', ratio > 9 and ratio < 11, ratio)
end

check('a route too short to compare returns 0 rather than dividing by nothing',
      select(1, stops.segmentOutlier({ 0, 0, 0, 1, 0, 0 })) == 0)

-- The real data. A fresh copy, because validate() removes in place and the
-- rest of this file reads the routes table.
do
    local fresh = dofile('scripts/WhyWalk/Caravans/caravans_routes.lua')
    local centres = stops.centres(fresh.routes)

    local ratios = {}
    for from, dests in pairs(fresh.routes) do
        for to, p in pairs(dests) do
            ratios[#ratios + 1] = { stops.segmentOutlier(p), from .. ' -> ' .. to }
        end
    end
    table.sort(ratios, function(a, b) return a[1] > b[1] end)

    check('the two worst routes in the data are the two known-corrupt ones',
          ratios[1][2] == 'vivec -> seyda neen'
          and ratios[2][2] == 'suran -> balmora',
          ratios[1][2] .. ' / ' .. ratios[2][2])
    -- THE THRESHOLD HAS TO SIT IN A GAP, or it is tuned to this data by luck.
    check('and the threshold sits in the gap below them',
          ratios[2][1] > stops.MAX_SEGMENT_RATIO
          and ratios[3][1] < stops.MAX_SEGMENT_RATIO,
          ('bad %.1f, next good %.1f, threshold %d')
              :format(ratios[2][1], ratios[3][1], stops.MAX_SEGMENT_RATIO))
    check('with real margin on both sides, not a hair',
          ratios[2][1] > stops.MAX_SEGMENT_RATIO * 2
          and ratios[3][1] < stops.MAX_SEGMENT_RATIO * 0.7,
          ('%.1f / %.1f'):format(ratios[2][1], ratios[3][1]))

    local before = 0
    for _, dests in pairs(fresh.routes) do
        for _ in pairs(dests) do before = before + 1 end
    end

    local dropped = stops.validate(fresh.routes, centres)
    local joined = table.concat(dropped, ' | ')

    check('validate drops exactly two routes', #dropped == 2, joined)
    check('and names the stray point in vivec -> seyda neen',
          joined:find('vivec %-> seyda neen %(stray point') ~= nil, joined)
    check('and still catches suran -> balmora by its endpoint',
          joined:find('suran %-> balmora %(ends') ~= nil, joined)
    check('the dropped reason says WHERE the stray point is',
          joined:find('segment 29 of 36') ~= nil, joined)

    local after = 0
    for _, dests in pairs(fresh.routes) do
        for _ in pairs(dests) do after = after + 1 end
    end
    check('the other 45 routes survive', after == before - 2,
          ('%d -> %d'):format(before, after))

    -- A drop is only acceptable because the other direction is intact; this
    -- is what makes findRoute's reverse fallback the actual fix.
    check('the reverse of vivec -> seyda neen survived',
          fresh.routes['seyda neen'] and fresh.routes['seyda neen']['vivec'] ~= nil)
    check('the reverse of suran -> balmora survived',
          fresh.routes['balmora'] and fresh.routes['balmora']['suran'] ~= nil)
    check('so both places are still reachable in both directions',
          fresh.routes['vivec']['seyda neen'] == nil
          and fresh.routes['seyda neen']['vivec'] ~= nil)

    -- And the surviving route is actually a sane ride.
    local rev = fresh.routes['seyda neen']['vivec']
    local ratio = stops.segmentOutlier(rev)
    check('and the surviving Vivec/Seyda Neen route has no stray point',
          ratio < stops.MAX_SEGMENT_RATIO, ratio)
    local prep = path.prepare(rev, true)
    check('reversed, it is a plausible length rather than 204,000 units',
          prep.total > 40000 and prep.total < 80000, prep.total)
end

-- ---------------------------------------------------------------------------
-- STEERING: THE BODY MOVES WHERE IT POINTS
-- ---------------------------------------------------------------------------
-- The fault this model exists to remove, reported every round for a week:
-- "the body is moving sideways at times", "directional facing wrong /
-- unresponsive". Placing the strider on the polyline and rotating it
-- separately lets facing and velocity disagree, and at a sharp corner they
-- disagree almost completely.
--
-- SIDEWAYS FRACTION is the measurement: the part of each frame's travel that
-- is perpendicular to where the body points, over the whole of it. Simulated
-- at 60fps over six real routes against the SHIPPED constants, so changing
-- any of them has to keep clearing these bars.

local stops2 = dofile('scripts/WhyWalk/Caravans/caravans_stops.lua')

do
    local v, dt = db.VEHICLE.siltstrider, 1 / 60
    local PAIRS = {
        { 'balmora', 'ald-ruhn' }, { 'seyda neen', 'vivec' },
        { 'vivec', 'molag mar' }, { 'balmora', 'seyda neen' },
        { 'suran', 'vivec' }, { 'khuul', 'gnisis' },
    }

    ---Ride every route and report how the body behaved.
    ---@param mode string 'steer' or 'place' (the old model, for comparison)
    ---@param tau number|nil correction constant; nil uses the shipped one
    local function ride(mode, tau)
        local sumSide, worstSide, nS = 0, 0, 0
        local sumDev, worstDev, nD = 0, 0, 0
        local worstEnd, arrived, routes_ = 0, 0, 0
        for _, pr in ipairs(PAIRS) do
            local p = R.routes[pr[1]] and R.routes[pr[1]][pr[2]]
            if p then
                routes_ = routes_ + 1
                local n = path.count(p)
                local prep = path.prepare(p, false)
                local sx, sy = path.at(p, prep, 0)
                local ax, ay = path.at(p, prep,
                    math.min(path.STEERING.AHEAD, prep.total))
                local body = { x = sx, y = sy,
                               heading = path.headingToward(sx, sy, ax, ay) or 0 }
                local travelled, lastX, lastY = 0, sx, sy
                local guard = 0
                while travelled < prep.total and guard < 200000 do
                    guard = guard + 1
                    travelled = travelled + v.speed * dt
                    local px, py = path.at(p, prep, travelled)
                    local cx, cy = path.at(p, prep,
                        math.min(travelled + path.STEERING.AHEAD, prep.total))
                    if mode == 'steer' then
                        path.steer(body, cx, cy, px, py, v.speed, v.turnRate,
                                   tau or path.STEERING.CORRECT_TAU, dt)
                    else
                        -- the old model: sampled position, independent heading
                        local _, _, _, yaw = path.at(p, prep, travelled)
                        local _, _, _, aim = path.at(p, prep,
                            math.min(travelled + 350, prep.total))
                        body.heading = path.easeHeading(body.heading, aim or yaw,
                                                        1.4, dt)
                        body.x, body.y = px, py
                    end
                    local vx, vy = body.x - lastX, body.y - lastY
                    local sp = math.sqrt(vx * vx + vy * vy)
                    if sp > 1e-9 then
                        local side = math.abs(vx * math.cos(body.heading)
                                            - vy * math.sin(body.heading)) / sp
                        sumSide, nS = sumSide + side, nS + 1
                        if side > worstSide then worstSide = side end
                    end
                    lastX, lastY = body.x, body.y
                    local d = math.sqrt((body.x - px) ^ 2 + (body.y - py) ^ 2)
                    sumDev, nD = sumDev + d, nD + 1
                    if d > worstDev then worstDev = d end
                end
                if travelled >= prep.total then arrived = arrived + 1 end
                local ex, ey = path.pointAt(p, n, n, false)
                local de = math.sqrt((body.x - ex) ^ 2 + (body.y - ey) ^ 2)
                if de > worstEnd then worstEnd = de end
            end
        end
        return {
            meanSide = 100 * sumSide / nS, worstSide = 100 * worstSide,
            meanDev = sumDev / nD, worstDev = worstDev,
            worstEnd = worstEnd, arrived = arrived, routes = routes_,
        }
    end

    local steer = ride('steer')
    local place = ride('place')

    -- THE HEADLINE. The old model's worst case was a strider travelling
    -- almost entirely crabwise; this must be several times better.
    check('the old model really did travel mostly sideways at its worst',
          place.worstSide > 60, ('%.1f%%'):format(place.worstSide))
    check('steering cuts the worst sideways motion at least threefold',
          steer.worstSide * 3 < place.worstSide,
          ('%.1f%% -> %.1f%%'):format(place.worstSide, steer.worstSide))
    check('and the typical sideways motion stays under 2% of travel',
          steer.meanSide < 2.0, ('%.2f%%'):format(steer.meanSide))

    -- AND THE ROUTE IS STILL FOLLOWED. Steering is only acceptable if the
    -- strider still goes where the caravan is supposed to go.
    check('every route is completed', steer.arrived == steer.routes,
          ('%d/%d'):format(steer.arrived, steer.routes))
    check('mean deviation stays well under one route segment',
          steer.meanDev < 150, ('%.0f units'):format(steer.meanDev))
    check('and the worst swing wide is bounded',
          steer.worstDev < 700, ('%.0f units'):format(steer.worstDev))
    check('the strider finishes near the stop, not orbiting it',
          steer.worstEnd < 500, ('%.0f units'):format(steer.worstEnd))

    -- THE CORRECTION IS WHAT MAKES IT ARRIVE, and it is also the only
    -- sideways motion left. Both halves of that have to be true, or the
    -- constant is doing nothing and could be removed.
    local nopull = ride('steer', 0)
    check('without the correction the sideways motion vanishes entirely',
          nopull.worstSide < 0.01, ('%.4f%%'):format(nopull.worstSide))
    check('but the strider then ends far from the stop',
          nopull.worstEnd > steer.worstEnd * 2,
          ('%.0f vs %.0f units'):format(nopull.worstEnd, steer.worstEnd))
    check('and wanders much further from the route',
          nopull.meanDev > steer.meanDev * 3,
          ('%.0f vs %.0f units'):format(nopull.meanDev, steer.meanDev))

    -- A faster pull tracks better and puts the fault back; the shipped value
    -- has to be on the gentle side of that trade.
    local hard = ride('steer', 0.25)
    check('a harder pull measurably increases sideways motion',
          hard.worstSide > steer.worstSide,
          ('%.1f%% vs %.1f%%'):format(hard.worstSide, steer.worstSide))
end

-- ---------------------------------------------------------------------------
-- VERTICAL SMOOTHING
-- ---------------------------------------------------------------------------
-- The route's z is piecewise linear, so vertical POSITION is continuous and
-- vertical SPEED is not: it changes abruptly at every waypoint, about once a
-- second at 1400 units a second. Worst measured step 13.4 units of vertical
-- speed per frame, which is the reported bumpiness.

do
    local v, dt = db.VEHICLE.siltstrider, 1 / 60
    local PAIRS = {
        { 'balmora', 'ald-ruhn' }, { 'seyda neen', 'vivec' },
        { 'vivec', 'molag mar' }, { 'balmora', 'seyda neen' },
        { 'suran', 'vivec' }, { 'khuul', 'gnisis' },
    }

    ---Worst vertical-speed step and worst deviation from the path, with the
    ---smoothing on or off.
    local function ride(smooth)
        local worstJump, worstDev = 0, 0
        for _, pr in ipairs(PAIRS) do
            local p = R.routes[pr[1]] and R.routes[pr[1]][pr[2]]
            if p then
                local prep = path.prepare(p, false)
                local travelled, z, lastZ, lastDz = 0, nil, nil, nil
                while travelled < prep.total do
                    travelled = travelled + v.speed * dt
                    local _, _, pz = path.at(p, prep, travelled)
                    z = smooth and path.easeVertical(z, pz, dt) or pz
                    local dev = math.abs(z - pz)
                    if dev > worstDev then worstDev = dev end
                    if lastZ then
                        local dz = z - lastZ
                        if lastDz then
                            local j = math.abs(dz - lastDz)
                            if j > worstJump then worstJump = j end
                        end
                        lastDz = dz
                    end
                    lastZ = z
                end
            end
        end
        return worstJump, worstDev
    end

    local rawJump = ride(false)
    local smoothJump, smoothDev = ride(true)

    check('the raw route really does jolt, so there is something to fix',
          rawJump > 10, ('%.2f u/frame'):format(rawJump))
    check('smoothing cuts the worst jolt by at least four times',
          smoothJump * 4 < rawJump,
          ('%.2f -> %.2f u/frame'):format(rawJump, smoothJump))

    -- THE COST IS LAG, and it has to stay small against the animal. A silt
    -- strider is 1284 units tall; anything past a tenth of that would be
    -- visible as the strider floating over a slope.
    check('and costs under a tenth of the strider height in vertical lag',
          smoothDev < 128, ('%.1f units'):format(smoothDev))
    check('well inside the clamp, so the clamp is a backstop not the mechanism',
          smoothDev < path.VERTICAL.MAX_DRIFT, smoothDev)

    -- The clamp itself: a cliff must not leave the strider hanging.
    local far = path.easeVertical(0, 100000, dt)
    check('a huge step is clamped rather than eased forever',
          math.abs(far - 100000) <= path.VERTICAL.MAX_DRIFT + 1e-6, far)

    check('the first frame places the strider exactly, not eased up from zero',
          path.easeVertical(nil, 1234, dt) == 1234)
    check('a zero dt holds the path value rather than dividing by it',
          path.easeVertical(500, 1234, 0) == 1234)

    -- HORIZONTAL IS UNTOUCHED. Smoothing x or y would cut corners, which is a
    -- different and worse fault than a jolt.
    local p = R.routes['balmora']['ald-ruhn']
    local prep = path.prepare(p, false)
    local x1, y1 = path.at(p, prep, 5000)
    local x2, y2 = path.at(p, prep, 5000)
    check('path.at is still exact and repeatable in x and y',
          x1 == x2 and y1 == y2)
end

print(('\n%d passed, %d failed'):format(pass, fail))
if fail > 0 then os.exit(1) end
print('ALL PASS')
