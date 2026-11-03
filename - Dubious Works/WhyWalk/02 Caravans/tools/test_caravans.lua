-- test_caravans.lua -- the route walker, the price, and the imported data
--
--   run from "02 Caravans":  luarun.py tools/test_caravans.lua
--
-- Against the REAL imported routes, not a mock. The 2026-10-22 fallback bug
-- got through because the previous suite's mock skeleton happened to contain
-- every group it asked for, so these assertions read the shipped data file.

-- RUN UNDER LuaJIT's MATHS, NOT 5.4's (2026-11-03c).
-- OpenMW is LuaJIT (Lua 5.1): math.atan takes ONE argument and ignores a
-- second. These tests run on liblua5.4, where math.atan(y, x) is the
-- two-argument form -- so caravans_path's `math.atan(dx, dy)` passed every
-- test here while computing atan(dx) in the game, and the strider faced the
-- wrong way through every build. Emulated before any module loads, so that
-- spelling now fails here exactly as it misbehaves there.
do
    local atan54 = math.atan
    math.atan = function(y) return atan54(y) end
    math.atan2 = function(y, x) return atan54(y, x) end
end

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
    for i = 2, #fwd.cum do
        if fwd.cum[i] <= fwd.cum[i - 1] then return false end
    end
    return true
end)())
check('total equals the last cumulative length',
      near(fwd.total, fwd.cum[#fwd.cum]), fwd.total)
-- Measured in 3D: this route climbs from z 1315 to z 2630, and a 2D
-- measurement would finish the uphill legs early. Compared against the same
-- rounded path walked in the horizontal plane, because rounding the corners
-- shortens the route a little and an absolute threshold would test that
-- instead.
do
    local flat, lx, ly = 0, nil, nil
    for d = 0, fwd.total, 50 do
        local x, y = path.at(pts, fwd, d)
        if lx then flat = flat + math.sqrt((x - lx) ^ 2 + (y - ly) ^ 2) end
        lx, ly = x, y
    end
    check('length is measured in 3D, not 2D', fwd.total > flat + 500,
          ('%.0f 3D vs %.0f flat'):format(fwd.total, flat))
end
-- Rounding cuts each corner, so the path is shorter than the polyline -- by
-- well under a percent, which is what keeps the journey times and prices.
do
    local n, poly = path.count(pts), 0
    for i = 2, n do
        local ax, ay, az = path.pointAt(pts, n, i - 1)
        local bx, by, bz = path.pointAt(pts, n, i)
        poly = poly + math.sqrt((bx - ax) ^ 2 + (by - ay) ^ 2 + (bz - az) ^ 2)
    end
    check('rounding shortens the route by under 1%',
          fwd.total < poly and fwd.total > 0.99 * poly,
          ('%.0f rounded vs %.0f polyline'):format(fwd.total, poly))
end
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
-- 1226, not [R]'s 1223: the cabin floor is at 1223.1 (raycast in OpenMW
-- 0.52), and a rider pinned 0.1 units below it falls through every frame.
check('the player sits on the centreline just above the cabin floor',
      v.slots[1].x == 0 and v.slots[1].z > 1223.1 and v.slots[1].z < 1240,
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
-- WHICH WAY THE BODY POINTS, AND HOW FAST IT TURNS
-- ---------------------------------------------------------------------------
-- The rounded route (caravans_path, 2026-11-03c), held to numbers over EVERY
-- route at 60fps and the shipped speed, with the corner speed profile on --
-- which is exactly what caravans_global does per frame.
--
-- The model it replaces measured, on the same data: turn rate up to 9123 deg/s,
-- sideways travel up to 178 degrees (driving backwards), mean 2.05 degrees.
-- Each bound below is one that model fails by an order of magnitude.

do
    local v, dt = db.VEHICLE.siltstrider, 1 / 60

    ---Distance from (x, y) to the authored polyline, in the horizontal plane.
    local function offLine(p, x, y)
        local n, best = path.count(p), math.huge
        for i = 2, n do
            local ax, ay = path.pointAt(p, n, i - 1)
            local bx, by = path.pointAt(p, n, i)
            local vx, vy = bx - ax, by - ay
            local l2 = vx * vx + vy * vy
            local t = l2 > 0 and math.max(0, math.min(1, ((x - ax) * vx + (y - ay) * vy) / l2)) or 0
            local d = math.sqrt((ax + vx * t - x) ^ 2 + (ay + vy * t - y) ^ 2)
            if d < best then best = d end
        end
        return best
    end

    local worstTurn, worstSide, sumSide, nSide, worstDev = 0, 0, 0, 0, 0
    local riddenTime, cruiseTime, routesRidden = 0, 0, 0
    for _, dests in pairs(R.routes) do
        for _, p in pairs(dests) do
            local prep = path.prepare(p, false)
            routesRidden = routesRidden + 1
            local d, frames = 0, 0
            local px, py, _, ph = path.at(p, prep, 0)
            while d < prep.total do
                d = d + path.speedAt(prep, d, v.speed) * dt
                frames = frames + 1
                local x, y, _, h = path.at(p, prep, d)
                local turn = math.deg(math.abs(path.angleDiff(ph, h))) / dt
                if turn > worstTurn then worstTurn = turn end
                local mx, my = x - px, y - py
                if mx * mx + my * my > 1e-6 then
                    local side = math.deg(math.abs(path.angleDiff(path.headingOf(mx, my), h)))
                    sumSide, nSide = sumSide + side, nSide + 1
                    if side > worstSide then worstSide = side end
                end
                if frames % 10 == 0 then
                    local off = offLine(p, x, y)
                    if off > worstDev then worstDev = off end
                end
                px, py, ph = x, y, h
            end
            riddenTime = riddenTime + frames * dt
            cruiseTime = cruiseTime + prep.total / v.speed
        end
    end

    check('every route was ridden', routesRidden >= 45, routesRidden)
    -- The bound is the speed profile's own, plus a sliver for the 60fps
    -- sampling of an arc's tangent.
    check('the body never turns faster than 90 degrees a second',
          worstTurn <= math.deg(path.SPEED.MAX_TURN_RATE) * 1.02,
          ('%.1f deg/s'):format(worstTurn))
    -- On a line the heading is the step; on an arc the step is a chord and
    -- the tangent leads it by half the frame's turn. Nothing else.
    check('it points where it is going: sideways under 2 degrees, ever',
          worstSide < 2, ('%.2f deg'):format(worstSide))
    check('and a fraction of a degree on average',
          sumSide / nSide < 0.5, ('%.3f deg'):format(sumSide / nSide))
    -- THE BOUND THE STEERING BUILD BROKE. It left the line by 494 units and put
    -- the strider through buildings; the rounding is capped at MAX_DEV.
    check('it never leaves the authored line by more than MAX_DEV',
          worstDev <= path.TURN.MAX_DEV + 1, ('%.0f units'):format(worstDev))
    check('slowing for the tight corners costs under 5% of journey time',
          riddenTime < cruiseTime * 1.05,
          ('+%.1f%%'):format(100 * (riddenTime / cruiseTime - 1)))

    -- STATELESS. The facing is the path's tangent at a distance; nothing
    -- remembers anything. Every facing bug in this module's history -- lag,
    -- accumulation, the 2pi wrap, the 340-degree turn -- needed state.
    local p = R.routes['balmora']['ald-ruhn']
    local prep = path.prepare(p, false)
    local _, _, _, a1 = path.at(p, prep, 12345)
    for _ = 1, 50 do path.at(p, prep, math.random() * prep.total) end
    local _, _, _, a2 = path.at(p, prep, 12345)
    check('the facing is a pure function of distance along the route',
          a1 == a2, ('%s vs %s'):format(tostring(a1), tostring(a2)))
    check('and is defined at the very end of a route, not nil',
          select(4, path.at(p, prep, prep.total)) ~= nil)
    check('and at the very start', select(4, path.at(p, prep, 0)) ~= nil)
    check('the speed profile is pure as well',
          path.speedAt(prep, 12345, 1400) == path.speedAt(prep, 12345, 1400))
end

-- A right angle, built by hand, so the geometry is checkable by eye.
do
    -- north 5000, then east 5000: a 90-degree right turn at (0, 5000)
    local p = { 0, 0, 0, 0, 5000, 0, 5000, 5000, 0 }
    local prep = path.prepare(p, false)
    local _, _, _, h0 = path.at(p, prep, 100)
    local _, _, _, h1 = path.at(p, prep, prep.total - 100)
    check('a right angle starts heading north', near(h0, 0, 1e-9), h0)
    check('and ends heading east', near(h1, math.pi / 2, 1e-9), h1)
    -- The heading changes continuously through the corner: no step between
    -- samples 10 units apart is more than the arc can turn in 10 units.
    local arcs = 0
    for _, pc in ipairs(prep.pieces) do if pc.kind == 2 then arcs = arcs + 1 end end
    check('the corner became one arc', arcs == 1, arcs)
    local worstStep, prev = 0, nil
    for d = 0, prep.total, 10 do
        local _, _, _, h = path.at(p, prep, d)
        if prev then
            local step = math.abs(path.angleDiff(prev, h))
            if step > worstStep then worstStep = step end
        end
        prev = h
    end
    local r = prep.pieces[2][3]
    check('the heading never jumps through the corner',
          worstStep <= 10 / r * 1.001, ('%.4f rad vs %.4f'):format(worstStep, 10 / r))
    -- Deepest point of the arc, against the corner's own two segments.
    local mx, my = path.at(p, prep, (prep.cum[2] + prep.cum[3]) / 2)
    local inside = math.min(math.abs(mx), math.abs(5000 - my))
    check('the corner is cut by exactly MAX_DEV at its deepest',
          near(inside, path.TURN.MAX_DEV, 0.5), ('%.2f units'):format(inside))
    -- And the strider slows for it: a 90-degree corner capped at MAX_DEV has a
    -- radius of 410, which at 90 deg/s allows 644 u/s.
    local onArc = path.speedAt(prep, (prep.cum[2] + prep.cum[3]) / 2, 1400)
    check('the strider slows through a right angle',
          near(onArc, path.SPEED.MAX_TURN_RATE * r, 1), ('%.0f u/s'):format(onArc))
    check('and is back at cruise well clear of it',
          path.speedAt(prep, 100, 1400) == 1400 and path.speedAt(prep, prep.total - 100, 1400) == 1400)
    check('a straight route is never slowed',
          path.speedAt(path.prepare({ 0, 0, 0, 0, 9000, 0 }, false), 4500, 1400) == 1400)
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
