# CAKE — Compelling Alternative Koala-Echidna

Wearable accessories — lanterns, masks, eyewear, scarves, belts, bags — that
occupy no equipment slot and cost nothing per frame.

---

## How wearing works

Every accessory is a pair of `types.Miscellaneous` records:

```
dbs_<thing>        sits in the inventory
dbs_<thing>_eq     replaces it while worn
```

Using the base record destroys it and creates the `_eq` record. Using the
`_eq` record converts it back. Because a Miscellaneous item occupies no
equipment slot, nothing has to be blocked from equipping and no helmet,
pauldron or belt is displaced. Swapping within a category, or putting on
something that conflicts, returns the previous item to the inventory first.

The worn state lives **in the inventory**, not in a saved variable. That is
the design's main benefit: there is nothing to persist, nothing to reconcile
on load, and no way for the display and the inventory to disagree. Every
script here reads worn state fresh rather than tracking it.

This is Sun's Dusk's backpack mechanism, generalised across eight categories.

---

## Contents

| Category | Items | Bone | Vanilla fallback |
|---|---|---|---|
| lanterns | 46 | `Bip01 L hipDBS` | `Bip01 Pelvis` |
| eyewear | 20 | `Bip01 eyesDBS` | `head` |
| masks | 17 | `Bip01 mouthDBS` | `head` |
| scarves | 16 | `Bip01 scarfDBS` | `Bip01 Neck` |
| belts | 14 | `Bip01 beltDBS` | `Bip01 Pelvis` |
| bags | 13 | `Bip01 beltDBS` | `Bip01 Pelvis` |
| smokes | 2 | `Bip01 mouthDBS` | `head` |
| ears | 1 | `Bip01 earsDBS` | `head` |

129 pairs. Masks and smokes conflict; everything else stacks.

**Tails are not included.** The plugins define 34 tail pairs, but they belong
on the beast skeleton (`xbase_animkna`) and CAKE ships only
`xbase_anim_dbs.nif`, which has no tail bone — all 123 of its nodes were read
and none is a tail. Pointing them somewhere plausible would produce a feature
that looks like it works and silently does nothing, so they are left out until
a beast skeleton with a tail bone exists. See HANDOFF.md §6.

---

## Bones

The DBS bones come from `xbase_anim_dbs.nif` and are simply absent without it,
so every category also names a vanilla fallback. Attaching to a bone that does
not exist is a **silent no-show, not an error**, which is why the player script
probes with `animation.hasBone` before committing and retries once after 0.1s —
right after a perspective switch the rebuilt skeleton may not be ready yet.

The skeleton setting offers auto-detect (probe and fall back), `dbs` (trust the
skeleton, skip the probe), and vanilla (pin everything to fallbacks).

---

## Layout

```
CAKE/
  CAKE.omwscripts
  README.md
  HANDOFF.md                             engineering notes and open questions
  l10n/CAKE/en.yaml
  scripts/cake/
    cake_shared.lua                      generated registry: ids, bones, categories
    cake_global.lua                      the equip/unequip swap (GLOBAL)
    cake_player.lua                      attachment on the player (PLAYER)
    cake_npc.lua                         attachment on other actors (NPC)
    cake_settings.lua                    settings page (MENU)
    cake_anim.lua                        optional equip gestures, off by default
    AnimRefresh_v1.lua                   bundled, version-guarded
  scripts/SuperSettingsRenderers/
    SuperSelect3.lua                     bundled verbatim, optional
  tools/                                 parser, generator, checkers, tests
```

`cake_shared.lua` is the only file that names an item id, and it is
**generated** from the plugins rather than maintained by hand.

---

## Bundled libraries

`AnimRefresh_v1.lua` and `SuperSelect3.lua` ship alongside rather than being
copied into CAKE's own files, the same way SharedRay is bundled.

`SuperSelect3` provides the dropdown for the skeleton setting. It is **optional**:
it advertises itself through the session-lifetime `InstalledSettingsRenderers`
storage section as it loads, and `cake_settings.lua` falls back to the engine's
built-in `select` renderer when that flag is absent. Deleting
`scripts/SuperSettingsRenderers/` degrades the dropdown to arrows and changes
nothing else.

It must load **before** `cake_settings.lua`, which is why the manifest lists it
first — entries in one `.omwscripts` run in written order. If you also have
SuperSettingsRenderers installed standalone, delete the bundled folder and its
manifest line; CAKE will find the standalone copy.

---

## Performance

No `onFrame` and no `onUpdate` anywhere in the mod. Nothing polls camera mode
and nothing polls inventories.

- Perspective changes arrive through `AnimRefresh`, subscribed **only while
  something is worn**. A player wearing nothing pays a single empty-table check.
- Equip and unequip arrive as events from the global script.
- Items leaving the inventory are caught on UI-mode exit (Inventory, Barter,
  Container, Companion) and on the menus that rebuild the player model (Rest,
  Travel, Training).
- NPCs do one inventory walk on `onActive`, covering all eight categories, and
  nothing after that.

---

## Regenerating and testing

```
python3 tools/tes3.py <plugins>       # parse records -> cake_records.json
python3 tools/gen_cake_shared.py      # -> cake_shared.lua
python3 tools/luacheck.py   scripts/cake/*.lua
python3 tools/check_names.py scripts/cake/*.lua
python3 tools/sweep.py                # cross-reference sweep, see below
python3 tools/luarun.py scripts/cake/cake_shared.lua tools/test_shared.lua
python3 tools/luarun.py tools/test_integration.lua
```

`luacheck.py` and `luarun.py` drive the system `liblua5.4.so.0` through ctypes,
so no Lua interpreter needs installing.

`sweep.py` is the one that matters. Syntax checking cannot see a settings key
nothing reads, a category name that no longer exists, a skeleton option the
player script does not understand, or an event with no handler — and every one
of those shipped in the original `globalcake.lua` / `playergear.lua`. The sweep
cross-references all of them plus l10n keys and orphaned modules.

`test_integration.lua` mocks the OpenMW API and runs the real global, player,
NPC and anim scripts through equip, swap, conflict, unequip, first-person
hiding, `AnimRefresh` re-attachment, bone fallback, the single retry, the
vanilla profile, item loss and the NPC toggle.
