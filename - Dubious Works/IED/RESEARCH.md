# OpenMW Lua — accrued research

Written for agents making changes to this mod suite. Everything here was found
by reading, instrumenting or breaking real code: Bardcraft, Sun's Dusk,
Fashionwind, OMWFW, InventoryEquipmentDisplay and CAKE, plus the riding stack —
WhyWalk, AnimatedCreatureRiding, Devilish Horse/Guar Riding — and two external
references read for comparison, Sturdy Steed (SimpleHorseRidingBase) and p37z.
Where a rule has a counter-example, the counter-example is named.

Two things dominate: **per-frame work** and **`pcall`**. They are related. Bad
polling wastes frames you can measure; `pcall` hides the bugs you cannot.

---

# Part 1 — Per-frame work

## 1.1 The measured cost

Fashionwind's bug report is the only hard field data in this suite, and it is
worth quoting because it sets the scale:

> 7 NPC scripts have `onUpdate` on every active NPC... One cosmetic mod having
> 7 scripts cranking out constant 1k ops/s in just Pelagiad is really bad. In
> Narsis it's 5-6k ops/s per script.

Seven near-identical scripts, each walking every active NPC's inventory every
20 frames. The fix is not "poll less often". It is **one script instead of
seven**, and then **no polling at all**.

## 1.2 `onFrame` vs `onUpdate` — not interchangeable

| | runs while paused | use it for |
|---|---|---|
| `onFrame` | **yes** | work that must continue during a menu, and nothing else |
| `onUpdate` | no | all gameplay work |

Almost everything in a cosmetic or animation mod wants `onUpdate`. You cannot
change perspective from a menu, so a camera-mode check in `onFrame` is running
during menus purely to observe that nothing happened.

Bardcraft polled `camera.getMode()` in `onFrame`, unconditionally, for the
whole session:

```lua
onFrame = function(dt)
    local camMode = camera.getMode()
    if camMode ~= lastCameraMode then ... end
```

At 144 fps that is ~144 calls a second, forever, to catch an event that happens
a handful of times an hour — and it ran whether or not anything was attached.

## 1.3 The escalation ladder

Take the highest rung that works. Do not start at the bottom.

1. **Engine event.** `onActive`, `onInactive`, `UiModeChanged`, `onSave`/`onLoad`,
   `I.ItemUsage` handlers. Zero cost when nothing happens.
2. **Trigger handler.** `input.registerTriggerHandler("TogglePOV", ...)`.
   Instant, and not reached unless the key is pressed. Register defensively —
   trigger keys come from built-in scripts and a stripped setup may lack them:
   ```lua
   if input.triggers and input.triggers.TogglePOV then
   ```
3. **Key press/release handlers.** `onKeyPress` / `onKeyRelease` for held state
   (§1.12). Documented engine handlers for player local scripts; they are what
   `input.isKeyPressed` polling is usually standing in for.
4. **Storage subscription.** `settings:subscribe(async:callback(fn))`. Fires on
   change only.
5. **Interface subscription.** Publish an interface others subscribe to, and
   **hold the subscription only while it is needed** (§1.5).
6. **One-shot timer.** `async:newUnsavableSimulationTimer(delay, fn)` for a
   deferred settle. `time.runRepeatedly` for genuine periodic work.
7. **Throttled `onUpdate` with a cheap change signature** (§1.6).
8. **`onUpdate`, unthrottled.** Only when there is no event for what you are
   watching (§1.11) — and then with an early-out as the first line.
9. **`onFrame`.** Only for work that must survive a pause.

## 1.4 Event-first, poll-as-backstop

Some state changes arrive without an event. Camera mode is the canonical case:
`TogglePOV` covers deliberate presses, but vanity mode after idle, preview mode
while a key is held, and another mod calling `setMode` do not fire it.

`AnimRefresh` is the pattern: trigger handler for the case the player notices,
plus a **1 s** poll as a backstop for the cases they did not ask for. One second
of latency is acceptable precisely because those changes were not requested.

Never let the backstop become the mechanism. If the poll is doing all the work,
the event hookup is broken.

## 1.5 Subscribe only while active

The single highest-leverage rule. A mod that costs nothing when idle is a mod
nobody profiles.

```lua
local function syncSubscription(want)
    if want == subscribed then return end
    if not (I.AnimRefresh and I.AnimRefresh.subscribe) then return end
    if want then I.AnimRefresh.subscribe('MyMod', cb)
    else I.AnimRefresh.unsubscribe('MyMod') end
    subscribed = want
end
```

With no subscribers `AnimRefresh`'s `onUpdate` does one table-empty check and
returns, and its trigger handler is never reached. A player wearing nothing pays
essentially zero.

Call `sync` from every place the underlying state can change — in CAKE that is
`onActive`, the equip event, and `UiModeChanged`. A subscription that is never
released is just a poll with extra steps.

## 1.6 The change-signature pattern

When you genuinely must poll, make the "nothing changed" path free. From IED:

```lua
-- Deliberately avoids record() lookups: recordId and count are already on the
-- object, so the common path never touches the record store or the filesystem.
local function buildSignature(actor, equippedWeaponId, equippedShieldId, isDrawn)
```

Compare the string; rebuild only on difference. Two rules:

- **Never do a record lookup, VFS lookup or mesh resolution inside the
  signature.** That is the path taken every tick.
- **`getAll` ordering is not documented as stable.** If it ever varies, the
  signature differs and you do one redundant rebuild. Harmless — but do not
  build correctness on the order.

Fold settings into the signature rather than giving every context its own
subscription:

```lua
local signature = buildSignature(...) .. '|' .. tostring(cfg:get('showWeapons'))
```

## 1.7 Detecting rest, wait and travel

Bardcraft's trick, and the one most likely to be missed:

```lua
local currentTime = core.getGameTime()
if lastUpdate and currentTime - lastUpdate > 1 then
    self:setSheatheVfx()   -- rest / wait / fast travel all land here
end
```

Rest, wait and fast travel all appear as a discontinuity in game time. One test
covers all three without knowing which UI mode caused it. `UiModeChanged` on
`Rest`/`Travel`/`Training` covers the menus that rebuild the model **without**
advancing time. **Use both** — neither is a superset.

## 1.8 Deferred refresh after a model rebuild

Attaching to a skeleton that is about to be replaced attaches nothing. Both
prior mods defer, and Sun's Dusk's version is the better one:

| | defer | guard | retry |
|---|---|---|---|
| Bardcraft | 1 frame | none | no |
| Sun's Dusk | 0.1 s timer | `animation.hasBone` | once |

One frame is not always enough. Use the timer, guard with `hasBone`, retry
once, and **do not retry forever** — a missing bone is usually a missing
skeleton, not a race.

## 1.9 NPC scripts

- **One script for all categories.** Adding a slot must not add a script.
- **One inventory walk covering everything**, not one per category.
- `onActive` is normally sufficient. An NPC's inventory does not change while
  you are looking at it.
- If you must poll, `time.runRepeatedly` at ≥1 s, never a frame counter.
- **NPC local scripts cannot read a player settings section.** Route through a
  global section:
  `MENU declares → PLAYER subscribes and pushes → GLOBAL writes globalSection → NPC reads`.
  Absent config must read as *enabled*: an NPC can activate before the section
  is seeded, and defaulting to off looks like a broken mod.

## 1.10 Cheap wins, verified

- `item.recordId` — not a `getRecordId()` helper doing record lookups.
- `inv:find(id)` / `inv:countOf(id)` — engine-side, not a Lua `getAll` loop.
- `types.Actor.inventory(self)` — the handle is stable and self-updating; hoist
  it to script init rather than re-resolving.
- Memoize record and mesh lookups keyed by `recordId`. Cache the **miss** too
  (store `false`, distinguish from `nil`) or you re-derive it every pass.
- Cache a `hasBone` probe per animation-object lifetime, but invalidate it on
  anything that could rebuild the skeleton — and on a deliberate equip, which
  costs one probe on a keypress and stops a stale hit attaching to a bone that
  is no longer there.
- `core.land.getHeightAt(pos, cell)` instead of a downward raycast for ground
  clamping. A direct heightmap query — no ray, no collision traversal — which
  matters when it runs every frame. From Rideable Silt Striders via WhyWalk.
  Exterior-only: guard with `cell.isExterior`, do not discover it by catching
  (§2.4).
- Derive per-object constants from `obj:getBoundingBox()` rather than
  hand-measuring one entry per record. p37z positions a rider as a *fraction*
  of the mount's own half-extents (`Offset:emul(halfSize)`), so one default
  covers every creature in the game; WhyWalk hand-tunes nine `saddle` entries
  and still has nothing for the tenth creature. Fewer entries is also fewer
  lookups.
- Let the engine's character controller drive where you can. Writing
  `controls.movement` / `sideMovement` / `yawChange` on a creature costs
  nothing per frame and gets gait animation, root motion, collision, gravity
  and pathing for free; integrating movement yourself and `teleport`-ing the
  mount every frame reimplements all five, badly. p37z versus WhyWalk. The
  trade is control: you lose exact speed and turn-radius tuning.

## 1.11 When per-frame really is irreducible

Not every `onUpdate` is a failure. **Nothing in the OpenMW Lua API parents one
object's transform to another**, so a mod that pins one object to another has to
place it every frame. There is no event for "the thing I am attached to moved".

WhyWalk states this plainly in its own header, and that is the right way to
handle it: name the irreducible cost, keep it to *one* handler, and put a single
early-out at the top so the not-mounted case is one comparison.

```lua
local function onUpdate(dt)
    if not session then return end   -- the whole cost when not riding
```

The test for whether yours qualifies: **is there an event that fires when the
thing you are watching changes?** Camera mode has one (`TogglePOV`) plus
backstop cases (§1.4). Another object's position does not. If an event exists
and you are polling anyway, you are on the wrong rung.

Two corollaries:

- The irreducible handler should do *only* the irreducible part. WhyWalk's
  `onUpdate` pins the rider; it does not also read keys, or check camera mode,
  or re-derive a mount profile. Everything separable moved to an event.
- Once one handler is per-frame, adding work to it is invisible in a profile
  but not free. Audit it as its own budget.

## 1.12 Held keys are events, not state to poll

The most common avoidable `onFrame` in this suite. Both Devilish riding mods
and Sturdy Steed poll `input.isKeyPressed(input.KEY.W)` every frame to answer a
question the engine already announced twice.

`onKeyPress` / `onKeyRelease` are documented engine handlers for player local
scripts. Track held state from the edges:

```lua
local heldForward = false
local function onKeyPress(key)   if key.symbol == 'w' then heldForward = true  end end
local function onKeyRelease(key) if key.symbol == 'w' then heldForward = false end end
```

Rewriting the riding animation controller this way removed its `onFrame`
outright and took it from ~390 lines to ~270 — the deleted bulk was a throttle
simulation that existed only to give the per-frame poll something to compare.

Three details that bite:

- **Modifier state is cheaper to read than to track.** Rather than matching
  Shift's own `key.symbol`, call `input.isShiftPressed()` at the moment a
  movement key event arrives. Every key event re-evaluates it, including
  Shift's own.
- **Seed once on entry.** A key already held when the state begins generated
  its press event before you were listening. One `isKeyPressed` snapshot on
  mount — not a poll — fixes it.
- **Press events are their own edge detector.** Jump needs no
  `lastJumpPressed` bookkeeping; `onKeyPress` for Space *is* the edge.

## 1.13 Send intent on change, not state every frame

A rider holding W across a valley should generate **one** event, not one per
frame. Both reference riding mods re-send identical control values 60 times a
second; WhyWalk sends on change and integrates movement from last-known intent
in the global script.

This is the event-side twin of §1.6's change signature: instead of making the
"nothing changed" path cheap, do not take the path at all. Where a signature
still costs a comparison per tick, intent events cost nothing between changes.

The MWScript bridge has a matching idiom worth stealing — p37z writes a value,
and the script **zeroes it after applying**:

```
if ( moveX != 0.0 )
    player->setpos x moveX
    set MoveX to 0.0
endif
```

Consume-on-use makes the pin idempotent, stops stale values re-applying, and
means "no fresh write" and "no work" are the same condition. Its one trap is
using `0` as the sentinel for a value that can legitimately *be* zero — p37z
gates rotation on `zRot != 0.0`, so a mount facing exactly north (yaw 0) never
rotates its rider (§3.7).

## 1.14 Handlers that are not rate-limited by the frame

A per-frame poll has an implicit ceiling: it cannot run more than once a frame,
so even a badly broken one degrades to "wasteful". **Event handlers have no such
ceiling**, and the failure mode is qualitatively worse.

`addAnimationEndedHandler` is the case in this suite. Re-issuing a pose from the
ended-handler is correct — it recovers from interruptions no `TogglePOV` hook
would catch. But if the group name is wrong or its text keys are missing, the
clip ends immediately, the handler re-issues, and that is a tight loop inside
one frame, not one iteration per frame.

AnimatedCreatureRiding burst-guards it: **five restarts in a second stops and
logs a hint.** Any self-re-triggering handler needs the equivalent. The guard is
also a diagnostic — tripping it means a bad group name, which is exactly the
silent-asset class of bug in §3.2.

The same reasoning applies to anything that re-enters its own trigger:
storage subscriptions that write the section they watch, interface callbacks
that re-publish, text-key handlers that replay their own group.

---

# Part 2 — `pcall`

## 2.1 The rule

> **`pcall` is banned unless you are calling code you do not control, or
> failure is a supported state you have documented.**

Everywhere else it converts a diagnosable crash into an undiagnosable silence.
On a mod whose entire output is "a mesh appears", silence is indistinguishable
from working.

Audited across this suite: **21 `pcall`s found, 18 removed, 3 kept.**
A later sweep of the riding stack found **11 more, 9 removed, 2 kept** — the two
kept being the subscriber-callback isolation in `SharedRay` and `AnimRefresh`
(§2.3). Running total: **32 found, 27 removed, 5 kept.** No sweep so far has
found a *third* category worth keeping.

## 2.2 The two bugs it actually hid

Not hypothetical. Both cost real time.

**CAKE — a whole session.** `cake_shared.lua` baked the plugin's raw `MODL`
string into the registry and handed it to `addVfx`:

```
plugin MODL     RV\Ashmask1.nif        <- raw, relative to meshes/
record.model    meshes/rv/ashmask1.nif <- VFS path, what the API wants
```

Different strings. `addVfx` got a path that does not exist. `pcall` swallowed
it. The item was consumed, the `_eq` record created, state set correctly — and
nothing appeared. The report was "the item does nothing when selected."

**IED — silently believed nothing was ever equipped.** The original called
`types.Actor.equipment`, a function that does not exist. The `pcall` around it
returned `false`, the code treated that as "no equipment", and the mod worked
just wrongly enough not to look broken.

Note the shape both share: **the pcall did not protect against a failure, it
manufactured a plausible-looking wrong answer.**

## 2.3 What justifies one

**Third-party callbacks.** You do not control subscriber code, and one
subscriber throwing must not stop delivery to the others:

```lua
for key, callback in pairs(subscribers) do
    local ok, err = pcall(callback, mode, previous)
    if not ok then
        print("[AnimRefresh] callback error in '" .. tostring(key) .. "': " .. tostring(err))
    end
end
```

Note it **prints the key**. A pcall that discards the error is not isolation,
it is concealment.

**An optional module.** `require` has no non-throwing form, and if the file is
documented as deletable then absence is a supported state:

```lua
local ok, mod = pcall(require, 'scripts.cake.cake_anim')
if not ok then print('[CAKE] cake_anim.lua not loadable; gestures disabled') end
```

That is the entire list.

## 2.4 What does not justify one

Every one of these was removed:

| Call | Why the pcall was wrong |
|---|---|
| `anim.addVfx` | Path and bone are validated immediately above. A failure means one of those checks is wrong. |
| `anim.removeVfx` | Removing an id that was never added is a no-op. |
| `anim.hasBone` | Documented for any actor; cannot throw on a valid one. |
| `anim.playBlended` / `anim.cancel` | Playing or cancelling a group the skeleton lacks is a no-op. |
| `inv:countOf` | Documented method on an inventory you just obtained. |
| `obj:getBoundingBox` | Documented `GameObject` method on an object you just enumerated. |
| `types.Weapon.record` / `types.Armor.record` | The caller already established the type via `getAll(types.X)` or `objectIsInstance`. |
| `types.Actor.getEquipment` / `getStance` | Documented, on a valid actor. |
| `storage.playerSection` | Available in its context and creates on demand. |
| `world.mwscript.getGlobalVariables` | Documented as returning `MWScriptVariables` with no failure path — it fetches Morrowind's own global table, which exists whether or not your ESP loaded. Wrapping it detects nothing (§2.7). |
| `core.land.getHeightAt` | Exterior-only, and `cell.isExterior` is a documented field. Check the condition, do not catch it. |
| `types.Actor.stats.dynamic.health` | On a mount whose `isValid()` passed four lines above and whose type was checked at mount time. |
| `obj:teleport` | Inside a block already guarded by `isValid()` on both objects. |
| `spells:add` / `spells:remove` | See §2.9 — the pcall was covering a placeholder record id, not a runtime failure. |
| `input.isKeyPressed` | Documented for a player local script. If the key enum resolves at all it resolves every time. |

The recurring tell: **you are pcall-ing a documented API on an object you have
already validated.** If that can throw, your validation is the bug.

## 2.5 When you want a guard, not a pcall

A missing asset is a legitimate thing to handle — but *report* it:

```lua
elseif vfs.fileExists(path) then
    result = path
else
    print("[IED] mesh not in VFS, skipping: " .. tostring(path))
end
```

Checking and logging is not the same as swallowing. The distinction is whether
someone reading the log can tell what happened.

## 2.6 The dominant anti-pattern: a static condition, tested at runtime frequency

**Eight of the nine `pcall`s removed from the riding stack shared one shape.**
It is worth naming because it is not obvious from any single site:

> The wrapped call fails for a reason that is fixed at load — and it is being
> re-tested every frame.

Whether the ESP is installed. Whether a spell record exists. Whether a creature
is an Actor. None of these change between frames. Each was wrapped in a `pcall`
that ran at the frequency of the *use*, not of the *condition*.

Three costs, in increasing order of seriousness:

1. Wasted work, forever.
2. The answer is recomputed but never reported, so nobody learns it.
3. The code reads as if failure were expected here, which is a lie about the
   system that the next reader has to disprove.

The fix is always the same shape — resolve once, cache the verdict as a
boolean, branch on it, and **say something when it is false**:

```lua
local bridge = nil
local function bridgeReady()
    if bridge ~= nil then return bridge end
    local g = world.mwscript.getGlobalVariables(world.players[1])
    local ok = pcall(function() return g[NAMES.active] end)
    bridge = ok and g or false
    if not bridge then
        print("[WhyWalk] MWScript bridge unavailable ('" .. NAMES.active
              .. "' not found) -- falling back to the teleport backend")
    end
    return bridge
end
```

One `pcall`, once per session, on the cheapest possible probe. Everything
downstream writes bare, because the probe already established that it can.

Ask of every `pcall`: **at what frequency does the thing it is testing actually
change?** If the answer is "never", it belongs at load, not in the hot path.

## 2.7 The probe that probes the wrong thing

A `pcall` around the wrong call is worse than none: it *looks* like the
capability is being detected, so nobody checks again.

WhyWalk wrapped `world.mwscript.getGlobalVariables(...)` to detect a missing
ESP. But that function returns Morrowind's own global variable table and is
documented with no failure path — it succeeds whether or not the mod's plugin
loaded. The real failure was one layer down, in `g[names.x] = pos.x`, indexing a
name the ESP never defined. So the guard that was supposed to detect "ESP
missing" detected nothing, and the actual failure was caught by a *different*
`pcall`, per frame, silently.

When you write a capability probe, state what specific operation is expected to
fail, and probe **that** — here, reading one of your own names, not fetching the
table that contains them.

## 2.8 Silent degradation is worse than silent failure

§2.2 covers `pcall` producing a plausible wrong answer. There is a nastier
variant: `pcall` selecting a **fallback code path** and never saying so.

`placeRiderMWScript` returned the `pcall`'s `ok`. On failure the caller quietly
used the teleport backend instead — the path the mod's own comments describe as
triggering an engine bug with nearby NPCs. So a user with a missing ESP got the
known-buggier implementation, every frame, forever, with nothing in the log.

The mod did not break. It got worse, invisibly, and the report would have been
about the *symptom of the fallback*, not the missing plugin.

Any `pcall` whose result chooses between implementations must log the choice
once. If two backends exist, which one is live is a fact worth being able to
read out of a log.

## 2.9 A `pcall` standing in for a missing asset

Sometimes the `pcall` is not wrong so much as it is a symptom.

WhyWalk's `levitationSpellId` was `"placeholder_whywalk_levitate"` — a record
that had never been authored. `spells:add` therefore failed **by design**, every
mount, and the `pcall` existed purely to absorb a guaranteed failure. Removing
the `pcall` alone would have been wrong; it was load-bearing for a broken
design.

The real fix removed the dependency. p37z modifies the effect magnitude
directly, with no record at all:

```lua
types.Actor.activeEffects(actor):modify(1, core.magic.EFFECT_TYPE.Levitate)
```

That deleted the spell id, the ESP record it implied, the `levitationAdded`
bookkeeping and **both** `pcall`s together.

When a `pcall` is wrapping your own missing asset, the question is not "is this
`pcall` justified" but "why is the asset missing, and is there a form of this
feature that does not need it?"

## 2.10 Removing a `pcall` exposes what it was resting on

Expect the removal to surface adjacent bugs. That is the point, but it means a
sweep is not a mechanical edit.

Renaming the cached handle in §2.6 turned up `mwGlobals = nil` in `onLoad`,
left over from the old name. After the rename it would have silently created a
**global** variable and left the real cache stale across a load — so a save
loaded with a different mod order would keep the previous session's verdict
forever. The `pcall` had not caused that bug, but it had made the variable's
lifetime invisible enough for it to survive review.

Two habits follow:

- After removing `pcall`s, grep for every name involved. A stale assignment to a
  now-renamed local is a silent global write, and Lua will not tell you.
- Run `check_names.py` (§Part 4) specifically for this. It is the tool that
  catches the class.

## 2.11 Removal checklist

For each `pcall`, in order. Any "no" means remove it.

1. Is the wrapped code third-party, or a documented-optional `require`? → keep
   (§2.3).
2. Does the failure it catches change at runtime, or is it fixed at load?
   (§2.6)
3. Is it wrapping the call that actually fails, or a neighbouring one? (§2.7)
4. Does the failure path silently select a different implementation? (§2.8)
5. Is it covering an asset of yours that does not exist yet? (§2.9)
6. Has the object already been validated by an enclosing guard?
7. If it stays: does it print the error, and enough context to identify the
   subscriber or path? A `pcall` that discards the error is concealment.

---

# Part 3 — Bug catalogue

Every one of these was found in shipped code in this suite.

## 3.1 Paths and assets

| Bug | Detail |
|---|---|
| **Raw `MODL` vs VFS path** | Plugin `MODL` is relative to `meshes/` with original case and backslashes. `record.model` is a VFS path. Resolve from the record **at runtime**; never bake the plugin string into Lua. |
| **Sharing one mesh between world object and VFX** | Bardcraft states it outright: a mesh attached as VFX stops being interactable until restart. Sun's Dusk avoids it by convention — `_g` ground mesh on the base record, worn mesh on `_eq`. Treat "worn model ≠ ground model" as a requirement. |
| **Unchecked base mesh path** | Existence-checking only a `_sh`/`_eq` variant and returning the base path unchecked is one `pcall` away from silent failure. |
| **Preserving plugin fidelity in the wrong place** | Reproducing paths verbatim is right for the *plugin* and wrong for the *Lua registry*. Assert against the engine's expectations, not the plugin's. |

## 3.2 Animation API

| Bug | Detail |
|---|---|
| **`BONE_GROUP` ≠ `BLEND_MASK`** | `BONE_GROUP` is a sequential index (LowerBody 1, Torso 2, LeftArm 3, RightArm 4). `BLEND_MASK` is a bitmask (1, 2, 4, 8). Summing `BONE_GROUP` yields a valid but meaningless mask — Torso+LeftArm+RightArm = 9 = LowerBody+RightArm. `BLEND_MASK.UpperBody` (14) already means torso plus both arms. |
| **`PRIORITY.Scripted`** | Pauses every non-Scripted animation globally. Wrong for a short gesture — it freezes the walk cycle. Use `PRIORITY.Weapon` on an upper-body mask. |
| **Missing bone is silent** | Attaching to a bone that does not exist is a no-show, not an error. Always `hasBone` first, and always declare a vanilla fallback. |
| **`animation.cancel`** | Lives on `openmw.animation` and takes the actor. It is not on `I.AnimationController`. |
| **`types.Actor.equipment`** | Does not exist. It is `getEquipment`. |
| **KF text keys** | A group keyed `loop start`/`loop stop` will not answer to `start`/`stop`. Read the keys out of the binary; the resulting stuck or absent pose reads as a scripting bug when it is a naming one. |
| **`vfxId` and magic effects** | The engine uses `vfxId` to add and remove magic effects. The docs warn explicitly against ids that collide with `core.MagicEffectId` values. Namespace yours (`saw_w_<recordId>`, `cake_<category>`). |

## 3.3 Bones and slot arbitration

| Bug | Detail |
|---|---|
| **Occupancy keyed by type, not bone** | IED mapped `AxeOneHand` and `LongBladeOneHand` to one bone, and `Arrow`/`Bolt` to another, but deduplicated by weapon *type*. An equipped sheathed longsword plus a carried axe stacked two meshes on one bone. Key by **resolved bone name**, and compute the shared set from the map rather than restating it. |
| **The engine occupies the same bones** | OpenMW's native weapon sheathing puts the equipped-and-undrawn weapon and shield on the same bones a display mod uses. Claim the bone only while `not isDrawn`; drawn, it is free again. |
| **Excluding by record id, not occupancy** | Skipping "the equipped shield" by `recordId` still lets a *second, different* shield onto the bone the engine already filled. |
| **Arbitration that never arbitrates** | OMWFW's five head categories each wrote their "bone owner" lock to a *different* storage section, so every `xIsOurs()` was unconditionally true. Distinct `vfxId`s mean shared-bone categories do not evict each other anyway — declare explicit `conflicts` both ways and assert symmetry. |

## 3.4 State

| Bug | Detail |
|---|---|
| **Inferring worn state from inventory presence** | If "the `_eq` record is in your bag" *is* the test, then **looting one equals wearing it**. Keep explicit state set by activation; the inventory audits it, it does not define it. |
| **String surgery for id derivation** | `id:sub(1, -4)` and `id .. "_eq"` are right only if the id already carries the expected prefix. Use an explicit reverse index so a naming change fails loudly at generation time, not silently at runtime. |
| **Record ids are lowercase** | Comparisons against `item.recordId` must be lowercased. Half of one table's keys were capitalised and could never match. |
| **A refresh trigger that does not refresh** | Bardcraft's `UiModeChanged` called `verifySheathedInstrument()`, which returns a boolean and has no side effect. The documented refresh never happened. |

## 3.5 Plugin data

| Bug | Detail |
|---|---|
| **`_eq` applied to `FNAM` instead of `NAME`** | 320 records with 160 unique ids: two identical blocks differing only in display name. The second silently overwrote the first (TES3 is last-wins), leaving zero `_eq` records and every item named "…_eq". |
| **Ids from a different content set** | 50 ids in a script, **none** of which existed in any shipped plugin. Always cross-check the registry against the plugin binary. |
| **Undeclared masters** | Meshes from OAAB, Project Cyrodiil and others resolve fine for you and not for users. Declare the masters — do **not** "fix" it by editing or dropping the records; those paths are correct. |
| **Bodypart / item id collisions** | Reusing bodypart ids (`_RV_Ashmask1_H`) for wearable items works at the engine level but conflates the two everywhere else. A prefix resolves it. |

## 3.6 Structure

- **Dead settings are worse than no settings** — they imply a feature exists.
  Cross-reference declared against read.
- **An empty category is a load failure waiting to happen** if anything
  validates its keys against it. Prune empties at generation time.
- **Registration must be idempotent.** `onInit` and `onLoad` both call it and
  only one runs on a given start.
- **Bundle shared libraries, do not copy them in.** Version-guard the file
  itself (`if I.X and I.X.version >= MY_VERSION then return end`) so only the
  newest loaded copy runs. `AnimRefresh`, `SharedRay`, `SuperSettingsRenderers`.

## 3.7 Riding, pinning and the MWScript bridge

| Bug | Detail |
|---|---|
| **Missing `player->` prefix** | In MWScript an unprefixed command applies to the object the script runs on. `SetAngle Z pa` in a script attached to a creature rotates the **mount**; `player->SetAngle Z pa` rotates the rider. Both Sturdy Steed scripts keep the prefix even in `SimpleHorseRiding222`, which *is* a local creature script — the prefix is what makes the target explicit rather than positional. Symptom: the mount spins instead of the rider. |
| **`rotateZ` sign is not settled** | Four independent usages disagree. Sturdy Steed's pillion positioning and WhyWalk's rider use `rotateZ(+yaw)`; p37z's rider and WhyWalk's *mount* use `rotateZ(-yaw)` — WhyWalk uses both signs in one function. Cod3x documents the `teleport` rotation parameter only as `util.Transform`, with no sign convention. Vector transforms are unambiguous (`rotateZ(getYaw())`, per Cod3x's own actor-space example); the `teleport` rotation argument is not. **Verify in game before changing either.** A negation may also be compensating for a creature NIF whose mesh faces −Y. |
| **Perspective gate on the wrong side** | The rider's body yaw must be forced **only** in third person — in first person the player's yaw *is* the look direction and overwriting it fights mouse-look. `PCGet3rdPerson` is free and always correct in MWScript, and camera mode is not readable from a global Lua script, so the gate belongs in the MWScript, not in Lua. |
| **`0` as both a value and a sentinel** | p37z signals "do not rotate" by writing `zRot = 0`, and the script gates on `zRot != 0.0`. A mount facing exactly north has yaw 0, which is indistinguishable from "no request" — the rider never aligns. Pick a sentinel outside the value's range, or carry a separate flag. |
| **One saddle offset for both perspectives** | `setFirstPersonOffset` is documented as the offset between the character's **head** and the camera. The pin places the rider's **feet**, so a first-person camera lands at `saddle.up` + head height above the mount — far too high — and the only correction available walks the camera down *through* the mount's neck. Sturdy Steed carries two poses per creature (`sdlUp3 80` / `sdlUp1 47`) and picks on `PCGet3rdPerson`: move the body, not the camera. |
| **Mixed priority tiers in one pose** | `RightArm` at `PRIORITY.Scripted` while `LeftArm`/`Torso` were `PRIORITY.Weapon`, in the same `playBlendedAnimation` call. Given §3.2's note that `Scripted` pauses all non-Scripted animation, mixing tiers within one pose is almost certainly unintentional. |
| **A defined group that is never played** | `GROUPS.HANDOFF` existed and the state branch played `GROUPS.DRAWN` instead. Cross-reference every declared group against its play sites — `sweep.py` territory. |
| **Cancel with a hardcoded blend mask** | The "reissue at `Default` priority" cancel idiom must reproduce the mask the group was *played* with. A shared `releaseGroup` hardcoding the full-body mask corrupted upper-body-only poses. `animation.cancel` takes only the group name and cannot get this wrong (§3.2). |
| **Reset lists that miss a group** | `forceReset()` released the groups that existed when it was written and was never updated for `HANDOFF` or the per-target-type firing variants. Enumerate from the table that defines them, do not restate the list. |
| **`for i = n, -1 do`** | p37z's duplicate-registration guard. No step, so it counts *up* from `n` to `-1` and the body never runs when `n >= 0`. The guard it advertises does not exist. `for i = n, 1, -1`. |

---

# Part 4 — Verification

Tooling in `tools/`. No Lua interpreter is installed; `luacheck.py` and
`luarun.py` drive the system `liblua5.4.so.0` through ctypes. (The same library
also links directly — `gcc` against `/usr/lib/x86_64-linux-gnu/liblua5.4.so.0`
with `luaL_newstate` / `luaL_loadfilex` / `lua_tolstring` declared by hand, since
no Lua headers are installed. Useful as a second opinion when a ctypes signature
is in doubt.)

| Tool | Catches |
|---|---|
| `luacheck.py` | Syntax. |
| `check_names.py` | Undefined names, unused requires. |
| `api_sweep.py` | Every `module.member` call vs the Cod3x stubs. **Run this** — a misspelled API inside a pcall-wrapped call is §2.2 again. |
| `sweep.py` | Settings declared vs read, categories used vs defined, events sent vs handled, l10n keys, orphaned modules. |
| `test_*.lua` | Mocked-API behaviour tests. |

## 4.1 A mock that accepts everything tests nothing

The single most important testing lesson here. CAKE's integration test passed
through the entire path-bug session because its mock returned `m/<id>.nif` for
`record.model` and its `addVfx` accepted any string.

Mocks must **assert the contract the engine enforces**:

```lua
addVfx = function(_, path, o)
    assert(path:sub(1,7)=='meshes/' and not path:find('\\',1,true),
           'addVfx got a non-VFS path: '..path)
    assert(world.files[path], 'addVfx got a path not in the VFS: '..path)
    if world.vfx[o.boneName] then world.doubled = (world.doubled or 0) + 1 end
    ...
```

That last line is the other half: a counter that trips whenever two meshes land
on one bone turns §3.3 into a test rather than a code review.

## 4.2 Assert the invariant that matters

Four assertions were once added guarding "the registry matches the plugin". It
did. The thing that had to match was **the engine**. Before writing an
assertion, ask which side actually enforces the constraint.

## 4.3 Generate, do not hand-maintain

Registries derived from plugin data should be generated by a script that
**asserts its own invariants** — every category bone exists in the skeleton,
every item resolves to a category, ids are lowercase, conflicts are symmetric.
A typo then fails at generation rather than silently in game.

---

# Part 5 — Checklist before changing anything here

1. Does this add an `onFrame` or `onUpdate` handler? Justify it against §1.3.
   Specifically: **is there an event for the thing you are watching?** If yes,
   you are on the wrong rung. If genuinely not (§1.11), is the early-out the
   first line?
2. Does it poll anything a subscription or engine event would give you? Held
   keys are the usual offender — `onKeyPress`/`onKeyRelease`, not
   `isKeyPressed` every frame (§1.12).
3. If it subscribes, is the subscription released when idle?
4. Does it re-send unchanged state? Send intent on change instead (§1.13).
5. Can the handler re-trigger itself? Animation-ended and text-key handlers are
   not rate-limited by the frame — burst-guard them (§1.14).
6. Are you adding a `pcall`? Walk §2.11. It needs to be third-party code or a
   documented optional; everything else has a specific reason it is wrong.
7. Are you passing a mesh path? Resolve it from the record at runtime.
8. Are you attaching to a bone? `hasBone` first, vanilla fallback declared.
9. Are you tracking occupancy? Key it by bone, not by type — and check whether
   the engine already owns that bone.
10. Are you inferring state from inventory presence? Don't.
11. Are you cancelling an animation? `animation.cancel(self, group)` — not a
    reissue at `Default` priority with a hand-written blend mask (§3.7).
12. Did you write MWScript? Every command that should affect the player needs
    the `player->` prefix (§3.7).
13. Run `luacheck.py`, `check_names.py`, `api_sweep.py`, `sweep.py` and the
    tests. All five, not the first one. After a `pcall` sweep, `check_names.py`
    is the one that matters (§2.10).
14. If you added behaviour, does the mock actually enforce the engine's
    contract, or would it accept a wrong answer?
