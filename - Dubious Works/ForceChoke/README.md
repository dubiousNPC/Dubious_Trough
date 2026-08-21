# ForceChoke

A telekinetic choke-and-throw spell for OpenMW 0.51+. No framework dependency.

Cast it at an NPC and they are lifted, paralyzed, and held in a looping choke
pose. From there you either sheathe the spell — they collapse, winded — or you
cast it again to squeeze and throw, flinging them away and putting them down
considerably harder.

## Requirements

- **OpenMW 0.51+**. Nothing else.
- **SharedRay** is bundled and version-guarded, so if another mod ships a newer
  copy only that one runs.

Spell Framework Plus is no longer required, and neither is OSSC.

## Controls

ForceChoke binds no new keys and, as of this revision, **intercepts none either**.

| Input | Effect |
|---|---|
| Cast Force Choke at an NPC | Grab. |
| Cast it again while holding | Squeeze and throw. |
| **Sheathe spell** (`ToggleSpell`) | Release. |

Force Choke is cast like any other spell — ready it, aim, cast. Because a
readied spell makes the attack key the cast key, the controls are what the
original design asked for; they are simply no longer hijacked.

## Sequence

1. **Cast.** The engine resolves the cast normally: magicka spent, success
   rolled, cast animation and VFX played, Alteration trained.
2. **Grab.** On success, the crosshair target is read and the hold begins.
   Target plays `fchokeidle` looping, full-body at `PRIORITY.Scripted`,
   paralyzed and refreshed once per second. Player plays `fchoke1` looping,
   upper-body only, so you can still walk.
3a. **Release** — target plays `fchokedrop`, takes fatigue damage.
3b. **Throw** — a second successful cast flings the target away, playing
   `fchokefly` in flight; on landing it plays `fchokedrop` and takes the
   heavier fatigue damage **plus** health damage.

A failed cast never reaches the mod at all: the engine plays its own failure
sound and the grip simply holds, which is the intended "grip slips" outcome.

## Files

```
ForceChoke.omwscripts
scripts/SharedRay/SharedRay_v2.lua   -- bundled, version-guarded
scripts/forcechoke/
  shared.lua   -- data only: groups, text keys, priorities, masks, tuning
  global.lua   -- state machine, records, teleports, stat writes
  player.lua   -- cast detection, target acquisition, player pose, messages
  target.lua   -- NPC pose + throw integration
xbase_anim/    -- animation assets
```

## Changes in this revision

### Messages were being silently discarded

`notify()` in `global.lua` sent `Ui_ShowMessage`. That was never an OpenMW
event — it is an **SF+ internal convention**, handled in `magexp_player.lua`.
When the SF+ dependency was dropped nothing was left listening, so every
message the mod produced went nowhere. Messages now go through
`ForceChoke_Notify` to `ui.showMessage` in `player.lua`, which is where `ui`
actually exists.

### Casting is detected, not intercepted

The previous revision bound the attack key and then re-implemented Morrowind's
cast formula in `global.lua` — charging magicka by hand and rolling
`(2*skill - cost + 0.2*willpower + 0.1*luck) * fatigueTerm`. All of that is
gone. `player.lua` now hooks `I.SkillProgression.addSkillUsedHandler`, which
fires only on a **successful** cast, so the engine handles magicka, the real
roll, the cast animation, the VFX, and skill progression.

That old formula also hardcoded **Mysticism**. Force Choke is built on vanilla
paralyze, which is **Alteration** — it was reading the wrong skill entirely.
The school is now derived from the effect record rather than named.

### The crosshair read is deferred

The ray is read on a 0.05s timer rather than inline. Two independent reasons,
both of which the reference mods hit: camera/viewport state has not settled at
the instant the skill-used handler runs (Banishing literally names its variable
`viewportBugfixDelay`), and SharedRay's cast is async so an inline read returns
what was under the crosshair *before* the cast.

### Telekinesis now extends reach

Reach is `iMaxActivateDist + thirdPersonDistance + (telekinesis.magnitude * 22)`,
matching vanilla activation rules, with `castRange` as a floor rather than a
flat constant. `global.lua` accepts the player script's reported reach as an
upper bound but clamps it to `maxReach`, so a stale or forged payload cannot
grant unlimited range.

### Spellmaker support, if you supply a plugin

If an `.omwaddon` in the load order defines the magic effect named by
`MARKER_EFFECT` (`"forcechoke"`), matching switches from record-id to
effect-id and **any** spell containing that effect works — including ones the
player builds at a spellmaker. This is how NiftySpellPack and the TR spell
packs do it. **This mod does not ship that plugin**: `createRecordDraft` can
create spells but not magic effects, so a plugin is the only way. Without it,
matching falls back to the single runtime-generated record.

Matching never falls back to the raw `paralyze` effect id, which would fire on
every paralyze spell in the game.

## Animation assets

Group names and text keys are read from the shipped `xForce.kf` and
`Force.nif`, not assumed. Both files agree, and all five groups the
controllers use are present and complete:

| Group | Start | Loop Start | Loop Stop | Stop | Used by |
|---|---|---|---|---|---|
| `fchokeidle` | ✓ | ✓ | ✓ | ✓ | target, hold |
| `fchokefly` | ✓ | ✓ | ✓ | ✓ | target, in flight |
| `fchokedrop` | ✓ | ✓ | ✓ | ✓ | target, collapse |
| `fchoke1` | ✓ | ✓ | ✓ | ✓ | player, hold |
| `fchokeend` | ✓ | — | — | ✓ | unused |

Also present and unused: `fchokel`, `fchoker`, `fchokerfwd`, `fchokertwd`
(Start/Stop only) — directional lean variants, available if the hold is ever
made to track the target's bearing.

**`fchokedrop: Stop` now exists.** The previously bundled `xForce.kf` was the
one group in the file missing it, which is why earlier revisions stopped
`fchokedrop` at `"loop stop"`. The current asset adds the key (25 → 26 keys,
+24 bytes) and `shared.lua` now stops it at `"stop"`, so the clip runs to its
real end and settles on the final collapsed frame instead of being cut at the
loop boundary. `STOP_KEY` remains a per-group table so a future asset change
stays a one-line edit.

The KF drives the **full** `Bip01` skeleton — pelvis, both leg chains, spine,
neck, head and both clavicle chains — so the full-body mask on target poses and
the upper-body mask on the player pose are both valid against the actual data.

## Design notes

**Target poses are uniformly `PRIORITY.Scripted`.** `Scripted` pauses all
non-Scripted animation on that actor globally — exactly what "held, paralyzed"
wants. Because *all four* bone groups get the same priority, this is not the
mixed-priority bug (Scripted on one bone group, Weapon on another) that
silently freezes an actor's other animations.

**The player pose omits `LowerBody`** from both mask and priority table, so
locomotion stays under normal engine control.

**Target animation lives in a local script.** `playBlended` takes a
`SelfObject`; a global script cannot pose another actor. Movement round-trips
back through global because `teleport()` is global-only — local computes
`nextPos` → global teleports → global pings local for the next step.

**`skipSkillUse`** guards against re-entering the skill-used handler, the same
pattern Utility Spells uses.

**`onUpdate` is throttled or inert.** `global.lua` gates hold maintenance to
once per second. `target.lua` early-returns on a single boolean unless that
actor is mid-throw. The throw has a hard `throwMaxSeconds` cap so an actor
wedged in geometry always lands rather than hanging paralyzed in the air.

Tuning is all in `shared.lua`'s `TUNING` table.
