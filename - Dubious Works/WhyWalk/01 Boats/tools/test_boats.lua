-- test_boats.lua -- unit tests for boats_physics and boats_db.
-- Run from the module root:  python3 tools/luarun.py tools/test_boats.lua
package.path = './?.lua;' .. package.path

local phys = require('scripts.WhyWalk.Boats.boats_physics')
local db   = require('scripts.WhyWalk.Boats.boats_db')
-- Poses live in Core; the repo layout puts it beside this module.
local core = dofile('../00 Core/scripts/WhyWalk/whywalk_shared.lua')

local passed, failed = 0, 0
local function check(name, cond, detail)
    if cond then passed = passed + 1
    else failed = failed + 1; print('FAIL ' .. name .. (detail and ('  ' .. detail) or '')) end
end
local function near(a, b, eps) return math.abs(a - b) <= (eps or 1e-6) end
local PI = math.pi

-- ---------------------------------------------------------------- frames
do
    local fx, fy = phys.forward(0)
    check('forward(0) is north', near(fx, 0) and near(fy, 1))
    fx, fy = phys.forward(PI / 2)
    check('forward(pi/2) is east: yaw grows to the right', near(fx, 1) and near(fy, 0))
    for _, yaw in ipairs({ 0, 0.3, 1.9, -2.4, 5.5 }) do
        local wx, wy = phys.toWorld(0, 1, yaw)
        local ex, ey = phys.forward(yaw)
        check('toWorld(0,1) == forward @' .. yaw, near(wx, ex) and near(wy, ey))
        wx, wy = phys.toWorld(1, 0, yaw)
        ex, ey = phys.right(yaw)
        check('toWorld(1,0) == right @' .. yaw, near(wx, ex) and near(wy, ey))
        local px, py = phys.toWorld(37, -12, yaw)
        local lx, ly = phys.toLocal(px, py, yaw)
        check('toLocal inverts toWorld @' .. yaw, near(lx, 37, 1e-9) and near(ly, -12, 1e-9))
    end
    check('angleDiff wraps across north', near(phys.angleDiff(6.2, 0.1), 0.1 + 2 * PI - 6.2, 1e-9))
    check('angleDiff sign', phys.angleDiff(0, 0.5) > 0 and phys.angleDiff(0.5, 0) < 0)
end

-- ---------------------------------------------------------------- speed
local function simulateSpeed(v, throttle, seconds, fps, start)
    local speed, t, dt = start or 0, 0, 1 / fps
    local reached = nil
    while t < seconds do
        speed = phys.stepSpeed(speed, throttle, v, dt)
        t = t + dt
        if not reached and throttle > 0 and speed >= v.maxSpeed * throttle - 1e-9 then reached = t end
    end
    return speed, reached
end

do
    local row = db.vessel('rowboat')
    local s60, t60 = simulateSpeed(row, 1, 4, 60)
    local s144, t144 = simulateSpeed(row, 1, 4, 144)
    check('rowboat tops out at maxSpeed', near(s60, 144) and near(s144, 144))
    check('rowboat reaches top in maxSpeed/accel = 2 s', near(t60, 2, 1 / 60 + 1e-9), tostring(t60))
    check('acceleration is frame-rate independent', near(t60, t144, 1 / 60 + 1e-9), t60 .. ' vs ' .. t144)

    local coasted = simulateSpeed(row, 0, math.log(2) / row.drag, 240, 144)
    check('coasting halves speed in ln2/drag', near(coasted, 72, 1.0), tostring(coasted))

    local s = 100
    local t = 0
    while s > 0 do s = phys.stepSpeed(s, -1, row, 1 / 60); t = t + 1 / 60 end
    check('astern throttle brakes ahead way at `brake`', near(t, 100 / row.brake, 1 / 30), tostring(t))
    local astern = simulateSpeed(row, -1, 5, 60, 0)
    check('astern tops out at reverseSpeed', near(astern, -row.reverseSpeed))

    check('cap limits ahead speed', phys.stepSpeed(140, 1, row, 1 / 60, 50) == 50)
    check('cap 0 stops dead', phys.stepSpeed(140, 1, row, 1 / 60, 0) == 0)
    check('astern cap', phys.stepSpeed(-70, -1, row, 1 / 60, nil, 20) == -20)
    check('half throttle holds half speed', near(simulateSpeed(row, 0.5, 6, 60), 72, 0.5))
end

-- ---------------------------------------------------------------- bumper
do
    check('stoppingCap formula', near(phys.stoppingCap(140, 72, 40), math.sqrt(2 * 72 * 100)))
    check('stoppingCap inside margin is 0', phys.stoppingCap(30, 72, 40) == 0)

    -- Full throttle at a jetty 600 u ahead, bumper re-probed at 10 Hz: the
    -- hull must stop short of it, never pass through.
    for _, id in ipairs({ 'rowboat', 'gondola', 'longboat' }) do
        local v = db.vessel(id)
        local dist, speed, timer, cap = 600, v.maxSpeed, 0, nil
        local dt = 1 / 60
        for _ = 1, 60 * 30 do
            timer = timer - dt
            if timer <= 0 then timer = 0.1; cap = phys.stoppingCap(dist, v.brake, db.TUNING.obstacleMargin) end
            speed = phys.stepSpeed(speed, 1, v, dt, cap)
            dist = dist - speed * dt
        end
        check(id .. ' stops before the jetty', dist > 0 and speed < 1, string.format('dist %.1f speed %.2f', dist, speed))
    end
end

-- ---------------------------------------------------------------- heading
do
    local g = db.vessel('gondola')
    check('authority at rest is pivot', near(phys.authority(0, g), g.pivot))
    check('authority at full way is 1', near(phys.authority(g.maxSpeed, g), 1))

    local rate = 0
    for _ = 1, 600 do rate = phys.stepYawRate(rate, 1, g.maxSpeed, g, 1 / 60) end
    check('yaw rate converges to turnRate', near(rate, g.turnRate, 1e-4), tostring(rate))
    rate = 0
    for _ = 1, 600 do rate = phys.stepYawRate(rate, 1, -g.reverseSpeed, g, 1 / 60) end
    check('rudder acts the other way astern', rate < 0)

    local f = db.vessel('fishing_boat')
    rate = 0
    for _ = 1, 600 do rate = phys.stepYawRate(rate, 1, 0, f, 1 / 60) end
    check('a sailboat cannot turn at rest (pivot 0)', near(rate, 0))

    local T = db.TUNING
    local r, e = phys.viewRudder(0, 0.05, false, T)
    check('view steering ignores small offsets', r == 0 and not e)
    r, e = phys.viewRudder(0, 0.2, false, T)
    check('view steering engages past 6 deg', r > 0 and e)
    r, e = phys.viewRudder(0, 0.05, true, T)
    check('view steering holds until 1.5 deg', r > 0 and e)
    r, e = phys.viewRudder(0, 0.01, true, T)
    check('view steering releases inside 1.5 deg', r == 0 and not e)
    r = phys.viewRudder(0.1, 2 * PI - 0.3, false, T)
    check('view steering turns the short way across north', r < 0)
end

-- ---------------------------------------------------------------- delivery
-- An engine model built from the mapping documented in controlsFor.
local function engineVelocity(mv, side, run, pilotYaw, walk, runSpeed, doubling)
    local mag = math.max(math.abs(mv), math.abs(side))
    if mag == 0 then return 0, 0 end
    local speed
    if run then speed = runSpeed * mag
    else speed = walk * ((doubling and mag <= 0.5) and 2 * mag or mag) end
    local len = math.sqrt(mv * mv + side * side)
    local fx, fy = phys.forward(pilotYaw)
    local rx, ry = phys.right(pilotYaw)
    local dx = (fx * mv + rx * side) / len
    local dy = (fy * mv + ry * side) / len
    return dx * speed, dy * speed
end

do
    local walk, runSpeed = 150, 300
    local worst = 0
    for i = 0, 40 do
        local pilotYaw = i * 0.37
        local boatYaw = i * 1.13
        for _, speed in ipairs({ 20, 100, 149, 151, 220, 299 }) do
            local fx, fy = phys.forward(boatYaw)
            local vx, vy = fx * speed, fy * speed
            local mv, side, run = phys.controlsFor(vx, vy, pilotYaw, walk, runSpeed, 1)
            local ex, ey = engineVelocity(mv, side, run, pilotYaw, walk, runSpeed, true)
            worst = math.max(worst, math.abs(ex - vx), math.abs(ey - vy))
        end
    end
    check('controlsFor reproduces the boat velocity at any pilot facing', worst < 1e-6, tostring(worst))

    local mv, side, run, achievable = phys.controlsFor(0, 500, 0, 150, 300, 1)
    check('above run speed: clamped and reported', near(mv, 1) and near(side, 0) and run and achievable == 300)

    -- Engine WITHOUT the walking doubling: the gain loop must find 2.
    local T = db.TUNING
    local gain, dt = 1, 1 / 60
    for _ = 1, 60 * 30 do
        local a, b, r2, asked = phys.controlsFor(0, 100, 0, 150, 300, gain)
        local _, ey = engineVelocity(a, b, r2, 0, 150, 300, false)
        gain = phys.stepGain(gain, asked, ey, dt, T)
    end
    check('gain loop converges on an engine without doubling', near(gain, 2, 0.02), tostring(gain))

    gain = 1.3
    check('gain frozen when the pilot is blocked', phys.stepGain(gain, 100, 5, dt, T) == gain)
end

-- ---------------------------------------------------------------- turning about the hull
do
    local ax, ay, w = 67, -457, 0.144
    for _, yaw in ipairs({ 0, 1, 2.5, 4 }) do
        local rx, ry = phys.toWorld(ax, ay, yaw)
        local vx, vy = w * ry, -w * rx
        local h = 1e-6
        local x1, y1 = phys.toWorld(ax, ay, yaw)
        local x2, y2 = phys.toWorld(ax, ay, yaw + w * h)
        check('omega x r matches the anchor\'s motion @' .. yaw,
              near(vx, (x2 - x1) / h, 1e-3) and near(vy, (y2 - y1) / h, 1e-3))
    end
end

-- ---------------------------------------------------------------- motion
do
    check('triangle 0', near(phys.triangle(0, 4), 0))
    check('triangle peak at P/4', near(phys.triangle(1, 4), 1))
    check('triangle zero at P/2', near(phys.triangle(2, 4), 0))
    check('triangle trough at 3P/4', near(phys.triangle(3, 4), -1))
    check('triangle periodic', near(phys.triangle(5, 4), phys.triangle(1, 4)))

    local m = db.vessel('longboat').motion
    local heel = 0
    for _ = 1, 600 do heel = phys.stepHeel(heel, 1, m, 1 / 60) end
    check('heel settles at -heelMax in a starboard turn', near(heel, -m.heelMax, 1e-9))
    local roll, pitch = phys.motion(0, 0, m)
    check('motion at t=0 is level', near(roll, 0) and near(pitch, 0))
end

-- ---------------------------------------------------------------- database
do
    local NUMERIC = { 'maxSpeed', 'reverseSpeed', 'accel', 'brake', 'drag', 'turnRate', 'turnResponse' }
    for id, v in pairs(db.VESSELS) do
        for _, k in ipairs(NUMERIC) do
            check(id .. '.' .. k .. ' > 0', type(v[k]) == 'number' and v[k] > 0)
        end
        check(id .. '.pivot in [0,1]', v.pivot >= 0 and v.pivot <= 1)
        check(id .. '.anchor', type(v.anchor) == 'table' and v.anchor.x and v.anchor.y and v.anchor.z)
        check(id .. '.pose is a Core vessel stance', core.VESSEL_STANCE[v.pose] ~= nil, tostring(v.pose))
        for _, k in ipairs({ 'roll', 'rollFreq', 'heelMax', 'heelRate', 'pitch', 'pitchPeriod' }) do
            check(id .. '.motion.' .. k, type(v.motion[k]) == 'number')
        end
        if v.hull then
            for _, k in ipairs({ 'bow', 'stern', 'halfBeam', 'draft' }) do
                check(id .. '.hull.' .. k, type(v.hull[k]) == 'number' and v.hull[k] > 0)
            end
        end
        check(id .. ' has provenance', db.PROVENANCE[id] ~= nil)
    end
    for key, entry in pairs(db.MODELS) do
        check(key .. ' -> known vessel', db.VESSELS[entry.vessel] ~= nil)
        check(key .. ' yawOffset 0 or pi', entry.yawOffset == 0 or near(entry.yawOffset, PI))
        check(key .. ' is normalised', db.normalizeModel(key) == key)
    end

    check('normalizeModel', db.normalizeModel('Meshes\\X\\Ex_De_Rowboat.NIF') == 'x/ex_de_rowboat.nif')
    check('modelEntry exact', db.modelEntry('meshes/x/ex_gondola_01.nif').vessel == 'gondola')
    check('modelEntry by basename', db.modelEntry('meshes/somemod/GV_Gondola.nif').vessel == 'gondola')
    check('modelEntry unknown', db.modelEntry('meshes/x/ex_de_ship.nif') == nil)
    check('recordEntry case-insensitive', db.recordEntry('GV_PlayerGond').claim == true)
    check('IT mounts are refused', db.recordEntry('a_gondola_01').claim == false)
    check('boat-like discovery', db.isBoatLikeModel('meshes/x/ex_de_ship.nif') and not db.isBoatLikeModel('meshes/x/ex_de_rowboat.nif'))

    local a = db.vessel('gondola')
    a.hull.bow = 1
    a.anchor.y = 999
    local b = db.vessel('gondola')
    check('vessel() returns a fresh copy', b.hull.bow == 354.1 and b.anchor.y == -81.5)
    check('vessel() carries its id', b.id == 'gondola')
end

print(string.format('%d passed, %d failed', passed, failed))
if failed > 0 then error('tests failed') end
