-- Drives the real g_scarves/p_scarves against a mocked Sun's Dusk environment.
local SETTINGS='sdfix/Scarves/scripts/SunsDusk/settings/'
local GLOBALM='sdfix/Scarves/scripts/SunsDusk/global_modules/'
local PLAYERM='sdfix/Scarves/scripts/SunsDusk/player_modules/'
local fails=0
local function check(n,c,e) if c then print('  ok   '..n) else fails=fails+1; print('  FAIL '..n..' '..tostring(e or '')) end end

local world_={vfx={},bones={},spells={},created={},events={},files={}}
local inv={}
local recs={}
local function mk(id)
  local m='meshes/rv/'..id..'.nif'
  recs[id]={id=id,model=m}; world_.files[m]=true
  local it; it={recordId=id,count=1,
    split=function(s,n) s.count=s.count-n; return mk(id) end,
    remove=function(s) for i,x in ipairs(inv) do if x==s then table.remove(inv,i) break end end end}
  return it
end
local function add(id) local i=mk(id); inv[#inv+1]=i; return i end
local function has(id) for _,x in ipairs(inv) do if x.recordId==id then return x end end end

-- Sun's Dusk shared environment
local env={}
env.types={Miscellaneous={record=function(o) return recs[type(o)=='string' and o or o.recordId] end,
                          records=setmetatable({},{__index=function(_,k) return recs[k] end})},
           Player={objectIsInstance=function(a) return a and a.isPlayer==true end},
           Actor={inventory=function() return {getAll=function() return inv end,
                                               find=function(_,id) return has(id) end} end},
           Container={content=function() return {getAll=function() return {} end} end},
           NPC={}, Creature={}}
env.world={createObject=function(id,c) world_.created[#world_.created+1]=id
    local it=mk(id)
    return {moveInto=function() inv[#inv+1]=it end, teleport=function() end} end}
env.util={vector3=function(x,y,z) return {x=x,y=y,z=z} end}
local itemHandlers={}
env.I={ItemUsage={addHandlerForType=function(_,fn) itemHandlers[#itemHandlers+1]=fn end}}
env.animation={removeVfx=function(_,id) for b,v in pairs(world_.vfx) do if v==id then world_.vfx[b]=nil end end end,
  addVfx=function(_,m,o)
    assert(m:sub(1,7)=='meshes/','addVfx got a non-VFS path: '..tostring(m))
    assert(world_.files[m],'addVfx got a path not in the VFS: '..tostring(m))
    world_.vfx[o.boneName]=o.vfxId end,
  hasBone=function(_,b) return world_.bones[b]==true end}
env.core={magic={spells={records=setmetatable({},{__index=function(_,k)
      return (k:find('^sd_scarf_w') or k:find('^sd_mask_blight_')) and {id=k} or nil end})}},
  sendGlobalEvent=function(n,d) world_.events[#world_.events+1]={n=n,d=d} end}
env.async={newUnsavableSimulationTimer=function(_,_,f) f() end}
env.self={isPlayer=true}
env.saveData={}
env.typesActorSpellsSelf={add=function(_,id) world_.spells[id]=true end,
                          remove=function(_,id) world_.spells[id]=nil end}
env.typesActorInventorySelf={find=function(_,id) return has(id) end}
env.log=function() end
env.G_eventHandlers={}; env.G_onFrameJobsSluggish={}; env.G_onFrameJobs={}
env.G_onLoadJobs={}; env.G_UiModeChangedJobs={}; env.G_settingsChangedJobs={}
env.SCARVES_ENABLED=true; env.SCARVES_WARMTH=4
env.MASKS_ENABLED=true;  env.MASKS_BLIGHT_RES=30
env.math=math; env.table=table; env.ipairs=ipairs; env.pairs=pairs
env.tostring=tostring; env.print=print; env.type=type

local function run(f) local c=assert(loadfile(f,'t',env)); c() end
-- p_scarves now requires its settings file by module path, so the mock env
-- needs a `require` that resolves it the way Sun's Dusk's loader would.
env.require=function(path)
    if path=='scripts.SunsDusk.settings.scarves_settings' then
        -- player context: `world` is nil, so the file takes its registerPage
        -- branch. Stubbed here; the point is only that the call resolves.
        return true
    end
    error('unexpected require: '..tostring(path))
end
run(GLOBALM..'g_scarves.lua')
run(PLAYERM..'p_scarves.lua')

for _,b in ipairs({'Bip01 scarfDBS','Bip01 mouthDBS','Bip01 Neck','head'}) do world_.bones[b]=true end

local onUse=itemHandlers[1]
local player={isPlayer=true, sendEvent=function(_,n,d)
    local h=env.G_eventHandlers[n]; if h then h(d) end end}

print('equip swap')
check('one ItemUsage handler registered', #itemHandlers==1)
local scarf=add('dbs_rv_scarf_01')
onUse(scarf, player)
check('base scarf consumed, _eq created',
      has('dbs_rv_scarf_01')==nil and has('dbs_rv_scarf_01_eq')~=nil)
check('scarf vfx on the DBS scarf bone', world_.vfx['Bip01 scarfDBS']=='SD_scarfVfx')
check('scarf warmth granted as binary abilities',
      world_.spells['sd_scarf_w3']==true and world_.spells['sd_scarf_w1']==nil,
      'warmth 4 = bit 4 only')

print('categories are independent')
local mask=add('dbs_rv_ashmask1_h')
onUse(mask, player)
check('mask does not remove the scarf', has('dbs_rv_scarf_01_eq')~=nil)
check('both vfx present on their own bones',
      world_.vfx['Bip01 scarfDBS']~=nil and world_.vfx['Bip01 mouthDBS']~=nil)
check('mask grants blight resistance at the configured step',
      world_.spells['sd_mask_blight_30']==true)

print('replacement within a category')
local scarf2=add('dbs_rv_scarf_05')
onUse(scarf2, player)
check('second scarf returns the first to the inventory',
      has('dbs_rv_scarf_01')~=nil and has('dbs_rv_scarf_01_eq')==nil
      and has('dbs_rv_scarf_05_eq')~=nil)
check('mask untouched by a scarf swap', has('dbs_rv_ashmask1_h_eq')~=nil)

print('toggle off')
onUse(has('dbs_rv_scarf_05_eq'), player)
check('using a worn scarf takes it off', has('dbs_rv_scarf_05')~=nil)
check('warmth removed with the scarf', world_.spells['sd_scarf_w3']==nil)
check('blight resistance survives, it belongs to the mask',
      world_.spells['sd_mask_blight_30']==true)

print('settings')
env.SCARVES_WARMTH=7
local scarf3=add('dbs_rv_scarf_09'); onUse(scarf3, player)
check('warmth 7 sets bits 1+2+4', world_.spells['sd_scarf_w1'] and world_.spells['sd_scarf_w2']
      and world_.spells['sd_scarf_w3'] and not world_.spells['sd_scarf_w4'])
env.MASKS_BLIGHT_RES=50
env.G_settingsChangedJobs.sdScarves(nil,'MASKS_BLIGHT_RES')
check('changing blight % swaps to the right record',
      world_.spells['sd_mask_blight_50']==true and world_.spells['sd_mask_blight_30']==nil)
env.MASKS_ENABLED=false
env.G_settingsChangedJobs.sdScarves(nil,'MASKS_ENABLED')
check('disabling masks drops the ability', world_.spells['sd_mask_blight_50']==nil)
env.MASKS_ENABLED=true

print('item lost from inventory')
for i,x in ipairs(inv) do if x.recordId=='dbs_rv_ashmask1_h_eq' then table.remove(inv,i) break end end
world_.events={}
env.G_onFrameJobsSluggish[1]()
check('a worn item leaving the bag triggers the cell sweep',
      #world_.events==1 and world_.events[1].n=='SunsDuskScarves_convertInCell')
check('and its vfx is removed', world_.vfx['Bip01 mouthDBS']==nil)

print('fallback bone')
world_.bones['Bip01 scarfDBS']=nil
env.G_UiModeChangedJobs[1]({oldMode='Rest'})
check('scarf falls back to a vanilla bone when the DBS rig is absent',
      world_.vfx['Bip01 Neck']~=nil, 'a missing bone is a SILENT no-show')

print(fails==0 and 'ALL PASS' or (fails..' FAILURES'))
if fails>0 then os.exit(1) end
