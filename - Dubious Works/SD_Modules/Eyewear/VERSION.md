# Eyewear v0.02

Same verification pass run on Scarves. **Records and bones check out
completely. Four script issues, all inherited from the template — which is
where they are fixed.**

---

## What is correct

| | |
|---|---|
| `SD_Gear.omwaddon` | 110 MISC = **55 base + 55 `_eq`** pairs |
| module ids | 20 base, **all 20 resolve**, and **all 20 `_eq` twins exist** |
| `SD_Goggles.esp` | `sd_goggles_luck1` — Fortify Attribute, **Luck** (attr 7), magnitude 1, type Ability |
| ability name in code | `LUCK_ABILITY = "sd_goggles_luck1"` — matches, and guarded by `core.magic.spells.records[...]` |
| `Bip01 eyesDBS` | present in **all four** skeleton folders |

The `xbase_animkna` copy of `dubiousBones.nif` differs from the other three,
which is expected — beast skeleton. The other three are byte-identical.

No `pcall` anywhere in the module's own scripts. The `hasBone` guard with a
vanilla fallback is already in place.

---

## Issues found

### 1 & 2. Both Scarves regressions are here too

Eyewear was templated from the pre-review Scarves, so it inherited both:

**`G_settingsChangedJobs = G_settingsChangedJobs or {}`** with a named key.
Every Sun's Dusk module uses `table.insert` (`p_clean.lua:2499`,
`p_temp.lua:3752`). Both forms get *called* — consumers iterate with `pairs()` —
but this reassigns a table the host owns on an ordering assumption never
checked. If the host ever created it after this module loaded, the handler would
be silently discarded.

**`---@omw-context global`** on `goggles_settings.lua`, which
`p_goggles.lua:55` requires from PLAYER. It runs in two contexts: GLOBAL takes
the `registerGroup` branch, PLAYER takes `registerPage`. `global` describes half
of what it does. Now `runtime`.

### 3. A missing mesh failed silently

`addVfx(rec.model)` with no `vfs.fileExists` check. Eyewear meshes ship
separately, and `addVfx` on a path not in the VFS attaches nothing **and says
nothing** — the item still swaps to its worn record and the Luck ability still
applies, so a user without the mesh pack gets eyewear that equips, buffs and is
invisible, with a clean log.

Guarded and logged. `vfs` is a Sun's Dusk global (`sd_p.lua:18`), so no new
require.

### 4. A linear scan on every Miscellaneous item use

```lua
for _, b in ipairs(EYEWEAR_IDS) do
    if b == id then eqId = id .. "_eq" break end
end
```

`BASE_OF_EQ` was already a hash; the base→`_eq` direction was not. This handler
runs on **every Miscellaneous use in the game**, so it walked a 20-entry list for
every potion and every key. Added `EQ_OF_BASE`, built in the same loop.

---

## The template is the real fix

All four faults are in `TEMPLATE/`, which is where the next module would pick
them up. **Every fix is applied to both `TEMPLATE/` and the shipped module**, so
this does not recur with the third one.

That is worth stating as a rule: when a mod is generated from a template, a bug
found in the mod is a bug in the template until proven otherwise, and fixing
only the instance guarantees it comes back.

---

## Not a bug, but worth a decision

**Base and `_eq` records share the same mesh** — `dbs_rv_blindfold1_h` and its
`_eq` twin both point at `RV\blindfold1.nif`.

RESEARCH §3.1 records that Bardcraft and Sun's Dusk both attach a *different*
mesh from the one the world object uses, and Bardcraft states why outright: a
mesh attached as VFX stops being interactable until the game restarts. Sun's
Dusk reaches the same place by naming — `_g` ground mesh on the base record, the
worn mesh on `_eq`.

It also means a dropped pair of goggles renders with its *worn* mesh, which for
something authored to hang off a bone usually sits wrong.

`SD_Gear.omwaddon` is new, so this is the cheapest moment to split it: point the
base records at a `_GND` variant and leave the worn mesh on `_eq`.

---

## Verification

Cod3x 0.4. Sun's Dusk modules need `--preset sunsdusk` on the two checkers that
execute code, since the host injects its environment as globals.

| Check | Result |
|---|---|
| `luacheck.py` (module + template) | 6 files, **0 failures** |
| `check_load.py --preset sunsdusk` | 3 files, **0 failures** |
| `globalcheck.py --preset sunsdusk` | **0 undeclared** |
| `ctxcheck.py` | **0 issues** |
| `api_sweep.py` vs Cod3x 0.4 | **nothing unrecognised** |
| `pcall` in the module's own scripts | **none** |
| `tools/test_goggles.lua` | **11/11** |

The test harness is new — Eyewear shipped none. Written fresh rather than
adapted from the Scarves one, which has two categories to Eyewear's one and
would have needed more editing than writing. It covers the equip swap, the
replacement and toggle, the ability, pass-through of unrelated items, the bone
fallback, and the missing-mesh guard. Its mock `addVfx` **asserts the path is in
the mock VFS**, so an unguarded attach fails the suite rather than passing it.

`tools/` also gained `check_load.py`, `globalcheck.py`, `ctxcheck.py`,
`check_names.py`, `api_sweep.py` and `luarun.py` — it shipped with three.
