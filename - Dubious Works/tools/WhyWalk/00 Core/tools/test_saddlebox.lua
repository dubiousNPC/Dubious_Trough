-- test_saddlebox.lua -- saddleFromBoundingBox, the fallback for creatures
-- that PROFILE has never heard of
--
--   run from "00 Core":  luarun.py tools/test_saddlebox.lua
--
-- The load-bearing claim in that function is that it reads ONLY yaw-invariant
-- parts of the bounding box. Cod3x leaves it ambiguous whether `halfSize` is
-- in body axes or world axes, and the function is written to be correct under
-- either reading -- but only because it never touches halfSize.x or .y. These
-- tests hold it to that: the same creature facing two directions has to
-- produce the same saddle, and the only way that can fail is if someone later
-- "improves" the forward offset by reading a horizontal extent.

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

-- --- stubs -----------------------------------------------------------------

local function v3(x, y, z) return { x = x, y = y, z = z } end

package.loaded['openmw.util'] = {
    vector3 = v3,
    vector2 = function(x, y) return { x = x, y = y } end,
    transform = { rotateZ = function() return {} end },
    clamp = function(v, lo, hi) return math.max(lo, math.min(hi, v)) end,
}
package.loaded['openmw.core'] = { l10n = function() return function(k) return k end end }

local printed = {}
local realPrint = print
print = function(...) printed[#printed + 1] = table.concat({ ... }, ' ') end

local shared = dofile('scripts/WhyWalk/whywalk_shared.lua')

print = realPrint

check('saddleFromBoundingBox is exported',
      type(shared.saddleFromBoundingBox) == 'function',
      type(shared.saddleFromBoundingBox))

-- A creature whose origin sits at ground level, body centred 70 above it,
-- 90 units from centre to crown. Roughly guar-shaped.
local function creature(id, halfSize, centreAboveOrigin, originZ)
    originZ = originZ or 0
    return {
        recordId = id,
        position = v3(0, 0, originZ),
        getBoundingBox = function()
            return {
                center   = v3(0, 0, originZ + centreAboveOrigin),
                halfSize = halfSize,
            }
        end,
    }
end

-- --- TEST 1: the derived offset is sane for a guar-shaped box -------------

local guarish = creature('test_guar', v3(40, 110, 90), 70)
local s = shared.saddleFromBoundingBox(guarish)

check('returns a saddle table', type(s) == 'table', type(s))
check('forward is zero (documented: the measured profiles are -6..-12)',
      s and s.forward == 0, s and s.forward)
check('right is zero', s and s.right == 0, s and s.right)
-- 70 + 90 * 0.72 = 134.8, against DGR's measured 130 for a guar.
check('up lands within 10 units of the measured guar value of 130',
      s and math.abs(s.up - 130) <= 10, s and s.up)
check('up sits below the top of the box, not on it',
      s and s.up < 70 + 90, s and s.up)
check('up sits above the centre of the box',
      s and s.up > 70, s and s.up)

-- --- TEST 2: yaw invariance ----------------------------------------------

-- The same animal, with its horizontal extents swapped as if it had turned 90
-- degrees. Under the world-axes reading of halfSize this is exactly what a
-- quarter turn looks like; under the body-axes reading it cannot happen. The
-- answer must not change either way.
local turned = creature('test_guar_turned', v3(110, 40, 90), 70)
local t = shared.saddleFromBoundingBox(turned)
check('swapping halfSize.x and .y does not change the saddle',
      t and s and math.abs(t.up - s.up) < 1e-9,
      t and s and (t.up - s.up))

-- And a 45 degree case, where the world-axes reading mixes length and width
-- into both components and neither is recoverable.
local diagonal = creature('test_guar_diag', v3(106, 106, 90), 70)
local d = shared.saddleFromBoundingBox(diagonal)
check('a 45-degree box gives the same saddle',
      d and s and math.abs(d.up - s.up) < 1e-9,
      d and s and (d.up - s.up))

-- --- TEST 3: the offset is relative to the ORIGIN, not the world ----------

-- Same animal standing on a mountain. The saddle is an offset, so it must not
-- grow with altitude -- and this is the test that catches reading box.center.z
-- without subtracting the object's own position.
local high = creature('test_guar_high', v3(40, 110, 90), 70, 4096)
local h = shared.saddleFromBoundingBox(high)
check('altitude does not change the saddle offset',
      h and s and math.abs(h.up - s.up) < 1e-9, h and s and (h.up - s.up))

local sunken = creature('test_guar_low', v3(40, 110, 90), 70, -1500.25)
local lo = shared.saddleFromBoundingBox(sunken)
check('a negative origin Z does not change the saddle offset',
      lo and s and math.abs(lo.up - s.up) < 1e-9, lo and s and (lo.up - s.up))

-- --- TEST 4: scale -------------------------------------------------------

-- A silt strider is an order of magnitude bigger. The derivation has to scale
-- rather than clamp, or large mounts put the rider at their ankles.
local strider = creature('test_strider', v3(300, 400, 700), 560)
local st = shared.saddleFromBoundingBox(strider)
check('a much larger creature gets a much larger offset',
      st and st.up > 900, st and st.up)
check('the large offset is still below the top of its box',
      st and st.up < 560 + 700, st and st.up)

-- --- TEST 5: refusing a box it cannot use --------------------------------

check('nil mount returns nil', shared.saddleFromBoundingBox(nil) == nil,
      'got a table')

local flat = creature('test_flat', v3(40, 110, 0), 0)
check('a zero-height box returns nil rather than guessing',
      shared.saddleFromBoundingBox(flat) == nil, 'got a table')

local noBox = {
    recordId = 'test_nobox',
    position = v3(0, 0, 0),
    getBoundingBox = function() return nil end,
}
check('a missing box returns nil', shared.saddleFromBoundingBox(noBox) == nil,
      'got a table')

local partial = {
    recordId = 'test_partial',
    position = v3(0, 0, 0),
    getBoundingBox = function() return { center = v3(0, 0, 70) } end,
}
check('a box with no halfSize returns nil',
      shared.saddleFromBoundingBox(partial) == nil, 'got a table')

-- --- TEST 6: it reports once per record, not once per mount --------------

printed = {}
print = function(...) printed[#printed + 1] = table.concat({ ... }, ' ') end
local fresh = creature('test_report_once', v3(40, 110, 90), 70)
shared.saddleFromBoundingBox(fresh)
local afterFirst = #printed
shared.saddleFromBoundingBox(fresh)
shared.saddleFromBoundingBox(creature('test_report_once', v3(40, 110, 90), 70))
local afterRest = #printed
print = realPrint

check('the derived offset is reported', afterFirst >= 1, afterFirst)
check('it is reported once per record, not per mount',
      afterRest == afterFirst,
      ('%d lines, then %d'):format(afterFirst, afterRest))

-- The log line is the only route by which the real number reaches a human, so
-- it has to carry a value that can be pasted into PROFILE.
local line = printed[1] or ''
check('the report names the creature', line:find('test_report_once', 1, true) ~= nil,
      line)
check('the report includes a usable up value',
      line:find('up = ', 1, true) ~= nil, line)
check('the report says where to put it',
      line:find('PROFILE', 1, true) ~= nil, line)

-- --- TEST 7: profileFor never hands out a shared table ------------------

-- The bounding-box fallback works by REPLACING profile.saddle on the session.
-- If profileFor returned the module-level DEFAULT_PROFILE (it used to), that
-- write would rewrite the default for every later ride in the session: mount
-- one silt strider and every subsequent unknown creature seats its rider a
-- thousand units up.
local a = shared.profileFor(nil)
local b = shared.profileFor(nil)
check('two unknown-type profiles are different tables', a ~= b, 'same table')
check('their saddles are different tables too', a.saddle ~= b.saddle,
      'shared saddle table')

local baseline = b.saddle.up
a.saddle.up = 9999
check('writing to one profile does not affect the next',
      shared.profileFor(nil).saddle.up == baseline,
      shared.profileFor(nil).saddle.up)

-- Same hazard on the known-type path: PROFILE's own tables are module-level.
local guarType = shared.MOUNT_TYPE and shared.MOUNT_TYPE.GUAR
if guarType then
    local g1 = shared.profileFor(guarType)
    local before = g1.saddle.up
    g1.saddle.up = -1
    check('writing to a known profile does not affect the next',
          shared.profileFor(guarType).saddle.up == before,
          shared.profileFor(guarType).saddle.up)
end

-- ---------------------------------------------------------------------------
-- THE COMPILED CREATURE PROFILE
-- ---------------------------------------------------------------------------
-- 917 CREA records from Morrowind, Tribunal, Bloodmoon, Tamriel Data and
-- OAAB, baked into whywalk_creatures.lua by tools/gen_creatures.py. Two jobs:
-- where a rider sits, and whether the creature may be ridden at all.
--
-- These assertions are against the SHIPPED table, not a mock. The point of
-- generating it is that the numbers are real; a mock would test the
-- arithmetic and nothing about the data.

local creatures = require('scripts.WhyWalk.whywalk_creatures')

check('the table covers the whole compiled profile',
      creatures.COUNT > 900, creatures.COUNT)
check('and shares shapes rather than repeating them',
      #creatures.SHAPES < creatures.COUNT / 5,
      ('%d shapes for %d creatures'):format(#creatures.SHAPES, creatures.COUNT))

check('get is case-insensitive, since record ids arrive lower-cased',
      creatures.get('Guar') ~= nil and creatures.get('guar') ~= nil)
check('and returns nil for a creature nobody compiled',
      creatures.get('detd_guarride1') == nil)
check('and does not fall over on a nil id', creatures.get(nil) == nil)

-- ------------------------------------------------------------- rideability
check('a guar may be ridden', creatures.get('guar').ride == true)
check('a dremora may not: biped and armed',
      creatures.get('dremora').ride == false)
check('nor a golden saint', creatures.get('golden saint').ride == false)
check('a scamp may be: not a biped by the record',
      creatures.get('scamp').ride == true)

check('barredFromRiding agrees with the table',
      shared.barredFromRiding('dremora') == true
      and shared.barredFromRiding('guar') == false)
check('and says why', select(2, shared.barredFromRiding('dremora')) ~= nil)

-- THE LIVE RECORD IS THE AUTHORITY for anything the profile never saw, which
-- is every mount a riding mod adds. Without this a mod-added biped would be
-- rideable purely because nobody compiled it.
check('a live biped record is barred even when the table has never seen it',
      shared.barredFromRiding('some_mod_biped', { isBiped = true }) == true)
check('so is a live weapon carrier',
      shared.barredFromRiding('some_mod_brute', { canUseWeapons = true }) == true)
check('a live record that is neither is allowed',
      shared.barredFromRiding('some_mod_beast',
          { isBiped = false, canUseWeapons = false }) == false)
check('the live record WINS over a table entry that allows it',
      shared.barredFromRiding('guar', { isBiped = true }) == true)

check('isBlacklisted refuses a biped too, so one gate covers both',
      shared.isBlacklisted('dremora') == true)
check('and still lets an ordinary creature through',
      shared.isBlacklisted('guar') == false)

-- ------------------------------------------------------------- ride height
local guar = shared.saddleFromProfile('guar')
check('a known creature gets a saddle from the compiled box',
      guar ~= nil and guar.up > 100 and guar.up < 180, guar and guar.up)
check('with forward left at zero, as the box-derived one is',
      guar.forward == 0 and guar.right == 0)
check('an unknown creature gets nil, so the box read still happens',
      shared.saddleFromProfile('detd_guarride1') == nil)

-- A FLIER IS MEASURED FROM THE BOTTOM OF ITS BOX. A netch's box starts 348
-- units above its origin and the rider hangs under the bell; the walker rule
-- would seat them 660 units up, inside the sky.
local netch = creatures.get('netch_bull')
check('a netch is flagged as flying', netch.fly == true)
check('and its ride height is the bottom of its box, not a fraction of the top',
      netch.up > 300 and netch.up < 400, netch.up)

-- A flier whose box starts at ground level is a flier in name only.
local racer = creatures.get('cliff racer')
check('a cliff racer, whose box starts at zero, uses the walker rule',
      racer.fly == true and racer.up > 100, racer and racer.up)

-- THE PROFILE STILL WINS. Its values came from the riding mods' own configs;
-- the compiled figure is derived from a bounding box and lands near them, not
-- on them.
local T = shared.MOUNT_TYPE
check('PROFILE keeps its measured guar saddle',
      shared.profileFor(T.GUAR).saddle.up == 130,
      shared.profileFor(T.GUAR).saddle.up)
check('and the compiled figure is close to it without replacing it',
      math.abs(creatures.get('guar').up - 130) < 20,
      creatures.get('guar').up)

print(('\n%d passed, %d failed'):format(pass, fail))
if fail > 0 then os.exit(1) end
print('ALL PASS')
