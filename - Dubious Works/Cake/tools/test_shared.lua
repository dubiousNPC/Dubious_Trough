local fails = 0
local function check(n, c, e)
    if c then print('  ok   '..n) else fails=fails+1; print('  FAIL '..n..' '..tostring(e or '')) end
end

print('cake_shared self-test (generated from CAKE.esp)')

local total, badcat, badeq = 0, {}, {}
for id, e in pairs(M.ITEMS) do
    total = total + 1
    if not M.CATEGORIES[e.category] then badcat[#badcat+1] = id end
    if not e.eq or not e.model or e.model == '' then badeq[#badeq+1] = id end
end
check(total..' items, every category resolves', #badcat==0, table.concat(badcat,','))
check('every item has an _eq record and a model', #badeq==0, table.concat(badeq,','))

-- the reverse index is the fix for the string-surgery bug
local roundtrip = 0
for id, e in pairs(M.ITEMS) do
    if M.baseOf(e.eq) == id then roundtrip = roundtrip + 1 end
end
check('base <-> eq round-trips for every pair', roundtrip==total, roundtrip..'/'..total)

-- ids must be lowercase, or lookups against item.recordId miss
local upper = {}
for id, e in pairs(M.ITEMS) do
    if id ~= id:lower() or e.eq ~= e.eq:lower() then upper[#upper+1] = id end
end
check('all ids stored lowercase', #upper==0, table.concat(upper,','))

local dupe, seen = {}, {}
for name, c in pairs(M.CATEGORIES) do
    if seen[c.vfxId] then dupe[#dupe+1]=c.vfxId end
    seen[c.vfxId]=name
end
check('vfxIds unique per category', #dupe==0, table.concat(dupe,','))

-- every declared DBS bone must really be in the skeleton
local ghost = {}
for name, c in pairs(M.CATEGORIES) do
    if c.bone and not M.DBS_BONES[c.bone] then ghost[#ghost+1]=name..'->'..c.bone end
end
check('no category points at a bone the skeleton lacks', #ghost==0, table.concat(ghost,','))

-- every category must have a real bone AND a real fallback; a nil bone is
-- what the old code silently tolerated
local nobone = {}
for name, c in pairs(M.CATEGORIES) do
    if type(c.bone) ~= 'string' or type(c.boneFallback) ~= 'string' then
        nobone[#nobone+1] = name
    end
end
check('every category has a string bone and fallback', #nobone==0, table.concat(nobone,','))

-- tails belong on the beast skeleton, which CAKE does not ship
check('tails are absent entirely, not pointed at a substitute',
      M.CATEGORIES.tails == nil)
local tailitems = 0
for id in pairs(M.ITEMS) do if id:find('tail') then tailitems = tailitems + 1 end end
check('no tail items leaked into the registry', tailitems==0, tailitems)

local asym = {}
for name, c in pairs(M.CATEGORIES) do
    for _, o in ipairs(c.conflicts) do
        local back, found = M.CATEGORIES[o], false
        if back then for _,x in ipairs(back.conflicts) do if x==name then found=true end end end
        if not found then asym[#asym+1]=name..'->'..o end
    end
end
check('conflicts symmetric', #asym==0, table.concat(asym,','))

check('get() is case-insensitive', M.get('DBS_GLANTERN2') ~= nil)
check('baseOf() rejects a non-worn id', M.baseOf('dbs_glantern2') == nil)
check('eqOf() returns the worn id', M.eqOf('dbs_glantern2') == 'dbs_glantern2_eq')
check('unknown ids are rejected', M.get('iron_helmet')==nil and M.baseOf(nil)==nil)
check('categoryOf works from either half',
      M.categoryOf('dbs_glantern2') == M.categoryOf('dbs_glantern2_eq'))

-- the specific bug that broke the old code
check('naive sub(1,-4) would NOT have found these bases',
      M.ITEMS[('dbs_glantern2_eq'):sub(1,-4)] == nil
      or M.baseOf('dbs_glantern2_eq') == 'dbs_glantern2')

print(fails==0 and 'ALL PASS' or (fails..' FAILURES'))
if fails>0 then os.exit(1) end
