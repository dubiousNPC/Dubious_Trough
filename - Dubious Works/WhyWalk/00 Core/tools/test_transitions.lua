-- test_transitions.lua -- mounting transitions and the saddle choice
--
--   run from "00 Core":  luarun.py tools/test_transitions.lua

local pass, fail = 0, 0
local function check(name, cond, got)
    if cond then pass = pass + 1; print(('  ok   %s'):format(name))
    else fail = fail + 1; print(('  FAIL %s  -> %s'):format(name, tostring(got))) end
end
local function v3(x, y, z) return { x = x, y = y, z = z } end
package.loaded['openmw.util'] = {
    vector3 = v3, vector2 = function(x, y) return { x = x, y = y } end,
    transform = { rotateZ = function() return {} end },
    clamp = function(v, lo, hi) return math.max(lo, math.min(hi, v)) end,
}
package.loaded['openmw.core'] = { l10n = function() return function(k) return k end end }
local shared = dofile('scripts/WhyWalk/whywalk_shared.lua')

print('which clip climbs on')
local g, d = shared.mountTransition(40)
check('a scrib (rise 40) is a vault', g == 'wwvault1', g)
g, d = shared.mountTransition(130)
check('a guar (rise 130, about one body) is a mantle', g == 'wwmantle1', g)
g, d = shared.mountTransition(320)
check('a netch betty (rise 320) is a boost', g == 'wwboostup', g)
local _, d2 = shared.mountTransition(755)
check('a taller climb takes longer', d2 > d, string.format('%.2f vs %.2f', d2, d))
check('and never longer than maxDuration', d2 <= shared.MOUNT_TRANSITION.maxDuration, d2)
g = shared.mountTransition(-30)
check('a saddle below the feet (a dreugh in a dip) is a vault', g == 'wwvault1', g)

print('the arc')
local from, to = v3(0, 0, 0), v3(100, 0, 120)
local a0 = shared.mountArc(from, to, 0, 18)
local a1 = shared.mountArc(from, to, 1, 18)
check('starts where the player stands', a0.x == 0 and a0.z == 0, a0.z)
check('ends exactly on the saddle', math.abs(a1.x - 100) < 1e-9 and math.abs(a1.z - 120) < 1e-9, a1.z)
local half = shared.mountArc(from, to, 0.5, 18)
check('rises before it moves across (half way: more than half up, half across)',
    half.z > 60 and math.abs(half.x - 50) < 1e-9, string.format('x %.1f z %.1f', half.x, half.z))
local early = shared.mountArc(from, to, 0.25, 18)
check('a quarter of the way it is mostly climbing', early.z / 120 > early.x / 100 * 2, string.format('x %.1f z %.1f', early.x, early.z))
local prev, mono = -1, true
for i = 0, 20 do local p = shared.mountArc(from, to, i / 20, 0); if p.x < prev then mono = false end; prev = p.x end
check('never moves backwards', mono)
local tall = shared.mountArc(v3(0, 0, 0), v3(0, 0, 750), 0.05, 0)
check('a boost onto a netch eases in (5% of the time, under 3% of the height)', tall.z < 0.03 * 750, tall.z)

print('which saddle')
local s, src = shared.chooseSaddle('detd_guarride1', shared.MOUNT_TYPE.GUAR, 95, nil, nil)
check('the riding mod\'s own creature keeps its authored saddle', src == 'authored' and s.up == 130, src .. ' ' .. s.up)
s, src = shared.chooseSaddle('guar', shared.MOUNT_TYPE.GUAR, 112, nil, nil)
check('a vanilla guar uses the measured back', src == 'measured' and s.up == 114, src .. ' ' .. s.up)
check('and keeps the profile\'s fore/aft offset', s.forward == shared.profileFor(shared.MOUNT_TYPE.GUAR).saddle.forward, s.forward)
s, src = shared.chooseSaddle('netch_bull', shared.MOUNT_TYPE.NETCH, 755, nil, nil)
check('a netch bull sits on its bell, not at 200', src == 'measured' and s.up == 757, src .. ' ' .. s.up)
s, src = shared.chooseSaddle('netch_bull', shared.MOUNT_TYPE.NETCH, nil, shared.saddleFromProfile('netch_bull'), nil)
check('unmeasured, a netch takes its own compiled height, not the shared 200', src == 'compiled' and s.up > 700, src .. ' ' .. s.up)
s, src = shared.chooseSaddle('kagouti', shared.MOUNT_TYPE.KAGOUTI, nil, shared.saddleFromProfile('kagouti'), nil)
check('unmeasured, other typed mounts keep their PROFILE', src == 'profile' and s.up == 120, src .. ' ' .. s.up)
s, src = shared.chooseSaddle('cliff racer', nil, nil, { forward = 0, right = 0, up = 430 }, nil)
check('unmeasured and untyped: the compiled table', src == 'compiled' and s.up == 430, src)
s, src = shared.chooseSaddle('cliff racer', nil, 2, { forward = 0, right = 0, up = 430 }, nil)
check('a measurement below the bounds is ignored', src == 'compiled', src)
s, src = shared.chooseSaddle('x', nil, nil, nil, nil)
check('nothing at all: the default', src == 'default' and s.up == 130, src)

print('compiled fliers sit on top')
local c = shared.CREATURES
check('netch_bull compiled saddle is on its bell (> 700)', c.get('netch_bull').up > 700, c.get('netch_bull').up)
check('netch_betty compiled saddle is on its bell (> 300)', c.get('netch_betty').up > 300, c.get('netch_betty').up)

print('vessel seat transitions')
check('a rowboat sits down on the bench clip', shared.VESSEL_SEAT_TRANSITION.rowing.enter == 'wwsitd2')
check('a standing stance has none', shared.VESSEL_SEAT_TRANSITION.stand == nil and shared.VESSEL_SEAT_TRANSITION.gondola == nil)

print(('%d passed, %d failed'):format(pass, fail))
if fail > 0 then error('test_transitions failed') end
