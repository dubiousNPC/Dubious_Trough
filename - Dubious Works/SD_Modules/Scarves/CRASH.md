# The startup crash, and what it was

```
OpenMW: Fatal error
Flags mismatch for scripts/sunsduskscarves/scarves_settings.lua
```

## Cause

The manifest I shipped declared one file under two different flags:

```
MENU:   scripts/SunsDuskScarves/scarves_settings.lua
GLOBAL: scripts/SunsDuskScarves/scarves_settings.lua
```

OpenMW allows a script path exactly one set of flags. Declaring it twice is
fatal at load, before the main menu — so the whole game refused to start, not
just the mod. My mistake, and a careless one: I copied Sun's Dusk's
`if world then registerGroup else registerPage end` pattern, which needs the
file loaded in two contexts, and reached for the manifest to do it.

## Why the manifest was the wrong tool

**Sun's Dusk does not list its settings or modules in its manifest at all.**
Its whole manifest is eight lines, and `clean_settings.lua`, `g_backpacks.lua`
and `p_backpacks.lua` appear in none of them. They are picked up by Sun's Dusk's
own loaders:

```lua
-- sd_g.lua:43
for filename in vfs.pathsWithPrefix("scripts/SunsDusk/settings/") do ... require(...) end
-- sd_g.lua:56   -> scripts/SunsDusk/global_modules/
-- sd_p.lua:390  -> scripts/SunsDusk/player_modules/p_*
```

A module is installed by **dropping files into those directories**. The VFS
merges data directories, so a separate mod folder works fine. That is how the
backpack module ships, and it is what "mimic the backpacks module" should have
meant structurally, not just behaviourally.

## The fix

No `.omwscripts` at all. The layout is now:

```
Scarves/
  scripts/SunsDusk/settings/scarves_settings.lua        auto-loaded by sd_g.lua
  scripts/SunsDusk/global_modules/g_scarves.lua         auto-loaded by sd_g.lua
  scripts/SunsDusk/player_modules/p_scarves.lua         auto-loaded by sd_p.lua
```

One wrinkle worth knowing: `sd_g.lua`'s settings loop runs in **global** context
only, where `world` is set and the file takes its `registerGroup` branch.
Registering the *page* needs a non-global context, and `sd_p.lua` requires only
`sd_settings` by name — so `p_scarves.lua` requires its own settings file, which
is the same thing `sd_p.lua:381` does. It also guarantees `SCARVES_WARMTH` and
friends exist before the player module reads them.

## The second problem, which the crash was hiding

**`SD_Scarves.esp` contains 320 MISC records and zero SPEL records.** It is the
CAKE item plugin; the ability records the bonuses need were never in it. Every
`core.magic.spells.records[id]` lookup would have missed, and because the module
guards each one (`if core.magic.spells.records[id] then`), that failure would
have been *silent* — scarves and masks would have equipped and displayed
correctly and simply granted nothing.

`SD_Scarves_abilities.esp` now ships alongside, with the 10 records:

| Records | Effect | Magnitudes |
|---|---|---|
| `sd_scarf_w1` … `w5` | Fortify Attribute, Willpower | 1, 2, 4, 8, 16 |
| `sd_mask_blight_10` … `_50` | Resist Blight Disease | 10–50 |

Effect ids were **not guessed**. `sd_hearthfire_1..4` was parsed out of Sun's
Dusk's own plugin and decodes as `(79, -1, 2, 0, 0, 2, 2)` — effect 79, attribute
2, magnitude 2. `sd_scarf_w2` writes byte-identical fields. 79 and 95 are Fortify
Attribute and Resist Blight Disease in the standard TES3 effect table, and the
generated file was re-parsed with the same reader used on Sun's Dusk to confirm
it round-trips.

## Guard added

`tools/check_manifest.py` fails on any `.omwscripts` declaring one path under two
flags. Run against the manifest that crashed:

```
SD_Scarves.omwscripts: 3 script(s)
  FLAGS MISMATCH  scripts/sunsduskscarves/scarves_settings.lua  declared as GLOBAL, MENU
```

It clears CAKE's and IED's manifests. This belongs in RESEARCH Part 4: it is a
fatal, load-time, trivially detectable error, and nothing else in the toolchain
looked at manifests at all.

## Install

Add `Scarves` as a data directory and enable **both** plugins:

```
SD_Scarves.esp             320 item records
SD_Scarves_abilities.esp   10 ability records
```

Load after Sun's Dusk. 19/19 module tests still pass from the new paths.
