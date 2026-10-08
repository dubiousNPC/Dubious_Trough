---@omw-context none
--[[
    boats_physics.lua -- the boat's equations of motion, and nothing else

    Pure functions on numbers, so the whole model is testable outside the
    engine (tools/test_boats_physics.lua). Yaw follows the engine convention
    used across WhyWalk: forward = (sin y, cos y), right = (cos y, -sin y),
    a right turn increases yaw.

    The model, and where each piece comes from:
      speed    accelerate / brake toward the throttle, coast with exponential
               drag                        Skyships, Stormrider, Aetherius
      heading  the yaw RATE eases toward rudder * turnRate * authority, so a
               turn starts and stops softly                       Skyships
      bumper   speed is capped so the hull can still stop before an obstacle
               ahead                          Skyships' safe-height look-ahead
      roll     sway sine plus a heel that leans into the turn  Immersive Travel
      pitch    triangle-wave rocking                       Your Own Gondola
]]

local M = {}

local exp, abs, sqrt, sin, cos, pi = math.exp, math.abs, math.sqrt, math.sin, math.cos, math.pi
local TWO_PI = 2 * pi

local function clamp(x, lo, hi)
    if x < lo then return lo end
    if x > hi then return hi end
    return x
end
M.clamp = clamp

---Shortest signed angle from a to b, in (-pi, pi].
function M.angleDiff(a, b)
    local d = (b - a) % TWO_PI
    if d > pi then d = d - TWO_PI end
    return d
end

function M.forward(yaw) return sin(yaw), cos(yaw) end
function M.right(yaw)   return cos(yaw), -sin(yaw) end

---Vessel-frame (x right, y forward) offset to a world-frame (x, y) offset.
function M.toWorld(x, y, yaw)
    local s, c = sin(yaw), cos(yaw)
    return x * c + y * s, -x * s + y * c
end

---World-frame (x, y) offset to the vessel frame; inverse of toWorld.
function M.toLocal(x, y, yaw)
    local s, c = sin(yaw), cos(yaw)
    return x * c - y * s, x * s + y * c
end

-- ---------------------------------------------------------------------------
-- SPEED
-- ---------------------------------------------------------------------------

---Advance signed speed (u/s, + ahead) by dt under a throttle in [-1, 1].
---`cap` is an extra ahead-limit from the bumper (nil = none); `capAstern` the
---same astern.
function M.stepSpeed(speed, throttle, v, dt, cap, capAstern)
    if throttle > 0 then
        local target = v.maxSpeed * throttle
        if speed < 0 then
            speed = math.min(0, speed + v.brake * dt)
        elseif speed < target then
            speed = math.min(target, speed + v.accel * dt)
        else
            speed = math.max(target, speed * exp(-v.drag * dt))
        end
    elseif throttle < 0 then
        local target = v.reverseSpeed * throttle
        if speed > 0 then
            speed = math.max(0, speed - v.brake * dt)
        elseif speed > target then
            speed = math.max(target, speed - v.accel * dt)
        else
            speed = math.min(target, speed * exp(-v.drag * dt))
        end
    else
        speed = speed * exp(-v.drag * dt)
        if abs(speed) < 1 then speed = 0 end
    end
    if cap and speed > cap then speed = math.max(cap, 0) end
    if capAstern and speed < -capAstern then speed = -math.max(capAstern, 0) end
    return speed
end

---Fastest speed from which the hull can still stop `distance` away with the
---given brake. The bumper caps speed to this, which is what makes a boat
---slide to a halt at a jetty instead of striking it.
function M.stoppingCap(distance, brake, margin)
    local room = distance - (margin or 0)
    if room <= 0 then return 0 end
    return sqrt(2 * brake * room)
end

-- ---------------------------------------------------------------------------
-- HEADING
-- ---------------------------------------------------------------------------

---Rudder authority in [0, 1]: `pivot` at rest rising to 1 at full way.
function M.authority(speed, v)
    local way = v.maxSpeed > 0 and math.min(1, abs(speed) / v.maxSpeed) or 0
    return v.pivot + (1 - v.pivot) * way
end

---Advance the yaw rate (rad/s, + to starboard) toward the rudder's demand.
---Going astern the rudder acts the other way, as it does on any boat.
function M.stepYawRate(yawRate, rudder, speed, v, dt)
    local sense = speed < -1 and -1 or 1
    local target = rudder * v.turnRate * M.authority(speed, v) * sense
    local k = math.min(1, v.turnResponse * dt)
    return yawRate + (target - yawRate) * k
end

---View-follow steering (Your Own Gondola's model): rudder toward the camera
---yaw, with hysteresis so a near-straight course does not hunt.
---Returns rudder, engaged.
function M.viewRudder(boatYaw, viewYaw, engaged, t)
    local d = M.angleDiff(boatYaw, viewYaw)
    local mag = abs(d)
    if engaged then
        if mag < t.viewSteerRelease then return 0, false end
    elseif mag < t.viewSteerEngage then
        return 0, false
    end
    return clamp(d / t.viewSteerFull, -1, 1), true
end

-- ---------------------------------------------------------------------------
-- DELIVERY -- turning a world velocity into the pilot's movement controls
-- ---------------------------------------------------------------------------
-- The pilot is moved by the engine, so the boat's velocity has to be phrased
-- as controls relative to where the PILOT faces (mouse-look is free). OpenMW
-- moves the player along the normalised (sideMovement, movement) direction
-- at speed * max(|movement|, |sideMovement|), and doubles analogue values
-- <= 0.5 while walking. Running avoids the doubling, so the mapping is:
--     walking:  factor = speed / (2 * walkSpeed)       (<= 0.5 by construction)
--     running:  factor = speed / runSpeed
-- `gain` is the closed-loop correction (stepGain) for any engine mapping that
-- turns out to differ; 1 when the above holds.

---@return number movement, number sideMovement, boolean run, number achievable
function M.controlsFor(vx, vy, pilotYaw, walkSpeed, runSpeed, gain)
    local speed = sqrt(vx * vx + vy * vy)
    if speed < 1e-3 then return 0, 0, false, 0 end

    local fx, fy = M.forward(pilotYaw)
    local rx, ry = M.right(pilotYaw)
    local f = (vx * fx + vy * fy) / speed
    local s = (vx * rx + vy * ry) / speed
    local dominant = math.max(abs(f), abs(s))

    local run, factor, achievable
    if walkSpeed and walkSpeed > 0 and speed <= walkSpeed then
        run = false
        factor = speed / (2 * walkSpeed)
        achievable = speed
    else
        run = true
        local top = (runSpeed and runSpeed > 0) and runSpeed or speed
        factor = math.min(1, speed / top)
        achievable = math.min(speed, top)
    end
    factor = clamp(factor * (gain or 1), 0, 1)

    local k = factor / dominant
    return f * k, s * k, run, achievable
end

---Closed-loop gain: nudge so the speed achieved matches the speed asked for.
---Frozen while bumping, so a wall does not wind it up.
function M.stepGain(gain, asked, achieved, dt, t)
    if asked < 20 then return gain end
    local ratio = achieved / asked
    if ratio < t.bumpRatio then return gain end
    local target = clamp(gain / math.max(ratio, 0.05), t.gainMin, t.gainMax)
    return gain + (target - gain) * math.min(1, t.gainRate * dt)
end

-- ---------------------------------------------------------------------------
-- MOTION (cosmetic)
-- ---------------------------------------------------------------------------

---Triangle wave in [-1, 1] with the given period: Your Own Gondola's
---"up for 1, down for 2, up for 1".
function M.triangle(t, period)
    local p = (t % period) / period
    if p < 0.25 then return p * 4 end
    if p < 0.75 then return 1 - (p - 0.25) * 4 end
    return -1 + (p - 0.75) * 4
end

---Heel eases toward a lean into the turn at heelRate (rad/s).
function M.stepHeel(heel, turnSign, m, dt)
    local target = -turnSign * m.heelMax
    local step = m.heelRate * dt
    if heel < target then return math.min(target, heel + step) end
    if heel > target then return math.max(target, heel - step) end
    return heel
end

---@return number roll, number pitch
function M.motion(t, heel, m)
    local roll = m.roll * sin(TWO_PI * m.rollFreq * t) + heel
    local pitch = m.pitch * M.triangle(t, m.pitchPeriod)
    return roll, pitch
end

return M
