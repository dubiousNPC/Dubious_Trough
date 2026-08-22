# Corrected plugins

`CAKE402.json` and `CAKE3npcCont.json`, rewritten by `tools/fix_plugins.py` and
verified by `tools/validate_fixed.py` (17 checks, all passing).

## ID scheme

`dbs_` + the original id with its leading underscore stripped, `_eq` for the
worn half:

```
_RV_Ashmask1_H  ->  dbs_RV_Ashmask1_H   /  dbs_RV_Ashmask1_H_eq
1adamantail     ->  dbs_1adamantail     /  dbs_1adamantail_eq
GLantern2       ->  dbs_GLantern2       /  dbs_GLantern2_eq
```

This is not a new convention. It reproduces the ids already in
CAKE.esp/CAKE34.esp for **159 of 160** records, and all 160 `_eq` partners
already exist there — so this converges the two generations rather than adding
a third. The prefix also resolves the bodypart collision: `dbs_RV_Ashmask1_H`
no longer shadows the `_RV_Ashmask1_H` bodypart.

## CAKE402.json

| | before | after |
|---|---|---|
| records | 320 | 320 |
| unique ids | **160** | **320** |
| `_eq` records | **0** | **160** |

- **The `_eq` suffix moved from `FNAM` to `NAME`.** Previously both blocks of
  160 shared one id set, so the second overwrote the first on load and no worn
  variant existed. Records now pair as `dbs_X` / `dbs_X_eq`, interleaved.
- **Display names restored.** Nothing reads "Ashmask_eq" any more. Both halves
  of a pair carry the same name; the worn state is conveyed by the item having
  moved, not by its text.
- **5 empty names filled** (`Goggles5-8`, `Orcishmask1` had `name: null`).
- **3 wrong names fixed**: `Ashmask3` was "tail armor", `Blindfold1` was
  "Ashmask", `hfirebelt` was "lantern".
- **Duplicate names numbered.** 16 items called "Scarf" are now "Scarf 1".."16".
  This matters because taking something off returns the *base* item to the
  inventory, so identical names are unusable.
- **99 of 160 records gained icons**, matched by rule against the shipped icon
  files and by reusing the icon the equivalent ARMO record already uses.

## CAKE3npcCont.json

Inventory references remapped so the items are obtainable. Of 194 entries:

| | count |
|---|---|
| already valid | 21 |
| remapped via explicit alias | 104 |
| remapped by normalising | 33 |
| vanilla, left untouched | 14 |
| unresolved | 22 |

**All 22 unresolved are tails**, which are excluded by design.

Aliases were curated, not fuzzy-matched. `difflib` confidently mapped
`LanternPapery1` onto `LanternPap1` — a different lantern, and one already
claimed by `LanternPaper1`. Every alias in `fix_plugins.py` was checked against
the target record's mesh path, and the script asserts no two source ids collapse
onto one record.

Notable renames the aliases cover: `GlassLantern*`→`GLantern*`,
`LanternPaper*`→`LanternPap*` (with `prp`→`pur` and `y`→`yel`),
`Indoril*`→`TRIndoril*Lan*`, `commonbelt*`→`cbelt*`, `fy_*`→`aa_*`,
`LanternDwem`→`Lantern0AABDwrn`, `ashl*`→`ash*`.

## Still outstanding

- **61 records have no icon**: 39 lanterns, 13 belts, 7 tails, 2 cigars. No
  icon files exist for these in the archive — a content gap, not a data one.
- **32 tails** remain excluded from `cake_shared.lua`. `xbase_anim_dbs.nif` has
  no tail bone; they need a beast skeleton (`xbase_animkna`).
- **9 meshes come from undeclared masters**: 4 Project Cyrodiil (`pc\`), 3 a
  Skyrim-style lantern mod (`sky\`), 2 OAAB_Data (`OAAB\`). Only Tamriel_Data
  is declared. Declare them, bundle the meshes, or drop the records.
- These are **JSON**, not `.esp`. Convert with whatever produced the exports.

## Regenerating

```
python3 tools/fix_plugins.py       # rewrite from the originals
python3 tools/validate_fixed.py    # 17 checks + emit registry inputs
python3 tools/gen_cake_shared.py   # -> cake_shared.lua
python3 tools/sweep.py
python3 tools/luarun.py tools/test_integration.lua
```
