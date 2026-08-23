-- Offline check of the heading -> atlas frame mapping.
-- Reimplements tileForHeading exactly as BSC_p.lua has it, then verifies it
-- against the needle angles measured out of BSCompasAtlas.png.

local fails, checks = 0, 0
local function check(cond, msg)
	checks = checks + 1
	if not cond then fails = fails + 1; print('  FAIL: ' .. msg) end
end

local TILES = 36
local INVERT_ROTATION = false
local HEADING_OFFSET = 0

local function tileForHeading(deg, n, invert, offset)
	n = n or TILES
	local step = 360 / n
	local raw = math.floor((deg + (offset or 0)) / step + 0.5)
	if invert then return raw % n end
	return (n - raw) % n
end

-- Measured from BSCompasAtlas.png: on-screen angle of the long needle arm for
-- every frame, in degrees where 0 = right and 90 = up. Taken as the principal
-- axis of the needle pixels, which is stable to about a degree.
local MEASURED = {
	[0] = -91.7, [1] = -100.4, [2] = -110.1, [3] = -120.3, [4] = -131.0, [5] = -139.8,
	[6] = -149.2, [7] = -160.4, [8] = -171.6, [9] = 178.6, [10] = 169.9, [11] = 159.6,
	[12] = 150.1, [13] = 140.2, [14] = 130.1, [15] = 119.8, [16] = 109.7, [17] = 99.6,
	[18] = 90.1, [19] = 80.9, [20] = 70.6, [21] = 59.1, [22] = 48.2, [23] = 39.5,
	[24] = 30.6, [25] = 21.7, [26] = 10.5, [27] = 0.7, [28] = -10.1, [29] = -20.3,
	[30] = -30.6, [31] = -40.3, [32] = -50.0, [33] = -60.1, [34] = -71.1, [35] = -81.2,
}

local function angdiff(a, b)
	local d = (a - b) % 360
	if d > 180 then d = d - 360 end
	return d
end

print('=== 1. the atlas rotates clockwise, 10 deg per frame ===')
local total, worst = 0, 0
for t = 1, 35 do
	local d = angdiff(MEASURED[t], MEASURED[t - 1])
	total = total + d
	if math.abs(d + 10) > math.abs(worst + 10) then worst = d end
	check(math.abs(d - (-10)) < 3,
		string.format('frame %d->%d turned %.1f deg, expected -10', t - 1, t, d))
end
-- and the wrap back to frame 0 closes the circle
total = total + angdiff(MEASURED[0], MEASURED[35])
print(string.format('  mean %.2f deg per frame, worst %.1f, full loop %.1f deg',
	total / 36, worst, total))
check(math.abs(total + 360) < 6, 'the 36 frames close a full 360, got ' .. string.format('%.1f', total))

print('=== 2. basic mapping ===')
check(tileForHeading(0) == 0, 'north is frame 0')
check(tileForHeading(360) == 0, '360 wraps to frame 0')
check(tileForHeading(355) == 0, '355 rounds into frame 0')
check(tileForHeading(5) == 35, '5 deg rounds to frame 35')
for d = 0, 359 do
	local t = tileForHeading(d)
	if t < 0 or t >= TILES then
		check(false, 'frame out of range at ' .. d)
	end
end
check(true, 'all 360 headings map inside 0..35')

print('=== 3. every frame is reachable, and each covers 10 degrees ===')
local seen, counts = {}, {}
for d = 0, 359 do
	local t = tileForHeading(d)
	seen[t] = true
	counts[t] = (counts[t] or 0) + 1
end
local n = 0
for _ in pairs(seen) do n = n + 1 end
check(n == TILES, 'all 36 frames reachable, got ' .. n)
local uneven = 0
for t = 0, TILES - 1 do if counts[t] ~= 10 then uneven = uneven + 1 end end
check(uneven == 0, 'each frame covers exactly 10 degrees, ' .. uneven .. ' did not')

print('=== 4. a world-fixed marker counter-rotates ===')
-- This is the actual correctness condition. Turn the player clockwise and the
-- needle must swing counter-clockwise on screen by the same amount.
local bad = 0
for d = 0, 350, 10 do
	local t1 = tileForHeading(d)
	local t2 = tileForHeading((d + 90) % 360)
	local a1 = MEASURED[t1]
	local a2 = MEASURED[t2]
	if a1 and a2 then
		local swing = angdiff(a2, a1)
		-- player turned +90 (right), so the needle must go +90 on screen
		if math.abs(swing - 90) > 4 then
			bad = bad + 1
			print(string.format('    heading %d: frames %d->%d, needle swung %.1f (want +90)', d, t1, t2, swing))
		end
	end
end
check(bad == 0, 'needle counter-rotates correctly at every sampled heading')

print('=== 5. the four cardinals, spelled out ===')
-- Long arm points SOUTH on this artwork (frame 0 = facing north = arm down).
local CARD = { { 0, 'north', -91.7 }, { 90, 'east', 0.7 }, { 180, 'south', 90.1 }, { 270, 'west', 178.6 } }
for _, c in ipairs(CARD) do
	local t = tileForHeading(c[1])
	local a = MEASURED[t]
	check(a ~= nil and math.abs(angdiff(a, c[3])) < 1,
		string.format('facing %s -> frame %d, needle at %.1f', c[2], t, a or 0))
	-- the long arm indicates south, so on screen it must sit at
	-- (180 - heading) measured from 'right', i.e. south relative to the player
	local expected = 90 - (180 - c[1])
	check(math.abs(angdiff(a, expected)) < 3,
		string.format('facing %s: arm should be at %.0f for a south indicator, is %.1f',
			c[2], expected, a))
	print(string.format('  facing %-5s -> frame %2d, long arm at %6.1f deg', c[2], t, a or 0))
end
print('  (long arm points south: down when facing north, up when facing south,')
print('   right when facing east, left when facing west. Consistent.)')

print('=== 5b. full 360 sweep, needle tracks south exactly ===')
local sweepBad, worstErr = 0, 0
for d = 0, 350, 10 do
	local t = tileForHeading(d)
	local a = MEASURED[t]
	local expected = 90 - (180 - d)
	local err = math.abs(angdiff(a, expected))
	if err > worstErr then worstErr = err end
	if err > 3 then sweepBad = sweepBad + 1 end
end
print(string.format('  worst deviation across all 36 headings: %.1f deg', worstErr))
check(sweepBad == 0, 'south indicator holds across the full sweep, ' .. sweepBad .. ' off')

print('=== 6. inverted mapping is the mirror ===')
for d = 0, 350, 10 do
	local a = tileForHeading(d, 36, false)
	local b = tileForHeading(d, 36, true)
	check((a + b) % 36 == 0, 'invert mirrors at ' .. d)
end

print('=== 7. heading offset ===')
check(tileForHeading(0, 36, false, 10) == 35, '+10 offset shifts one frame')
check(tileForHeading(0, 36, false, -10) == 1, '-10 offset shifts the other way')

print('=== 8. other tile counts ===')
for _, n in ipairs({ 4, 8, 16, 32, 64, 360 }) do
	local s = {}
	for d = 0, 359 do s[tileForHeading(d, n)] = true end
	local c = 0
	for _ in pairs(s) do c = c + 1 end
	check(c == n, n .. '-frame atlas uses all its frames, got ' .. c)
end

print('')
print(string.format('%d checks, %d failures', checks, fails))
os.exit(fails == 0 and 0 or 1)
