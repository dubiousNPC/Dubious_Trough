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

local sqrt, floor, atan, pi = math.sqrt, math.floor, math.atan, math.pi
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
-- MEASURING
-- ---------------------------------------------------------------------------

---Measure a route once. Returns a table the stepper reads:
---  n        point count
---  reversed direction flag
---  cum      cum[i] = distance from the start to point i (cum[1] = 0)
---  total    full route length
---
---Measured in 3D. The vertical component is real -- a strider climbing out of
---the Ascadian Isles toward Ald-ruhn gains thousands of units -- and ignoring
---it would make uphill legs finish early.
---@param points table
---@param reversed boolean|nil
function M.prepare(points, reversed)
    local n = M.count(points)
    local cum = { 0 }
    local px, py, pz = M.pointAt(points, n, 1, reversed)
    local run = 0
    for i = 2, n do
        local x, y, z = M.pointAt(points, n, i, reversed)
        local dx, dy, dz = x - px, y - py, z - pz
        run = run + sqrt(dx * dx + dy * dy + dz * dz)
        cum[i] = run
        px, py, pz = x, y, z
    end
    return { n = n, reversed = reversed == true, cum = cum, total = run }
end

-- ---------------------------------------------------------------------------
-- STEPPING
-- ---------------------------------------------------------------------------

---Segment index containing arc-length `d`, by binary search.
---
---Linear search from the last index would be faster per frame and is the
---obvious thing to write, but it makes the cost depend on how far along the
---route you are and it breaks the moment anything seeks (a save resumed
---mid-journey, a debug skip). A binary search over 72 points is ~7
---comparisons, every frame of every journey, which is not worth optimising.
---@return number index of the segment start point, 1..n-1
local function segmentFor(prep, d)
    local cum, lo, hi = prep.cum, 1, prep.n
    if d <= 0 then return 1 end
    if d >= prep.total then return prep.n - 1 end
    while lo < hi - 1 do
        local mid = floor((lo + hi) / 2)
        if cum[mid] <= d then lo = mid else hi = mid end
    end
    return lo
end

---Heading of a vector in Morrowind's convention: 0 = +Y, increasing toward
---+X, i.e. forward = (sin yaw, cos yaw). Matches Core and Boats.
local function headingOf(dx, dy)
    if dx == 0 and dy == 0 then return nil end
    return atan(dx, dy) % TWO_PI
end
M.headingOf = headingOf

---Position and heading at arc-length `d` along a prepared route.
---
---`d` is clamped: before the start it returns the first point, past the end
---the last. Clamping rather than wrapping matters because the caller decides
---when a journey is over, and a route that silently restarted would strand a
---passenger in a loop.
---@return number x, number y, number z, number|nil yaw
function M.at(points, prep, d)
    local n, rev = prep.n, prep.reversed
    if n == 1 then
        local x, y, z = M.pointAt(points, n, 1, rev)
        return x, y, z, nil
    end
    if d <= 0 then
        local x, y, z = M.pointAt(points, n, 1, rev)
        local nx, ny = M.pointAt(points, n, 2, rev)
        return x, y, z, headingOf(nx - x, ny - y)
    end
    if d >= prep.total then
        local x, y, z = M.pointAt(points, n, n, rev)
        local px, py = M.pointAt(points, n, n - 1, rev)
        return x, y, z, headingOf(x - px, y - py)
    end

    local i = segmentFor(prep, d)
    local ax, ay, az = M.pointAt(points, n, i, rev)
    local bx, by, bz = M.pointAt(points, n, i + 1, rev)
    local segStart = prep.cum[i]
    local segLen = prep.cum[i + 1] - segStart
    -- A zero-length segment would divide by zero. The source has duplicated
    -- consecutive points in places, so this is not hypothetical.
    local t = segLen > 0 and (d - segStart) / segLen or 0
    return ax + (bx - ax) * t,
           ay + (by - ay) * t,
           az + (bz - az) * t,
           headingOf(bx - ax, by - ay)
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
-- STEERING, RATHER THAN PLACING
-- ---------------------------------------------------------------------------
-- THE STRIDER MOVES WHERE IT POINTS. That is the whole of this section, and it
-- is a different movement model from the one above.
--
-- `M.at` answers "where is the arc-length point d along this polyline", and
-- the vehicle was placed there each frame while being rotated, separately,
-- toward the segment's heading. Those are two independent quantities, and any
-- disagreement between them IS the body moving sideways -- which is what was
-- reported, every round, for a week: "the body is moving sideways at times",
-- "directional facing wrong/unresponsive". Easing the heading faster, aiming
-- it further ahead and unwrapping it all made the disagreement smaller
-- without removing it, because the model allows it to exist.
--
-- Immersive Travel does not have the fault, and the reason is structural
-- rather than better-tuned (main.lua, the mount update):
--
--     local d = (nextPos - currentPos):normalized()   -- bearing to the POINT
--     local new_facing = math.atan2(d.x, d.y)
--     ... turn toward new_facing, clamped ...
--     mount.facing = facing
--     mount.position = currentPos + delta             -- delta along `forward`
--
-- Two things follow from that, and neither can be had by tuning:
--
--   1. The heading target is the BEARING TO THE NEXT WAYPOINT, not the
--      heading of the current segment. A segment heading is piecewise
--      constant and jumps at every node; a bearing to a point rotates
--      smoothly and continuously as you approach it. That is the "gentle
--      drift between each point, long gradual turns" the real thing does.
--
--   2. The position is INTEGRATED along the facing, not sampled from the
--      polyline. Velocity and facing are the same vector by construction, so
--      sideways motion is not merely small, it is impossible.
--
-- The cost is that the route is now followed rather than traced: the strider
-- has a turning radius (speed / turnRate) and will swing wide of a corner too
-- sharp for it, exactly as a real animal would. That is a feature of the model
-- and it is bounded -- tools/test_caravans.lua measures the worst deviation
-- from the polyline and holds it under a cap.

-- WHAT REPLACED IT, AND THE NUMBERS. Simulated at 60fps over eight real
-- routes, measuring the SIDEWAYS fraction of motion -- how much of each
-- frame's travel is perpendicular to where the body points, which is the
-- thing that was being seen:
--
--     model                      mean side  worst side  mean dev  end gap
--     place on path (what shipped)    3.8%       88.1%       0 u      0 u
--     steer only, no correction       0.0%        0.0%     323 u    906 u
--     steer + correction tau 2.0      1.0%       16.9%      64 u    315 u
--     steer + correction tau 0.5      2.9%       37.7%      25 u     86 u
--
-- 88% sideways at the sharpest corner is a strider travelling almost entirely
-- crabwise, and no amount of tuning the old model removes it, because nothing
-- in that model ties facing to velocity. Steering ties them by construction
-- and the measured worst case falls to 17%.
--
-- THE CORRECTION is the price of steering. Pure steering never rejoins the
-- route -- it swings wide of every corner, ends 906 units from the stop, and
-- on one route orbits the destination forever because its turning radius
-- (speed / turnRate = 1400 units) exceeds the distance it needs to close. So
-- the position is pulled gently back toward where the route says it should be,
-- which bounds the deviation, guarantees arrival, and is itself the only
-- sideways motion left. tau 2.0 keeps that pull slow enough to stay under a
-- fifth of the worst case of the old model.
--
-- THE ROUTE IS STILL FOLLOWED, within 64 units on average on segments 1500
-- units long. The strider walks a smoother line than the polyline, which is
-- what an animal would do.

---Bearing from one point to another, or nil if they coincide.
---@return number|nil radians, in [0, 2pi)
function M.headingToward(x, y, tx, ty)
    return headingOf(tx - x, ty - y)
end

---One step of the steering model.
---
---`st` is the vehicle's own state: { x, y, heading }. It is advanced in place
---and also returned, so a caller can read it either way.
---@param st table { x, y, heading }
---@param carrotX number the point on the route to steer at
---@param carrotY number
---@param pathX number where the route says the vehicle should be
---@param pathY number
---@param speed number units per second
---@param turnRate number radians per second
---@param correctTau number seconds; 0 disables the correction
---@param dt number
---@return table st
function M.steer(st, carrotX, carrotY, pathX, pathY, speed, turnRate, correctTau, dt)
    local aim = M.headingToward(st.x, st.y, carrotX, carrotY)
    st.heading = M.easeHeading(st.heading, aim, turnRate, dt)

    -- Forward along the facing. This is the whole reason for the model: the
    -- velocity IS the facing, so there is nothing sideways in it.
    local step = speed * dt
    st.x = st.x + sin(st.heading) * step
    st.y = st.y + cos(st.heading) * step

    -- Then back toward the route, gently. Without this the vehicle never
    -- rejoins the path and can orbit its destination; see the note above.
    if correctTau and correctTau > 0 and dt > 0 then
        local k = 1 - exp(-dt / correctTau)
        st.x = st.x + (pathX - st.x) * k
        st.y = st.y + (pathY - st.y) * k
    end
    return st
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
M.STEERING = {
    -- How far along the route to aim. Measured: 250 to 1200 all keep the mean
    -- deviation near 23-36 units, and the longer the aim the fewer direction
    -- changes per second (2.1/s at 250, 1.2/s at 1200). 700 is the gentlest
    -- that still tracks tightly, which is what "long gradual turns" asks for.
    AHEAD       = 700,
    -- Seconds for the corrective pull. The trade is in the table above: a
    -- faster pull tracks the route more closely and puts more sideways motion
    -- back in, which is the fault being fixed.
    CORRECT_TAU = 2.0,
}

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
