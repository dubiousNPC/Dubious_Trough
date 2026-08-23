# Plugin state — `CAKEv4_2.json` + `CAKE_npc.json`

Produced by `tools/enrich_from_sources.py`, verified by `tools/validate_fixed.py`
(17 checks, all passing).

## Records are now defined from their source mods

Every CAKE wearable is a Miscellaneous stand-in for an `ARMO` record in one of
the mods that supplies its mesh. Those originals carry the authored name, the
icon path, and a weight and value the author chose. The CAKE records carried a
placeholder name, a uniform `0.5 / 2` for everything, and no icon on 61 of 160.

The link is the bodypart, and it needs no alias table or guesswork:

```
_RV_Ashmask_1 (Armor, "Dunmer Ashmask")
      └─ biped_objects[].male_bodypart ─→ _RV_Ashmask1_H (Bodypart)
                                                 └─→ dbs_RV_Ashmask1_H (CAKE)
```

**158 of 160** resolve this way, across all seven source files.

| | before | after |
|---|---|---|
| records with an icon | 99 / 160 | **158 / 160** |
| distinct weights | 1 | 12 |
| distinct values | 1 | 19 |
| placeholder names | 160 | 0 |

```
dbs_RV_Ashmask1_H   "Ashmask 1"       ->  "Dunmer Ashmask"
dbs_RV_Ashmask3_H   "Ashmask 3"       ->  "Visorless Dwemer Ashmask"
dbs_RV_Scarf_10     "Scarf 10"        ->  "Expensive Ashlander Scarf"
dbs_ash1            "Ash lantern 1"   ->  "Wearable Ashlander Lantern 1"
```

Values are scaled to a quarter of the source, floored at 1. The originals are
enchanted armour worth 100+; these carry no armour rating and should not price
like it, but 46 lanterns all worth exactly 2 was no better. Scaling keeps the
relative ordering the author chose.

Names that still collide after enrichment get numbered, and the worn half
always copies its base, so a pair can never disagree.

## Asset paths untouched

Meshes, icons and textures are supplied by the source mods, so every path is
reproduced exactly as written — original case, original backslashes. The
enrichment script **asserts** no mesh path changed, and deliberately does not
take the ARMO's mesh: those are `_GND` ground meshes, while the CAKE record's
is the worn variant.

```
OAAB\l\dwrv_lantern.nif        tr\l\TR_l_de_MhLant_whi_03.nif
pc\l\pc_col_lantern_02.nif     RV\Ashmask1.nif
```

Four assertions in `tools/test_shared.lua` carry this through to
`cake_shared.lua`, including one that checks a real backslash survives into the
runtime string rather than only the source.

## CAKE_npc.json

Container and vendor inventories, 194 entries:

| | count |
|---|---|
| already valid | 158 |
| remapped via source mod | 20 |
| vanilla, untouched | 14 |
| dropped — no such record | 2 |

The remap needs no alias table either: the same Armor → bodypart → CAKE chain
turns the authored `adamantium_tail` into `dbs_1adamantail`.

`arg_domina` and `domina_tail` were **dropped**. They exist in the source mod
and in the old `CAKE.esp`, but no `dbs_` record for them exists in `CAKEv4_2`
(`dbs_1argdomina`, `dbs_1argdominaf`, `dbs_1dominatail` are all absent). A
reference to an undefined record is a load warning and an item that can never
appear. Re-add the three records if you want these back.

## Outstanding

- **2 cigars** (`dbs_01cigar`, `dbs_02cigar`) have no source mod among the
  seven supplied, so no name, icon or value could be taken. They keep their
  placeholder.
- **32 tails** are in the plugin but excluded from `cake_shared.lua`:
  `xbase_anim_dbs.nif` has no tail bone. Their records are inert — using one
  does nothing — until a beast skeleton (`xbase_animkna`) with a tail bone
  ships.
- **9 records depend on undeclared masters**: 4 Project Cyrodiil, 3 the
  Skyrim-style lantern mod, 2 OAAB_Data. Paths are correct; declare the masters
  or document them as soft requirements. Listing in `tools/mesh_provenance.json`.
- These are **JSON**, not `.esp`.

## Regenerating

```
python3 tools/enrich_from_sources.py   # source mods -> fixed/*.json
python3 tools/validate_fixed.py        # 17 checks + registry inputs
python3 tools/gen_cake_shared.py       # -> cake_shared.lua
python3 tools/sweep.py
python3 tools/luarun.py tools/test_integration.lua
```

`tools/sources/` holds the seven source-mod exports the enrichment reads.
