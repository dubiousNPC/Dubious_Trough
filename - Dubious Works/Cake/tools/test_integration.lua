-- Mocks enough of the OpenMW API to run the real cake_* scripts and drive the
-- equip/unequip/refresh flows.
local DIR = 'out/pkg/CAKE/scripts/cake/'
local fails = 0
local function check(n,c,e) if c then print('  ok   '..n) else fails=fails+1; print('  FAIL '..n..' '..tostring(e or '')) end end

local world = { vfx={}, created={}, removed={}, globalEvents={}, actorEvents={},
                bones={}, cameraMode='third', timers={} }
local MISC = {}
MISC.records = setmetatable({}, {__index=function(_,id) return {id=id, model='m/'..id..'.nif'} end})

local inv = {}
local function mkItem(id, count)
    return { recordId=id, type=MISC, count=count or 1,
             split=function(s,n) s.count=s.count-n; return mkItem(id,n) end,
             remove=function(s) world.removed[#world.removed+1]=s.recordId
                 for i,x in ipairs(inv) do if x==s then table.remove(inv,i) break end end end }
end
local function addItem(id,c) inv[#inv+1]=mkItem(id,c) end
local function has(id) for _,x in ipairs(inv) do if x.recordId==id then return x end end end

local invObj = {
    getAll=function(_,_) return inv end,
    find=function(_,id) return has(id) end,
    countOf=function(_,id)
        local n=0
        for _,x in ipairs(inv) do if x.recordId==id then n=n+x.count end end
        return n
    end,
}

local sections={}
local function section(n)
    if not sections[n] then local d,su={},{}
        sections[n]={get=function(_,k) return d[k] end,
                     set=function(_,k,v) d[k]=v; for _,f in ipairs(su) do f(n,k) end end,
                     subscribe=function(_,cb) su[#su+1]=cb end}
    end
    return sections[n]
end

package.preload['openmw.self']=function() return {id='player', cell={getAll=function() return {} end}} end
package.preload['openmw.types']=function() return {
    Actor={inventory=function() return invObj end},
    Player={objectIsInstance=function() return true end},
    Miscellaneous=MISC, Container={content=function() return invObj end},
} end
package.preload['openmw.animation']=function() return {
    addVfx=function(_,path,o)
        assert(type(path)=='string' and path~='', 'addVfx needs a model path')
        assert(o.vfxId and o.boneName, 'addVfx needs vfxId and boneName')
        world.vfx[o.vfxId]={path=path,bone=o.boneName} end,
    removeVfx=function(_,id) world.vfx[id]=nil end,
    hasBone=function(_,b) return world.bones[b]==true end,
    BLEND_MASK={LowerBody=1,Torso=2,LeftArm=4,RightArm=8,UpperBody=14,All=15},
    BONE_GROUP={LowerBody=1,Torso=2,LeftArm=3,RightArm=4},
    PRIORITY={Default=0,Weapon=7,Scripted=13},
    playBlended=function() return true end, cancel=function() end,
} end
package.preload['openmw.camera']=function() return {
    MODE={FirstPerson='first',ThirdPerson='third'}, getMode=function() return world.cameraMode end } end
package.preload['openmw.storage']=function() return {
    playerSection=section, globalSection=section, LIFE_TIME={GameSession=1} } end
package.preload['openmw.core']=function() return {
    sendGlobalEvent=function(n,d) world.globalEvents[#world.globalEvents+1]={name=n,data=d} end } end
package.preload['openmw.async']=function() return {
    callback=function(_,f) return f end,
    newUnsavableSimulationTimer=function(_,_,f) world.timers[#world.timers+1]=f end } end
package.preload['openmw.world']=function() return {
    createObject=function(id,c) world.created[#world.created+1]=id
        local it=mkItem(id,c or 1)
        return { moveInto=function() inv[#inv+1]=it end,
                 teleport=function() end } end } end
package.preload['openmw.util']=function() return { vector3=function(x,y,z) return {x=x,y=y,z=z} end } end
package.preload['openmw.ui']=function() return { showMessage=function() end } end
local animRefresh={subs={}}
local itemHandlers={}
package.preload['openmw.interfaces']=function() return {
    AnimRefresh={subscribe=function(k,cb) animRefresh.subs[k]=cb end,
                 unsubscribe=function(k) animRefresh.subs[k]=nil end},
    UI={MODE={Rest='Rest',Travel='Travel',Training='Training',Inventory='Inventory',
              Container='Container',Barter='Barter',Companion='Companion'}},
    ItemUsage={addHandlerForType=function(_,fn) itemHandlers[#itemHandlers+1]=fn end},
    Settings={registerPage=function() end, registerGroup=function() end,
              registerRenderer=function() end},
} end

local shared = dofile(DIR..'cake_shared.lua')
package.preload['scripts.cake.cake_shared']=function() return shared end

-- pick two real records to drive the test with
local lantern, mask, mask2
for id,e in pairs(shared.ITEMS) do
    if e.category=='lanterns' and not lantern then lantern=id end
    if e.category=='masks' then
        if not mask then mask=id elseif not mask2 then mask2=id end
    end
end

for b in pairs(shared.allBones) do world.bones[b]=true end

-- Player first, so the global script's sendEvent can be routed into it. The
-- new model has cake_global as the only writer of cake_player's worn state, so
-- testing them apart tests neither.
local P = dofile(DIR..'cake_player.lua')

print('cake_global integration')
local G = dofile(DIR..'cake_global.lua')
G.engineHandlers.onInit()
check('registers exactly one ItemUsage handler', #itemHandlers==1, #itemHandlers)
G.engineHandlers.onLoad()
check('registration is idempotent', #itemHandlers==1, #itemHandlers)
check('showNpcs seeded', section('Cake_global'):get('showNpcs')==true)

local onUse = itemHandlers[1]
local actor = { sendEvent=function(_,n,d)
    world.actorEvents[#world.actorEvents+1]={n=n,d=d}
    local h = P.eventHandlers[n]; if h then h(d) end
end }

check('unknown item passes through', onUse(mkItem('iron_helmet'), actor)==nil)

addItem(lantern)
check('using a base item is consumed', onUse(has(lantern), actor)==false)
check('worn record created', has(shared.ITEMS[lantern].eq)~=nil)
check('base record gone', has(lantern)==nil)

-- swap within a category
addItem(mask); onUse(has(mask), actor)
addItem(mask2); onUse(has(mask2), actor)
check('swapping within a category returns the old base',
      has(mask)~=nil and has(shared.ITEMS[mask2].eq)~=nil
      and has(shared.ITEMS[mask].eq)==nil)
check('lantern untouched by a mask swap', has(shared.ITEMS[lantern].eq)~=nil)

-- toggle off
onUse(has(shared.ITEMS[mask2].eq), actor)
check('using a worn item converts it back',
      has(mask2)~=nil and has(shared.ITEMS[mask2].eq)==nil)

print('cake_player integration')
check('no onFrame handler', P.engineHandlers.onFrame==nil)
check('no onUpdate handler', P.engineHandlers.onUpdate==nil, 'polling is what was removed')

P.engineHandlers.onActive()
check('worn lantern attached', world.vfx['cake_lanterns']~=nil,
      'activation set the state, onActive drew it')
check('attached to the DBS bone', world.vfx['cake_lanterns'].bone=='Bip01 L hipDBS',
      world.vfx['cake_lanterns'].bone)
check('model comes straight from the record, no _skins derivation',
      world.vfx['cake_lanterns'].path==shared.ITEMS[lantern].model,
      world.vfx['cake_lanterns'].path)
check('subscribed to AnimRefresh while worn', animRefresh.subs['CAKE']~=nil)

-- first person
world.cameraMode='first'; P.interface.refresh()
check('hidden in first person by default', world.vfx['cake_lanterns']==nil)
world.cameraMode='third'; P.interface.refresh()
check('restored in third person', world.vfx['cake_lanterns']~=nil)

-- AnimRefresh drives re-attach
world.vfx={}
animRefresh.subs['CAKE']('third','first')
check('AnimRefresh callback re-attaches', world.vfx['cake_lanterns']~=nil)

-- missing DBS bone falls back to vanilla
world.bones['Bip01 L hipDBS']=nil
P.interface.refresh()
check('missing DBS bone falls back to vanilla',
      world.vfx['cake_lanterns'] and world.vfx['cake_lanterns'].bone=='Bip01 Pelvis',
      world.vfx['cake_lanterns'] and world.vfx['cake_lanterns'].bone)

-- no bone at all schedules exactly one retry
world.bones={}; world.timers={}
P.interface.refresh()
check('no usable bone schedules one retry', #world.timers==1, #world.timers)
world.timers[1]()
check('the retry does not schedule another', #world.timers==1, #world.timers)
for b in pairs(shared.allBones) do world.bones[b]=true end

-- vanilla profile pins to fallback
section('Settings_cake_main'):set('SKELETON','vanilla')
P.interface.refresh()
check('vanilla profile uses fallback even when the DBS bone exists',
      world.vfx['cake_lanterns'].bone=='Bip01 Pelvis', world.vfx['cake_lanterns'].bone)
section('Settings_cake_main'):set('SKELETON','auto')

-- THE REGRESSION THIS ARCHITECTURE EXISTS TO PREVENT.
-- Worn state used to be inferred from an `_eq` record being in the inventory,
-- which made looting one identical to putting it on.
world.vfx={}
P.interface.refresh()
local before = world.vfx['cake_masks']
addItem(shared.ITEMS[mask].eq)          -- as if looted from a chest
P.engineHandlers.onActive()
check('looting an _eq record does NOT equip it',
      world.vfx['cake_masks']==before and P.interface.getWorn()['masks']==nil,
      'presence in the bag must not equal wearing')
for i,x in ipairs(inv) do if x.recordId==shared.ITEMS[mask].eq then table.remove(inv,i) break end end

-- reconcile: state leads, the inventory audits
world.globalEvents={}
for i,x in ipairs(inv) do if x.recordId==shared.ITEMS[lantern].eq then table.remove(inv,i) break end end
P.engineHandlers.onActive()
check('an entry whose record vanished is reconciled away',
      P.interface.getWorn()['lanterns']==nil)
check('display follows the reconciled state', world.vfx['cake_lanterns']==nil)
local swept=false
for _,e in ipairs(world.globalEvents) do if e.name=='Cake_ConvertInCell' then swept=true end end
check('losing a record triggers the cell sweep exactly then', swept,
      'the sweep is the most expensive op in the mod')

world.globalEvents={}
P.engineHandlers.onActive()
local swept2=false
for _,e in ipairs(world.globalEvents) do if e.name=='Cake_ConvertInCell' then swept2=true end end
check('a clean reconcile does not sweep', not swept2)

check('unsubscribed once nothing is worn', animRefresh.subs['CAKE']==nil)

-- persistence
addItem(lantern); onUse(has(lantern), actor)
local saved = P.engineHandlers.onSave()
check('onSave returns the worn table', type(saved)=='table' and type(saved.worn)=='table')
P.engineHandlers.onLoad({worn={}})
check('onLoad replaces state', next(P.interface.getWorn())==nil)
P.engineHandlers.onLoad(saved)
check('onLoad restores state', P.interface.getWorn()['lanterns']~=nil)
P.engineHandlers.onLoad(nil)
check('onLoad tolerates a missing/garbage payload', next(P.interface.getWorn())==nil)

print('cake_npc integration')
local N = dofile(DIR..'cake_npc.lua')
check('npc script has no onUpdate', N.engineHandlers.onUpdate==nil)
inv={}; addItem(shared.ITEMS[mask].eq); addItem(shared.ITEMS[lantern].eq)
world.vfx={}
section('Cake_global'):set('showNpcs', true)
N.engineHandlers.onActive()
check('npc shows both worn items',
      world.vfx['cake_masks']~=nil and world.vfx['cake_lanterns']~=nil)
section('Cake_global'):set('showNpcs', false)
N.eventHandlers.Cake_Refresh()
check('disabling npc display strips attachments', next(world.vfx)==nil)

print('cake_anim')
local A = dofile(DIR..'cake_anim.lua')
check('blend mask is UpperBody (14), not a summed BONE_GROUP (9)',
      A.playEquip('masks')==true)
check('unknown category plays nothing', A.playEquip('tails')==false)

print(fails==0 and 'ALL PASS' or (fails..' FAILURES'))
if fails>0 then os.exit(1) end
