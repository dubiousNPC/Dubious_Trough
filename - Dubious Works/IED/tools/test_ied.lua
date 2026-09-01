local DIR='iedfix/IED/scripts/show-all-weapons/'
local fails=0
local function check(n,c,e) if c then print('  ok   '..n) else fails=fails+1; print('  FAIL '..n..' '..tostring(e or '')) end end

local W={ShortBladeOneHand=0,LongBladeOneHand=1,LongBladeTwoHand=2,BluntOneHand=3,
         BluntTwoClose=4,BluntTwoWide=5,SpearTwoWide=6,AxeOneHand=7,AxeTwoHand=8,
         MarksmanBow=9,MarksmanCrossbow=10,MarksmanThrown=11,Arrow=12,Bolt=13}
local world={vfx={},bones={},equip={},stance=0,cfg={}}
local inv={}
local recs={}
local function mk(id,wtype,model) recs[id]={id=id,type=wtype,model=model or ('m/'..id..'.nif')}
    return {recordId=id,count=1,type=nil} end

local WeaponT={TYPE=W, record=function(o) return recs[o.recordId] end,
               objectIsInstance=function(o) return recs[o.recordId]~=nil end}
local ArmorT={TYPE={Shield=8}, record=function(o) return recs[o.recordId] end,
              objectIsInstance=function(o) return recs[o.recordId]~=nil end}
local invObj={getAll=function(_,t)
        local out={}
        for _,i in ipairs(inv) do
            local r=recs[i.recordId]
            local isArmor = r and r.type==ArmorT.TYPE.Shield and r.armor
            if (t==ArmorT and isArmor) or (t==WeaponT and not isArmor) then out[#out+1]=i end
        end
        return out end,
    countOf=function(_,id) local n=0 for _,i in ipairs(inv) do if i.recordId==id then n=n+i.count end end return n end}

package.preload['openmw.types']=function() return {
    Weapon=WeaponT, Armor=ArmorT,
    Actor={inventory=function() return invObj end,
           getEquipment=function() return world.equip end,
           getStance=function() return world.stance end,
           STANCE={Nothing=0,Weapon=1,Spell=2},
           EQUIPMENT_SLOT={CarriedRight='CR',CarriedLeft='CL'},
           hasEquipped=function(_,it) return world.equip.CR==it or world.equip.CL==it
               or world.ammoEquipped==it end},
} end
package.preload['openmw.vfs']=function() return {fileExists=function() return false end} end
package.preload['openmw.animation']=function() return {
    hasBone=function(_,b) return world.bones[b]==true end,
    addVfx=function(_,m,o)
        if world.vfx[o.boneName] then world.doubled=(world.doubled or 0)+1 end
        world.vfx[o.boneName]=o.vfxId end,
    removeVfx=function(_,id) for b,v in pairs(world.vfx) do if v==id then world.vfx[b]=nil end end end,
} end
package.preload['openmw.storage']=function() return {
    globalSection=function() return {get=function(_,k) return world.cfg[k] end} end } end
package.preload['openmw.interfaces']=function() return {} end
package.preload['scripts.show-all-weapons.bones']=function() return dofile(DIR..'bones.lua') end

local bones=dofile(DIR..'bones.lua')
local common=dofile(DIR..'common.lua')

print('bones.lua')
local shared=bones.sharedBones()
check('shared bones are computed, not listed',
      shared['Bip01 LongBladeOneHand']==true and shared['Bip01 Ammo']==true)
check('unshared bones are not flagged', shared['Bip01 ShortBladeOneHand']==nil)

for _,b in pairs({'Bip01 LongBladeOneHand','Bip01 ShortBladeOneHand','Bip01 AttachShield',
                  'Bip01 AxeTwoClose','Bip01 MarksmanBow','Bip01 AttachWeapon'}) do
    world.bones[b]=true
end

print('weapon sheathing clash')
-- equipped longsword, sheathed (engine owns Bip01 LongBladeOneHand);
-- inventory axe maps to the SAME bone
local sword=mk('longsword',W.LongBladeOneHand)
local axe  =mk('axe',W.AxeOneHand)
inv={sword,axe}
world.equip={CR=sword}; world.stance=0; world.doubled=0; world.vfx={}
common.handler(nil, sword, nil, false)
check('inventory axe does NOT stack on the engine-sheathed longsword',
      (world.doubled or 0)==0 and world.vfx['Bip01 LongBladeOneHand']==nil,
      'doubled='..tostring(world.doubled))

-- drawn: engine frees the bone, so the axe may use it
world.stance=1; world.doubled=0; world.vfx={}
common.handler(nil, sword, nil, true)
check('once the weapon is drawn the freed bone is reused',
      world.vfx['Bip01 LongBladeOneHand']=='saw_w_axe',
      tostring(world.vfx['Bip01 LongBladeOneHand']))

-- two inventory weapons that share a bone
inv={mk('ls2',W.LongBladeOneHand), mk('axe2',W.AxeOneHand)}
world.equip={}; world.stance=0; world.doubled=0; world.vfx={}
common.handler(nil, nil, nil, false)
check('two carried weapons sharing a bone do not overlap', (world.doubled or 0)==0,
      'doubled='..tostring(world.doubled))

print('shield sheathing clash')
local sh1=mk('shield1',nil); recs['shield1'].type=ArmorT.TYPE.Shield; recs['shield1'].armor=true
local sh2=mk('shield2',nil); recs['shield2'].type=ArmorT.TYPE.Shield; recs['shield2'].armor=true
inv={sh1,sh2}
world.equip={CL=sh1}; world.stance=0; world.doubled=0; world.vfx={}
common.handler(nil, nil, sh1, false)
check('carried shield does NOT stack on the engine-sheathed one',
      world.vfx['Bip01 AttachShield']==nil, tostring(world.vfx['Bip01 AttachShield']))
world.stance=1; world.vfx={}
common.handler(nil, nil, sh1, true)
check('with the shield drawn the back is free again',
      world.vfx['Bip01 AttachShield']~=nil)

print('settings')
inv={mk('ls3',W.LongBladeOneHand)}
world.equip={}; world.vfx={}; world.cfg={showWeapons=false}
common.handler(nil,nil,nil,false)
check('showWeapons=false hides carried weapons', next(world.vfx)==nil)
world.cfg={}
world.vfx={}
common.handler(nil,nil,nil,false)
check('absent config behaves as enabled, not disabled', next(world.vfx)~=nil)

print(fails==0 and 'ALL PASS' or (fails..' FAILURES'))
if fails>0 then os.exit(1) end
