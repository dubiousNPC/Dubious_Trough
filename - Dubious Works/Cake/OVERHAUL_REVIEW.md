# Review of CAKE_fixed

## Verdict: the architectural change is correct and fixes a real flaw I introduced

The overhaul replaces inventory-inferred worn state with explicit
activation-set state. That is not a style preference — the version it replaces
was wrong, and wrong in a way that was hard to see.

**Looting an `_eq` record counted as wearing it.** Presence in the bag *was* the
test, so activation had stopped being what put something on; it was merely one
of several ways an `_eq` record could reach your inventory. Opening a chest
containing a worn-variant record would have equipped it.

Everything downstream was propping that inference up. The cell-wide sweep —
every Miscellaneous object in the cell plus a `getAll` on every container — ran
on every UI-mode exit because it was load-bearing for correctness. With explicit
state it becomes world hygiene, and the overhaul correctly moves it behind
`reconcile()`, firing only when an entry actually lost its backing record. That
is the same trigger Sun's Dusk uses.

This is Sun's Dusk's `saveData.backpackId` model, which is what the mod was
meant to follow from the start.

### Verified against the API stubs

- `Inventory:countOf(recordId)` — exists (`Cod3x/openmw/core.lua:813`).
- `GameObject:isValid()` — exists; the added `player:isValid()` guard in the
  cell sweep is right, since a global handler can be reached with a stale ref.
- `onSave` / `onLoad` on a PLAYER script — correct placement for the new state.
- `self.object` rather than `self` in `sendGlobalEvent` — correct; `self` is a
  `LocalSelf`, not the GameObject.

### Smaller changes, all correct

- `cake_shared.lua` retagged `---@omw-context none`. Right: it is a plain data
  library, not context-bound.
- `attached` table removed from `cake_player` — it was write-only once `worn`
  became authoritative.
- `EQUIPANIM` explicitly justified in the settings header rather than dropped,
  since `playGesture` does read it.

### No hotkeys

Confirmed by grep across the package: no `registerTriggerHandler`,
`registerActionHandler`, `bindAction` or key handling anywhere in
`scripts/cake/`. The only input handler in the mod is AnimRefresh's `TogglePOV`
listener, which detects a perspective change to re-attach meshes — it does not
equip anything.

Every item is equipped by using it from the inventory, via one
`I.ItemUsage.addHandlerForType(types.Miscellaneous, ...)` registration.

## Tests updated

The integration suite drove the old model and had to be rewritten: the global
script is now the only writer of the player's state, so testing them apart
tests neither. `actor:sendEvent` is routed into the player's handlers and the
player script loads first.

Five assertions were added for behaviour that did not previously exist:

- **looting an `_eq` record does not equip it** — the regression this
  architecture exists to prevent
- an entry whose record vanished is reconciled away
- losing a record triggers the cell sweep *exactly then*
- a clean reconcile does **not** sweep
- `onSave`/`onLoad` round-trip, including a garbage payload

All pass. Full suite: 21 registry + 35 integration + 17 plugin checks, plus
syntax, unused-name and cross-reference sweeps.

## One thing to be aware of

The 32 tail pairs exist in the plugin but are absent from `cake_shared.lua`
(no tail bone in `xbase_anim_dbs.nif`). Using a tail item therefore does
nothing, and a tail `_eq` record is not recognised by `CAKE.baseOf`, so the
cell sweep will not convert a loose one back. They are inert rather than
broken, but they are visible in the vendor's stock. Either ship a beast
skeleton with a tail bone, or drop them from the plugin until you do.
