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
  shared.lua   -- data only: ids, groups, keys, priorities, masks, tuning
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
| `luacheck.py` (liblua5.4 parser) | 5 files, 0 failed |
| `globalcheck.py` | 0 undeclared global reads |
| `api_sweep.py` vs Cod3x stubs | nothing unrecognised |
| pcall audit | 0 in code |
| Event send/handle symmetry | 13 events, 0 orphans |
| `S.` / `T.` reference resolution | 0 unresolved |

Not verified: in-game behaviour. Static analysis cannot confirm that
`activeSpells:add` accepts an Ability-type record for the hold spell, nor that
`onPlayerAdded` fires in your build — both are worth watching on first run.
