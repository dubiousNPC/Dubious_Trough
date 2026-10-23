# Caravans — first implementation

The vehicle taxi module from `SILTSTRIDER_NOTES.md`'s IMPLEMENTATION NOTE,
built to the shape it suggested: a separate vehicle mode sharing Core's
session/pin/animation layers, with `slots[]` instead of a saddle and a route
walker instead of steering input.

Six files, 47 routes, 78 assertions. Everything green across all three modules.

---

## What the notes asked for, and what shipped

| the note said | what shipped |
|---|---|
| "a separate VEHICLE mode" | `caravans_db.VEHICLE`, its own table; Core's `PROFILE` untouched |
| "`slots[]` instead of a single saddle" | player slot + guide slot + 2 recorded passenger slots |
| "a route walker instead of steering input" | `caravans_path.lua`, pure, arc-length based |
| "sharing WhyWalk's session, pin and animation layers" | same session/early-out discipline; Core's `SILT_STRIDER` sitting pose used as-is |
| "The rider animation layer needs no change" | correct — `ridingAnim.lua` is not touched |
| "Take from [R]: route point sets, measurements, sway constants, pricing" | all four |
| "Take from [B]: runtime record creation" | `createRecordDraft`/`createRecord`/`createObject` |
| "Take from neither: the movement loop" | written fresh against `dt` |

---

## 1. Intercepting the travel menu

`I.UI.registerWindow(name, showFn, hideFn)` — documented as overriding a
built-in window. The engine calls our callback and never draws its travel list.

Ben's mod polls `I.UI.getMode() == I.UI.MODE.Travel` every frame. That spends a
frame handler for the whole game to catch a menu opened twice an hour, and the
vanilla window is already up by the time it fires — so it has to close one.

### What is inferred

Being explicit, because two of these could be wrong in a way that only the game
will show:

- **Documented:** `registerWindow` overrides built-in windows; window names live
  in `I.UI.WINDOW`; `UiModeChanged` is an *event* carrying `{oldMode, newMode}`.
- **Inferred:** that the travel window is named `I.UI.WINDOW.Travel`, and that
  the show callback receives nothing useful (Cod3x types it `fun(...): any`
  with no documented arguments, and does not enumerate the `MODE`/`WINDOW`
  tables at all).

So the module does not trust either. It resolves the name *through*
`I.UI.WINDOW` and logs a line and stands down if there is no `Travel` entry,
rather than hard-coding the string. And it finds the guide itself.

**The failure mode is the right one:** if the override does not take, the
vanilla window appears and ordinary travel works.

### The guide

`UiModeChanged` has no target field — AnimRefresh v5 reads `oldMode` and
`newMode` and nothing else — so the mode change cannot identify the NPC. The
guide is latched at **activation** instead, via
`I.Activation.addHandlerForType(types.NPC, …)` in the global script, which is
sound because activating an NPC is the only route to their travel topic. The
handler returns nothing, so activation proceeds normally — it observes, it does
not intercept. Nearest-travel-seller is the fallback.

## 2. Destinations from the game, geometry from the data

`types.NPC.record(guide).travelDestinations` turned out to be the find of the
session: the engine exposes the real destination list (`cellId`, `position`,
`rotation`), and `servicesOffered.Travel` says who sells travel.

That means **no hardcoded NPC→destination table**, which is what Ben's mod
carries (9 origin NPCs, 33 routes, vanilla only). The menu shows whatever that
caravaner actually offers, including mod-added destinations this module has
never heard of. What the route database adds is the one thing the engine does
not have: the *shape* of the path.

## 3. The route import

47 routes, 2150 points, 25 places, from Immersive Travel's Caravaner set.

The notes' warnings all landed:

- **Two empty files** (`Necrom_Sailen`, `Sailen_Bosmora`) would "teleport the
  strider to origin". Dropped, with a test that keeps them dropped.
- **Duplicates** — the importer keeps the longer. (None in this archive; the
  notes warn they appear when archives overlap.)
- **Case** — the source is Title Case except `balmora_vivec`. Everything folds
  to lower case, asserted.

Two structural decisions:

**Flat arrays.** `{x,y,z, x,y,z, …}` rather than 2150 three-field tables —
thousands of allocations at load for no gain. The walker indexes by stride 3
and builds a vector only for the point it is interpolating.

**One direction only.** Not merely a size saving: the source is genuinely
one-directional in places (there is a `balmora_vivec` and no `vivec_balmora`),
and reversal is an index flip in `pointAt` that covers every gap *including*
the two dropped files. Verified: forward and reverse measure identically, and
reverse's end is forward's start.

**Arc length, not point index.** The source is wildly uneven — Vivec → Seyda
Neen covers 204,146 units in 37 points while Suran → Vivec covers 49,526 in 26.
Stepping point-to-point would make speed depend on how finely a leg was
authored. Routes are measured once into a cumulative table and queried by
distance, in 3D, because a route climbing to Ald-ruhn gains thousands of units
and a 2D measurement would finish uphill legs early.

## 4. Placed, not driven — and the gait that follows

The route points sit at z 1300–2600 with `offset: -1220` and
`ground_offset: 1025`. Those are **body** positions on an authored path; the
strider's feet are 1200 units below the line. There is nothing to steer a
walker along, so the vehicle is placed, as Boats places a boat.

Which means the T-pose lesson applies in full: a placed creature is never asked
to move, never picks a gait, and renders at bind pose. `caravans_vehicle.lua`
plays `runforward` explicitly, with:

- **`loops = 999999`, not `-1`.** Cod3x's contract is `>= 0`. This is the third
  occurrence of that constant — the mount script (10-08) and `ridingAnim`
  (10-09) both shipped it — so the reasoning is written into the file.
- **`hasGroup` before playing**, with a `runforward → walkforward → idle`
  fallback. `playBlended` on a missing group is a silent no-op, which was the
  whole of the 10-22 fallback bug.
- **`PRIORITY.Scripted`**, and the reasoning changed. Core's mount script uses
  `Default` and argues a ridden creature's locomotion is its own — right when
  the engine is moving it. This creature is placed, nothing else should animate
  it mid-journey, and the Boats priority work found a uniform priority is
  *deleted* by anything sharing it, so one hit at `Default` would strip the gait
  for the rest of the journey. The old objection to `Scripted` (that it pauses
  everything) was corrected on 10-17: that comes from `mPlayScriptedOnly`,
  which the engine sets only from the MWScript queue.
- **`enableAI(false)`** on start, restored unconditionally on load.

### Creature preferred, activator fallback

Ben's mod spawns an **Activator** with the strider mesh. It moves, but an
activator has no animation controller — its legs never move, which is the
entire point of "animated movement".

So this searches `types.Creature.records` for one whose **mesh** matches and
clones it with `createRecordDraft{ template = … }`. Matched on mesh, not record
id: `c_siltstrider` is Immersive Travel's id, not a vanilla one, and guessing
ids across unknown load orders is how a mod works on one install and not
another. With no match it logs a line and falls back to an activator.

## 5. The fare

OpenMW's own formula, reimplemented from the engine source Immersive Travel
cites. Kept **pure** — the caller supplies the GMSTs and both actors' stats —
so every term is tested: each cap independently (luck 10, personality 10,
mercantile 100, summing to 120), disposition direction, both parties'
mercantile pulling opposite ways, followers, and `fTravelMult` of 0 or nil
behaving as 1 rather than dividing by zero.

The gold moves player → guide in the **global** script, not the player script
that computed it: inventory moves between actors are a global operation, and
the charge happens *before* anything is spawned, so a player who cannot afford
it ends the request there rather than mid-journey.

`Inventory:countOf('gold_001')` does the counting — I had written a
`getAll(Miscellaneous)` loop before finding it in the stubs.

## 6. The clock

Vanilla advances `distance / fTravelTimeMult` — ~8 hours for Balmora →
Ald-ruhn. An animated journey passes real time, which at 30× timescale is well
under an hour. Left alone, riding would be a stealth buff to travel.

On arrival the **remainder** is added: vanilla's hours less what the journey
consumed, never negative. Settled on arrival rather than at departure, because
jumping the sun at the start would be worse than either. Computed from the
**route** length rather than the straight line — the strider walks the route,
and it is always the longer of the two. A setting turns it off.

---

## Defects found and fixed during the build

**`chargeFare` used 119 lines above its declaration.** `check_declorder.py` —
the tool added on 10-10 — caught it in my own code. In Lua the name would have
bound to a nil global and the first fare would have crashed. Moved.

**A mid-journey save stranded the guide.** The journey takes the caravaner off
their post and carries them in the guide slot. `onLoad` released the vehicle but
not the guide, leaving them standing in the wilderness for the rest of the save
and no longer where anyone looking to travel would find them. Their home is now
persisted in `onSave` and restored on load, from the saved data rather than the
session — which may not exist on that side of the load, which is the point.

**Two dead things in my own files**, both caught by the checkers: an unused
`openmw.types` require and a `running` flag written three times and never read
in `caravans_vehicle.lua`; an unused `openmw.async` require and a leftover
scaffolding line referencing `world` — a global-only API — from a player
script in `caravans_player.lua`. That last one `check_names.py` reported as
`possibly undefined: world`.

**`skills.mercantile` is not in the API surface.** Cod3x declares `SkillStats`
as an empty class with no members, so that read is evidence from Immersive
Travel's working code rather than from the stubs — and it does not exist for a
*creature* guide, which Morrowind has no example of but a mod could add. Read
through an existence check now; a guide with no mercantile prices as if it were
0, which is the engine's behaviour for an actor without the skill.

---

## Verification

| check | result |
|---|---|
| `luacheck.py` | 25/25 across all three modules |
| `check_load.py` | 6/6 |
| `check_handlers.py` | 18 keys, 0 findings |
| `check_names.py` | 0 findings |
| `globalcheck.py` | 0 undeclared reads |
| `check_declorder.py` | 0 used-before-declaration |
| `ctxcheck.py` vs Cod3x 0.4 | 6 files, 0 issues |
| `api_sweep.py` | nothing unrecognised |
| `check_manifest.py` | 0 mismatches |
| `test_caravans.lua` | **78 pass** (new) |
| Core + Boats suites | unchanged, all pass |

Every new API call was checked against the stubs individually rather than
trusting the sweep: `types.NPC.record().travelDestinations` and
`.servicesOffered`, `types.Creature.records` and `record.model`,
`Creature.createRecordDraft` (`template` field),
`Activator.createRecordDraft`, `I.Activation.addHandlerForType`,
`Inventory:countOf`/`find`, `GObject:split`/`moveInto`/`remove` (all global —
and the fare is in the global script), `types.NPC.getDisposition`,
`core.getGMST`, `world.advanceTime` (hours), `cell.name`/`displayName`, and
`teleport(cell, pos, { onGround = true })`.

Two test failures on first run were both **faults in the test**, not the code,
and worth naming: one asserted a heading wrap after a single easing step that
the easing rightly refused to take, the other tried to express a nil override
through a table, which `pairs` cannot see. Both fixed to assert what they meant.

### What to check in game, in order

1. **Does the menu appear at all?** Talk to a caravaner and click Travel. If the
   vanilla list appears instead, the `I.UI.WINDOW.Travel` inference is wrong
   (§1) — the log line will say so, and ordinary travel still works.
2. **Do the destinations look right?** They come from the guide's own data, so
   anything missing means the cell-id-to-route-key fold missed — which falls
   back to ordinary travel rather than failing.
3. **Do the strider's legs move?** If not, no creature record matched and it
   fell back to an activator; there is a log line for that too.
4. **Is the rider seated correctly?** Slot 1 is the measured front seat
   `(0, 80, 1223)` and the body offset is 1220.
5. **Fare and clock.** Compare the quoted price against vanilla's for the same
   trip — it should match, same formula. Check the arrival time looks like a
   vanilla journey.
6. **Save mid-journey, load.** The journey should abort, put you down on the
   ground, and the caravaner should be back on their post.
