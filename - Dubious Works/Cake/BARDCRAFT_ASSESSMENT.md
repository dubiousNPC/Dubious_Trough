# Bardcraft's sheathing, and what CAKE should take from it

Bardcraft is the origin of this pattern, Sun's Dusk is the refinement, and
Fashionwind is the cautionary tale. The three together answer most of the
design questions for a slot framework — including one thing CAKE currently
gets wrong.

---

## What Bardcraft actually does

Two files matter: `BackpackSheathe.lua` (a standalone extract of the mechanism)
and the same three functions inside `performer.lua`.

```lua
function P:setSheatheVfx()
    if not P.hasAnim() then return end
    anim.removeVfx(omwself, 'BC_BackInstrument')
    if not self.stats.sheathedInstrument then return end
    local record = types.Miscellaneous.record(self.stats.sheathedInstrument)
    if record and self:verifySheathedInstrument()
       and (not self.instrumentItem or record.id ~= self.instrumentItem.id) then
        local modelName = 'meshes/bardcraft/vfx/sheathe/'
                          .. record.model:match("([^/]+)$")
        if not anim.hasBone(omwself, 'Bip01 BOInstrumentBack') then return end
        anim.addVfx(omwself, modelName, { vfxId = 'BC_BackInstrument',
            boneName = 'Bip01 BOInstrumentBack', loop = true,
            useAmbientLight = false })
    end
end
```

The shape is: **remove first, verify the record is still in the inventory, check
the bone exists, then attach.** Worn state is a single record id on a saved
table (`stats.sheathedInstrument`), toggled by re-use:

```lua
function P:setSheathedInstrument(recordId, force)
    if self.stats.sheathedInstrument == recordId and not force then
        self.stats.sheathedInstrument = nil   -- using it again takes it off
    else
        self.stats.sheathedInstrument = recordId
    end
    self:setSheatheVfx()
end
```

Entry point is a global `ItemUsage` handler that sends the record id to the
player script. **No hotkeys, no UI** — exactly the interaction model you want.

### Refresh triggers

VFX attached to the player's animation object are dropped whenever that object
is rebuilt, so the function is re-run from four places:

| Trigger | Where | Catches |
|---|---|---|
| `onActive` | `player.lua:707` | load, cell change |
| camera mode change | `onFrame`, deferred one frame via `setVfxNextFrame` | first/third person |
| `core.getGameTime()` jump > 1 | `performer.lua:118` | resting, waiting, travel |
| after any performance event | `performer.lua:638` | its own animation work |

The gameTime-jump check is the neat one: rest, wait and fast travel all
manifest as a discontinuity in game time, so one test covers all three without
knowing which UI mode caused it.

---

## Three real problems in this code

### 1. `UiModeChanged` does not actually refresh

`how_it_works.txt` says the function is called in `UiModeChanged`. It isn't:

```lua
UiModeChanged = function(data)
    Performer:verifySheathedInstrument()   -- returns a boolean, no side effect
```

`verifySheathedInstrument` only does `inventory:find(id) ~= nil` and returns it.
The return value is discarded. So closing a menu that rebuilt the model does
**not** restore the instrument — it is the gameTime jump that saves resting, and
menus that rebuild the model without advancing time (Travel to an adjacent cell,
Training) are not covered at all. It reads like `setSheatheVfx` was intended
there and the wrong method name was typed.

### 2. Camera detection is a per-frame poll

`onFrame` compares `camera.getMode()` against `lastCameraMode` every frame,
forever, whether or not anything is sheathed. That is what `AnimRefresh` exists
to replace: a `TogglePOV` trigger handler, plus a once-per-second backstop, and
zero cost when nothing is subscribed.

Bardcraft's one-frame defer is the same insight as Sun's Dusk's 0.1s settle
timer, just cruder — one frame is not always enough for the skeleton to be
ready, which is why Sun's Dusk additionally guards with `hasBone` **and** retries.

### 3. The `ItemUsage` handler is O(instruments × ids) per use

```lua
for instr, _ in pairs(Data.SheathableInstruments) do
    for recordId, _ in pairs(Data.InstrumentItems[instr]) do
        if record.id == recordId then
```

A nested scan to answer a question a flat lookup table answers in one step. It
only runs on item use so it does not matter at four instruments — it matters a
lot at 128 items, which is the scale CAKE works at.

It also `return true` on every path, including the match. Returning `true`
tells the engine to proceed with normal use; for a Miscellaneous item that is
harmless, but it is not what you want if the item type has real use behaviour.

---

## The finding that matters for CAKE

**Both Bardcraft and Sun's Dusk attach a *different* mesh from the one the
world object uses. CAKE attaches the same one.**

Bardcraft states the reason outright — meshes attached as VFX stop being
interactable until you restart the game — and dodges it with a parallel mesh
tree at `meshes/bardcraft/vfx/sheathe/`.

Sun's Dusk does the same thing with a naming convention rather than a folder.
Reading its records:

```
sd_backpack_adventurer      model = ...\misc_bkpk01a[g].NIF    <- ground mesh
sd_backpack_adventurer_eq   model = ...\misc_bkpk01a.NIF       <- worn mesh
sd_backpack_satchelbrown    model = ...\war_msc_pch01_g.nif
sd_backpack_satchelbrown_eq model = ...\war_msc_pch01_f.NIF
```

Every pair differs. The `_g` suffix is the ground version; the base record uses
it, the `_eq` record uses the worn one, and only the `_eq` model is ever passed
to `addVfx`.

**CAKE has 160 pairs and all 160 share one mesh.** I checked. That gives two
problems:

- it walks straight into the interactability bug Bardcraft documents, and
- the ground/inventory appearance is the *worn* mesh. A mesh authored to be
  attached to a bone will often sit wrong when dropped as a world object, and if
  it is skinned it may not render sensibly at all without a skeleton.

This is the single highest-value correction available to CAKE right now, and it
is a plugin edit rather than a script change: point each **base** record at the
ground mesh and leave the `_eq` record on the worn one. The `MWSEoriginals`
exports have `_GND` models on their ARMO records — the same enrichment pass that
pulled names and icons can pull ground meshes for the base half.

---

## The Fashionwind bug report, checked against CAKE

Every point in it is already addressed, which is worth recording so it does not
get re-litigated:

| Report | CAKE |
|---|---|
| 7 NPC scripts each running `onUpdate` | **1** NPC script, and it has **no** `onUpdate` at all |
| ~1k ops/s per script in Pelagiad, 5–6k in Narsis | zero polling; one inventory walk on `onActive` |
| use a 1s `time.runRepeatedly` instead of every 20 frames | not needed — event-driven, so even 1s is 1s too often |
| `Actor.inventory(self)` resolved every time | resolved per rebuild, not per item; could be hoisted further |
| `getRecordId()` should be `item.recordId` | uses `item.recordId` |
| `findHornsItem()` should use `inv:find()` | uses `inv:find` / `inv:countOf` |
| consider Follower Detection Util | not applicable yet — no follower gating |

The one piece of the report still worth acting on: **hoist
`types.Actor.inventory(self)` to script init.** The handle is stable and updates
itself; CAKE re-resolves it on each rebuild. Small, but free.

---

## Evolution summary

| | Bardcraft | Sun's Dusk | CAKE now |
|---|---|---|---|
| slots | 1 (back) | 1 (back) | 7 categories |
| worn state | saved record id | saved record id (`saveData.backpackId`) | saved category → record id |
| item identity | base record only | base + `_eq` record swap | base + `_eq` record swap |
| VFX mesh | separate `vfx/sheathe/` copy | `_eq` record's own mesh | **same mesh as base** ✗ |
| POV handling | per-frame poll | camera-mode tracking on a throttled list | AnimRefresh (event + 1s backstop) |
| settle | 1 frame | 0.1s timer + `hasBone` retry | 0.1s timer + `hasBone` retry |
| rest/menu | gameTime jump | UiModeChanged | UiModeChanged + reconcile |
| NPCs | fixed data table on bard NPCs | none | event-driven, 1 script |

CAKE is ahead on everything except the mesh split, and that one is a real
regression against both predecessors rather than a simplification.
