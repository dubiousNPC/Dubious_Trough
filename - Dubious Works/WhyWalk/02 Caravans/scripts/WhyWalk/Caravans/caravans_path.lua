---@omw-context none
--[[
    caravans_path.lua -- walking a route polyline, and nothing else

    Pure functions on numbers and flat arrays, so the whole route walker is
    testable outside the engine (tools/test_path.lua). No openmw requires, so
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
function M.easeHeading(current, target, rate, dt)
    if current == nil then return target end
    if target == nil then return current end
    local diff = M.angleDiff(current, target)
    local step = rate * dt
    if diff > step then diff = step elseif diff < -step then diff = -step end
    return (current + diff) % TWO_PI
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

return M
