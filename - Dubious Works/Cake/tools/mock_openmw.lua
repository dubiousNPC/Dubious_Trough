-- mock_openmw.lua -- a small simulated OpenMW for CAKE's tests.
--
-- Scripts are loaded as separate instances, each with its own `openmw.self`,
-- the way the engine runs them. Time is simulated: step(dt) fires due timers,
-- then delivers queued events, then runs onUpdate, in the engine's order
-- (LuaManager::update: processTimers -> events -> engine handlers -> onUpdate).
-- AnimRefresh v6 runs for real on top of it.
--
-- Where the engine fails loudly, so does the mock: addVfx on a bone the
-- actor does not have raises (Animation::addEffect: "Can't find bone"), and a
-- model that is not a `meshes/` VFS path raises too.

local M = {}

local ROOT = (os.getenv('CAKE_ROOT') or '.') .. '/00 Core/'

local clock, timers, queue = 0, {}, {}
local scripts = {}          -- every live script instance
local storageSections = {}

M.log = {}
local function note(s) M.log[#M.log + 1] = s end

-- --------------------------------------------------------------------------
-- objects and inventories
-- --------------------------------------------------------------------------
local nextId = 0
local records = {}          -- recordId -> { model = 'meshes/...' }
M.records = records

local function newInventory(owner)
    local inv = { items = {}, owner = owner, resolved = true }
    function inv:getAll(_type)
        local out = {}
        for _, it in ipairs(self.items) do if it.count > 0 then out[#out + 1] = it end end
        return out
    end
    function inv:countOf(id)
        local n = 0
        for _, it in ipairs(self.items) do if it.recordId == id:lower() then n = n + it.count end end
        return n
    end
    function inv:find(id)
        for _, it in ipairs(self.items) do if it.recordId == id:lower() and it.count > 0 then return it end end
    end
    function inv:isResolved() return self.resolved end
    return inv
end

local function detach(obj)
    if obj.inv then
        for i, it in ipairs(obj.inv.items) do
            if it == obj then table.remove(obj.inv.items, i) break end
        end
        obj.inv = nil
    end
    if obj.cellList then
        for i, it in ipairs(obj.cellList) do
            if it == obj then table.remove(obj.cellList, i) break end
        end
        obj.cellList = nil
    end
end

local function newObject(id, count, kind)
    nextId = nextId + 1
    local o = { id = nextId, recordId = id:lower(), count = count or 1, kind = kind or 'misc',
                valid = true, position = { x = 0, y = 0, z = 0 }, rotation = {} }
    function o:isValid() return self.valid end
    function o:remove(n)
        n = n or self.count
        self.count = self.count - n
        if self.count <= 0 then detach(self); self.valid = false end
    end
    function o:split(n)
        self.count = self.count - n
        local c = newObject(self.recordId, n, self.kind)
        c.inv = self.inv
        if self.inv then table.insert(self.inv.items, c) end
        return c
    end
    function o:moveInto(inv)
        detach(self)
        self.inv = inv
        table.insert(inv.items, self)
    end
    function o:teleport(cell, pos)
        detach(self)
        self.cellList = cell.objects
        self.position = pos
        table.insert(cell.objects, self)
    end
    function o:getBoundingBox()
        return { center = { x = 0, y = 0, z = 10 }, halfSize = { x = 1, y = 1, z = 1 } }
    end
    return o
end

M.cell = { objects = {}, containers = {} }
function M.cell:getAll(t)
    if t == M.ContainerType then return self.containers end
    local out = {}
    for _, o in ipairs(self.objects) do out[#out + 1] = o end
    return out
end

-- --------------------------------------------------------------------------
-- actors
-- --------------------------------------------------------------------------
local VANILLA = { 'Bip01 Pelvis', 'Bip01 Neck', 'Head', 'Bip01 Head', 'Bip01 Spine' }

function M.newActor(kind, opts)
    opts = opts or {}
    local a = newObject(opts.id or kind, 1, kind)
    a.cell = M.cell
    a.inventory = newInventory(a)
    a.bones = {}
    a.vfx = {}             -- vfxId -> { model, bone }
    a.addVfxCalls = 0
    a.attached = {}        -- script path -> instance
    a.ready = true
    for _, b in ipairs(VANILLA) do a.bones[b:lower()] = true end
    for _, b in ipairs(opts.bones or {}) do a.bones[b:lower()] = true end
    function a:sendEvent(name, data) queue[#queue + 1] = { target = self, name = name, data = data } end
    function a:hasScript(path) return self.attached[path] ~= nil end
    function a:addScript(path, init)
        assert(not self.attached[path], 'addScript: ' .. path .. ' already attached')
        self.attached[path] = M.load(path, self)
        M.call(self.attached[path], 'onInit', init)
    end
    function a:removeScript(path)
        assert(self.attached[path], 'removeScript: ' .. path .. ' not attached')
        self.attached[path].dead = true
        self.attached[path] = nil
    end
    return a
end

-- Simulate a model rebuild: every attached VFX is lost, and the skeleton is
-- not answering for `notReadyFor` seconds.
function M.rebuild(actor, notReadyFor)
    actor.vfx = {}
    if notReadyFor and notReadyFor > 0 then
        actor.ready = false
        M.after(notReadyFor, function() actor.ready = true end)
    end
end

-- --------------------------------------------------------------------------
-- time
-- --------------------------------------------------------------------------
function M.after(delay, fn)
    timers[#timers + 1] = { at = clock + delay, fn = fn }
end

function M.now() return clock end

local function deliver()
    local n = 0
    while #queue > 0 do
        local q = table.remove(queue, 1)
        n = n + 1
        assert(n < 10000, 'event storm')
        if q.target == 'global' then
            for _, s in ipairs(scripts) do
                if s.context == 'global' and not s.dead then M.event(s, q.name, q.data) end
            end
        else
            for _, s in ipairs(scripts) do
                if s.owner == q.target and not s.dead then M.event(s, q.name, q.data) end
            end
        end
    end
end

function M.step(dt)
    clock = clock + dt
    -- processTimers: a timer created by a timer with a deadline already past
    -- is popped in the same pass, as in the engine's while-loop over the heap.
    while true do
        local best
        for i, t in ipairs(timers) do
            if t.at <= clock and (not best or t.at < timers[best].at) then best = i end
        end
        if not best then break end
        local t = table.remove(timers, best)
        t.fn()
    end
    deliver()
    for _, s in ipairs(scripts) do
        if not s.dead then M.call(s, 'onUpdate', dt) end
    end
    deliver()
end

function M.run(seconds, dt)
    dt = dt or 1 / 30
    local stop = clock + seconds
    while clock < stop - 1e-9 do M.step(dt) end
end

-- --------------------------------------------------------------------------
-- engine packages
-- --------------------------------------------------------------------------
M.camera = { mode = 2, MODE = { Static = 0, FirstPerson = 1, ThirdPerson = 2, Vanity = 3, Preview = 4 } }
local cameraPkg = {
    MODE = M.camera.MODE,
    getMode = function() return M.camera.mode end,
}

local animPkg = {
    hasBone = function(actor, bone)
        local a = actor.object or actor
        return a.ready and a.bones[bone:lower()] == true
    end,
    addVfx = function(actor, model, opts)
        local a = actor.object or actor
        assert(type(model) == 'string' and model:sub(1, 7) == 'meshes/' and not model:find('\\', 1, true),
               'addVfx: not a VFS path: ' .. tostring(model))
        assert(a.ready and a.bones[opts.boneName:lower()], "Can't find bone " .. tostring(opts.boneName))
        local cur = a.vfx[opts.vfxId]
        -- Animation::addEffect returns early for a looping effect with the same id and bone.
        if cur and cur.bone == opts.boneName then return end
        a.vfx[opts.vfxId] = { model = model, bone = opts.boneName }
        a.addVfxCalls = a.addVfxCalls + 1
    end,
    removeVfx = function(actor, id)
        local a = actor.object or actor
        a.vfx[id] = nil
    end,
}

local function section(name)
    if not storageSections[name] then
        local s = { values = {}, subs = {} }
        function s:get(k) return self.values[k] end
        function s:set(k, v)
            self.values[k] = v
            for _, cb in ipairs(self.subs) do cb(name, k) end
        end
        function s:subscribe(cb) self.subs[#self.subs + 1] = cb end
        storageSections[name] = s
    end
    return storageSections[name]
end
M.section = section

local typesPkg = {
    Miscellaneous = { record = function(id) return records[id:lower()] end },
    Actor = { inventory = function(a) return (a.object or a).inventory end },
    Player = { objectIsInstance = function(a) return (a.object or a).kind == 'player' end },
    NPC = { objectIsInstance = function(a) local k = (a.object or a).kind; return k == 'npc' or k == 'player' end },
}
typesPkg.Container = { inventory = function(c) return c.inventory end }
M.ContainerType = typesPkg.Container

M.itemHandlers = {}
M.interfaces = {
    ItemUsage = { addHandlerForType = function(_t, fn) M.itemHandlers[#M.itemHandlers + 1] = fn end },
    Settings = { registerPage = function() end, registerGroup = function() end },
}

local worldPkg = {
    createObject = function(id, count)
        assert(records[id:lower()], 'createObject: no record ' .. id)
        return newObject(id, count)
    end,
    activeActors = {},
}
M.world = worldPkg

-- --------------------------------------------------------------------------
-- loading scripts
-- --------------------------------------------------------------------------
local CONTEXT = {
    ['scripts/cake/cake_global.lua'] = 'global',
    ['scripts/cake/cake_player.lua'] = 'player',
    ['scripts/cake/cake_npc.lua'] = 'local',
    ['scripts/cake/cake_settings.lua'] = 'menu',
    ['scripts/AnimRefresh/AnimRefresh_v6.lua'] = 'player',
}

function M.load(path, owner)
    local inst = { path = path, owner = owner, context = CONTEXT[path] }
    local selfObj = owner and setmetatable({ object = owner }, { __index = owner }) or nil
    local pkgs = {
        ['openmw.self'] = selfObj,
        ['openmw.types'] = typesPkg,
        ['openmw.animation'] = animPkg,
        ['openmw.camera'] = cameraPkg,
        ['openmw.world'] = worldPkg,
        ['openmw.interfaces'] = M.interfaces,
        ['openmw.util'] = { vector3 = function(x, y, z) return { x = x, y = y, z = z } end },
        ['openmw.storage'] = { playerSection = section, globalSection = section },
        ['openmw.core'] = {
            sendGlobalEvent = function(name, data) queue[#queue + 1] = { target = 'global', name = name, data = data } end,
        },
        ['openmw.async'] = {
            newUnsavableSimulationTimer = function(_, delay, fn) M.after(delay, fn) end,
            callback = function(_, fn) return fn end,
        },
    }
    local env = setmetatable({}, { __index = _G })
    env.require = function(name)
        if pkgs[name] then return pkgs[name] end
        if name == 'scripts.cake.cake_shared' then return M.shared end
        error('mock: no module ' .. name)
    end
    local chunk = assert(loadfile(ROOT .. path, 't', env))
    if setfenv then setfenv(chunk, env) end
    inst.ret = chunk() or {}
    if inst.ret.interfaceName and inst.ret.interface then
        M.interfaces[inst.ret.interfaceName] = inst.ret.interface
    end
    scripts[#scripts + 1] = inst
    return inst
end

function M.call(inst, handler, ...)
    local h = inst.ret.engineHandlers and inst.ret.engineHandlers[handler]
    if h and not inst.dead then return h(...) end
end

function M.event(inst, name, data)
    local h = inst.ret.eventHandlers and inst.ret.eventHandlers[name]
    if h and not inst.dead then return h(data) end
end

function M.sendGlobal(name, data) queue[#queue + 1] = { target = 'global', name = name, data = data } end

-- The engine's UseItem: global ItemUsage handlers, in registration order.
function M.use(item, actor)
    for _, fn in ipairs(M.itemHandlers) do
        if fn(item, actor) == false then return false end
    end
    return true
end

function M.give(actor, id, count)
    local o = worldPkg.createObject(id, count or 1)
    o:moveInto(actor.inventory)
    return o
end

function M.reset()
    clock, timers, queue, scripts = 0, {}, {}, {}
    storageSections = {}
    M.itemHandlers = {}
    M.log = {}
    M.interfaces.AnimRefresh = nil
    M.interfaces.CAKE = nil
    M.camera.mode = 2
    worldPkg.activeActors = {}
    M.cell.objects, M.cell.containers = {}, {}
end

function M.timerCount() return #timers end

return M
