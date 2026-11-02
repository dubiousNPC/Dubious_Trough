-- test_resolveanim.lua -- the rider's group resolution, and the fallback
--
--   run from "00 Core":  luarun.py tools/test_resolveanim.lua
--
-- WHAT THIS GUARDS
--
-- Two bugs, both silent, both reported as "no animation plays on unusual
-- creatures":
--
--   1. FALLBACK_ANIM named five groups that do not exist anywhere
--      (ride_generic_idle and friends). playBlended on a group the skeleton
--      does not define is a no-op with no error, so the fallback resolved to
--      a name, passed every nil check, and played nothing.
--
--   2. Six recognised mount types carry placeholder names of their own, and
--      because a set WAS found for them the per-state fallback never fired --
--      it only triggered on a missing table key, never on a missing group.
--      Fixing (1) alone would not have fixed any of them.
--
-- So the assertions below are mostly about what resolves when a group is
-- ABSENT from the skeleton, which is the case no previous test covered: the
-- old suite's mock skeleton happened to contain every group it asked for.

local shared = dofile('scripts/WhyWalk/whywalk_shared.lua')
local S, T = shared.STATE, shared.MOUNT_TYPE

local pass, fail = 0, 0
local function check(name, cond, got)
    if cond then
        pass = pass + 1
        print(('  ok   %s'):format(name))
    else
        fail = fail + 1
        print(('  FAIL %s  -> %s'):format(name, tostring(got)))
    end
end

-- The groups this package actually ships, per tools/check_anims.py: the horse
-- and guar rider sets, the gondola set and the rowing set. Nothing else.
local SHIPPED = {}
for _, g in ipairs({
    'rideh1', 'rideh2', 'rideh3', 'rideh4', 'rideh5',
    'rideg1', 'rideg2', 'rideg3', 'rideg4', 'rideg5',
    'gondola1', 'gondolal', 'gondolar',
    'rowing1', 'rowingidle', 'rowingl', 'rowingr', 'rowslow',
}) do SHIPPED[g] = true end

-- Plus the vanilla groups the base game provides, which this package does not
-- ship and check_anims.py therefore cannot see.
local VANILLA = { idle = true, walkforward = true, runforward = true }

local function realSkeleton(group) return SHIPPED[group] == true end
local function withVanilla(group)
    return SHIPPED[group] == true or VANILLA[group] == true
end

local function r(mountType, state, hasGroup)
    -- rng pinned to "first entry" so variant lists are deterministic here;
    -- the random choice is tested separately below.
    return shared.resolveAnim(mountType, state, function() return 1 end, hasGroup)
end

-- --- TEST 1: the reported bug -------------------------------------------

-- An unusual creature has no mount type at all. This is the case the user
-- saw: it must now produce a real, shipped group.
for _, st in ipairs({ S.IDLE, S.WALK, S.GALLOP, S.REVERSE, S.JUMP }) do
    local g = r(nil, st, realSkeleton)
    check(('unknown creature, %s -> a group that exists'):format(st),
          g ~= nil and realSkeleton(g), tostring(g))
end
check('unknown creature idles on the horse set', r(nil, S.IDLE, realSkeleton) == 'rideh1',
      r(nil, S.IDLE, realSkeleton))
check('unknown creature gallops on the horse set', r(nil, S.GALLOP, realSkeleton) == 'rideh3',
      r(nil, S.GALLOP, realSkeleton))

-- The old placeholders must be gone outright, not merely unreachable.
local function mentionsGeneric()
    for _, set in pairs(shared.RIDE_ANIM) do
        for _, v in pairs(set) do
            local list = type(v) == 'table' and v or { v }
            for _, g in ipairs(list) do
                if type(g) == 'string' and g:find('ride_generic', 1, true) then return true end
            end
        end
    end
    for _, v in pairs(shared.FALLBACK_ANIM) do
        if type(v) == 'string' and v:find('ride_generic', 1, true) then return true end
    end
    return false
end
check('no ride_generic_* placeholder survives anywhere', not mentionsGeneric())

-- --- TEST 2: the six placeholder types ----------------------------------

-- These have sets of their own, all naming groups nothing defines. Each must
-- reach the horse set rather than stopping at its own placeholder.
for _, mt in ipairs({ T.BOAR, T.NIX, T.STRIDENT, T.KAGOUTI }) do
    for _, st in ipairs({ S.IDLE, S.WALK, S.GALLOP, S.REVERSE, S.JUMP }) do
        local g = r(mt, st, realSkeleton)
        check(('%s, %s -> a group that exists'):format(tostring(mt), st),
              g ~= nil and realSkeleton(g), tostring(g))
    end
end

-- --- TEST 3: an explicit `false` still beats the fallback ---------------

-- A netch has no reverse and no jump. Handing it the horse's would be worse
-- than handing it nothing, so `false` must outrank the fallback.
for _, mt in ipairs({ T.NETCH, T.SKYRENDER }) do
    check(('%s has no reverse, even with a fallback available'):format(tostring(mt)),
          r(mt, S.REVERSE, realSkeleton) == nil, r(mt, S.REVERSE, realSkeleton))
    check(('%s has no jump, even with a fallback available'):format(tostring(mt)),
          r(mt, S.JUMP, realSkeleton) == nil, r(mt, S.JUMP, realSkeleton))
    -- but its flying states still resolve to something playable
    check(('%s still has an idle'):format(tostring(mt)),
          r(mt, S.IDLE, realSkeleton) ~= nil, 'nil')
end

check('the silt strider keeps its no-reverse',
      r(T.SILT_STRIDER, S.REVERSE, realSkeleton) == nil,
      r(T.SILT_STRIDER, S.REVERSE, realSkeleton))

-- --- TEST 4: the verified sets are untouched ----------------------------

check('a horse still rides the horse set', r(T.HORSE, S.WALK, realSkeleton) == 'rideh2',
      r(T.HORSE, S.WALK, realSkeleton))
check('a guar still rides the guar set, not the fallback',
      r(T.GUAR, S.WALK, realSkeleton) == 'rideg2', r(T.GUAR, S.WALK, realSkeleton))
for _, st in ipairs({ S.IDLE, S.WALK, S.GALLOP, S.REVERSE, S.JUMP }) do
    local g = r(T.GUAR, st, realSkeleton)
    check(('the guar set is complete and shipped (%s)'):format(st),
          g ~= nil and g:sub(1, 5) == 'rideg', tostring(g))
end

-- --- TEST 5: FALLBACK_ANIM is the horse set ----------------------------

check('FALLBACK_ANIM is the horse table itself, not a copy that can drift',
      shared.FALLBACK_ANIM == shared.RIDE_ANIM[T.HORSE],
      'separate tables')
check('every fallback state names a shipped group',
      (function()
          for _, st in ipairs({ S.IDLE, S.WALK, S.GALLOP, S.REVERSE, S.JUMP }) do
              local g = shared.FALLBACK_ANIM[st]
              if type(g) ~= 'string' or not SHIPPED[g] then return false end
          end
          return true
      end)())

-- --- TEST 6: without hasGroup, the old behaviour -----------------------

-- The pure-data callers (and the existing suites) pass no skeleton. Every
-- candidate is then assumed present, which must still resolve the type's own
-- set rather than the fallback.
check('no skeleton given: a boar uses its own placeholder name',
      r(T.BOAR, S.WALK, nil) == 'rideb2', r(T.BOAR, S.WALK, nil))
check('no skeleton given: an unknown creature still gets the fallback',
      r(nil, S.WALK, nil) == 'rideh2', r(nil, S.WALK, nil))

-- --- TEST 7: variant lists --------------------------------------------

-- A list where only some entries exist must choose from the ones that do,
-- rather than rolling the dice and sometimes playing nothing. The boar's idle
-- is { "rideb1", "rideb1_alt" }; pretend one of them shipped.
local partial = function(g) return g == 'rideb1_alt' end
check('a half-resourced variant list picks the entry that exists',
      r(T.BOAR, S.IDLE, partial) == 'rideb1_alt', r(T.BOAR, S.IDLE, partial))

-- With neither present it must fall through, not return a missing name.
check('a variant list with nothing present falls through to the fallback',
      r(T.BOAR, S.IDLE, realSkeleton) == 'rideh1', r(T.BOAR, S.IDLE, realSkeleton))

-- The random choice still happens when several entries are present.
local both = function(g) return g == 'rideb1' or g == 'rideb1_alt' end
local seen = {}
for i = 1, 2 do
    local g = shared.resolveAnim(T.BOAR, S.IDLE, function() return i end, both)
    seen[g] = true
end
check('both present variants are reachable', seen.rideb1 and seen.rideb1_alt,
      'only one')

-- --- TEST 8: useFallbackAnim off --------------------------------------

shared.TUNING.useFallbackAnim = false
check('fallback disabled: an unknown creature resolves to nothing',
      r(nil, S.IDLE, realSkeleton) == nil, r(nil, S.IDLE, realSkeleton))
check('fallback disabled: a placeholder type resolves to nothing',
      r(T.BOAR, S.IDLE, realSkeleton) == nil, r(T.BOAR, S.IDLE, realSkeleton))
check('fallback disabled: a horse is unaffected',
      r(T.HORSE, S.IDLE, realSkeleton) == 'rideh1', r(T.HORSE, S.IDLE, realSkeleton))
shared.TUNING.useFallbackAnim = true

-- --- TEST 9: the silt strider's sitting group ------------------------

-- "vasittingfloor" is NOT vanilla -- Rideable Silt Striders supplies it. With
-- that mod absent the strider should straddle rather than freeze; with it
-- present the sitting pose must win.
check('silt strider without the sitting pack falls through to the horse set',
      r(T.SILT_STRIDER, S.IDLE, realSkeleton) == 'rideh1',
      r(T.SILT_STRIDER, S.IDLE, realSkeleton))
local withSitting = function(g) return realSkeleton(g) or g == 'vasittingfloor' end
check('silt strider with the sitting pack sits',
      r(T.SILT_STRIDER, S.IDLE, withSitting) == 'vasittingfloor',
      r(T.SILT_STRIDER, S.IDLE, withSitting))

-- --- TEST 10: allJumpGroups still covers the fallback ---------------

-- Text-key handlers are registered per jump group up front, so the fallback's
-- jump has to be in that list or a fallen-back rider's jump never completes.
local jumps = shared.allJumpGroups()
local set = {}
for _, g in ipairs(jumps) do set[g] = true end
check('allJumpGroups includes the fallback jump', set[shared.FALLBACK_ANIM[S.JUMP]] == true,
      table.concat(jumps, ', '))
check('allJumpGroups has no duplicates now the fallback aliases the horse set',
      (function()
          local seenJump, n = {}, 0
          for _, g in ipairs(jumps) do
              if seenJump[g] then return false end
              seenJump[g] = true; n = n + 1
          end
          return n == #jumps
      end)(), table.concat(jumps, ', '))

-- --- TEST 11: the blacklist, code-level and player-level ---------------

-- isBlacklisted gained a second argument so the player's own list can be
-- consulted without this file reading player storage (which it cannot: it
-- requires no openmw module, which is what lets global, player and local
-- scripts share it).

check('nil record id is not blacklisted', shared.isBlacklisted(nil) == false)
check('an unlisted creature is not blacklisted',
      shared.isBlacklisted('guar') == false)
check('the code-level list still applies with no player list',
      shared.isBlacklisted('placeholder_questcreature_01') == true)

local mine = { ['guar'] = true, ['nix_hound'] = true }
check('a player-listed creature is blacklisted',
      shared.isBlacklisted('guar', mine) == true)
check('a creature on neither list is not',
      shared.isBlacklisted('kagouti', mine) == false)
check('the code-level list still applies alongside a player list',
      shared.isBlacklisted('placeholder_questcreature_01', mine) == true)

-- Record ids are matched lower-cased, and the renderer is configured with
-- lower = true, but a DEFAULT value or a hand-edited cfg is not lowercased
-- for you -- so the id side must do the folding.
check('a mixed-case record id matches a lower-cased entry',
      shared.isBlacklisted('Guar', mine) == true)
check('an upper-case record id matches a lower-cased entry',
      shared.isBlacklisted('NIX_HOUND', mine) == true)

-- An empty or absent list must not block anything, and must not throw.
check('an empty player list blocks nothing',
      shared.isBlacklisted('guar', {}) == false)
check('no player list blocks nothing', shared.isBlacklisted('guar', nil) == false)

-- A set with a false value is not a listing: the renderer stores `true`, and
-- a removed entry should not keep blocking.
check('an entry set to false is not blacklisted',
      shared.isBlacklisted('guar', { ['guar'] = false }) == false)

print(('\n%d passed, %d failed'):format(pass, fail))
if fail > 0 then os.exit(1) end
print('ALL PASS')
