# Sun's Dusk :: Scarves and Masks

A Sun's Dusk **module**, built to mirror `g_backpacks.lua` / `p_backpacks.lua`.
Item ids, bones and meshes are generated from CAKE's `cake_shared.lua` — 16
scarves and 17 masks.

Installed by dropping files into Sun's Dusk's own script directories, which its
loaders scan -- there is deliberately **no `.omwscripts`**. See CRASH.md.

Load **after** Sun's Dusk. This uses Sun's Dusk's shared environment (`types`,
`world`, `I`, `self`, `animation`, `async`, `core`, `util`, `saveData`,
`typesActorSpellsSelf`, `typesActorInventorySelf`, `log`, `MODNAME`, and the
`G_*` job lists) and requires none of them, exactly as the backpack module does.

---

## What it does

Same mechanism as backpacks: a `types.Miscellaneous` item and an `_eq` twin,
swapped by an `ItemUsage` handler. No equipment slot is consumed, so a scarf
costs you no helmet and no pauldron, and the worn state is visible in the
inventory as its own item.

| | Backpacks | This |
|---|---|---|
| Bonus | carry weight (Feather, scaled to camping gear) | **scarves:** warmth · **masks:** blight resistance |
| Categories | one | **two, worn together** |
| Bone | `Bip01 backpackSD` / `backpackWE` | `Bip01 scarfDBS` / `Bip01 mouthDBS` |

### Two categories, not one

A scarf and a mask sit on different bones and are worn simultaneously. The
"take off what's already worn" step is therefore **per category**: a second
scarf replaces the first, a mask leaves the scarf alone.

### `getBaseId` is a reverse lookup, not string surgery

`g_backpacks.lua` derives the base id with `equippedId:sub(1, -4)`, which is
correct only while every id ends in exactly `_eq` and the base record exists.
This uses an explicit table, so it cannot silently produce an id that was never
defined — and the table is the module's whole vocabulary in one place.

---

## The bonuses, and an honest note about warmth

Both are granted as **ability records**, which is how backpacks grants Feather
and how Sun's Dusk itself grants hearthfire comfort.

### Masks — blight resistance

One record per 10% step (`sd_mask_blight_10` … `_50`), effect
**Resist Blight Disease**. Default 30%. The setting snaps to the nearest step.

### Scarves — warmth

Binary-encoded over five records (`sd_scarf_w1` … `w5`, magnitudes 1/2/4/8/16),
so any value 0–31 is expressible; the setting allows 0–20, default 4. Only the
bits that change are added or removed, exactly as `updateFeatherMagnitude` does.

The effect data was read out of Sun's Dusk's own plugin rather than guessed:
`sd_hearthfire_1..4` are **Fortify Attribute on Willpower (attribute 2)**,
magnitudes 2/4/6/8, spell type Ability. These records mirror that exactly, so a
scarf warms you by the same mechanism a fire does.

**What this does not do:** it does not bend the temperature curve. Sun's Dusk
computes that from `equipmentData` in `p_temp.lua`, which scans **equipped**
armour and clothing for material modifiers — and a CAKE scarf is a
Miscellaneous item occupying no slot, so it is invisible to that scan.
`I.SunsDusk`'s temperature functions return display *strings*, not numbers, so
there is nothing to add to there either.

The one true hook is `G_coolRate`, which insulation would naturally multiply.
It is **not** used here, deliberately: `p_temp.lua` resets it to `1` at line
3299 and consumes it at line 3472, so writing it from a module means racing
that window every cycle, and losing the race produces a bonus that silently
does nothing some of the time. If you want real curve modification, the clean
version is a one-line hook inside `p_temp` — an `G_externalColdResistance`
global folded into `equipmentData.coldResistance` — rather than a module
reaching in from outside. Say the word and I'll write that patch.

---

## Settings

Sun's Dusk's own convention: `l10n = "none"` (literal text, not keys), and each
key becomes a **global of the same name**, written by `readAllSettings()` and
kept current by the section subscription — the same way `p_clean.lua` reads
`NEEDS_CLEAN`.

| Key | Default | Range |
|---|---|---|
| `SCARVES_ENABLED` | on | checkbox |
| `SCARVES_WARMTH` | 4 | 0–20 |
| `MASKS_ENABLED` | on | checkbox |
| `MASKS_BLIGHT_RES` | 30% | 0–50, step 10 |

Changing a magnitude re-evaluates the abilities only, through
`G_settingsChangedJobs` — the worn item has not moved, so nothing is
re-attached.

---

## Records you need

`SD_Scarves_abilities.esp` ships the 10 spell records the module looks for; the
generator that wrote it is `tools/make_abilities_esp.py`.
Every ability is applied only `if core.magic.spells.records[id]`, so a missing
record degrades to **no bonus** rather than an error — strip them and the module
still works as a cosmetic.

The item pairs (`dbs_rv_scarf_01` / `dbs_rv_scarf_01_eq`, and the 17 masks) come
from CAKE's plugin; this module does not define them.

---

## Behaviour inherited from backpacks

- **Refresh on Rest and Travel** — those rebuild the player model and drop VFX.
- **`hasBone` guard with one 0.1s retry** — right after a perspective change the
  skeleton is still being rebuilt, and attaching to a bone that is not ready
  yet attaches nothing, silently.
- **`record.model`, never a baked path** — the record's model is a VFS path; a
  plugin's raw MODL string is not, and attaches nothing.
- **Cell sweep when a worn item leaves the inventory** — dropped, sold, put in a
  container or pickpocketed, `_eq` records are converted back across the cell,
  containers, NPCs and creatures.
- **The sluggish frame list**, not per-frame, and it returns immediately when
  nothing is worn.

Each category falls back to a vanilla bone (`Bip01 Neck`, `head`) when the DBS
rig is absent, rather than showing nothing.

---

## Testing

```
python3 tools/luarun.py tools/test_scarves.lua
```

Mocks Sun's Dusk's shared environment and drives the real handlers. **19/19
pass**, including the two things most likely to break: that the categories are
independent, and that a worn item leaving the bag triggers the cell sweep. The
mock `addVfx` asserts a VFS path that exists, per RESEARCH §4.1.

Regenerate the module from CAKE with `tools/gen_sd_scarves.py`.
