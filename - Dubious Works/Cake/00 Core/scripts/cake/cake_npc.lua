---@omw-context local
--[[
    cake_npc.lua -- draws what cake_global says an NPC is wearing

    Attached by cake_global (CUSTOM in CAKE.omwscripts) only to NPCs that carry
    a worn CAKE record, with the list to draw as init data. Later lists arrive
    as Cake_Show. It loads no registry and keeps no state of its own: the
    global script re-sends the list whenever the NPC becomes active.
]]

local self = require('openmw.self')
local anim = require('openmw.animation')
local core = require('openmw.core')

local drawn = {}   -- vfxId -> true

local function show(list)
    for vfxId in pairs(drawn) do anim.removeVfx(self, vfxId) end
    drawn = {}
    for _, it in ipairs(list) do
        local bone = anim.hasBone(self, it.bone) and it.bone
                     or anim.hasBone(self, it.fallback) and it.fallback or nil
        if bone then
            anim.addVfx(self, it.model, { vfxId = it.vfxId, boneName = bone, loop = true,
                                          useAmbientLight = false })
            drawn[it.vfxId] = true
        end
    end
    if #list == 0 then core.sendGlobalEvent('Cake_NpcIdle', self.object) end
end

return {
    engineHandlers = {
        onInit = function(list) if list then show(list) end end,
    },
    eventHandlers = {
        Cake_Show = show,
    },
}
