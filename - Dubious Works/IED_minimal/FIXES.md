# IED — minimal fix build

Same shape as the version you sent: **one manifest, one AnimRefresh, one player
script, one NPC script, one shared module, one bones module.** No settings page,
no MENU script, no GLOBAL script, no l10n, no new storage sections, no new
requires. Nothing was added to the load order.

Two files differ from the original, and `common.lua` is **one net line longer**.

| File | Status |
|---|---|
| `IED.omwscripts` | unchanged |
| `scripts/show-all-weapons/player.lua` | unchanged |
| `scripts/show-all-weapons/npc.lua` | unchanged |
| `scripts/AnimRefresh/AnimRefresh_v2.lua` | unchanged |
| `animations/**` (8 NIFs) | unchanged |
| `scripts/show-all-weapons/common.lua` | **3 edits** |
| `scripts/show-all-weapons/bones.lua` | **1 function added** |

---

## What was wrong

These attach to the same bones OpenMW's own weapon sheathing uses, so the engine
and the mod can both put a mesh on one bone. Two cases were doing exactly that.

### 1. Occupancy was keyed by weapon type, but bones are shared

`bones.lua` deliberately maps two weapon types onto one bone:

```
Bip01 LongBladeOneHand  <-  LongBladeOneHand, AxeOneHand
Bip01 Ammo              <-  Arrow, Bolt
```

`handler()` deduplicated with `slotTaken[rec.type]`, so:

> Equip a longsword, leave it sheathed. The engine draws it on
> `Bip01 LongBladeOneHand`. Carry an axe. `slotTaken[AxeOneHand]` is false, so
> the axe goes onto `Bip01 LongBladeOneHand` too — two meshes in one spot, one
> of them the engine's.

It also fires with no engine involvement: carry a longsword *and* an axe, equip
neither, and both land on the same bone.

**Fix:** `slotTaken` becomes `boneTaken`, keyed by the resolved bone name.

### 2. An equipped shield is drawn by the engine, and a second one was added

The equipped shield was excluded only by record id (`rid ~= equippedShieldId`).
Carry two *different* shields with one equipped and the other went onto
`Bip01 AttachShield`, where the engine had already put the equipped one.

**Fix:** while a shield is equipped and not drawn, the bone belongs to the
engine and the mod yields it. Drawn, the shield moves to the arm and the back is
free again.

### 3. Falling out of the above

The equipped weapon's bone is now claimed only while the weapon is **sheathed**,
which is when the engine actually occupies it. Draw your sword and the freed
bone becomes available to a carried weapon of that type.

---

## `bones.lua`

`BONE_BY_TYPE` is unchanged. One function was added:

```lua
function M.sharedBones()  -- bones that more than one weapon type maps onto
```

It computes the shared set from `BONE_BY_TYPE` rather than restating it, so
editing the map cannot leave a stale list behind. `common.lua` does not call it
— the bone-keyed table makes it unnecessary — but it exists so the sharing is
discoverable rather than folklore, and the test asserts against it.

The misleading part of the old comment is corrected: AxeOneHand sharing the long
blade bone is still deliberate, it just has to be accounted for downstream, and
previously it was not.

---

## What this build does NOT do

Deliberately excluded, since you asked for low impact:

- no settings page, MENU script or GLOBAL script
- no NPC display toggle — NPCs behave exactly as before
- no configurable poll interval (still 0.5s), weapon/shield/ammo toggles, or l10n
- no change to `player.lua`, `npc.lua` or the manifest

The fuller build with those is the separate `IED_assessed.zip`. The clash fixes
here are identical in both; the only difference is the settings layer around
them.

---

## Testing

```
python3 tools/luarun.py tools/test_ied_lite.lua
```

Mocks the OpenMW API and drives the real `handler()`, with a counter that trips
whenever two meshes land on one bone. 7/7 pass:

```
shared bones are computed, not listed
unshared bones are not flagged
inventory axe does NOT stack on the engine-sheathed longsword
once the weapon is drawn the freed bone is reused
two carried weapons sharing a bone do not overlap
carried shield does NOT stack on the engine-sheathed one
with the shield drawn the back is free again
```

Also clean: `luacheck.py` (5 files, 0 failures) and `check_names.py` (no
undefined names or unused requires).
