-- test_wwapi/player.lua -- the player-side assumptions that cost round trips

local testing = require('testing_util')
local self    = require('openmw.self')
local anim    = require('openmw.animation')
local camera  = require('openmw.camera')
local util    = require('openmw.util')
local I       = require('openmw.interfaces')

local function describe(label, v)
    local n, ok = 0, nil
    ok = pcall(function() for _ in pairs(v) do n = n + 1 end end)
    print(string.format('[wwapi] %-26s type=%-9s pairs=%s', label, type(v),
        ok and (n .. ' keys') or 'RAISES'))
    return ok, n
end

---Index a key that should not exist, and report whether that raises or
---returns nil. `anim.BONE_GROUP.Arms` RAISED, which stopped ridingAnim from
---loading at all and cost every animation in the suite.
local function probeUnknownKey(label, container)
    local ok, err = pcall(function() return container.NoSuchMemberHere end)
    print(string.format('[wwapi]   %s.<unknown> -> %s', label,
        ok and 'nil (table-like)' or ('RAISES: ' .. tostring(err))))
    return ok
end

-- ---------------------------------------------------------------------------
-- ENGINE ENUMS
-- ---------------------------------------------------------------------------
testing.registerLocalTest('wwapi: animation enums', function()
    describe('anim.BONE_GROUP', anim.BONE_GROUP)
    describe('anim.BLEND_MASK', anim.BLEND_MASK)
    describe('anim.PRIORITY', anim.PRIORITY)
    probeUnknownKey('anim.BONE_GROUP', anim.BONE_GROUP)

    -- The four members the engine actually has. `Arms` is not one of them.
    for _, name in ipairs({ 'LowerBody', 'Torso', 'LeftArm', 'RightArm' }) do
        local ok, v = pcall(function() return anim.BONE_GROUP[name] end)
        print(string.format('[wwapi]   BONE_GROUP.%-10s -> %s', name,
            ok and tostring(v) or 'MISSING'))
        testing.expect(ok, 'BONE_GROUP.' .. name .. ' must exist')
    end
    local armsOk = pcall(function() return anim.BONE_GROUP.Arms end)
    print(string.format('[wwapi]   BONE_GROUP.Arms -> %s',
        armsOk and 'EXISTS (the suite may use it)' or 'absent, as expected'))
end)

-- ---------------------------------------------------------------------------
-- UI MODES AND WINDOWS
-- ---------------------------------------------------------------------------
-- `type(I.UI.MODE) ~= 'table'` was always true, so the travel interception
-- stood down on every menu; and `I.UI.WINDOW` was declared to have no Travel
-- entry on evidence from the same bad check.
testing.registerLocalTest('wwapi: I.UI.MODE and I.UI.WINDOW', function()
    testing.expect(I.UI ~= nil, 'I.UI missing')
    describe('I.UI.MODE', I.UI.MODE)
    describe('I.UI.WINDOW', I.UI.WINDOW)
    probeUnknownKey('I.UI.MODE', I.UI.MODE)
    for _, name in ipairs({ 'Travel', 'Interface', 'Dialogue', 'Rest' }) do
        local ok, v = pcall(function() return I.UI.MODE[name] end)
        print(string.format('[wwapi]   MODE.%-10s -> %s', name,
            ok and tostring(v) or 'RAISES/absent'))
    end
    for _, name in ipairs({ 'Travel', 'Inventory', 'Dialogue' }) do
        local ok, v = pcall(function() return I.UI.WINDOW[name] end)
        print(string.format('[wwapi]   WINDOW.%-10s -> %s', name,
            ok and tostring(v) or 'RAISES/absent'))
    end
    local travelOk, travel = pcall(function() return I.UI.MODE.Travel end)
    testing.expect(travelOk and travel ~= nil,
        'MODE.Travel must exist; the whole interception is keyed on it')
end)

-- ---------------------------------------------------------------------------
-- THE YAW CONVENTION
-- ---------------------------------------------------------------------------
-- Probed in three modules with `rotateZ(0.5):getYaw() > 0`, which is
-- self-consistent and therefore tests nothing. This asks the real questions:
-- does getYaw invert rotateZ, and does a roll about Y disturb the yaw?
testing.registerLocalTest('wwapi: yaw convention', function()
    local t = util.transform
    for _, a in ipairs({ 0.0, 0.5, 1.5, 3.0, -0.5 }) do
        print(string.format('[wwapi]   rotateZ(%+.2f):getYaw() = %+.4f',
            a, t.rotateZ(a):getYaw()))
    end
    testing.expectEqualWithDelta(t.rotateZ(0.5):getYaw(), 0.5, 1e-6,
        'getYaw must invert rotateZ')

    -- placeVehicle composes rotateZ(yaw) * rotateY(roll) for the sway lean.
    -- If that disturbs the yaw, the lean and the facing are not separable.
    local composed = t.rotateZ(0.8) * t.rotateY(0.04)
    print(string.format('[wwapi]   (rotateZ(0.8) * rotateY(0.04)):getYaw()'
        .. ' = %+.6f  (want 0.8)', composed:getYaw()))
    testing.expectEqualWithDelta(composed:getYaw(), 0.8, 1e-3,
        'a small roll must not move the yaw, or sway corrupts the facing')
end)

-- ---------------------------------------------------------------------------
-- ANIMATION ON A NON-ACTOR
-- ---------------------------------------------------------------------------
-- The caravan vehicle is an activator. Whether an activator can animate at
-- all was inferred three different ways before the game was asked.
testing.registerLocalTest('wwapi: animation on an activator', function()
    -- (no openmw.world here: it is global-only, and requiring it in a player
    -- script raises "module not found")
    print(string.format('[wwapi]   hasAnimation(player) = %s',
        tostring(anim.hasAnimation(self))))
    testing.expect(anim.hasAnimation(self), 'the player must have animation')
    -- ct_chair is the synthetic game's activator.
    for _, obj in ipairs(require('openmw.nearby').activators or {}) do
        print(string.format('[wwapi]   hasAnimation(%s) = %s',
            tostring(obj.recordId), tostring(anim.hasAnimation(obj))))
    end
    print('[wwapi]   NOTE: this game ships no .kf, so hasGroup is'
          .. ' meaningless here; confirmed in game instead (2026-11-03):'
          .. ' an activator with the vanilla strider mesh reports'
          .. ' hasAnimation=true and the single group "idle".')
end)

-- ---------------------------------------------------------------------------
-- A MISSING ANIMATION GROUP IS A SILENT NO-OP
-- ---------------------------------------------------------------------------
testing.registerLocalTest('wwapi: playBlended on a missing group', function()
    local group = 'ww_no_such_group_at_all'
    print(string.format('[wwapi]   hasGroup(%q) = %s', group,
        tostring(anim.hasGroup(self, group))))
    local ok, err = pcall(anim.playBlended, self, group, { loops = 1 })
    print(string.format('[wwapi]   playBlended on it -> %s',
        ok and 'returns quietly (SILENT NO-OP)' or ('raises: ' .. tostring(err))))
    testing.expect(not anim.hasGroup(self, group),
        'the probe group must not exist, or this proves nothing')
end)

-- ---------------------------------------------------------------------------
-- LOOPS MUST BE >= 0
-- ---------------------------------------------------------------------------
testing.registerLocalTest('wwapi: playBlended loops contract', function()
    local ok, err = pcall(anim.playBlended, self, 'idle', { loops = -1 })
    print(string.format('[wwapi]   loops = -1 -> %s',
        ok and 'accepted (NOT infinite; out of contract)'
            or ('raises: ' .. tostring(err))))
    print('[wwapi]   the suite uses 999999 for "forever"')
end)

testing.registerLocalTest('wwapi: camera mode', function()
    print(string.format('[wwapi]   camera.getMode() = %s, MODE table:',
        tostring(camera.getMode())))
    describe('camera.MODE', camera.MODE)
end)

return {
    engineHandlers = { onUpdate = testing.updateLocal },
    eventHandlers = testing.localEventHandlers,
}
