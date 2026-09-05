# The Vibe Coders' Corpusorium — experimental resource

Companion to `RESEARCH.md`. Where `RESEARCH.md` records what was found by
breaking this mod suite, this file records what was found by reading four and a
half years of the OpenMW `#lua-scripting` channel and checking every load-bearing
claim against the Cod3x 0.4 stubs.

**Status: experimental.** Nothing here is a primary source. Discord is a record
of what people *believed* on a given date, and a large fraction of it was true
then and is false now. Every entry below carries a date and an author for that
reason. Entries that survived a Cod3x check are marked; entries that did not are
marked louder.

---

# Part 0 — Provenance and how to trust it

## 0.1 What the corpus is

| | |
|---|---|
| Source | Discord `#lua-scripting`, one channel, JSON page dumps |
| Messages | 103,899 unique after dedupe |
| Span | 2021-06-16 → 2025-12-19 |
| Engine horizon | ends around **OpenMW 0.50** |

Cod3x 0.4 documents **OpenMW 0.52**. The corpus is therefore *two releases stale
at its newest point and four and a half years stale at its oldest*. That gap is
not a footnote — it is the single most important fact about this resource, and
Part 5 exists entirely because of it.

## 0.2 The trust ladder

Take the highest rung that answers the question. This mirrors §1.3's structure
deliberately.

1. **Cod3x 0.4 stubs.** Generated from the 0.52 API. Authoritative on shape,
   context, receiver type and option names.
2. **Engine source quoted in-channel.** Several answers in the corpus are
   verbatim C++ (`correctMeshPath`, the `BlendMask` enum, `addVfx`'s sol
   binding). These are checkable and were checked.
3. **A statement by the person who wrote the binding.** `ptmikheev` (Lua core),
   `urm`/uramer (Lua core), `assumeru` (engine), `.foll` (the animation API),
   `akortunov`, `zackhasacat`, `s3kshun.8` (Cod3x's author), `greatness7`
   (tooling). These are usually right and occasionally superseded.
4. **A working code snippet posted by a mod author.** Evidence that it worked on
   that date, on that build. Nothing more.
5. **Anything else.** Treat as a lead, not a fact.

## 0.3 The dating rule that matters most: the camelCase watershed

On **2024-07-19** the animation API's option keys were renamed from lowercase to
camelCase (`startkey` → `startKey`, `stopkey` → `stopKey`, `autodisable` →
`autoDisable`, `blendmask` → `blendMask`, `bonename` → `boneName`). `.foll`, who
made the change, gave the reasoning plainly: people kept getting them wrong, and
the options table has no name enforcement, so "you won't even get an error
message".

Consequences, in order of importance:

- **Every animation snippet in the corpus dated before 2024-07-19 is wrong
  today**, and wrong in the worst possible way: it parses, it runs, it returns,
  and it does nothing.
- Several later threads are people hitting exactly this and reporting it as
  "playBlendedAnimation does nothing, no errors are printed" (2025-05-24) —
  fifteen months after the rename. It is still catching people.
- s3kshun.8 diagnosed a broken published mod from this alone (2024-09-22).

**Rule for using this corpus: check the date on any animation snippet before
copying it, and check every option key against `openmw/animation.lua`.**

## 0.4 Citation format

Entries cite `author, YYYY-MM-DD`. The corpus has no stable public message ids
you can navigate to, so Appendix A gives the flattening script that produces a
reproducible chronological index if you want to re-find a thread.

---

# Part 1 — Corrections to `RESEARCH.md`

These are the entries where the corpus or Cod3x contradicts something currently
written down. Fix these first.

## 1.1 `BONE_GROUP` values are 0–3, not 1–4 — Cod3x 0.4

`RESEARCH.md` §3.2 says `BONE_GROUP` is "a sequential index (LowerBody 1, Torso
2, LeftArm 3, RightArm 4)". `openmw/animation.lua` says:

```
BoneGroupLowerBody  0
BoneGroupTorso      1
BoneGroupLeftArm    2
BoneGroupRightArm   3
```

Off by one. The conclusion §3.2 draws is unaffected and in fact gets stronger:
summing `BONE_GROUP` values to build a mask is meaningless, and with `LowerBody
= 0` it is meaningless in a new way — adding `LowerBody` to a sum contributes
nothing at all, so `Torso + LeftArm + RightArm = 6 = BLEND_MASK.Torso |
BLEND_MASK.RightArm`, and adding `LowerBody` does not change it. Two different
intents produce the same wrong mask.

The worked example in §3.2 ("Torso+LeftArm+RightArm = 9") should be corrected to
6, and the sentence about `BLEND_MASK.UpperBody` (14) stands.

**Why the confusion is structural, and the fix:** `BONE_GROUP` is not an
alternative spelling of `BLEND_MASK`. It is the **key type of the `priority`
table**. `BLEND_MASK` is the **value type of the `blendMask` field**. They appear
in the same call and never in the same slot:

```lua
priority  = { [anim.BONE_GROUP.LeftArm] = anim.PRIORITY.Weapon,
              [anim.BONE_GROUP.Torso]   = anim.PRIORITY.Weapon },
blendMask = anim.BLEND_MASK.LeftArm + anim.BLEND_MASK.Torso,
```

That shape (s3kshun.8, 2025-10-26) is the one to copy. If a `BONE_GROUP` value
ever appears to the right of `=`, or a `BLEND_MASK` value inside `[]`, it is a
bug.

## 1.2 `types.Actor.equipment` existed — it was renamed, not invented

`RESEARCH.md` §2.2 describes IED calling `types.Actor.equipment`, "a function
that does not exist". Sharper: ptmikheev, **2023-05-08**: the function was
renamed to `getEquipment` that day. Documentation and examples posted the day
before use `equipment`.

This matters for the pcall argument rather than weakening it. The failure mode
was not a typo — it was **inherited code that was correct against an older
engine**, wrapped in a `pcall` that converted an API rename into "the player has
no equipment". A `pcall` around a version-sensitive call is worse than a `pcall`
around a typo, because the typo would have been caught in the first test and the
rename would not.

Restate §2.2's lesson as: *a `pcall` around an engine API converts version drift
into silent behavioural drift.* That is the general case, and it is the reason
`api_sweep.py` exists.

## 1.3 "Missing bone is silent" — silent on screen, loud in the log

`RESEARCH.md` §3.2 says attaching to a nonexistent bone is "a no-show, not an
error". Half right, and the other half is a diagnostic you are currently not
using.

s3kshun.8, **2025-12-01**, on reading other people's logs: certain animation
mods fill the log with `missing bone <name>` lines, one per attach attempt, and
he can identify which mod is installed from which bone names appear. In the same
exchange greatness7 notes players routinely run with gigabyte-scale error logs
and never look.

Corrected rule: **the visual result is silent; the log is not.** `hasBone` first
is still right — it is cheaper than logging and it lets you take the fallback —
but "check the log for `missing bone`" belongs in Part 4 as a verification step,
and a CAKE/IED shipping check should be "attach everything, then grep the log for
`missing bone`", which will catch a wrong bone name in an authored mesh that
`hasBone` guards will otherwise hide by silently taking the fallback.

## 1.4 Settings reads are cheap — the caching rule needs a different reason

`RESEARCH.md` §1.10 and §1.6 both push toward caching settings via `subscribe`
rather than reading per-frame. ptmikheev, **2023-01-02**, flatly:

> Accessing a setting is not expensive. It is fine to do it in every frame.

Both can be true, but the *justification* currently written down is wrong, and a
wrong justification will be misapplied. The defensible reasons to keep the
`subscribe` pattern are:

- It removes the read from the change signature entirely (§1.6), so the
  "nothing changed" path is a string compare and not a storage lookup plus a
  concat.
- `section:get` on a table value returns a read-only view; `getCopy` allocates.
  Per-frame `getCopy` is the expensive one, not `get`.
- A subscription gives you a *change edge*, which is what §1.5's
  subscribe-only-while-active needs. A per-frame read gives you a level, and you
  then have to diff it yourself.

Rewrite §1.10's bullet as "prefer the change edge, not because `get` is slow".

## 1.5 `onFrame` availability is narrower than the table implies

`RESEARCH.md` §1.2's table implies `onFrame` and `onUpdate` are two options
available in the same place. They are not, and the discrepancy is unresolved
between sources:

| Source | Claim |
|---|---|
| zackhasacat, 2023-12-05 | `onFrame` fires only in **player** scripts, and does not fire while a video is playing |
| Cod3x 0.4 plugin | `FRAME_CONTEXT = { local, player, menu }` — the availability set gating `core.getRealFrameDuration` |

Cod3x does not model engine handlers at all (§4.2), so its `FRAME_CONTEXT` is
evidence about a frame-duration accessor, not proof about `onFrame`. The safe
reading for this suite:

- **Never put `onFrame` in a global script.** Neither source supports it there.
- Do not rely on `onFrame` for anything that must survive a video cutscene.
- The §1.2 table should say "player (and possibly local/menu) scripts only" until
  someone tests it.

This does not change any conclusion in Part 1 — the answer to "should this be
`onFrame`?" is still almost always no — but the table currently reads as though
it were a free choice.

---

# Part 2 — Confirmations

Places where an independent source agrees with something already written down.
These are worth recording because they convert a suite-local rule into a
general one.

## 2.1 Animations are reattached on camera-mode change — first-party confirmation

s3kshun.8, **2025-12-01**, in passing while complaining about missing bone
names: "The anims get reattached when you change camera mode".

This is the entire premise of `AnimRefresh` (§1.4, §1.8) stated by someone
outside this suite, as background knowledge rather than a discovery. The
`TogglePOV` trigger handler plus 1 s backstop is not a workaround for a quirk of
one mod; it is the correct response to documented engine behaviour.

It also explains why the missing-bone log spam is *per camera toggle* rather than
once per load, which is why those logs get so large.

## 2.2 `PRIORITY.Scripted` pauses everything — now confirmed by the stub text

§3.2's warning against `PRIORITY.Scripted` for short gestures is confirmed
verbatim in `openmw/animation.lua`: when any animation with that priority is
present, all animations without it are paused. Global, not per-bone-group. The
recommendation (`PRIORITY.Weapon` on an upper-body mask) stands.

Corpus corroboration from the other direction: `playQueued` effectively pauses
the character controller until the animation finishes, which includes movement
and death animations (.foll, 2023-12-25). Users who reach for `playQueued`
because `playBlended` "does nothing" then report being stuck in place
(2025-05-24). Both symptoms have the same root: the character controller wins,
and the fix is priority and blend mask, not a different function.

## 2.3 `interface.version` is the documented convention

§3.6 recommends version-guarding bundled shared libraries with
`I.X.version >= MY_VERSION`. ptmikheev posted the canonical interface-override
example (2023-05-29) with `version = 1` as the first field, and the
`onInterfaceOverride` chaining pattern:

```lua
return {
  interfaceName = "SomeUtils",
  interface = interface,
  engineHandlers = {
    onInterfaceOverride = function(base)
      baseInterface = base
      setmetatable(interface, { __index = base })
    end,
  },
}
```

Two details from that thread worth adding to §3.6:

- The `setmetatable` form costs an extra table lookup on every non-overridden
  function. The explicit copy form (clear, copy base, apply overrides) does not.
  For `AnimRefresh` and `SharedRay`, which are called from hot paths, prefer the
  copy.
- `onInterfaceOverride` can fire more than once. ptmikheev's own example clears
  the interface table first for that reason. A bundled library that assumes it
  runs once will double-apply.

## 2.4 One script, not seven — and the mechanism

§1.9's "one script for all categories" is confirmed with a mechanism nobody in
this suite had written down (urm and .foll, 2024-04-23):

- Compiled chunks are cached **globally**, in a single `LuaState`. Requiring a
  file from a thousand actors does not compile it a thousand times.
- The module **body re-runs per script sandbox**. Every path in `.omwscripts`,
  and every `object:addScript`, gets its own sandbox with its own `loaded` table.
- Within one sandbox, a repeated `require` does not re-run the body.

So the cost of a shared library is *(number of distinct scripts) × (body cost)*,
not *(number of actors) × (number of requires)*. This is why "seven near-identical
NPC scripts" is expensive in a way that "one script requiring seven modules" is
not — and it is also why **module-level state in a bundled library is per-script,
not global**. `SharedRay` and `AnimRefresh` must not assume a single instance of
their upvalues exists; that is what the interface is for.

## 2.5 The escalation ladder's timer rung is cheaper than assumed

§1.3 rung 5 (one-shot timers, `time.runRepeatedly`) is treated as a
last-resort-before-polling. ptmikheev, **2022-07-17**: timers are handled
**per object, not per script**, as a sorted queue of timestamps, so an object
carrying a thousand timers costs one comparison per frame, not a thousand.

Practical effect: a deferred settle timer is nearly free, and there is no reason
to hesitate about the 0.1 s deferred-refresh timer in §1.8 or to try to merge
several timers into one for performance. Merge them for clarity if you like; do
not merge them for cost.

---

# Part 3 — New material

Things the corpus knows that `RESEARCH.md` does not. Ordered roughly by how
likely each is to bite this suite.

## 3.1 Animation option keys are silently ignored when misspelled

Covered in §0.3 as a dating rule; it is also a bug-catalogue entry in its own
right, and it generalises.

.foll, **2024-07-19**: options tables get no content or name enforcement, so a
wrong key produces no error message. The engine reads the keys it knows and
ignores the rest.

This is the same failure shape as §3.1's raw-`MODL` bug and §3.2's missing bone:
**the API accepts a well-formed call that means nothing.** Add it to §3.2 as a
row, and add an assertion to the mock harness (§4.1): the mock `playBlended`
should reject any option key not in the known set, rather than reading the ones
it recognises. A mock that ignores unknown keys reproduces the engine's bug
instead of catching it.

Known-good key set as of Cod3x 0.4: `loops`, `priority`, `blendMask`,
`autoDisable`, `speed`, `startKey`, `stopKey`, `startPoint`, `forceLoop`. For
`addVfx`: `loop`, `boneName`, `particleTextureOverride`, `vfxId`,
`useAmbientLight`, `autoTransform`, `transform`.

## 3.2 Priority identity is a four-tuple, and equal priorities do not co-play

.foll, **2024-07-18**, on how the animation object arbitrates:

- Priorities are set **per bone group** — four independent values, not one.
- Two animations with **identical** priorities cannot play simultaneously.
- "Identical" means *all four* values equal. Differ in one bone group and both
  play.

And the failure mode when you get it wrong (.foll, 2024-07-19): your animation
plays, then the original plays with blend mask 0, and **neither is visible**.
Blend mask alone does not win the arbitration; you must also change the
priority.

For this suite: any override of a vanilla group (CAKE gestures, WhyWalk riding
poses, FLOW movement) must differ in at least one bone group's priority from
whatever the character controller is playing, or the visible result is nothing —
with no error, and with `getCurrentTime` reporting the animation as playing.

## 3.3 The start key is not emitted as a text-key event

.foll, **2023-12-25**: the start key does not arrive as a text-key event, and
should not. Text keys are delivered from the first key *after* the current state
time.

`RESEARCH.md` §3.2 warns that a group keyed `loop start`/`loop stop` will not
answer to `start`/`stop`. Add the complement: **you cannot use a text-key handler
to detect the beginning of an animation you started.** If you need a start edge,
take it at the call site. Reacting to a text key also cannot pre-empt the
character controller — the controller's own logic continues regardless
(.foll, 2023-12-25); overrides belong in the play handler
(`addPlayBlendedAnimationHandler`), not the text-key handler.

## 3.4 `createRecord` double-prefixes `model` — the inverse of the CAKE path bug

This is the highest-value new entry for CAKE, because CAKE creates `_eq` records.

zackhasacat, **2023-05-29**, with the engine source:

```cpp
std::string Misc::ResourceHelpers::correctMeshPath(const std::string& resPath, const VFS::Manager* vfs)
{
    return "meshes\\" + resPath;
}
```

Unconditional prefix. No VFS lookup, no case correction, no idempotence check —
unlike `correctIconPath`, which routes through `correctResourcePath`.

Therefore:

| Direction | What the string is |
|---|---|
| **Reading** `types.X.record(obj).model` | already prefixed — a VFS path |
| **Writing** `createRecordDraft{ model = ... }` | must be **unprefixed**, relative to `meshes/` |

Round-tripping — reading `record.model` and passing it into a new record — yields
`meshes\meshes\...` and a record that never loads. Icons are unaffected.

`RESEARCH.md` §3.1 currently has one direction of this ("resolve from the record
at runtime; never bake the plugin string into Lua"). The other direction is the
exact opposite instruction, and both are needed:

> **Read the VFS path from the record. Write the plugin-relative path into the
> record. Never pass either one to the other side.**

Two caveats before acting on this. First, it is a 2023 observation of a
then-acknowledged bug that zackhasacat filed an issue for; it may have been
fixed between then and 0.52, and Cod3x's `createRecord` stubs do not say which
convention they take. **Test the round trip on your target build before
shipping.** Second, the `"meshes\\"` literal is a *backslash* — which is
consistent with §3.1's observation that raw `MODL` uses backslashes, and means
any assumption that `record.model` is forward-slashed is build-dependent and
should be asserted in the mock, not assumed.

## 3.5 `setEquipment` is whole-table, destructive, and coalesced

Multiple independent confirmations, and every one of them is a hazard for a
cosmetic mod that touches slots.

- **It unequips everything absent from the table** (ptmikheev, 2023-05-08:
  intended behaviour). Read-modify-write is mandatory; never construct a fresh
  table with just your slot.
- **It genuinely unequips and re-equips**, it does not diff (clavernever tested
  it, 2024-03-17). Anything hooked to equip/unequip fires for every slot you
  passed through, including other mods' handlers.
- **Constant effects do not apply** when an item is equipped this way
  (sosnoviybor, 2025-05-02). Enchanted items equipped via `setEquipment` behave
  differently from the same item equipped through the inventory.
- **Multiple calls in one frame coalesce** — urm, 2025-01-22: only the first
  applies. Two mods reacting to the same event both writing equipment means one
  of them silently loses.
- The item **must already be in the actor's inventory**.
- Receiver rules: Cod3x 0.4 types it `openmw.SelfObject` — local scripts, self
  only. ptmikheev floated allowing it in global scripts in 2023 and the corpus
  does not record it landing; **Cod3x is the authority here**.

For CAKE and IED: this is why worn state must be activation-driven and
explicitly held (§3.4), and it is an additional argument for it. Any design that
reconstructs equipment from an inferred state will re-equip the player's whole
loadout on every reconciliation, and the constant-effect gap means the player
may lose enchantment effects while your mod believes it changed nothing.

## 3.6 `onActivated` does not fire on objects carrying an MWScript

zackhasacat found it (2023-05-30); ptmikheev explained it the next day: MWScript
activation deliberately bypasses Lua, because Lua can intercept activation and
does so with a one-frame delay, and MWScript may misbehave with a delay.

CAKE's worn state is activation-driven (§3.4). If any accessory record — or any
record inherited from an external mod whose paths are preserved verbatim
(§3.5) — carries an MWScript, activation never reaches the handler and the item
does nothing when used. This presents identically to the original CAKE path bug:
"the item does nothing when selected."

Add to the generator's invariant set: **assert no accessory record has a
non-nil `mwscript` field.** That is a generation-time check, per §4.3, and it is
one line.

## 3.7 `onInactive` runs with a stale `nearby`

ptmikheev, **2022-05-05**, two rules:

1. `onInactive` fires only if the object left the scene but still exists. If it
   is removed outright, the script goes with it and never handles `onInactive`.
2. During `onInactive` the object is already out of the active cell, and
   `nearby` will not return correct results.

Consequence for §1.5's subscribe-only-while-active: `onInactive` is a valid place
to release a subscription and remove your own VFX, and **not** a valid place to
do anything that inspects surroundings. Any cleanup that walks `nearby` to decide
what to remove must instead remove from state you already hold. And any cleanup
that must happen on deletion cannot live in `onInactive` at all.

## 3.8 Local scripts get a **read-only** `globalSection`

Repeatedly hit and never clearly documented: greatness7, 2024-05-25, on
discovering he could not write storage from an object script; urm confirming you
cannot get a writable reference. Cod3x 0.4 encodes this properly at the type
level — `StorageAll.globalSection` returns `StorageSection`, `StorageGlobal.globalSection`
returns `MutableStorageSection`. Only `set`/`reset`/`setLifeTime`/`removeOnExit`
live on the mutable one.

This validates §1.9's routing chain and supplies the missing reason for it. It
also surfaces a simpler alternative that §1.9 does not mention — urm, 2024-01-23,
to someone in exactly this position:

> Move `registerGroup` into a global script and use the `globalSection` in your
> local script.

That is: **if a setting will ever be read by a non-player script, register it as
a global setting in the first place**, and skip the
`MENU → PLAYER → GLOBAL → NPC` push entirely. The four-hop chain is only
required for settings that must live in `playerSection` (per-character state).
For a mod-wide toggle like "show accessories on NPCs", a global section is
correct and the chain is over-engineering — which §5 of `RESEARCH.md` would
otherwise not catch, because the chain works.

Note the ordering hazard either way: `Trying to access inactive storage` is a
real startup error (johnnyhostile, 2024-10-19), so §1.9's "absent config must
read as enabled" default remains necessary.

## 3.9 Cross-context events cost a frame, and they queue

s3kshun.8, across 2025: global events go into a queue processed on the next
frame; a global event followed by a `teleport` is two delays stacked; a global
event that stops a sound stops it a frame after the object is gone.

Add to §1.3 as a property of rung 1: **engine events are free, but cross-context
events are not synchronous.** Anything that reads state immediately after sending
an event reads the old state. In this suite that matters for the
`PLAYER → GLOBAL → NPC` push (§1.9) — the NPC does not see the new value on the
frame the player script wrote it — and for any equip-then-refresh sequence, which
is a second reason the §1.8 deferred refresh exists.

## 3.10 `onInit` and `onLoad` are mutually exclusive, by design

§3.6 says "registration must be idempotent, `onInit` and `onLoad` both call it
and only one runs on a given start". ptmikheev, 2022-01-27, gives the exact
semantics: `onInit` is script initialisation, `onLoad` is restoring prior state,
and `onLoad` fires only if the script already existed when the game was saved. He
explicitly declined to fire `onLoad` for new scripts as inconsistent, and posted
the canonical workaround — assign the same function to both.

Two additions to §3.6:

- `onSave` fires on **actual game save**, not on cell deactivation. urm believed
  otherwise in 2022 and ptmikheev corrected it: they do not currently run on
  deactivation, though multiplayer will need that later. So do not use
  `onSave` as a "going away" hook.
- Objects saved in `onSave` may be invalid on `onLoad` if their cell is not
  loaded (ptmikheev, 2021-09-26). Anything §1.10-ish that caches an object handle
  across a save must re-validate with `isValid()`, which is already the rule for
  `SharedRay`'s `hitObject` and should be generalised.
- Returning `nil` from `onSave` clears the stored data.
- Timers do not survive a load. `runRepeatedly` and friends must be restarted in
  `onLoad` (ptmikheev, 2021-11-05) — which matters for §1.4's 1 s backstop poll
  and §1.8's deferred refresh.

## 3.11 Dynamic records and saves — a caution, not a rule

zackhasacat, 2023-05-31: creating a misc record, saving and reloading produced
`Try to override existing record: Generated:0x1e` for a record that did not
exist; creating it a second time succeeded. ptmikheev's response was that
corrupting saves is serious and needs a fast fix, and the corpus does not record
the resolution.

s3kshun.8's practice (2024-03-18) is to avoid dynamic records almost entirely.
zackhasacat's rule for when you do use them (2024-06-24): the record itself is
saved automatically, but **the generated id is not** — capture the id returned by
`createRecord` and persist it yourself.

CAKE creates `_eq` records. This is old and probably fixed, but the failure mode
is save corruption, so: **test create → save → reload → create again on the
target build**, and make the generated-id persistence explicit rather than
assuming the record can be re-derived.

---

# Part 4 — Cod3x 0.4 cross-check

## 4.1 Verdicts

| Claim in the corpus | Cod3x 0.4 | Verdict |
|---|---|---|
| `BLEND_MASK` is a bitmask 1/2/4/8, UpperBody 14 | matches, incl. `All = 15` | **confirmed** |
| `BONE_GROUP` is 0–3 | matches | **confirmed; `RESEARCH.md` is wrong** |
| `PRIORITY.Scripted` pauses all non-Scripted | matches, verbatim | **confirmed** |
| animation option keys are camelCase | matches | **confirmed** |
| `types.Actor.equipment` → `getEquipment` | only `getEquipment` present | **confirmed; rename landed** |
| `setEquipment` usable in global scripts | typed `SelfObject`, "local scripts, only on self" | **not landed — corpus speculation** |
| `playBlended`/`cancel`/`addVfx`/`removeVfx` self-only | matches | **confirmed** |
| `hasBone` needs self | typed `openmw.Object` | **corpus over-restricts; any object is fine** |
| local scripts get read-only `globalSection` | encoded in the type split | **confirmed** |
| `onFrame` is player-only | not modelled | **unresolved — see §1.5** |
| `createRecord` double-prefixes `model` | not stated either way | **unresolved — test it** |
| `types` available in menu scripts | removed in 0.4; menu excluded | **corpus is stale** |

## 4.2 What Cod3x does not cover

Worth knowing, because these are the gaps `ctxcheck.py` and `api_sweep.py`
cannot close for you:

- **Engine handlers are not modelled.** `onFrame`, `onUpdate`, `onActive`,
  `onInactive`, `onSave`, `onLoad`, `onInterfaceOverride`, `onActivated` — none
  appear in the availability tables. An `onFrame` handler in a global script
  will not be flagged. `FLOW`'s `mwSelf`-as-undeclared-global class of bug is
  caught by `globalcheck.py`; a handler in the wrong context is caught by
  nothing you currently run.
- **Receiver-context rules live in prose, not types.** The plugin's own TODO
  names this: `Cell:getAll`, `Inventory:resolve` and "local `self` restrictions
  for nested members such as `core.sound.playSound3d`" are unenforced. So is
  every "can only be used on self" note in `animation.lua` — LuaLS will type-check
  the `SelfObject` parameter, but only if you actually pass `self` rather than a
  variable it has inferred as `Object`.
- **Options tables are `table`, not shaped types.** `playBlended`'s options are
  documented in a prose blob on one `@param` line. Nothing type-checks
  `startkey` vs `startKey`. This is §3.1's bug, and it is the strongest argument
  for a project-local shaped alias:

  ```lua
  ---@class omw.PlayBlendedOptions
  ---@field priority? table<integer, integer>|integer
  ---@field blendMask? integer
  ---@field autoDisable? boolean
  ---@field startKey? string
  ---@field stopKey? string
  ---@field startPoint? number
  ---@field speed? number
  ---@field loops? integer
  ---@field forceLoop? boolean
  ```

  Declared once in the suite and used at every call site, this turns the single
  most common silent animation failure into a diagnostic. It is worth writing
  even though it duplicates Cod3x, and it is a candidate to contribute upstream.
- **No `@deprecated` markers.** The changelog mentions adding "missing
  (deprecated) Actor and Container functions", but nothing in the stubs
  distinguishes them, so `api_sweep.py` cannot tell a live API from a
  compatibility shim.

---

# Part 5 — What the corpus does not know: the 0.50 → 0.52 surface

The corpus ends at 0.50. Everything below is in Cod3x 0.4 and appears in the
0.52 changelog, and several items directly obsolete workarounds the corpus
recommends.

## 5.1 `addVfx` gained `transform`, `autoTransform` and `useAmbientLight`

The largest single win for CAKE and IED.

| Option | Effect |
|---|---|
| `transform` | a `util.Transform` applied relative to the bone |
| `autoTransform` | if true (default) the engine computes a transform; `transform` applies on top |
| `useAmbientLight` | Morrowind attaches a white ambient light to VFX; set false to suppress |

What this replaces: the corpus's entire approach to positioning an attachment
was to edit the NIF — sjek, 2024-02-26, describes copying a `NiTriShape` into a
VFX's `NiBSAnimationNode` and setting keyframe data to constants to get a model
to sit on a bone. That whole technique is now an option table entry.

Concretely, for this suite:

- Per-record positional tweaks (a scarf sitting slightly wrong on a beast-race
  neck, a weapon offset on `Weapon Bone left`) become **data in the registry**
  rather than a re-export through `BizarreMorrowindAnimatonUtilities`.
- `useAmbientLight = false` is almost certainly correct for cosmetic
  attachments. The default white ambient light is a magic-effect convention; a
  worn scarf lit by it will not match the body it sits on. Worth testing across
  interiors and night exteriors before deciding.
- It weakens §3.1's "worn model ≠ ground model" requirement only slightly — the
  interactability problem is unchanged — but it removes one of the reasons a
  separate `_eq` mesh was needed.

## 5.2 `world.vfx.remove` exists, with a footgun

`VFX.spawn` now takes `loop` and `vfxId`; `VFX.remove(vfxId)` removes all VFX
with that id. Both are best invoked through the `SpawnVfx` / `RemoveVfx` global
events.

The footgun, from the stub text: passing an **empty string** removes every VFX
that has no `vfxId` — *including non-scripted ones*. That is the engine's own
effects. `RESEARCH.md` §3.2 already says to namespace `vfxId` to avoid colliding
with `core.MagicEffectId`; extend it: **never call `remove('')`, and never let a
variable that could be `nil`-coerced-to-`''` reach it.** An id-derivation bug
(§3.4's string surgery) that produces an empty string now has a blast radius.

## 5.3 Other 0.52 additions relevant here

- `camera.getFocusRay` — a first-class replacement for hand-rolled
  camera-position-and-direction raycasts. Directly relevant to `SharedRay` and
  Hookshot Redux; check whether it subsumes part of the shared library.
- `world.getObjectsInRange`, `world.getObjectsByRecordId` — engine-side lookups
  replacing Lua `getAll` loops. Exactly the §1.10 "cheap wins" pattern, one level
  further down.
- `object.saveState` / gameobject persistence — relevant to §3.10's
  re-validation rule.
- `animation.getTextKeyTime(actor, text)` — read the absolute time of a text key
  without parsing the KF. §3.2's "read the keys out of the binary" advice stands
  for *discovering* key names; this covers *timing* against them at runtime.
- Spell, enchantment and ingredient record creation; region record functions;
  moon phases; `Weather.getCurrentMoons`; werewolf attribute values; knockdown
  and hit-recovery accessors; `MouseWheelEvent`; `getElements`.
- Magic effect records are **string-keyed** now, and `MagicEffectId` is a string.
  Any surviving numeric effect id in this suite is a latent bug. Several corpus
  snippets pass `id = 40`; those are dead.

---

# Part 6 — Additions to Part 4 of `RESEARCH.md` (verification)

Three things the corpus uses routinely that the current tooling list does not
mention.

## 6.1 The Lua console

`~` to open, then `luap` for a player-context Lua prompt (`luag` global,
`luas` on the selected object), then `view(x)` to dump a table. ptmikheev's own
suggested route for "what are the equipment slot numbers" (2023-05-08) is
`view(types.Actor.EQUIPMENT_SLOT)`.

This is the fastest way to answer "does this bone exist on this actor" —
`luas` on the actor, `animation.hasBone(self, 'Weapon Bone left')` — without a
build-test cycle. It belongs next to `luarun.py` in Part 4, and it is the one
verification route that runs against the *actual engine* rather than the stubs
or a mock.

`reloadlua` in the console reloads scripts in place. Note the caveat maxyari
found (2025-04-13): a script attached by another script at runtime can end up in
a confused state after a main-menu round trip, and `reloadlua` fixes it — so a
bug that only appears after leaving the main menu, and vanishes on `reloadlua`,
is an attachment-lifecycle bug and not the thing you were testing.

## 6.2 The F10 profiler

Built-in Lua profiler, on by default, disabled with `lua profiler = false` in
`settings.cfg`. It reports an **estimated instruction count** per script rather
than measured frame time (urm, 2024-04-28), which is exactly the metric
Fashionwind's bug report is quoted in (§1.1) — the "1k ops/s" figure is this
tool's output.

That makes §1.1's numbers reproducible rather than anecdotal. **Before and after
any change that touches a handler in §1.3's ladder, record the F10 number.** It
is the only measurement in this suite that is comparable to the one field report
it has.

Related settings worth knowing: the Lua memory limit and the instruction limit
per call are both configurable in `settings.cfg`, and exceeding the latter
produces `Lua instruction count exceeded, probably an infinite loop in a script`
— which is a real error users hit with shipped mods, not just a debug artefact.

## 6.3 Grep the log for silent failures

Three engine messages that indicate a bug in a mod that otherwise appears to
work:

| Log string | Means |
|---|---|
| `missing bone <name>` | an attach targeted a bone the skeleton lacks (§1.3) |
| `Trying to access inactive storage` | storage touched before its section is live (§3.8) |
| `Try to override existing record` | dynamic-record id collision after reload (§3.11) |

A shipping check that loads a save, toggles the camera three times, and greps
the log for these is cheap and catches things `luacheck` cannot.

---

# Part 7 — Open questions

Things the corpus raises that neither `RESEARCH.md` nor Cod3x settles. Each is a
candidate for a session.

1. **Does `createRecord` still prefix `meshes\`?** (§3.4) Test the round trip.
   The answer changes how CAKE's `_eq` generator must be written, in opposite
   directions.
2. **Is `onFrame` available in local and menu scripts?** (§1.5) One test each,
   and then §1.2's table can be stated rather than hedged.
3. **Does `record.model` use forward or back slashes on 0.52?** The 2023 engine
   source says `"meshes\\"`; §2.2 of `RESEARCH.md` records `meshes/rv/ashmask1.nif`.
   Both cannot be right on the same build. The mock's `addVfx` assertion (§4.1)
   currently rejects backslashes — if the engine emits them, the mock is wrong
   in the direction that hides bugs.
4. **Does `addVfx`'s `transform` compose with a bone that is itself animated?**
   If it does, per-record offsets are free. If it fights the animation, they are
   not, and the NIF-editing route stays.
5. **Do the 0.52 knockdown / hit-recovery accessors give WhyWalk a cleaner
   dismount edge** than the current approach?
6. **Does `camera.getFocusRay` subsume `SharedRay`'s player-ray path?** If so,
   the shared library shrinks and one class of `isValid()` guard moves into the
   engine.

---

# Appendix A — Reproducing the index

The corpus ships as ~108 JSON pages of Discord message objects, with overlap
between pages. To get a stable chronological index for citation:

```python
import json, glob, pickle

msgs = []
for f in sorted(glob.glob('lua-scripting_*/*.json')):
    for m in json.load(open(f)):
        msgs.append({
            'id':      m.get('id'),
            'ts':      m.get('timestamp', ''),
            'user':    (m.get('author') or {}).get('username') or m.get('userName') or '?',
            'content': m.get('content') or '',
        })

seen = {m['id']: m for m in msgs}                       # pages overlap
msgs = sorted(seen.values(), key=lambda x: x['ts'])     # 103,899 unique
pickle.dump(msgs, open('msgs.pkl', 'wb'))
```

Index positions in that list are stable as long as the zip is. They are *not*
Discord ids and cannot be linked; the dates and authors in this document are the
portable citation.

Searching it: a regex over `content`, optionally filtered by `user`, with a few
messages of context either side. Nearly every finding above came from reading
the twenty messages around a hit rather than the hit itself — the answer to a
question is usually three messages later and from a different person, and the
correction is usually the message after that.

High-signal authors, by rough authority: `ptmikheev`, `urm`, `assumeru`,
`akortunov` (engine and Lua core); `.foll` (the animation API — read everything
they wrote about priorities); `zackhasacat` (bindings, and the most reliable
reporter of engine bugs); `s3kshun.8` (Cod3x's author; opinionated and usually
right about current behaviour); `greatness7` (tooling and file formats);
`maxyari` (FLOW/AMF — the animation threads with `.foll` are the densest
material in the corpus).
