# Plugin audit — CAKE402.json and CAKE3npcCont.json

Checked: record counts, ID uniqueness, base/`_eq` pairing, display names, icons,
mesh resolution, master declarations, and cross-file reference integrity.

**Verdict: CAKE402 cannot work as a CAKE plugin in its current state.** Four
blocking defects, listed first. CAKE3npcCont is internally sound but stocks a
generation of item IDs that no longer exists.

---

## CAKE402.json — blocking

### 1. The `_eq` suffix went on the display name, not the record ID

This is the whole problem, and everything else follows from it.

The file holds **320 MiscItem records with only 160 unique IDs** — two blocks of
160, in the same order. Records 0–159 and 160–319 differ in exactly one field:

| | record #0 | record #160 |
|---|---|---|
| `id` | `_RV_Ashmask1_H` | `_RV_Ashmask1_H` |
| `name` | `Ashmask` | `Ashmask_eq` |
| `mesh` | `RV\Ashmask1.nif` | `RV\Ashmask1.nif` |

The second block was meant to be the worn variants. The suffix landed on `FNAM`
(display name) instead of `NAME` (record ID). Consequences:

- **The second block silently overwrites the first on load**, because TES3
  resolves duplicate IDs last-wins. You end up with 160 records, every one
  displaying as "Ashmask_eq", "Scarf_eq", "lantern_eq" in the inventory.
- **There are zero `_eq` records**, so the equip mechanism has nothing to swap
  to. `CAKE.baseOf()` and `CAKE.eqOf()` have nothing to index, and no item can
  ever be worn.

**Fix:** append `_eq` to `id` on records 160–319 and revert `name` to the base
string. The worn variant should keep its base display name, or carry a
deliberate marker like `Ashmask (worn)` — but the marker must never be the
mechanism.

### 2. No `dbs_` prefix

Zero of the 160 IDs carry it. CAKE.esp / CAKE34.esp use `dbs_<thing>` /
`dbs_<thing>_eq` throughout, and `cake_shared.lua` is generated against that
scheme. Either convention is fine, but it has to be one convention — the
generator asserts it, so a mismatch fails at generation rather than in game.

### 3. Every one of the 160 IDs is also a Bodypart ID

159 of 160 CAKE402 MiscItem IDs collide exactly with Bodypart IDs in
CAKE3npcCont: `_RV_Blindfold1_H`, `1adamantail`, and so on. The `_H` suffix is
the Fashionwind convention for a **Hair-slot bodypart**, and CAKE402 has reused
those IDs verbatim for wearable Miscellaneous items.

TES3 keeps bodyparts and misc items in separate stores, so this does not clash
at the engine level — but every CAKE item is now named after a bodypart it is
not, `_H` implies a slot these records do not have, and any tooling that indexes
by ID across types will conflate them. It also makes fix #1 ambiguous:
`_RV_Ashmask1_H_eq` reads as "the worn variant of a hair bodypart".

**Recommendation:** rename to `dbs_rv_ashmask1` / `dbs_rv_ashmask1_eq`, dropping
`_H`. That resolves #2 and #3 together.

### 4. No icons — all 320 records

Not one MiscItem has an `icon` field. A Miscellaneous item with no icon renders
as a blank slot, which for a mod whose entire interaction is "click the thing in
your inventory" is a hard usability failure.

99 of 160 have been filled from icons that ship in the CAKE archive, matched by
rule and by reusing the icon each equivalent ARMO record already uses. The
remaining 61 — 39 lanterns, 13 belts, 7 tails, 2 cigars — need icon paths from
the mods that supply their meshes. Those were left **empty rather than guessed**:
a wrong path renders blank exactly like an empty one, but also buries a false
reference in the record. Fill them from the source mods.

---

## CAKE402.json — non-blocking

### 5. Five records have no display name at all

`_RV_Goggles5_H`, `_RV_Goggles6_H`, `_RV_Goggles7_H`, `_RV_Goggles8_H`,
`_RV_Orcishmask1_H` have `name: null`. These are also the only five pairs where
blocks A and B are byte-identical — the rename pass skipped them precisely
because there was no name to append to. They show as blank text in the
inventory.

### 6. Three display names are wrong

| ID | Name | Mesh | Should be |
|---|---|---|---|
| `_RV_Ashmask3_H` | `tail armor` | `RV\Ashmask3.nif` | Ashmask |
| `_RV_Blindfold1_H` | `Ashmask` | `RV\blindfold1.nif` | Blindfold |
| `hfirebelt` | `lantern` | `Belts\belt_hfire.nif` | a belt name |

Copy-paste drift. Worth a full pass rather than just these three.

### 7. Display names are heavily duplicated

16 items named `Scarf`, 11 `Wearable paper lantern`, 10 `lantern`, 9 `Wearable
Indoril lantern`, 8 `Facewrap`, 7 `Glasses`, 7 `Ash lantern`. Since the swap
mechanism returns the *base* item to the inventory when you take something off,
a player holding several scarves cannot tell them apart.

### 8. Every record has identical weight and value

All 160: `weight 0.5`, `value 2`. Harmless, and arguably right for cosmetics —
flagged only in case it was meant to vary.

### 9. Three undeclared master dependencies

Declared: `Morrowind.esm`, `Tribunal.esm`, `Bloodmoon.esm`, `Tamriel_Data.esm`.

Mesh provenance across the 160 base records:

| Source | Records | Declared? |
|---|---|---|
| CAKE (bundled) | 114 | n/a |
| Tamriel_Data.esm | 20 | yes |
| Morrowind.esm (vanilla) | 17 | yes |
| Project Cyrodiil (`pc\`) | 4 | **no** |
| Skyrim-style lantern mod (`sky\`) | 3 | **no** |
| OAAB_Data.esm (`OAAB\`) | 2 | **no** |

These nine records depend on assets those mods supply. **The paths are correct
and must stay exactly as written** — the fix is to declare the masters (or
document them as soft requirements), not to alter or remove the records. Full
per-record listing in `tools/mesh_provenance.json`.

---

## CAKE3npcCont.json

Internally consistent. 163 Bodypart, 20 Armor, 10 Container, 5 Enchantment,
2 Static, 2 MiscItem, 1 NPC, 1 Cell edit (Balmora, Clagius Clanler: Outfitter,
adding vendor `_RV_glassesman` and stocked barrels).

- All 20 Armor → Bodypart references resolve. ✓
- All 5 Enchantment records are defined. ✓
- Masters (Morrowind/Tribunal/Bloodmoon) match its content. ✓

### 10. The containers stock items from a dead generation

135 distinct inventory entries across the containers and the vendor reference
IDs that exist in **neither** file. Excluding ~30 vanilla items the NPC
legitimately carries (`extravagant_pants_02`, `sc_vigor`, …), roughly 105 are
CAKE content under obsolete names.

Three ID generations are now in circulation:

| Gen | Example | Where it lives |
|---|---|---|
| 1 | `GlassLantern2`, `LanternDwem`, `_RV_Ashmask_1`, `_RV_Scarf01` | containers + the original `globalcake.lua` list |
| 2 | `dbs_GLantern2_eq` | CAKE.esp / CAKE34.esp |
| 3 | `GLantern2`, `_RV_Ashmask1_H` | CAKE402.json |

Only 30 of the 105 map cleanly onto a CAKE402 record by rule
(`GlassLantern`→`GLantern`, `LanternPaper`→`LanternPap`, drop the underscore
before a digit, add `_H`). The remaining ~75 — all 16 scarves, the tails, the
`fy_*` bags, `commonbelt*`, `ashl*`, `colovianlant*`, `orclantern*`,
`TravelLantern*`, `Indoril*`, `LanternDwem`, `cavernlant` — have no counterpart
under any transformation.

**Net effect: 130 of the 160 CAKE402 wearables are unobtainable.** Nothing
stocks them.

---

## Category coverage (CAKE402, 160 items)

| Category | Count |
|---|---|
| lanterns | 48 |
| tails | 32 |
| eyewear | 19 |
| masks | 18 |
| scarves | 16 |
| bags | 13 |
| belts | 12 |
| smokes | 2 |

Coverage matches CAKE.esp closely, so the *content* survived the rename intact.
It is the naming and the pairing that broke.

**Tails (32) still have nowhere to attach.** `xbase_anim_dbs.nif` has no tail
bone — all 123 nodes were read. They belong on the beast skeleton
(`xbase_animkna`), which is not in the package, so they stay excluded from
`cake_shared.lua`.

---

## Fix order

1. Move `_eq` from `FNAM` to `NAME` on records 160–319 and restore the base
   display names. Nothing works until this is done.
2. Settle on one ID scheme — `dbs_<thing>` / `dbs_<thing>_eq` recommended, which
   also resolves the bodypart-ID collision.
3. Add icons to all 320 records; the 96 shipped icon files cover most.
4. Fill the 5 empty names, fix the 3 wrong ones, de-duplicate the rest.
5. Update container and vendor inventories to the final IDs, or the items stay
   unobtainable.
6. Declare `OAAB_Data.esm`, Project Cyrodiil and the `sky\` lantern mod as
   masters or soft requirements. Do **not** alter or drop those 9 records —
   their paths point at assets those mods provide and are correct as written.

Once 1, 2 and 5 are done:

```
python3 tools/tes3.py <plugins>      # -> cake_records.json
python3 tools/gen_cake_shared.py     # -> cake_shared.lua
python3 tools/sweep.py               # cross-reference check
python3 tools/luarun.py tools/test_integration.lua
```

The generator asserts every category bone exists in the skeleton, and
`sweep.py` cross-references categories, settings, events and l10n keys — so a
fourth ID generation fails loudly rather than silently.
