# Glasses, Goggles & Eyepatches — a Sun's Dusk module

Wearable eyewear from the CAKE item set: **20 records** — glasses, goggles,
eyepatches, lenses, blindfolds. Occupies no equipment slot.

**Boon:** 1 point of Luck while worn. One setting toggles it off.

## Install

Add `Eyewear` as a data directory. Enable **both** plugins, after Sun's Dusk:

```
SD_Goggles.esp              item records (the CAKE eyewear set)
SD_Goggles_abilities.esp    1 SPEL record — sd_goggles_luck1
```

There is deliberately **no `.omwscripts`**. Sun's Dusk loads modules by
scanning its own directories; declaring them in a manifest as well is fatal at
load. See `TEMPLATE/README.md`.

## The hook

Other Sun's Dusk player modules ask whether eyewear is worn through the
plain-global convention Sun's Dusk uses internally:

```lua
local worn, baseId, eqId = G_gogglesIsWorn()
```

There is no `I.SunsDuskGoggles`. A module runs inside `sd_p.lua` and cannot
publish an interface; v0.02 tried to assign one, which aborted `sd_p.lua` on
load and took every Sun's Dusk player module down with it (fixed in v0.03).

Returns `false, nil, nil` when nothing is worn, otherwise `true` plus both
record ids so a caller can branch on **which** pair.

It reads explicit saved state, not the inventory. An inventory scan answers a
different question — "is an `_eq` record in the bag" rather than "is a pair
being worn" — and is wrong for a looted one.

## Files

| | |
|---|---|
| `settings/goggles_settings.lua` | one checkbox, `GOGGLES_ENABLED` |
| `global_modules/g_goggles.lua` | the ItemUsage equip swap, cell sweep |
| `player_modules/p_goggles.lua` | worn state, the Luck ability, VFX, the hook |
| `TEMPLATE/` | skeletons + checklist for the next module |
| `tools/make_abilities_esp.py` | regenerates the ability plugin |
| `tools/check_manifest.py` | catches the one-path-two-flags crash |

Zero `pcall`. Zero undeclared globals. Contexts verified against Cod3x.
