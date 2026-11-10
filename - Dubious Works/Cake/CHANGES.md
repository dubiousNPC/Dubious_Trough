# CAKE changes (2026-11-10)

Tested in OpenMW 0.52 RC1 with the real Morrowind, Tribunal and Bloodmoon data.

## Why CAKE never worked on the player

The delivered build failed in two ways at startup:

1. **`cake_player.lua` never started.** It built a table from
   `I.UI.MODE['Inventory']`, and that key does not exist in 0.52 (the inventory
   mode is called `Interface`). `I.UI.MODE` raises on an unknown key, so the
   engine logged `Key not found: Inventory` and dropped the script. With it
   went everything shown on the player and the `I.CAKE` interface.
2. **AnimRefresh was not loaded.** The manifest listed `AnimRefresh_v3.lua`
   while the folder held `AnimRefresh_v6.lua` (`Resource ... not found`). The
   player script checked `if not I.AnimRefresh then return end` and so would
   have skipped every perspective refresh without a word.

In the engine with the delivered build, using an item swapped the records, but
nothing appeared on the player. NPCs did show their items.

## AnimRefresh v6, integrated

- The manifest loads `scripts/AnimRefresh/AnimRefresh_v6.lua`, unmodified and
  byte-identical to the FLOW and Hookshot Redux copies.
- The player script subscribes only while something is worn, with
  `{ verify = true }`. The callback is the only place that attaches meshes. It
  returns `false` while the skeleton is not answering, so v6 retries it.
  CAKE's own 0.1 s retry timer is gone.
- Subscribing draws: v6's join delivery replaces the immediate redraw.
- Rest, Travel, Training, Jail, race change and loading are v6's menu latch and
  reconcile. CAKE's own list of rebuilding menus is gone, along with the
  `I.UI.MODE` lookup that crashed it.

## Bugs fixed

| bug | effect | fix |
|---|---|---|
| A conflicting category was cleared in the bag but not in the player's state | after putting on a cigar, the mask stayed drawn until a menu closed, and the audit then swept the cell for nothing | `Cake_Changed` lists every category it cleared |
| Swapping cleared only the first worn record found in a category | a second `_eq` of the same category (looted) survived | every worn record of the cleared categories goes back to its bag form |
| Turning "NPCs wear accessories" off or on did nothing until each NPC was re-activated | the setting looked broken | the global script re-syncs every active NPC at once |
| `Cake_Gear.omwaddon` listed `Tamriel_Data.esm` as a master, though none of its records need it | the core plugin would not load without Tamriel_Data | master removed; every model it uses is in `00 Core` |
| 11 Argonian scarves in `Cake_Gear.omwaddon` were not in the registry | using one did nothing | now excluded on purpose: their meshes are skinned, and in game they draw nothing as an attachment (checked on an Argonian NPC) |

## Performance

The research behind DED's 2026-11-08 pass applied here: on a crowd, the cost is
the per-NPC script instance, its module body and its first walk, all on the
frame the NPCs become active.

- **NPCs carry no CAKE script by default.** `cake_global` reads each actor's
  inventory once when it becomes active (`onActorActive`). It attaches
  `cake_npc.lua` (now `CUSTOM`) only to NPCs carrying a worn record, and passes
  the list of meshes to draw.
- **`cake_npc.lua` loads no registry.** It is 30 lines, draws the list it is
  given, and asks to be removed once its list is empty.
- `cake_shared.lua` is loaded by two scripts in total: global and player.

The engine numbers below come from 80 NPCs spawning around the player, 20 of
them wearing CAKE items. Each build ran 3–5 times, alternating with the others.

| phase | Lua ms/s: new / delivered / no CAKE | worst frame ms: new / delivered / no CAKE |
|---|---|---|
| idle, nothing worn | 10.2 / 10.6 / 9.8 | 4.0 / 4.2 / 4.6 |
| player wearing 3 items | 9.1 / 9.2 / 9.1 | 3.9 / 3.2 / 4.2 |
| 10 perspective round trips | 9.9 / 9.1 / 9.5 | 3.4 / 4.9 / 3.9 |
| **80 NPCs become active** | 24.5 / 32.2 / 28.2 | **35.8 / 75.9 / 49.5** |
| 80 NPCs, steady | 15.3 / 15.1 / 16.4 | 4.6 / 5.3 / 6.3 |
| NPC display off, then on | 16.5 / 14.9 / 14.7 | 6.9 / 7.4 / 4.7 |

- **Activation spike:** the delivered build added about 26 ms to the worst
  frame when a crowd became active. The new build is within the run-to-run
  noise of having no CAKE at all (the worst frame ranged 37–63 ms across the
  no-CAKE runs).
- **Steady state:** no measurable cost in any build.
- **Display toggle:** the new build now does work here, redrawing 20 NPCs,
  which adds about 2 ms/s for the 8 s of the phase. The delivered build did
  nothing, which was the bug.
- **Caveat on the delivered numbers:** its player script never started, so
  they include no player-side cost.
- The renderer was llvmpipe at 7–10 fps, so these are relative numbers.

## Trimmed

| removed | why |
|---|---|
| `cake_anim.lua` and its setting | it played animation groups no file defines, and was CAKE's last `pcall` |
| the skeleton setting, its three profiles and the bundled SuperSelect3 | `dubiousBones.nif` ships with CAKE, so the bones exist; the fallback bones stay |
| `RESEARCH.md`, `HANDOFF.md`, `BUGFIX.md`, `OVERHAUL_REVIEW.md`, `SWEEP_REPORT.md`, `PLUGIN_AUDIT.md`, `FRAMEWORK_SPEC.md`, `plugins_fixed/` | session notes from earlier builds, most describing code that no longer exists; the findings live in the project |
| 6 one-off plugin tools and 5 JSON dumps | they built plugins that are now final |

CAKE's own Lua goes from 1,206 lines to 572 (178 of them the generated
registry). The bundled SuperSelect3 (739 lines) is gone too. AnimRefresh is
not counted.

## Package layout

```
00 Core/                    Cake_Gear.omwaddon, CAKE.omwscripts, scripts, l10n,
                            animations (dubiousBones.nif), meshes, icons, textures
01 Lanterns Belts Bags/     cake_v4.2.esp   (optional; Tamriel_Data)
02 Balmora Outfitter/       cake_npc.esp    (optional; needs 00 and 01)
tools/                      checks and the registry generator (not a data folder)
```

`assets.zip` is merged into `00 Core`.

## Verified in game (new build)

- wearing, swapping and taking off a mask, scarf and goggles; a cigar removing the mask
- the drawing survives a first-person round trip, a quickload, and leaving and re-entering the cell
- a looted worn record is not worn
- NPC display toggles live
- an NPC carrying only bag forms shows nothing
- the ItemUsage handler still works after a load
- a lantern hangs from the pelvis fallback

Screenshots were checked for each step.

## Toolchain

- `check_manifest.py` now fails on a script the manifest lists but the folder
  lacks, and on a context annotation that disagrees with the flag. It reports
  the delivered manifest's `AnimRefresh_v3.lua`.
- `check_meshes.py` (new): every worn model exists and is not skinned. It
  reports the Argonian scarves if they are registered again.
- `nif_bones.py` (new): which bones `dubiousBones.nif` adds, and which ones it
  cannot add.
- `gen_cake_shared.py` reads the plugins directly. It fails on an unknown model
  path or a worn record without its base. `check_all.sh` fails if the
  committed registry is stale.
- `test_integration.lua` was rewritten around a simulated engine
  (`mock_openmw.lua`) that runs the real AnimRefresh v6. It has 47 checks.
  Reverting any of the script fixes above makes at least one of them fail.
- `check_all.sh` runs everything on Lua 5.4, plus LuaJIT when `LUAJIT` is set.

## Found, not changed (yours to decide)

- **`dubiousBones.nif`:** `Bip01 L hipDBS`, `Bip01 R hipDBS`, `Bip01 capeDBS`
  and `Bip01 pendantDBS` are parented to `Bip01 Spine00` / `Bip01 Neck1`,
  which the game's skeletons lack, so OpenMW never adds them (confirmed with
  `hasBone` in game). Lanterns fall back to `Bip01 Pelvis`. Re-parenting them
  to `Bip01 Pelvis` / `Bip01 Neck` in the source file fixes it. WhyWalk ships
  the same file.
- **Missing models:** 13 belts (`meshes/Belts/`) and the 2 cigars
  (`meshes/ep/`) come from no folder here and show the error marker.
- **`cake_npc.esp`** sells 20 eyewear items as `ARMO` (`_RV_Glasses1` etc.,
  helmet slot), not as the CAKE eyewear, and 20 tails that cannot be worn.
- **Tails and Argonian scarves** need meshes made for a bone (rigid, authored
  in that bone's space) before they can be added.
