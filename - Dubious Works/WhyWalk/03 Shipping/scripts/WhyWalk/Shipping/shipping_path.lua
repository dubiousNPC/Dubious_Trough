---@omw-context none
--[[
    caravans_path.lua -- walking a route polyline, and nothing else

    Pure functions on numbers and flat arrays, so the whole route walker is
    testable outside the engine (tools/test_caravans.lua). No openmw requires, so
    global, player and local scripts can all use it.

    WHY A WALKER AND NOT CONTROLS

    WhyWalk Core drives a MOUNT by writing `controls.movement` and letting the
    engine move it, and the 2026-10-08 port exists because that is the right
    answer for a steered creature. A route vehicle is the opposite case and
    the route data says so plainly: the Caravaner points sit at z values of
    1300 to 2600, with the mount data carrying `offset: -1220` and the service
    `ground_offset: 1025`. Those are BODY positions on an authored path, not
    ground positions a walker could be steered along -- the strider's feet are
    1200 units below the line it follows.

    So the vehicle is PLACED along the polyline, as WhyWalk Boats places a
    boat. The consequence is the one the T-pose taught: a placed creature is
    never asked to move, so it never picks a gait, so caravans_vehicle.lua has
    to play one explicitly.

    ARC LENGTH, NOT POINT INDEX

    Stepping point-to-point would make speed depend on how finely that leg was
    authored, and the source is wildly uneven -- Vivec_Seyda Neen covers
    204,146 units in 37 points while Suran_Vivec covers 49,526 in 26. Routes
    are measured once into a cumulative length table and then queried by
    distance travelled, so a strider moves at the same speed everywhere.

    DIRECTION IS AN INDEX MAPPING

    The source ships one direction per pair, and not always the one you want:
    there is a balmora_vivec and no vivec_balmora, and two files are empty.
    Rather than storing both directions or copying arrays, `prepare` takes a
    `reversed` flag and every read goes through `pointAt`, which flips the
    index. Nothing downstream knows or cares which way it is going.
]]

local M = {}

local sqrt, floor, pi = math.sqrt, math.floor, math.pi

-- TWO-ARGUMENT ARCTANGENT, AND WHY IT IS SPELLED atan2 (2026-11-03c).
--
-- OpenMW runs LuaJIT, which is Lua 5.1: `math.atan` takes ONE argument and
-- silently ignores a second. Lua 5.3+ -- which is what tools/luarun.py runs
-- the tests on -- made `math.atan(y, x)` the two-argument form. So
-- `math.atan(dx, dy)` was a correct quadrant-aware heading in every test and
-- `atan(dx)` in the game, folded into (-90, +90) degrees. Measured in OpenMW
-- 0.52: math.atan(1, -1) = 0.7854, where 2.3562 was meant.
--
-- That was headingOf for the life of this module. Every facing model in the
-- FIX notes -- lag filter, lookahead, unwrap, steering, carrot, mesh offset --
-- was fed a heading that pointed the wrong way whenever the route ran south,
-- and was simply wrong in magnitude everywhere else. "Constantly facing the
-- wrong direction", through every one of them, and no test could see it.
--
-- math.atan2 exists in LuaJIT and in 5.3 under compatibility; math.atan is
-- the two-argument form everywhere atan2 is missing. tests/test_caravans
-- now runs with a LuaJIT-faithful math.atan, and tools/check_luajit.py
-- rejects a two-argument math.atan anywhere in the module.
local atan2 = math.atan2 or math.atan
local sin, cos, exp = math.sin, math.cos, math.exp
local TWO_PI = 2 * pi

-- ---------------------------------------------------------------------------
-- READING A FLAT ROUTE
-- ---------------------------------------------------------------------------
-- Routes are { x,y,z, x,y,z, ... }. Index is 1-based point number.

---Number of points in a flat route array.
function M.count(points) return #points / 3 end

---The i-th point, honouring direction. Returns x, y, z.
---@param points table flat x,y,z array
---@param n number point count
---@param i number 1-based point index in TRAVEL order
---@param reversed boolean|nil true to walk the array backwards
function M.pointAt(points, n, i, reversed)
    if reversed then i = n + 1 - i end
    local b = (i - 1) * 3
    return points[b + 1], points[b + 2], points[b + 3]
end

-- ---------------------------------------------------------------------------
-- THE PATH IS THE POLYLINE WITH ITS CORNERS ROUNDED (2026-11-03c)
-- ---------------------------------------------------------------------------
-- Every model this module shipped before took the polyline as-is and then
-- tried to choose a facing for it, and on a polyline no facing is right: the
-- direction of travel is constant along a segment and jumps at every node.
-- Facing exactly along the step snaps by the corner angle once a second;
-- facing anywhere smoother points across the corner. The notes called that a
-- trilemma, and for a body that has to move along the polyline exactly, it is.
--
-- The body does not have to. Round each corner into a circular arc tangent to
-- both of its segments and the path has a tangent EVERYWHERE, continuous
-- through every node. The facing is that tangent: exact, so nothing travels
-- sideways, and continuous, so nothing snaps. What it costs is leaving the
-- authored line inside each corner, and that is bounded by construction.
--
-- Measured over all 47 routes (2056 corners) at 60fps, 1400 u/s:
--
--                                   turn rate        sideways     off the line
--                                   p99     max      mean   max    p99   max
--   shipped: trace + carrot 350     213   9123      2.05  178.4      0     0
--   arcs R 1000, <=120 off line     104    659      0.13    5.5     67   120
--   + corner speed limit (below)     90     90      0.13    0.7     69   120
--
-- "Nauseatingly erratic" is the first row: a 9123 deg/s spin, and moments
-- where the body faced 178 degrees away from where it was going.
--
-- TWO LIMITS PER CORNER, the smaller wins:
--
--   RADIUS     1000 u. Larger is gentler; past ~1000 it stops mattering,
--              because the cap below or the segment lengths decide instead.
--   MAX_DEV    120 u, how far inside the corner the arc may run. The deepest
--              point of an arc of radius r through a turn of theta lies
--              r * (1 - cos(theta/2)) from the segments, so r is capped at
--              MAX_DEV / (1 - cos(theta/2)). The median corner (22 degrees)
--              is untouched by this; only the sharp ones are tightened.
--
-- and the tangent length r * tan(theta/2) never exceeds half of either
-- segment, so neighbouring arcs cannot overlap however short the legs are.
--
-- The previous steering build left the line by 494 units and put the strider
-- through buildings; 120 is a quarter of that, at the worst corner of any
-- route, and the typical corner is cut by under 30.
M.TURN = {
    RADIUS  = 1000,
    MAX_DEV = 120,
    -- A node turning by more than this is a reversal, not a corner; an arc
    -- through it would be a point. It is left sharp and the speed limit
    -- brings the strider nearly to a stop there.
    MAX_ARC = math.rad(179),
}

local function hdist(ax, ay, bx, by)
    local dx, dy = bx - ax, by - ay
    return sqrt(dx * dx + dy * dy)
end

---Measure a route once. Returns the table every other query reads:
---  n         point count
---  reversed  direction flag
---  pieces    lines and arcs in travel order (see below)
---  cum       cum[k] = distance to the start of piece k; cum[#pieces+1] = total
---  total     length of the rounded path
---
---A piece is a flat table, built once:
---  line  { kind = 1, ax, ay, az, bx, by, bz }
---  arc   { kind = 2, cx, cy, r, a0, sweep, az, bz }   a0/sweep in math radians
---
---Measured in 3D, as before: the vertical component is real -- a strider
---climbing toward Ald-ruhn gains thousands of units -- so an arc's length is
---its horizontal sweep combined with its rise.
---@param points table flat {x,y,z,...}
---@param reversed boolean|nil
---@param turn table|nil overrides for M.TURN (tests)
function M.prepare(points, reversed, turn)
    turn = turn or M.TURN
    local n = M.count(points)

    -- Travel-order points with coincident neighbours dropped. The source has
    -- duplicated consecutive points; a zero-length segment has no direction.
    local P = {}
    for i = 1, n do
        local x, y, z = M.pointAt(points, n, i, reversed)
        local last = P[#P]
        if not last or hdist(last[1], last[2], x, y) > 1e-3 then
            P[#P + 1] = { x, y, z }
        else
            last[3] = z
        end
    end

    local pieces = {}
    local function line(a, b) pieces[#pieces + 1] = { kind = 1, a[1], a[2], a[3], b[1], b[2], b[3] } end

    local cur = P[1]
    for i = 2, #P - 1 do
        local a, b, c = P[i - 1], P[i], P[i + 1]
        local la, lb = hdist(a[1], a[2], b[1], b[2]), hdist(b[1], b[2], c[1], c[2])
        local ux, uy = (b[1] - a[1]) / la, (b[2] - a[2]) / la
        local vx, vy = (c[1] - b[1]) / lb, (c[2] - b[2]) / lb
        local cross, dot = ux * vy - uy * vx, ux * vx + uy * vy
        local theta = atan2(math.abs(cross), dot)
        if theta < 1e-4 or theta > turn.MAX_ARC then
            line(cur, b); cur = b
        else
            local half = math.tan(theta / 2)
            local r = math.min(turn.RADIUS, turn.MAX_DEV / (1 - cos(theta / 2)))
            local t = math.min(r * half, la / 2, lb / 2)
            r = t / half
            local tin = { b[1] - ux * t, b[2] - uy * t, b[3] + (a[3] - b[3]) * t / la }
            local tout = { b[1] + vx * t, b[2] + vy * t, b[3] + (c[3] - b[3]) * t / lb }
            line(cur, tin)
            local s = cross > 0 and 1 or -1          -- +1 counter-clockwise (a left turn)
            local cx, cy = tin[1] - uy * r * s, tin[2] + ux * r * s
            pieces[#pieces + 1] = { kind = 2, cx, cy, r, atan2(tin[2] - cy, tin[1] - cx),
                                    s * theta, tin[3], tout[3] }
            cur = tout
        end
    end
    if #P >= 2 then line(cur, P[#P]) end

    -- Lengths, dropping anything degenerate.
    local kept, cum = {}, { 0 }
    for _, pc in ipairs(pieces) do
        local len
        if pc.kind == 1 then
            local dx, dy, dz = pc[4] - pc[1], pc[5] - pc[2], pc[6] - pc[3]
            len = sqrt(dx * dx + dy * dy + dz * dz)
        else
            local h, dz = pc[3] * math.abs(pc[5]), pc[7] - pc[6]
            len = sqrt(h * h + dz * dz)
        end
        if len > 1e-9 then
            kept[#kept + 1] = pc
            cum[#cum + 1] = cum[#cum] + len
        end
    end

    return {
        n = n, reversed = reversed == true, P = P,
        pieces = kept, cum = cum, total = cum[#cum],
    }
end

-- ---------------------------------------------------------------------------
-- STEPPING
-- ---------------------------------------------------------------------------

---Piece index containing arc-length `d`, by binary search: ~7 comparisons
---for the longest route, every frame, and correct after any seek.
local function pieceFor(prep, d)
    local cum, lo, hi = prep.cum, 1, #prep.pieces + 1
    if d <= 0 then return 1 end
    if d >= prep.total then return #prep.pieces end
    while lo < hi - 1 do
        local mid = floor((lo + hi) / 2)
        if cum[mid] <= d then lo = mid else hi = mid end
    end
    return lo
end

---Heading of a vector in Morrowind's convention: 0 = +Y, increasing toward
---+X, i.e. forward = (sin yaw, cos yaw). Matches Core and Boats, and the
---strider mesh: its head is at +Y (Head bone y=+255, root motion along +Y),
---so object yaw IS this heading, with no offset (see caravans_db).
local function headingOf(dx, dy)
    if dx == 0 and dy == 0 then return nil end
    return atan2(dx, dy) % TWO_PI
end
M.headingOf = headingOf

---Position and heading at arc-length `d` along a prepared route.
---
---The heading is the path's own TANGENT: exact on a line, continuous round an
---arc. There is nothing else to the facing -- no carrot, no filter, no state.
---
---`d` is clamped: before the start it returns the first point, past the end
---the last. Clamping rather than wrapping matters because the caller decides
---when a journey is over, and a route that silently restarted would strand a
---passenger in a loop.
---@return number x, number y, number z, number|nil yaw
function M.at(points, prep, d)
    if #prep.pieces == 0 then
        local p = prep.P[1]
        return p[1], p[2], p[3], nil
    end
    if d < 0 then d = 0 elseif d > prep.total then d = prep.total end
    local k = pieceFor(prep, d)
    local pc = prep.pieces[k]
    local len = prep.cum[k + 1] - prep.cum[k]
    local f = (d - prep.cum[k]) / len
    if pc.kind == 1 then
        return pc[1] + (pc[4] - pc[1]) * f,
               pc[2] + (pc[5] - pc[2]) * f,
               pc[3] + (pc[6] - pc[3]) * f,
               headingOf(pc[4] - pc[1], pc[5] - pc[2])
    end
    local cx, cy, r, a0, sweep = pc[1], pc[2], pc[3], pc[4], pc[5]
    local ang = a0 + sweep * f
    local c, s = cos(ang), sin(ang)
    -- d/dang of (cos, sin) is (-sin, cos); a clockwise arc runs the other way.
    local dir = sweep > 0 and 1 or -1
    return cx + r * c, cy + r * s, pc[6] + (pc[7] - pc[6]) * f,
           headingOf(-s * dir, c * dir)
end

-- ---------------------------------------------------------------------------
-- SLOWING FOR TIGHT CORNERS
-- ---------------------------------------------------------------------------
-- Rounding alone leaves a handful of corners turning too fast: five of the
-- 2056 turn by more than 90 degrees, one by 178.5, and an arc that stays
-- within 120 units of a hairpin is a tight one. At cruising speed the body
-- would spin through it at 650 degrees a second.
--
-- So the strider slows for them, as a large animal would. Each arc allows at
-- most MAX_TURN_RATE * r units a second while on it; ahead of it the speed
-- falls at ACCEL, after it recovers at ACCEL. The result caps the turn rate
-- everywhere and costs 1.2% of journey time at 1400 u/s, because almost every
-- corner is gentle enough to take at speed.
--
-- A PROFILE, NOT A CONTROLLER. The allowed speed is a function of distance
-- along the route alone -- the same speed at the same place on every ride --
-- so it cannot oscillate, lag or carry error from one corner to the next.
M.SPEED = {
    MAX_TURN_RATE = math.rad(90),   -- radians per second, at any point
    ACCEL         = 700,            -- u/s^2, both ways
}

---Speed allowed at `d` for a strider cruising at `cruise` u/s.
---@param prep table from M.prepare
---@param d number arc length travelled
---@param cruise number u/s
---@return number u/s, never above cruise and never zero
function M.speedAt(prep, d, cruise)
    local w, acc = M.SPEED.MAX_TURN_RATE, M.SPEED.ACCEL
    -- Corners further than this cannot lower the speed here.
    local reach = cruise * cruise / (2 * acc)
    local v = cruise
    local pieces, cum = prep.pieces, prep.cum
    if #pieces == 0 then return cruise end
    local k0 = pieceFor(prep, d)
    -- Behind (recovery) and ahead (braking), within reach.
    local k = k0
    while k >= 1 and d - cum[k + 1] <= reach do
        local pc = pieces[k]
        if pc.kind == 2 then
            local lim = w * pc[3]
            if lim < v then
                local gap = d - cum[k + 1]
                if gap <= 0 then v = lim
                else v = math.min(v, sqrt(lim * lim + 2 * acc * gap)) end
            end
        end
        k = k - 1
    end
    k = k0 + 1
    while k <= #pieces and cum[k] - d <= reach do
        local pc = pieces[k]
        if pc.kind == 2 then
            local lim = w * pc[3]
            if lim < v then v = math.min(v, sqrt(lim * lim + 2 * acc * (cum[k] - d))) end
        end
        k = k + 1
    end
    -- A reversal node is left as a corner with no arc; a strider must not
    -- stand still on it forever.
    return math.max(v, 30)
end

-- ---------------------------------------------------------------------------
-- TURNING
-- ---------------------------------------------------------------------------

---Shortest signed angle from a to b, in (-pi, pi]. Same as Boats'.
function M.angleDiff(a, b)
    local d = (b - a) % TWO_PI
    if d > pi then d = d - TWO_PI end
    return d
end

---Ease a heading toward a target at `rate` radians/second.
---
---The polyline turns in steps -- heading is constant along a segment and
---jumps at every point -- so applying it raw would snap the strider's whole
---body at each waypoint. The mount data gives `turnspeed: 30`, which is
---degrees per [R]'s frame step; this takes radians/second and is tuned in
---the profile instead of inherited, because [R]'s number is meaningless
---without its 60fps assumption (SILTSTRIDER_NOTES, COMPATIBILITY).
---THE RESULT IS NOT NORMALISED, and that is the point.
---
---This used to end `% TWO_PI`, which kept the heading in [0, 2pi) and looked
---tidy. It is the reason a 20-degree turn was performed as a 340-degree turn
---the other way. The arithmetic here was never wrong -- angleDiff takes the
---short arc and the step is clamped, so the heading only ever moves 1.34
---degrees per frame -- but the VALUE handed to the engine jumped by a full
---turn whenever it crossed north:
---
---    frame n      6.2797 rad     (359.8 degrees)
---    frame n+1    0.0036 rad     (  0.2 degrees)
---
---0.4 degrees of actual turn, delivered as a -359.6 degree change. Anything
---downstream that treats consecutive rotations as a continuous quantity then
---takes the long way round, which is exactly what was reported: extreme
---turns, in the wrong direction, with the body drifting back afterwards.
---
---Leaving the angle unwrapped removes the discontinuity at source. Nothing
---needs it normalised: angleDiff wraps internally, and rotateZ is periodic,
---so rotateZ(6.2833) and rotateZ(0) are the same rotation. The value grows
---by at most a few turns over a journey, which no float cares about.
---@param current number|nil radians, NOT required to be in any range
---@param target number|nil radians
---@param rate number radians per second
---@param dt number seconds
---@return number radians, continuous with `current`
function M.easeHeading(current, target, rate, dt)
    if current == nil then return target end
    if target == nil then return current end
    local diff = M.angleDiff(current, target)
    local step = rate * dt
    if diff > step then diff = step elseif diff < -step then diff = -step end
    return current + diff
end

-- ---------------------------------------------------------------------------
-- SWAY  (SILTSTRIDER_NOTES: [R] main.lua:20-23, 663-702)
-- ---------------------------------------------------------------------------
-- amplitude * sin(2*pi*FREQ*t), clamped to MAX_AMPL*amplitude, with the
-- amplitude eased toward its target rather than snapped. For a strider
-- (sway = 1) this is deliberately almost imperceptible.

M.SWAY = {
    MAX_AMPL    = 3,
    AMPL_CHANGE = 0.01,
    FREQ        = 0.12,
    AMPL        = 0.014,
}

---Ease the sway amplitude toward a target. `perSecond` converts [R]'s
---per-step AMPL_CHANGE into a rate, because its 0.01 is per 60fps frame.
function M.stepSway(amplitude, target, perSecond, dt)
    local step = perSecond * dt
    if amplitude < target then
        local v = amplitude + step
        return v > target and target or v
    elseif amplitude > target then
        local v = amplitude - step
        return v < target and target or v
    end
    return amplitude
end

---Lateral lean at time t for a mount whose `sway` multiplier is given.
function M.sway(t, amplitude, swayMult)
    local a = M.SWAY.AMPL * (swayMult or 1) * amplitude
    local limit = M.SWAY.MAX_AMPL * M.SWAY.AMPL * (swayMult or 1)
    local v = a * math.sin(TWO_PI * M.SWAY.FREQ * t)
    if v > limit then return limit end
    if v < -limit then return -limit end
    return v
end


-- ---------------------------------------------------------------------------
-- VERTICAL SMOOTHING
-- ---------------------------------------------------------------------------
-- The route's z is interpolated linearly along each segment, so the vertical
-- POSITION is continuous but the vertical SPEED is not: it changes abruptly at
-- every waypoint, and at 1400 units a second a waypoint arrives about once a
-- second. Measured over six real routes, the worst of those steps is 13.4
-- units of vertical speed per frame -- a jolt once a second, which is the
-- reported bumpiness.
--
-- A first-order ease on the vertical only. x and y keep following the path
-- exactly, because smoothing those would cut corners; nothing about the route
-- the strider walks changes, only how sharply it rises and falls along it.
--
-- The cost is lag, so the constant is a trade and was measured as one:
--
--     tau     worst jolt        worst deviation from the path
--     0.00    13.36 u/frame       0
--     0.05     4.24               34
--     0.10     2.34               73      <- chosen
--     0.25     0.97              170
--     0.80     0.30              393
--
-- 0.10 cuts the jolt by 5.7x for 73 units of lag at the very steepest point
-- of the steepest route. The strider is 1284 units tall, so that is under 6%
-- of its own height -- about a metre on an eighteen-metre animal, and only
-- where the ground is at its worst.
--
-- CLAMPED as well as eased. A route with a cliff in it could otherwise leave
-- the strider hanging in the air for as long as the ease takes to catch up;
-- past the clamp the vertical simply tracks the path and the jolt comes back,
-- which is the right failure.
M.VERTICAL = {
    TAU       = 0.10,   -- seconds
    MAX_DRIFT = 150,    -- units; beyond this, follow the path exactly
}

---Ease a vertical position toward the path's, bounded.
---@param current number|nil the eased z so far, or nil to start at `target`
---@param target number the path's z
---@param dt number seconds
---@return number
function M.easeVertical(current, target, dt)
    if current == nil then return target end
    local tau = M.VERTICAL.TAU
    if not (tau > 0) or not (dt > 0) then return target end
    local next_ = current + (target - current) * (1 - math.exp(-dt / tau))
    local drift = next_ - target
    local limit = M.VERTICAL.MAX_DRIFT
    if drift > limit then return target + limit end
    if drift < -limit then return target - limit end
    return next_
end

return M
