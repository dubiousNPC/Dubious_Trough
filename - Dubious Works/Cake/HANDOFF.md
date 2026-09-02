# CAKE — session handoff (updated: error sweep, tails removed, settings rewritten)

Everything needed to resume without re-deriving it. Read this first.

---

## 1. What CAKE actually is (this was misdiagnosed last session)

CAKE is **not** an ItemUsage-blocking mod like OMWFW. It is a copy of Sun's
Dusk's backpack module with the item ids swapped, using the **paired-record**
mechanism:

```
dbs_<thing>        types.Miscellaneous — sits in the inventory
dbs_<thing>_eq     types.Miscellaneous — replaces it while worn
```

Using the base record destroys it and creates the `_eq` record. Using the
`_eq` record converts it back. Because both are `Miscellaneous`, **no
equipment slot is ever occupied** — that is what makes it less invasive than
OMWFW, whose records are `ARMO` declaring real `Helmet` / `LeftPauldron` /
`RightPauldron` slots.

Worn state therefore lives **in the inventory**, not in script state. There is
nothing to save, nothing to reconcile on load, and no way for display and
inventory to disagree. The rewritten player script reads worn state fresh from
the inventory every time rather than tracking it.

Last session I built CAKE on the `ItemUsage → return false` model from OMWFW.
That was wrong and has been replaced.

---

## 2. Bugs found in the shipped CAKE (`globalcake.lua` / `playergear.lua`)

Ordered by severity. **The mod as shipped cannot run at all** — the first four
are each independently fatal.

| # | Bug | Effect |
|---|---|---|
| 1 | **No `.omwscripts` file anywhere in the archive** | Neither Lua file is ever registered. Nothing runs. |
| 2 | **No `require` statements in either file.** Both reference `I`, `types`, `world`, `self`, `animation`, `camera`, `async`, `core`, `util`, `saveData`, `typesActorSpellsSelf`, `typesActorInventorySelf`, `G_onFrameJobsSluggish`, `G_onFrameJobs`, `G_onLoadJobs`, `G_UiModeChangedJobs`, `G_onInventoryChangedJobs`, `G_eventHandlers` | These are Sun's Dusk's shared environment. Standalone, every one is nil. |
| 3 | **Not one of `globalcake.lua`'s 50 item ids exists in CAKE.esp or CAKE34.esp** — verified against both plugins. `fy_fannypack_b`, `indoril_tail`, `LanternDwem`… all absent. | No item can ever be equipped. |
| 4 | **`Bip01 tailsDBS` does not exist in `xbase_anim_dbs.nif`.** 32 tails assigned to it. | Every tail fails `hasBone`, renders nothing. **Resolved:** tails belong on the beast skeleton (`xbase_animkna`), which CAKE does not ship, so the 34 tail pairs are excluded from the registry rather than pointed at a substitute. |
| 5 | `DEFAULT_BONE` is a **table** (`{fallback=…, uiModes=…, vfxItem=…}`) used as `BACKPACK_BONES[id] or DEFAULT_BONE`, then passed to `animation.hasBone` which wants a string | Any item missing from the bones table hits this. |
| 6 | `BACKPACK_FEATHER_PERCENT` referenced in `playergear.lua`, **never defined there** | `refreshFeatherMagnitude` raises on first call. |
| 7 | `BACKPACK_Z_OFFSETS` referenced in `globalcake.lua`, **never defined** | Drop handler raises. |
| 8 | **Case.** Record ids compare lowercase; `LanternDwem`, `GlassLantern2`, `_RV_Scarf01` etc. are capitalised table keys | Even a correct id list would miss ~half of them. |
| 9 | Bones table mixes three conventions at once: `dbs_indoril_tail_eq`, `LanternDwem_eq`, `_RV_Scarf01` (no suffix) | None matches the real `dbs_<thing>_eq` scheme. |
| 10 | Single `VFX_ID = "SD_backpackVfx"` for all categories | A lantern and a mask cannot coexist. |
| 11 | `getBaseId` defined twice in `globalcake.lua` | Harmless, but signals copy-paste. |
| 12 | Hard dependency on Sun's Dusk records: `sd_feather_f1..f8`, `SunsDusk_playSound`, `SunsDusk_convertInCell`, `SunsDusk_backpackEquipped` | Silent no-ops or errors without Sun's Dusk. |
| 13 | Masks/glasses/scarves appear in `playergear.lua`'s bones table but **not** in `globalcake.lua`'s id list | Unreachable even if everything else worked. |

The id/naming mismatch is worth stating precisely, because it is subtle: the
Lua computes `itemId .. "_eq"` and `equippedId:sub(1, -4)`. That arithmetic is
*correct* for the plugin's `dbs_X` / `dbs_X_eq` scheme — but only if the id
list already carries the `dbs_` prefix. It did not. The rewrite uses an
explicit reverse index (`M.EQ_TO_BASE`) instead of string surgery, so a naming
change fails loudly at generation time rather than silently at runtime.

---

## 3. Hard data extracted (don't re-derive)

### The 12 DBS bones — read from `meshes/dbs/xbase_anim_dbs.nif`

```
Bip01 beltDBS      Bip01 R hipDBS     Bip01 L hipDBS     Bip01 chestDBS
Bip01 backpackDBS  Bip01 capeDBS      Bip01 mouthDBS     Bip01 eyesDBS
Bip01 earsDBS      Bip01 hornsDBS     Bip01 scarfDBS     Bip01 pendantDBS
```

**There is no tail bone.** No node in that file contains "tail" in any casing.
123 nodes total.

### Records in the CAKE plugins

| Plugin | Records |
|---|---|
| `CAKE.esp` | 352 MISC, 16 ARMO, 10 CONT, 2 STAT |
| `CAKE34.esp` | 163 BODY, 20 ARMO, 10 CONT, 2 MISC, 1 NPC_ |
| `CAKE402.esp` | 163 MISC |

530 unique MISC/ARMO ids. **183 `_eq` records, all prefixed `dbs_`.**
162 of them have a matching `dbs_` base record → those are the usable pairs.

**21 orphan `_eq` records** have no `dbs_` base twin — their base is the plain
Fashionwind record (`_RV_Glasses1`, `_RV_Blindfold1`, `_RV_Eyepatch1L/R`,
`_RV_Goggles1-8`, `_RV_Lenses1/2`, `1armunantail`, …). Either the base `dbs_`
records are missing from the plugin, or these are meant to pair with the
Fashionwind originals. **Open question — needs a decision.** This is why
eyewear shows 20 items, not 40.

### Category assignment (129 pairs; 34 tail pairs excluded)

| Category | Count | DBS bone | Vanilla fallback |
|---|---|---|---|
| lanterns | 46 | `Bip01 L hipDBS` | `Bip01 Pelvis` |
| eyewear | 20 | `Bip01 eyesDBS` | `head` |
| masks | 17 | `Bip01 mouthDBS` | `head` |
| scarves | 16 | `Bip01 scarfDBS` | `Bip01 Neck` |
| belts | 14 | `Bip01 beltDBS` | `Bip01 Pelvis` |
| bags | 13 | `Bip01 beltDBS` | `Bip01 Pelvis` |
| smokes | 2 | `Bip01 mouthDBS` | `head` |
| ears | 1 | `Bip01 earsDBS` | `head` |

Categories are assigned by regex over id + model path + display name. Bones
`backpackDBS`, `capeDBS`, `hornsDBS`, `pendantDBS`, `R hipDBS`, `chestDBS` are
in the skeleton but **currently unused** — the classifier found no items for
them. Worth a look: `chestDBS` was used by the old bones table for
`fy_fpkpch`, `fy_satchel`, `fy_ubelt`, so some bags probably belong there
rather than on `beltDBS`.

### From OMWFW (last session, still valid)

- Fashionwind `ARMO` slots: horns/antlers/ears/cloaks → `Helmet`; earrings and
  left piercings → `LeftPauldron`; right piercings → `RightPauldron`.
- `xbase_anim_fashVfx.nif` adds: `ScarfNeck`, `Ahead`, `Backpack1`, `MEH`,
  `Necklace`(+46/48/50/53/58), `Waist`(+sizes), `Ring L/R Finger1`(+sizes).
  A *different* skeleton from DBS — no overlap in naming.
- OMWFW's head-bone "owner" lock never arbitrated: each of the five head
  categories wrote to a different storage section, so every `xIsOurs()` was
  unconditionally true.

---

## 4. Reference patterns worth reusing

**Sun's Dusk `p_backpacks.lua`** — the deferred-refresh detail AnimRefresh
documents second-hand, now confirmed first-hand:

```lua
local function refreshVfx(retries)
    animation.removeVfx(self, VFX_ID)
    local boneName = BACKPACK_BONES[saveData.backpackId] or DEFAULT_BONE
    if not animation.hasBone(self, boneName) then
        if not retries then
            async:newUnsavableSimulationTimer(0.1, function() refreshVfx(1) end)
        end
        return
    end
    local record = types.Miscellaneous.record(saveData.backpackId)
    animation.addVfx(self, record.model, { vfxId=VFX_ID, boneName=boneName,
                                           loop=true, useAmbientLight=false })
end
```

Note: the model comes **straight from `record.model`** — no `_skins.nif`
derivation. That derivation is an OMWFW thing (their records are ground meshes
needing a skinned twin); CAKE's MISC records already point at the wearable
mesh. The rewrite does not derive paths.

Also in Sun's Dusk and worth stealing later:

- `G_onInventoryChangedJobs.backpack = function(gained, lost)` — a real
  inventory-delta hook. Sun's Dusk builds this itself; there is no engine
  equivalent, which is why CAKE currently refreshes on UI-mode exit instead.
- Binary-encoded ability magnitude: `sd_feather_f1..f8` with values
  1,2,4,…,128 summed to synthesise any magnitude 0–255 from 8 ability records.
  Clever, and reusable if a category ever needs a scaling buff.
- `SunsDusk_convertInCell` converts loose `_eq` records back to base form
  across cell objects, containers, NPCs and creatures.

**`InventoryEquipmentDisplay_fixed/common.lua`** — the house performance
pattern: memoized record/mesh caches, a cheap `buildSignature()` change
detector compared before any rebuild, time-based rather than frame-count
polling, and `I.AnimRefresh.subscribe` setting a `forceRebuild` flag. Its
header also records that `types.Actor.equipment` does not exist (it is
`getEquipment`) and that the bug hid inside a `pcall`.

---

## 5. What is built and passing

`out/pkg/CAKE/` — 7 Lua files, manifest, l10n, README.

| File | State |
|---|---|
| `cake_shared.lua` | Generated from CAKE.esp. **129 pairs, 8 categories** (tails excluded). Reverse index, skeleton profiles. Generator now asserts every category bone exists in the skeleton. |
| `cake_global.lua` | **Rewritten** to the `_eq` swap. Registers one `ItemUsage` handler for `types.Miscellaneous`. |
| `cake_player.lua` | **Rewritten.** Reads worn state from inventory. No `onFrame`, no `onUpdate`, no camera polling. AnimRefresh subscription + 0.1s bone retry. |
| `cake_npc.lua` | **Rewritten.** One inventory walk on `onActive`, no polling. |
| `cake_settings.lua` | **Rewritten.** Four live settings, no dead keys. Skeleton options built from `CAKE.SKELETON`. Uses bundled SuperSelect3 with engine `select` fallback. |
| `cake_anim.lua` | **Fixed.** Was summing `BONE_GROUP` into `blendMask` (=9, wrong bones); now `BLEND_MASK.UpperBody` (=14). Category keys were all OMWFW names and matched nothing; corrected and validated at load. Wired to `EQUIPANIM`. |
| `AnimRefresh_v2.lua` | Bundled verbatim, version-guarded. |
| `CAKE.omwscripts` | **New** — the original shipped none. Now also loads bundled `SuperSelect3.lua` ahead of the settings page. |
| `scripts/SuperSettingsRenderers/SuperSelect3.lua` | **Bundled verbatim**, like AnimRefresh. Not modified, not reimplemented. |

**Tests: 16 registry + 30 integration = 46 pass.** Syntax clean on all 8 Lua
files; `check_names.py` clean; `sweep.py` clean.

`sweep.py` is new and is the one to keep running: it cross-references settings
keys declared vs. read, category names used vs. defined, skeleton profiles
offered vs. supported, events sent vs. handled, l10n keys used vs. present, and
orphaned modules. It found 27 findings on the previous package — every stale
setting and every wrong category name — none of which syntax checking sees.

Tooling in `/home/claude/work/`: `tes3.py` (plugin parser), `gen_cake_shared.py`
(registry generator), `luacheck.py` + `luarun.py` (ctypes against system
`liblua5.4.so.0` — no interpreter installed), `check_names.py`.

Reference archives extracted under `ref/`.

---

## 6. Next session — ordered

1. **Tails (34 pairs) need a beast-skeleton variant.** They are excluded from
   the registry, so nothing is broken — they simply do not appear. To restore
   them, ship an `xbase_animkna` variant carrying a tail bone, add the bone to
   `DBS_BONES` in `tools/gen_cake_shared.py`, give the `tails` category that
   bone, and drop `'tails'` from `EXCLUDED`. The generator asserts the bone
   exists, so a typo fails at generation rather than silently in game.
2. **Resolve the 21 orphan `_eq` records.** Do they pair with plain Fashionwind
   records, or are `dbs_` bases missing from the plugin? Affects 20 eyewear
   items.
3. **Verify the bundled-renderer double-load case in game.** If a player also
   installs SuperSettingsRenderers standalone, both `.omwscripts` register the
   same MENU path and `I.Settings.registerRenderer('SuperSelect3', …)` runs
   twice. The Cod3x stub does not document whether re-registering a key errors
   or overwrites. If it errors, the fix is a version guard in the bundled copy
   (the AnimRefresh pattern) — but that means modifying third-party code, so
   confirm the behaviour before doing it. The manifest documents deleting the
   bundled folder as the manual workaround.
4. **Check the chest/belt split** — some bags likely belong on `Bip01 chestDBS`.
5. **`SharedTooltip_v4`** is unused. Natural fit: mark worn items in the
   inventory tooltip.
6. **`SharedRay_v2`** and `take_a_seat` (in `00_InDev`) are unused here.

---

## 7. Standing constraints (carried forward)

- `animation.cancel()` is on `openmw.animation`, not `I.AnimationController`.
- `PRIORITY.Scripted` pauses all non-Scripted animation globally — wrong for
  short cosmetic gestures; use `PRIORITY.Weapon` on an upper-body mask.
- Blend masks are bitmasks **summed**; `BONE_GROUP` ≠ `PRIORITY`.
- `onFrame` runs while paused; `onUpdate` does not. Prefer `onUpdate`, prefer
  events over polling, throttle to ≥1s.
- Read animation constraints from the binary (KF text keys, NIF nodes) — never
  infer from names. Both fatal CAKE bugs (#3, #4) were name-inference errors.
- `types.Actor.equipment` does not exist; it is `getEquipment`.
- **`blendMask` takes `BLEND_MASK`, not `BONE_GROUP`.** `BONE_GROUP` is a
  sequential index (LowerBody 1, Torso 2, LeftArm 3, RightArm 4); `BLEND_MASK`
  is a bitmask (1, 2, 4, 8). Summing `BONE_GROUP` values produces a valid but
  meaningless mask. `BLEND_MASK.UpperBody` (14) already means torso + arms.
- Attaching to a missing bone is a **silent no-show**, not an error.
