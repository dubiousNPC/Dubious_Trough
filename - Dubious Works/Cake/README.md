# CAKE — Cosmetic Attachment Kit for Equipment

Wearable accessories that take no equipment slot: masks, eyewear, scarves,
lanterns, belts, bags and cigars. Drag one onto your character in the inventory
to put it on; do the same with the worn one to take it off.

Requires OpenMW 0.52.

## Install

| folder | content files | needs |
|---|---|---|
| `00 Core` | `Cake_Gear.omwaddon`, `CAKE.omwscripts` | nothing; ships its own meshes and icons |
| `01 Lanterns Belts Bags` (optional) | `cake_v4.2.esp` | Tamriel_Data (27 lanterns use its meshes), OAAB_Data (2 lanterns) |
| `02 Balmora Outfitter` (optional) | `cake_npc.esp` | both folders above |

Add each folder you use as a data directory and enable its content files.
`02` stocks Clagius Clanler's shop in Balmora with everything.

Two sets of models are not shipped by any folder here: the 13 belts in
`meshes/Belts/` and the 2 cigars in `meshes/ep/`. Without them those items
show the yellow error marker. `tools/check_meshes.py` lists what is missing.

## What you can wear

| category | items | attaches to | on skeletons without the CAKE bones |
|---|---|---|---|
| masks | 17 | `Bip01 mouthDBS` | `Head` |
| eyewear | 20 | `Bip01 eyesDBS` | `Head` |
| scarves | 16 | `Bip01 scarfDBS` | `Bip01 Neck` |
| smokes | 2 | `Bip01 mouthDBS` | `Head` |
| lanterns | 46 | `Bip01 L hipDBS` | `Bip01 Pelvis` |
| belts | 14 | `Bip01 beltDBS` | `Bip01 Pelvis` |
| bags | 13 | `Bip01 beltDBS` | `Bip01 Pelvis` |

One item per category. A mask and a cigar take each other off.

The CAKE bones come from `animations/<skeleton>/dubiousBones.nif`, which OpenMW
grafts onto the six humanoid skeletons. WhyWalk ships the same file at the same
path. Four of its 14 bones are never added, because their parent in the file
(`Bip01 Spine00`, `Bip01 Neck1`) is not a bone of the game's skeletons:
`Bip01 L hipDBS`, `Bip01 R hipDBS`, `Bip01 capeDBS` and `Bip01 pendantDBS`. So
lanterns hang from `Bip01 Pelvis` for now. `tools/nif_bones.py` shows this.

Not wearable, and left out on purpose:

- **Tails** (32 in `cake_v4.2.esp`): there is no tail bone to attach them to.
- **Argonian scarves** (11 in `Cake_Gear.omwaddon`): the meshes are skinned
  body-part meshes. Attached to a bone they draw nothing, so they would be worn
  invisibly.

## Settings

- **NPCs wear accessories** (on): show what other characters wear.
- **Show in first person** (off): face items clip through the camera.

## Cost

Nothing runs per frame. Drawing happens when you put something on, when the
player model is rebuilt (through AnimRefresh), and when an NPC that wears
something comes into view. NPCs that wear nothing get no script at all.

## For other mods

- `I.CAKE.getWorn()` returns `category -> base record id` for the player.
- `I.CAKE.refresh()` redraws the player's items.
- After changing an NPC's CAKE items, send
  `core.sendGlobalEvent('Cake_RefreshNpc', { actor = npc })`.

## Development

`tools/` is not part of the mod; don't add it as a data directory.

```
tools/check_all.sh              # every check below; set LUAJIT, COD3X, MW_DATA to add more
tools/gen_cake_shared.py        # rebuild scripts/cake/cake_shared.lua from the plugins
tools/test_integration.lua      # the scripts + real AnimRefresh v6 on a simulated engine
tools/check_meshes.py           # every worn model exists and is not skinned
tools/check_manifest.py         # every script in the manifest exists, flags and contexts agree
tools/nif_bones.py              # which bones dubiousBones.nif adds, and which it cannot
```

`cake_shared.lua` is generated. A model path that matches no category rule
fails generation, as does a worn record without its base.
