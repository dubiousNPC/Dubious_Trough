# A lightweight slot framework — design notes

What Bardcraft, Sun's Dusk and Fashionwind between them say the design should
be, and what to avoid.

## The mechanism is settled

All three converge on the same four pieces, and there is no reason to deviate:

1. **A custom bone** added to `xbase_anim.nif`, `xbase_anim_female.nif`,
   `xbase_animkna.nif` and the `.1st` variant, dropped in `animations/` so
   OpenMW merges it as a skeleton extension.
2. **A global `ItemUsage` handler** as the only entry point. No hotkeys, no UI.
3. **A player script owning the worn state**, toggled by re-using the item.
4. **`removeVfx` → verify → `hasBone` → `addVfx`**, re-run whenever the
   animation object is rebuilt.

The interesting design work is all in the last point and in what the state
looks like.

## Where the three differ, and who is right

**Worn state.** Bardcraft and Sun's Dusk both keep a saved record id.
CAKE briefly inferred it from an `_eq` record being in the inventory, which
made *looting* one identical to wearing it. Explicit state wins; the inventory
audits it, it does not define it.

**The `_eq` record swap** is Sun's Dusk's addition and worth keeping even
though Bardcraft does fine without it. It gives the worn item a distinct icon
in the inventory, so the state is visible without a UI, and it means a companion
or a merchant carrying the worn record renders correctly with no extra code.
The cost is two records per item instead of one.

**Refresh triggers.** Take the union, not any one mod's set:

| Event | Source | Note |
|---|---|---|
| `onActive` | all three | load, cell change |
| perspective change | Bardcraft polls per frame | use AnimRefresh instead |
| `UiModeChanged` | Sun's Dusk | Rest, Travel, Training rebuild the model |
| gameTime jump > 1 | Bardcraft | catches rest/wait/travel without knowing the mode |
| settle delay + `hasBone` retry | Sun's Dusk | 1 frame is not always enough |

Bardcraft's gameTime-jump test is the one most likely to be missed and is worth
copying: rest, wait and fast travel all show up as a discontinuity in game time,
so a single check covers all three.

## What Fashionwind proves about scale

The bug report is unambiguous: seven cosmetic categories, seven NPC scripts,
each with `onUpdate` on every active actor, ~1k ops/s per script in Pelagiad and
5–6k in Narsis. The lesson is not "optimise the polling" but **do not have
seven scripts**, and then **do not poll at all**.

A framework makes this structural rather than a matter of discipline: one
registry, one global handler, one player script, one NPC script, regardless of
how many slots are registered. Adding a slot must not add a script.

The report's smaller points are all worth building in as defaults:
`item.recordId` over a helper, `inv:find` over iteration, and the inventory
handle hoisted to init rather than re-resolved.

## Registration API

The thing that makes it a framework rather than a mod is that another author
can add a slot without editing it. Two forms, both cheap:

```lua
-- from a global script, before or after load order does not matter
core.sendGlobalEvent('SlotKit_RegisterSlot', {
    key      = 'goggles',
    bone     = 'Bip01 eyesDBS',
    fallback = 'head',
    conflicts = { 'masks' },
})
core.sendGlobalEvent('SlotKit_RegisterItems', {
    slot = 'goggles',
    items = { ['mymod_goggles'] = 'mymod_goggles_eq' },
})
```

Two rules that are not optional:

- **Registration is additive and idempotent.** A mod re-registering on load
  must not duplicate or clobber another mod's slot.
- **A slot must declare a vanilla fallback bone.** Attaching to a missing bone
  is a silent no-show, not an error, which is the single most common way one of
  these mods appears broken.

## Sun's Dusk compatibility

Sun's Dusk exposes `I.SunsDusk` with `version` (currently 6) and a `getSaveData`
accessor, plus a set of `SunsDusk_*` global events. It does **not** expose a
backpack registration API — its backpack list is internal to
`g_backpacks.lua`.

So compatibility means coexistence, not integration:

- **Do not claim `Bip01 Spine2` or whatever bone Sun's Dusk's backpacks use for
  a slot of your own.** Its backpack and your pack would occupy one bone.
- **Use distinct `vfxId`s.** Sun's Dusk uses `SD_backpackVfx`; anything of yours
  namespaced differently coexists fine. The `addVfx` docs warn specifically
  against ids that collide with magic effect ids — that is the real hazard.
- **Honour `SunsDusk_LootVfxItem`.** Sun's Dusk broadcasts it when a VFX-bearing
  item is looted, and handles the reverse for its own items. A framework that
  emits an equivalent event lets add-ons hook without patching.
- **Version-gate on `I.SunsDusk.version`** if you ever read its save data;
  the API version is bumped deliberately and reading a table shape from an
  older build is how add-ons break.

Bundling AnimRefresh with a version guard is the right pattern for the shared
piece, exactly as SharedRay does.

## Do not repeat these

- **`UiModeChanged` calling a verifier instead of the refresh.** Bardcraft's
  `UiModeChanged` calls `verifySheathedInstrument()`, which returns a boolean
  and has no side effect. Its documented "refresh on UI mode change" does not
  happen; the gameTime check is what actually saves resting.
- **Per-frame camera polling.** `onFrame` comparing `camera.getMode()` runs
  forever whether or not anything is worn.
- **Nested id scans in the `ItemUsage` handler.** Fine at four instruments,
  quadratic nonsense at a hundred items. A flat lookup table is the whole fix.
- **Sharing one mesh between the world object and the VFX.** See below — this
  is the one CAKE got wrong.

## The mesh split is not optional

Bardcraft attaches from a parallel tree (`meshes/bardcraft/vfx/sheathe/`) and
states the reason: a mesh attached as VFX stops being interactable until the
game is restarted. Sun's Dusk arrives at the same place via naming — every
backpack pair has a `_g` ground mesh on the base record and the worn mesh on
the `_eq` record, so the model passed to `addVfx` is never a model a world
object uses.

**Any framework should treat "worn model ≠ ground model" as a registration
requirement**, and warn when a registered pair violates it, rather than leaving
each author to rediscover the bug.

### Applied to CAKE

All 160 pairs were sharing one mesh. 69 base records now point at a real ground
mesh recovered from the source mods, using a strict rule — the source model is
accepted only when it is unambiguously a ground mesh (`_GND.nif`, `_g.nif`, or
`<name> gnd.nif`, which is how Fashionwind's scarves are named).

16 were skipped as unlabelled. `dbs_RV_Eyepatch1L_H` is why: its source ARMO
points at `RV\blindfold1.nif`, a different item, so accepting "the source mesh"
uncritically would have put a blindfold on the ground in place of an eyepatch.

**91 pairs still share a mesh** because no ground mesh exists for them in the
source mods. Those need authoring — a `_GND` variant per item — and until then
they keep the current behaviour rather than a wrong mesh.
