# SD Scarves v0.05

## Worn items vanished until taken off and put back on

The symptom: a worn scarf, mask or pair of goggles disappears, and only
re-equipping brings it back. Rest and loading a save showed it too.

**Cause: half of p_backpacks' sluggish job was copied.** Switching first/third
person rebuilds the player's animation object and silently drops every
attached VFX. Sun's Dusk does **not** re-attach a module's VFX for it —
`p_backpacks` notices the change itself, in its own throttled job, right beside
the inventory check. This module had the inventory check and not the camera
check, so nothing ever re-attached after a perspective switch. Re-equipping
worked because that calls `refreshVfx` directly.

### Fix

The camera check now sits in the same throttled job, as it does in
`p_backpacks`:

- It compares the **first-person boundary**, not the raw mode. ThirdPerson,
  Preview and Vanity all draw the same model, so idling into auto-vanity must
  not re-attach anything.
- The baseline advances even when nothing is worn, so a switch made while
  bare is not replayed the moment something is put on.
- Being on the throttled list is also what makes it reliable: the tick lands
  after the rebuild has finished, so the re-attach is not racing it.

`UiModeChanged` now also covers **Training** and **Jail**, which rebuild the
model exactly as Rest and Travel do.

### Tests

Five new checks in `tools/test_scarves.lua`, and they **fail on the previous build** —
verified by running them against it:

```
  FAIL vfx re-attached after switching to first person
  FAIL vfx re-attached after switching back
```

Sweep clean: luacheck, check_load, globalcheck, ctxcheck, api_sweep (all with
`--preset sunsdusk` where applicable).

---

# Scarves v0.04

Bug sweep of the uploaded package. **One fatal regression, two reverted fixes,
one content gap.**

---

## 1. `SD_Scarves.esp` was missing — fatal

The upload ships only `SD_Scarves_abilities.esp` (10 `SPEL` records). The item
plugin — 320 `MISC` records, the `dbs_<thing>` / `dbs_<thing>_eq` pairs — is
gone.

`g_scarves.lua` names **33 base ids** (16 scarves, 17 masks). With no plugin
defining them, `world.createObject(entry.eq, 1)` has nothing to create and using
any scarf raises. Nothing else in the package supplies them.

Restored. Both plugins must be enabled:

```
SD_Scarves.esp             320 item records
SD_Scarves_abilities.esp   10 ability records
```

Neither carries a `LUAL` record, which is correct here — this is a Sun's Dusk
module and SD's own loaders pick the scripts up from
`scripts/SunsDusk/{settings,global_modules,player_modules}/` by directory scan.

## 2. Both fixes from the v0.03 review were reverted

The scripts in the upload are the **pre-review** versions.

**`G_settingsChangedJobs`** was back to:

```lua
G_settingsChangedJobs = G_settingsChangedJobs or {}
G_settingsChangedJobs.sdScarves = function(...)
```

Every Sun's Dusk module registers with `table.insert` (`p_clean.lua:2499`,
`p_temp.lua:3752`). Both forms are *called*, because the consumers iterate with
`pairs()` — but `= G_settingsChangedJobs or {}` reassigns a table the host owns,
on an ordering assumption never checked. If the host ever created it after this
module loaded, the handler would be silently discarded. Back to `table.insert`.

**`scarves_settings.lua`** was back to `---@omw-context global`. It runs in two
contexts: `sd_g.lua` requires it from GLOBAL (where `world` is set, so
`registerGroup` runs) and `p_scarves.lua` requires it from PLAYER (where `world`
is nil, so `registerPage` runs). Annotating it `global` describes half of what
it does. Back to `runtime`, with the header corrected.

## 3. Mask meshes are not shipped, and the failure was silent

Genuinely new and good: **16 scarf meshes** added under `meshes/RV/`. Every one
matches a record's model path exactly — `dbs_rv_scarf_01` → `RV/scarf1.nif`
through `scarf16.nif`, all 16 resolved, none missing.

But the module also ships **17 mask ids** whose meshes are not here:

```
RV/Ashmask1-3.nif   RV/Daedramask1-4.nif
RV/Facewrap1-8.nif  RV/Orcishmask1-2.nif
```

Those come from CAKE or Fashionwind. `addVfx` on a path that is not in the VFS
attaches nothing **and says nothing** — the item still swaps to its worn record
and the blight resistance still applies, so a user with neither installed gets a
mask that equips, buffs, and is invisible, with nothing in the log.

`refreshVfx` now checks `vfs.fileExists(record.model)` first and logs once:

```
[SD Scarves] mesh not in VFS, skipping: RV\Ashmask1.nif
(masks need CAKE or Fashionwind installed)
```

Reported, not swallowed. `vfs` is a Sun's Dusk global (`sd_p.lua:18`), so no new
require.

**Decide which you want:** ship the 17 mask meshes and be standalone, or declare
CAKE/Fashionwind a requirement in the README. Right now it is neither, and the
diagnostic is a stopgap.

---

## Verification

Cod3x 0.4. Sun's Dusk modules need `--preset sunsdusk` on the two checkers that
execute code, since the host injects its environment as globals.

| Check | Result |
|---|---|
| `luacheck.py` | 3 files, **0 failures** |
| `check_load.py --preset sunsdusk` | 3 files, **0 failures** |
| `globalcheck.py --preset sunsdusk` | **0 undeclared** |
| `ctxcheck.py` | **0 issues** |
| `pcall` in the module's own scripts | **none** |
| `tools/test_scarves.lua` | **20/20** |

One test is new: a record whose mesh is absent from the VFS attaches nothing and
does not error. The harness also gained a `vfs` stub — it had none, so the guard
above would have failed the suite for the wrong reason.

Plugins confirmed: `SD_Scarves.esp` 320 MISC, `SD_Scarves_abilities.esp` 10 SPEL.
