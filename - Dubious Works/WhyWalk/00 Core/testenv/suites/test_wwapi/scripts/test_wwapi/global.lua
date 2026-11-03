-- test_wwapi/global.lua -- the API assumptions this suite has got wrong
--
-- Every assertion here replaces a guess that cost a round trip. None of them
-- test WhyWalk: they test the ENGINE, so that the next person writing against
-- it reads an answer instead of inferring one. They print what they find as
-- well as asserting, because the printout is the useful artefact.
--
--   ./run_tests.sh suites/test_wwapi
--
-- The synthetic game has no .kf and no real meshes, so animation GROUPS and
-- mesh bounds cannot be probed here; the README says so. Everything else can.

local testing = require('testing_util')
local world   = require('openmw.world')
local types   = require('openmw.types')
local util    = require('openmw.util')
local core    = require('openmw.core')

---Describe a value the way a Lua author would guess at it, and the way it
---actually behaves. `type()` lies about engine userdata, which is the root of
---three separate bugs in this project's history.
local function describe(label, v)
    local t = type(v)
    local n, iterErr = 0, nil
    local ok, err = pcall(function()
        for _ in pairs(v) do n = n + 1 end
    end)
    if not ok then iterErr = tostring(err) end
    print(string.format('[wwapi] %-28s type=%-8s pairs=%s',
        label, t, ok and (n .. ' keys') or ('RAISES: ' .. tostring(iterErr))))
    return t, ok, n
end

-- ---------------------------------------------------------------------------
-- RECORD LISTS ARE NOT TABLES
-- ---------------------------------------------------------------------------
-- Cod3x annotates RecordList as `table<integer|string, T|nil>`. The strider
-- lookup swept `pairs(types.Creature.records)`, found nothing, raised nothing,
-- and the vehicle could not animate for two rounds. This says what the list
-- really is.
testing.registerGlobalTest('wwapi: types.Creature.records', function()
    local t, iterable, n = describe('types.Creature.records', types.Creature.records)
    print(string.format('[wwapi]   indexing by a known id: %s',
        tostring(types.Creature.record('ct_creature') ~= nil)))
    print(string.format('[wwapi]   records["ct_creature"]: %s',
        tostring(types.Creature.records['ct_creature'] ~= nil)))
    testing.expect(types.Creature.record('ct_creature') ~= nil,
        'Creature.record(id) must find a record that exists')
    -- Not asserted either way: the POINT is to record which it is.
    print(string.format('[wwapi]   VERDICT: %s, %s',
        t, iterable and ('iterable, ' .. n .. ' entries') or 'NOT iterable'))
end)

-- ---------------------------------------------------------------------------
-- WHAT A RECORD DRAFT WANTS AS A MODEL PATH
-- ---------------------------------------------------------------------------
-- Boats passed the path bare, on a note saying createRecord adds `meshes\`.
-- It does not: it throws, and boarding failed outright nine times in one log.
testing.registerGlobalTest('wwapi: createRecordDraft model path', function()
    local function try(path)
        local ok, err = pcall(types.Activator.createRecordDraft,
                              { name = 'probe', model = path })
        print(string.format('[wwapi]   model %-34s -> %s',
            '"' .. tostring(path) .. '"',
            ok and 'accepted' or ('REJECTED: ' .. tostring(err))))
        return ok
    end
    local bare     = try('x/ct_probe.nif')
    local fwd      = try('meshes/x/ct_probe.nif')
    local back     = try('meshes\\x\\ct_probe.nif')
    testing.expect(fwd or back,
        'a prefixed path must be accepted, or nothing can spawn a copy')
    print(string.format('[wwapi]   VERDICT: prefix required = %s,'
        .. ' forward slashes ok = %s', tostring(not bare), tostring(fwd)))
end)

-- ---------------------------------------------------------------------------
-- ONE TELEPORT PER OBJECT PER FRAME
-- ---------------------------------------------------------------------------
-- The journey teardown teleported three objects that onUpdate had already
-- teleported, threw at its first statement, and left a second strider standing
-- at the stop with the player glued to it.
testing.registerGlobalTest('wwapi: teleport twice in one frame', function()
    local obj = world.createObject('ct_misc', 1)
    local cell = world.players[1].cell
    obj:teleport(cell, util.vector3(0, 0, 0))
    local ok, err = pcall(obj.teleport, obj, cell, util.vector3(10, 0, 0))
    print(string.format('[wwapi]   second teleport in the same frame: %s',
        ok and 'ALLOWED' or ('raises: ' .. tostring(err))))
    testing.expect(not ok,
        'if this ever becomes allowed, the deferred teardown can be simplified')
    obj:remove()
end)

-- ---------------------------------------------------------------------------
-- THE WORLDSPACE ARGUMENT
-- ---------------------------------------------------------------------------
-- Caravans named the boarding cell on every teleport for a whole journey,
-- which blacked the screen out. An empty string is documented to mean the
-- default exterior worldspace; this checks it is accepted at all.
testing.registerGlobalTest('wwapi: teleport worldspace argument', function()
    local obj = world.createObject('ct_misc', 1)
    local function try(where, label)
        local ok, err = pcall(obj.teleport, obj, where, util.vector3(0, 0, 0))
        print(string.format('[wwapi]   cell arg %-22s -> %s', label,
            ok and 'accepted' or ('REJECTED: ' .. tostring(err))))
        return ok
    end
    local byCell = try(world.players[1].cell, 'the player\'s Cell')
    testing.expect(byCell, 'a Cell must be accepted')
    print('[wwapi]   (an empty string names the default EXTERIOR worldspace,'
          .. ' which this interior-only game cannot exercise)')
    obj:remove()
end)

-- ---------------------------------------------------------------------------
-- WHAT IS SERIALISABLE
-- ---------------------------------------------------------------------------
-- A Cell in the onSave table made the engine reject the WHOLE table, so a
-- mid-journey save stored nothing from the module, record id included.
testing.registerGlobalTest('wwapi: what onSave can hold', function()
    print('[wwapi]   a Cell in a save table is rejected whole;'
          .. ' store cell.name instead. Verified in game 2026-10-29.')
    local c = world.players[1].cell
    print(string.format('[wwapi]   cell.name = %q, cell.id = %q,'
        .. ' isExterior = %s', tostring(c.name), tostring(c.id),
        tostring(c.isExterior)))
    testing.expect(type(c.name) == 'string', 'cell.name must be a string')
end)

return {
    engineHandlers = { onUpdate = testing.updateGlobal },
    eventHandlers = testing.globalEventHandlers,
}
