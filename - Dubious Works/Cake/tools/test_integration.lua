-- test_integration.lua -- CAKE's global, player and NPC scripts plus the real
-- AnimRefresh v6, on the simulated engine in mock_openmw.lua.
--   lua tools/test_integration.lua        (from the package root; 5.1-5.4 or LuaJIT)
package.path = './tools/?.lua;' .. package.path
local W = require('mock_openmw')
local ROOT = (os.getenv('CAKE_ROOT') or '.') .. '/00 Core/'

local fails, total = 0, 0
local function check(name, ok, detail)
    total = total + 1
    if ok then print('  ok   ' .. name)
    else fails = fails + 1; print('  FAIL ' .. name .. (detail ~= nil and ('  [' .. tostring(detail) .. ']') or '')) end
end

local shared = dofile(ROOT .. 'scripts/cake/cake_shared.lua')
W.shared = shared

local DBS = { 'Bip01 beltDBS', 'Bip01 L hipDBS', 'Bip01 mouthDBS', 'Bip01 eyesDBS', 'Bip01 scarfDBS' }

local function setup(opts)
    opts = opts or {}
    W.reset()
    for base, e in pairs(shared.ITEMS) do
        W.records[base] = { model = 'meshes/cake/' .. base .. '.nif' }
        W.records[e.eq] = { model = 'meshes/cake/' .. e.eq .. '.nif' }
    end
    local player = W.newActor('player', { bones = opts.bones or DBS })
    W.player = player
    W.global = W.load('scripts/cake/cake_global.lua')
    W.load('scripts/AnimRefresh/AnimRefresh_v6.lua', player)
    local P = W.load('scripts/cake/cake_player.lua', player)
    W.call(P, 'onInit')
    W.call(P, 'onActive')
    W.run(0.5)
    return player, P
end

local function pick(category, n)
    local ids = {}
    for base, e in pairs(shared.ITEMS) do if e.category == category then ids[#ids + 1] = base end end
    table.sort(ids)
    return ids[n or 1]
end

local function wear(actor, base)
    local it = actor.inventory:find(base) or W.give(actor, base)
    W.use(it, actor)
    W.run(0.3)
end

local function vfxCount(a) local n = 0; for _ in pairs(a.vfx) do n = n + 1 end; return n end

-- --------------------------------------------------------------------------
print('registry')
local n = 0
for base, e in pairs(shared.ITEMS) do
    n = n + 1
    assert(shared.CATEGORIES[e.category], base)
    assert(shared.baseOf(e.eq) == base, base)
end
check('128 pairs, every one reversible', n == 128, n)
check('skinned Argonian scarves are not registered (they would draw nothing)',
      shared.get('dbs_ADMScarfBlack') == nil and shared.baseOf('dbs_A_ScarfBlack_eq') == nil)
check('ids match case-insensitively', shared.get('DBS_RV_Ashmask1_H') ~= nil)
check('an unknown id is not an item', shared.get('iron dagger') == nil and shared.baseOf('x_eq') == nil)

-- --------------------------------------------------------------------------
print('wearing')
local player, P = setup()
local mask, mask2, cigar = pick('masks', 1), pick('masks', 2), pick('smokes', 1)
local scarf, lantern = pick('scarves', 1), pick('lanterns', 1)
check('nothing worn: not subscribed to AnimRefresh', W.interfaces.AnimRefresh ~= nil
      and next(P.ret.interface.getWorn()) == nil and vfxCount(player) == 0)

wear(player, mask)
check('using a base record swaps it for the worn one',
      player.inventory:countOf(mask) == 0 and player.inventory:countOf(shared.ITEMS[mask].eq) == 1)
check('the state follows the use', P.ret.interface.getWorn().masks == mask)
check('the mask is drawn on its DBS bone',
      player.vfx.cake_masks and player.vfx.cake_masks.bone == 'Bip01 mouthDBS')
check('the model comes from the record, as a VFS path',
      player.vfx.cake_masks and player.vfx.cake_masks.model == W.records[shared.ITEMS[mask].eq].model)

wear(player, scarf); wear(player, lantern)
check('three categories at once', vfxCount(player) == 3, vfxCount(player))

wear(player, mask2)
check('swapping within a category returns the old one to the bag',
      player.inventory:countOf(mask) == 1 and player.inventory:countOf(shared.ITEMS[mask].eq) == 0)
check('and draws the new one', player.vfx.cake_masks.model == W.records[shared.ITEMS[mask2].eq].model)

wear(player, cigar)
check('a conflicting category takes the mask off',
      player.inventory:countOf(mask2) == 1 and player.inventory:countOf(shared.ITEMS[mask2].eq) == 0)
check('the cleared category leaves the state at once (no audit needed)',
      P.ret.interface.getWorn().masks == nil and P.ret.interface.getWorn().smokes == cigar)
check('and is no longer drawn', player.vfx.cake_masks == nil and player.vfx.cake_smokes ~= nil)

-- a second worn record of the same category does not survive a swap
local mask3 = pick('masks', 3)
W.give(player, shared.ITEMS[mask].eq); W.give(player, shared.ITEMS[mask3].eq)   -- looted
check('looting a worn record does not wear it', P.ret.interface.getWorn().masks == nil)
wear(player, mask2)
check('wearing converts every stray worn record of that category back',
      player.inventory:countOf(shared.ITEMS[mask].eq) == 0 and player.inventory:countOf(shared.ITEMS[mask3].eq) == 0
      and player.inventory:countOf(mask) == 2 and player.inventory:countOf(mask3) == 1,
      player.inventory:countOf(mask) .. '/' .. player.inventory:countOf(mask3))

W.use(player.inventory:find(shared.ITEMS[scarf].eq), player); W.run(0.3)
check('using a worn record takes it off',
      player.inventory:countOf(scarf) == 1 and P.ret.interface.getWorn().scarves == nil
      and player.vfx.cake_scarves == nil)

-- --------------------------------------------------------------------------
print('model rebuilds (AnimRefresh v6)')
-- worn now: a mask and a lantern
local calls0 = player.addVfxCalls
W.camera.mode = 1; W.rebuild(player, 0)
W.run(0.5)
check('first person hides everything by default', vfxCount(player) == 0, vfxCount(player))
W.camera.mode = 2; W.rebuild(player, 0)
W.run(0.5)
check('third person draws it all again', vfxCount(player) == 2, vfxCount(player))

-- the skeleton not answering yet: draw returns false, AnimRefresh retries
W.camera.mode = 1; W.run(0.5)
W.camera.mode = 2; W.rebuild(player, 0.15)
W.run(0.12)
check('not drawn while the skeleton is not answering', vfxCount(player) == 0, vfxCount(player))
W.run(0.5)
check('drawn by the retry once it answers', vfxCount(player) == 2, vfxCount(player))

-- a rebuild that lands after the delivery: only the verify pass can recover it
W.camera.mode = 1; W.run(0.5); W.camera.mode = 2; W.run(0.4)
W.rebuild(player, 0)
check('a late rebuild drops the attachments', vfxCount(player) == 0)
W.run(2.0)
check('the verify delivery 1.8 s later puts them back', vfxCount(player) == 2, vfxCount(player))

local storage = W.section('Settings_cake_main')
W.camera.mode = 1; W.rebuild(player, 0); W.run(0.5)
storage:set('SHOWFIRSTPERSON', true); W.run(0.2)
check('the first-person setting applies without a perspective change', vfxCount(player) == 2)
storage:set('SHOWFIRSTPERSON', false); W.run(0.2)
W.camera.mode = 2; W.rebuild(player, 0); W.run(0.5)
check('settled back in third person', vfxCount(player) == 2)
local drawsPerSwitch = player.addVfxCalls - calls0
print(('       (%d attaches across the run above)'):format(drawsPerSwitch))

-- --------------------------------------------------------------------------
print('missing bones')
local p2, P2 = setup({ bones = { 'Bip01 mouthDBS' } })
wear(p2, pick('lanterns', 1))
check('no DBS bone: the lantern uses its vanilla fallback',
      p2.vfx.cake_lanterns and p2.vfx.cake_lanterns.bone == 'Bip01 Pelvis')
check('subscribed while something is worn', P2.ret.interface.getWorn().lanterns ~= nil)

-- --------------------------------------------------------------------------
print('the bag audits the state')
player, P = setup()
wear(player, mask); wear(player, scarf)
local eqItem = player.inventory:find(shared.ITEMS[scarf].eq)
eqItem:teleport(W.cell, { x = 0, y = 0, z = 0 })        -- dropped in the inventory menu
W.event(P, 'UiModeChanged', { oldMode = 'Interface', newMode = nil }); W.run(0.2)
check('closing a menu drops an entry whose record left the bag',
      P.ret.interface.getWorn().scarves == nil and P.ret.interface.getWorn().masks == mask)
check('and stops drawing it', player.vfx.cake_scarves == nil and player.vfx.cake_masks ~= nil)
local loose = W.cell.objects[1]
check('the dropped worn record is converted back on the ground',
      loose and loose.recordId == scarf, loose and loose.recordId)

local before = #W.cell.objects
W.event(P, 'UiModeChanged', { oldMode = 'Interface', newMode = nil }); W.run(0.2)
check('a clean audit does not sweep the cell', #W.cell.objects == before)

W.use(player.inventory:find(shared.ITEMS[mask].eq), player); W.run(0.3)
check('nothing worn: unsubscribed and nothing drawn',
      next(P.ret.interface.getWorn()) == nil and vfxCount(player) == 0)
local t0 = W.timerCount()
W.camera.mode = 1; W.run(1); W.camera.mode = 2; W.run(1)
check('nothing worn: a perspective change schedules nothing', W.timerCount() <= t0)

-- --------------------------------------------------------------------------
print('saving and loading')
player, P = setup()
wear(player, mask); wear(player, lantern)
local saved = W.call(P, 'onSave')
local p3 = W.newActor('player', { bones = DBS })
W.reset()
for base, e in pairs(shared.ITEMS) do
    W.records[base] = { model = 'meshes/cake/' .. base .. '.nif' }
    W.records[e.eq] = { model = 'meshes/cake/' .. e.eq .. '.nif' }
end
W.give(p3, shared.ITEMS[mask].eq); W.give(p3, shared.ITEMS[lantern].eq)
W.load('scripts/cake/cake_global.lua')
local AR = W.load('scripts/AnimRefresh/AnimRefresh_v6.lua', p3)
P = W.load('scripts/cake/cake_player.lua', p3)
W.call(P, 'onLoad', saved); W.call(AR, 'onLoad'); W.call(P, 'onActive')
W.run(0.5)
check('a load restores the state', P.ret.interface.getWorn().masks == mask
      and P.ret.interface.getWorn().lanterns == lantern)
check('and draws it once AnimRefresh delivers', vfxCount(p3) == 2, vfxCount(p3))
W.call(P, 'onLoad', { worn = { masks = 'not_an_item', nonsense = mask } })
check('a load drops unknown entries', next(P.ret.interface.getWorn()) == nil)
W.call(P, 'onLoad', nil)
check('a load tolerates no saved data', next(P.ret.interface.getWorn()) == nil)

-- --------------------------------------------------------------------------
print('NPCs')
player, P = setup()
local npcA = W.newActor('npc', { bones = DBS })
local npcB = W.newActor('npc', { bones = {} })
local npcC = W.newActor('npc', { bones = DBS })
W.give(npcA, shared.ITEMS[mask].eq); W.give(npcA, shared.ITEMS[scarf].eq)
W.give(npcA, shared.ITEMS[mask2].eq)                       -- a second mask: one per category
W.give(npcB, shared.ITEMS[lantern].eq)
W.give(npcC, mask)                                         -- carried, not worn
W.world.activeActors = { player, npcA, npcB, npcC }
local g = W.global
W.call(g, 'onActorActive', npcA); W.call(g, 'onActorActive', npcB); W.call(g, 'onActorActive', npcC)
W.run(0.2)
check('an NPC wearing worn records gets the script', npcA:hasScript('scripts/cake/cake_npc.lua'))
check('an NPC carrying only bag forms gets nothing', not npcC:hasScript('scripts/cake/cake_npc.lua'))
check('the NPC draws one item per category', vfxCount(npcA) == 2 and npcA.vfx.cake_masks.bone == 'Bip01 mouthDBS',
      vfxCount(npcA))
check('an NPC without the DBS bones uses the fallback',
      npcB.vfx.cake_lanterns and npcB.vfx.cake_lanterns.bone == 'Bip01 Pelvis')

local section = W.section('Settings_cake_main')
section:set('SHOWNPCS', false); W.run(0.3)
check('turning NPC display off clears active NPCs at once', vfxCount(npcA) == 0 and vfxCount(npcB) == 0)
check('and detaches their scripts', not npcA:hasScript('scripts/cake/cake_npc.lua'))
section:set('SHOWNPCS', true); W.run(0.3)
check('turning it back on draws them again', vfxCount(npcA) == 2 and vfxCount(npcB) == 1)

W.call(g, 'onActorActive', npcA); W.run(0.2)
check('re-activation redraws without a second script', vfxCount(npcA) == 2)
check('the player is never handled as an NPC', not player:hasScript('scripts/cake/cake_npc.lua'))

print(fails == 0 and ('ALL PASS (%d)'):format(total) or ('%d of %d FAILED'):format(fails, total))
if fails > 0 then os.exit(1) end
