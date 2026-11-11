# ForceChoke

A telekinetic choke-and-throw spell for OpenMW **0.52+**. No framework dependency.

Cast it at an NPC and they are lifted, paralyzed, and held. Sheathe the spell
and they collapse, winded. Cast it again and they are hurled away.

## Requirements

- **OpenMW 0.52+** — required, not optional: records are declared through
  `openmw.content` in a `LOAD:` script, which older builds do not have.
- `use additional anim sources = true` under `[Game]` in `settings.cfg`,
  or nothing in `animations/` is loaded.
- **SharedRay** is bundled and version-guarded.

## Controls

Cast Force Choke like any spell. It binds no keys and intercepts none.

| Input | Effect |
|---|---|
| Cast at an NPC | Grab |
| Cast again while holding | Throw |
| Sheathe spell | Release |

Console: `luap` then `forcechoke_give` grants the spell.

## Changes in this revision

### Load cleanup errored on every disabled actor

In-game log, on loading a save:

```
L@0x18ce[scripts/forcechoke/target.lua] onLoad failed: Lua error: Can't use a disabled object
L@0x18fc[scripts/forcechoke/target.lua] onLoad failed: Lua error: Object has no animation
```

`onLoad` cancelled all four choke groups to clear a pose stranded by a
mid-choke save. `onLoad` runs for every NPC and creature carrying the script,
so it ran on disabled actors and actors not yet in the scene, and the engine
refused both. It also meant four cancels on every actor in the save to fix a
case that applies to at most one.

Now:
- `onSave` returns the playing group, and only when one is playing.
- `onLoad` just notes it.
- `onActive` issues the cancel once the actor is in the scene. A disabled
  actor gets it when enabled.

Every other actor does nothing.

`tools/test_target.lua` drives the real save/load path against a mock whose
`animation.cancel` raises the engine's two errors. The previous revision fails
7 of 10 checks, reproducing both log lines. This one passes all 10.

### The global script never started

In-game log:

```
Can't start Global[scripts/forcechoke/global.lua]; Lua error: module not found: openmw.animation
```

`global.lua` requires `shared.lua`, and `shared.lua` required
`openmw.animation` to build its priority and blend-mask tables. That module
exists only in local and player scripts. The state machine, paralysis,
teleports and throw were therefore all dead. Casting did nothing beyond the
player's own pose.

`shared.lua` was annotated `---@omw-context any`. `any` is not a Cod3x
context, so the context checker had nothing to compare against, and the
static checks in the table below all passed on a mod that could not start.

Fixed by splitting along the context boundary:

- `shared.lua` is now `---@omw-context none` with no requires: ids, groups,
  text keys, tuning. Legal in every context that loads it.
- `poses.lua` (new, `---@omw-context local | player`) holds everything built
  from `openmw.animation`: `FULLBODY_/UPPERBODY_PRIORITY`,
  `*_BLEND_MASK`, `targetPoseOptions`, `playerPoseOptions`. Moved verbatim.
  Only `player.lua` and `target.lua` require it.

Verified by loading each entry point under a sandbox whose `require` mirrors
the engine's per-context module list. Before the split, `global.lua` fails
with the same error as the log. After it, all three entry points start.

### Records are declared, not generated

`load.lua` declares the magic effect and both spells through `openmw.content`,
following the Ablution Intervention template. Records get **fixed ids**, so
nothing has to discover them at runtime. Deleted: `makeSpell`,
`ensureRecords`, the cached ids in save state, and the entire
`ForceChoke_SpellId` handshake that existed only to tell `player.lua` what id
the record happened to get.

This also makes the custom effect real. Previous revisions documented
`forcechoke` as a marker effect that only worked if the user supplied their
own `.omwaddon`, because `createRecordDraft` can create spells but not magic
effects. `content.magicEffects` can. Spellmaker variants now work out of the
box, and effect-id matching is safe because the effect is dedicated — matching
raw `paralyze` would have fired on every paralyze spell in the game.

### Every pcall removed

26 of them, across three files. The `animation.cancel` guards were the load
bearing ones, and they were guarding against a function that **exists** —
`animation.cancel(actor, groupName)`, confirmed in the API stubs. With that
established, the whole "reissue the group at `PRIORITY.Default` and let it
expire" release dance is gone too, replaced by a direct cancel.

Where a failure genuinely is a supported state, it is now **checked** rather
than caught: `anim.hasGroup` before playing a pose, `:isValid()` before
touching an object. The two remaining mentions of `pcall` in the tree are in a
comment explaining why it was removed.

### Text keys were wrong

`startKey`/`stopKey` are now `"start"`/`"stop"` for every group, not
`"loop start"`/`"loop stop"`.

Those keys delimit the whole segment the engine plays; the loop points are
found by the engine from the clip's own loop keys once `loops` is non-zero.
Passing the loop keys as segment bounds meant the intro and outro frames were
never played, and a group asked to stop at `"loop stop"` was cut at the loop
boundary instead of the clip's real end. It looked correct in play — the pose
appeared — which is exactly why it survived several revisions.

The per-group `STOP_KEY` table is gone with it. It existed to special-case
`fchokedrop`, which in an older asset build genuinely lacked a `Stop` key.
The current asset has it.

### The facing fallback was wrong

When the player stands exactly on top of the target, the throw direction fell
back to `util.vector3(math.cos(yaw), math.sin(yaw), 0)`. Wrong twice over:
OpenMW's yaw is a compass bearing (0 = +Y), so the components are swapped, and
the sign convention is not the trig one either. Now
`player.rotation * util.vector3(0, 1, 0)` — asking the engine for its own
forward vector, which cannot drift from it.

### Death mid-flight stranded global state

`target.lua` cleared locally and told nobody, leaving `global.lua` in
`active + thrown` with no landing ever arriving. It now reports
`ForceChoke_Landed` with `died = true`, and `global.lua` skips the landing
damage but still clears. (It was self-healing — the next cast reset it — but
only by accident.)

### Bone group enums

Priority tables key off `anim.BONE_GROUP.*` symbols, never numeric literals.
The stubs annotate these 1–4 while the corpus records them as 0–3; using the
symbols makes the code correct under either.

## Files

```
ForceChoke.omwscripts
scripts/forcechoke/
  load.lua     -- LOAD: declares effect + spell records (fixed ids)
  shared.lua   -- data only, any context: ids, groups, keys, tuning
  poses.lua    -- actor-only: priorities, blend masks, pose options
  global.lua   -- state machine, paralysis, teleports, stat writes
  player.lua   -- cast detection, targeting, player pose, messages, console
  target.lua   -- NPC pose + throw integration
scripts/SharedRay/SharedRay_v2.lua
animations/xbase_anim{,_female,kna}/
```

## v4 — post-test-run fixes (2026-11-10)

Three fixes from the in-game run (`forcechoke-fixes.patch`), plus five more
found while assessing it. Both are folded into this build;
`forcechoke-further-fixes.patch` holds the second set alone.

### From the test run
- **School.** The filter named the wrong school, so no cast ever reached the
  mod. It is now read off the effect record, not named — see below.
- **Targeting.** `SharedRay.get()` is clipped to activation distance and the
  ray is only fired that far. Now `requestDistance(maxReach)` at init plus
  `getUnclipped()`.
- **Stat writes.** 0.52 forbids a global script writing another actor's
  stats; the raise also took the state machine down mid-transition. Amounts
  are now sent to `target.lua` as `ForceChoke_Damage`.

### Found while assessing the patch
- **`autoDisable` must track `looping`.** It was `false` for both held loops
  and one-shots. The one-shot `fchokedrop` therefore sat in the active list
  at `PRIORITY.Scripted` forever, and Scripted pauses every other animation
  on that actor — which is why released NPCs never got up. Now `not looping`.
- **Four of six keyed animation files were the stale build.**
  `xForcechoke.kf` and `xForceEffect.kf` are byte-identical to each other and
  both predate the `fchokedrop: Stop` fix (25 keys, not 26), as do
  `Forcechoke.nif` and `ForceEffect.nif`. All three `.kf` define the same five
  groups, so which `fchokedrop` won was load-order dependent — a second,
  independent cause of the stranded drop pose. Only `xForce.kf`/`Force.nif`
  are kept; the package drops from 2.8 MB to 1.0 MB.
- **Throw physics are now per-second.** Velocity, drag and gravity were
  applied per integration step. A naive `dt` multiply would still have been
  wrong, because `onUpdate` returns early while a teleport round-trip is in
  flight and those frames' `dt` was dropped; time is now banked across the
  wait and the step clamped to `throwMaxStep`.
- **`CREATURE` dropped from the manifest.** `global.lua` filters targets with
  `types.NPC.objectIsInstance`, so creature instances could never do anything.
- **School read, not named.** `core.magic.effects.records[EFFECT_ID].school`.
  The constant was wrong twice; the engine already holds the answer, and
  reading it also tracks the `load.lua` template.

### target.lua is now attached on demand

`target.lua` is declared `CUSTOM` and attached by `global.lua` on grab, then
removed once the actor has finished with its pose. It exists only on actors
actually being choked — usually none, at most one — instead of on every NPC
and creature in the cell, each carrying a per-frame `onUpdate`.

`CUSTOM` is required rather than tidier: `addScript` refuses a path not
declared with that flag, and `removeScript` cannot remove an auto-started
script, so an `NPC:` line would attach fine and then never detach.

Two ordering traps, both closed:

- **The grab travels as `initData`, not as an event.** A `sendEvent` issued in
  the same frame as `addScript` is delivered before the new script runs its
  `onInit`, so the grab would be lost. Only an actor already carrying the
  script (a re-grab before its last detach landed) takes the event path.
- **The detach is requested by `target.lua`, not decided by `global.lua`.**
  Releasing an actor deliberately leaves `fchokedrop` running. Removing the
  script at that moment would strand the pose with nothing left able to cancel
  it — the exact failure `autoDisable` just closed. `target.lua` instead waits
  out its own clip (`anim.isPlaying`, with a grace window because the group is
  not playing for a frame or two after the call, and a timeout so a script can
  never be stuck on) and then sends `ForceChoke_Detach`.

`land()` sends `ForceChoke_Landed` *before* starting the settle, because
`global.lua` answers it with the damage event, which the script must still be
attached to receive.

A script attached when the game was saved survives into the save while
`global.lua`'s state does not, so `onActive` sheds it after undoing the
stranded pose — otherwise every actor ever choked would carry it for the rest
of the playthrough.

### First-person pose added

`animations/xbase_anim.1st/` now carries the same clip, so the grip pose shows
in first person.

### Still open
- **Throw constants need re-tuning in game.** They are the old per-step
  values scaled by 30, which should land near the old 60-70 fps feel, but the
  number was not measured.

## Verification


Checked with the project toolchain before delivery:

| Check | Result |
|---|---|
| `luacheck.py` (liblua5.4 parser) | 6 files, 0 failed |
| Per-context load simulation | global, player, local entry points all start |
| `tools/test_target.lua` (save/load) | 10/10 |
| `tools/test_detach.lua` (attach/settle/detach) | 18/18 |
| `ctxcheck.py` vs Cod3x 0.4 policy | 7 files, 0 issues (was: `shared.lua` INVALID-TOKEN `any`) |
| `globalcheck.py` | 0 undeclared global reads |
| `api_sweep.py` vs Cod3x stubs | nothing unrecognised |
| pcall audit | 0 in code |
| Event send/handle symmetry | 14 events, 0 orphans |
| `S.` / `T.` / `P.` reference resolution | 0 unresolved (caught `T.throwMagnitude` left dangling by the retune) |
| Animation text keys vs controller groups | all 5 groups, 26 keys, no stale build |

The two open questions from v3 are answered by the test run: `activeSpells:add`
does accept the Ability record and the hold stayed at one instance across
refreshes; `onPlayerAdded` does fire and the spell was granted.

Not verified in this pass: in-game behaviour of the v4 fixes. The throw
constants in particular are a conversion, not a measurement.
