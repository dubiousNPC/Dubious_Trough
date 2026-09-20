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

## Verification

Checked with the project toolchain before delivery:

| Check | Result |
|---|---|
| `luacheck.py` (liblua5.4 parser) | 6 files, 0 failed |
| Per-context load simulation | global, player, local entry points all start |
| `tools/test_target.lua` (save/load) | 10/10 |
| `ctxcheck.py` vs Cod3x 0.4 policy | 7 files, 0 issues (was: `shared.lua` INVALID-TOKEN `any`) |
| `globalcheck.py` | 0 undeclared global reads |
| `api_sweep.py` vs Cod3x stubs | nothing unrecognised |
| pcall audit | 0 in code |
| Event send/handle symmetry | 13 events, 0 orphans |
| `S.` / `T.` reference resolution | 0 unresolved |

Not verified: in-game behaviour. Static analysis cannot confirm that
`activeSpells:add` accepts an Ability-type record for the hold spell, nor that
`onPlayerAdded` fires in your build — both are worth watching on first run.
