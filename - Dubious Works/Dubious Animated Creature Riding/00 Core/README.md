# AnimatedCreatureRiding

A rider animation layer for OpenMW 0.51+.

It gives your character a proper riding pose on top of a riding mod you already
use. It does **not** move you, steer the mount, or handle mounting — that stays
with whatever riding mod you have installed. This is the animation only.

**Requires OpenMW 0.51 or newer, and a riding backend** (Devilish Horse Riding,
Devilish Guar Riding, Sturdy Steed, or similar).

> ### Which mod do I want?
>
> **AnimatedCreatureRiding** — you already have a riding mod you like and just
> want better rider animation across more creature types. Layers on top.
>
> **WhyWalk** — you want the whole thing: mounting, steering, placement *and*
> animation, in one mod. WhyWalk already contains an equivalent animation
> controller.
>
> **Do not install both.** Pick one.

---

## Contents

- [What it does](#what-it-does)
- [How it hooks in](#how-it-hooks-in)
- [Controls](#controls)
- [Performance](#performance)
- [Mount types and animations](#mount-types-and-animations)
- [Free ride](#free-ride)
- [Camera freedom](#camera-freedom)
- [Camera offset](#camera-offset)
- [Configuration](#configuration)
- [File layout](#file-layout)
- [Compatibility](#compatibility)
- [Known limitations](#known-limitations)
- [Credits and sources](#credits-and-sources)

---

## What it does

- **One controller for every mount type.** Nine types plus a generic fallback,
  driven by data tables.
- **Lower-body and torso poses.** The lower body carries the seated pose; the
  torso stays at weapon priority so weapons and spells keep working, and the
  arms are untouched.
- **Adjustable third person camera**, so you aren't looking down at the rider's
  head from mount height.
- **Random variation.** A state's animation can be a list, picked from on entry,
  so idling on a long ride isn't identical every time.
- **Automatic classification.** Twelve known creature record IDs read out of the
  shipped riding ESPs, plus ordered pattern matching for anything else.
- **Fallback set** for creatures the mod has no resources for, so an unknown
  mount still gets a pose rather than nothing.
- **Free ride.** Mount any creature with no script added to it.
- **Recovers from interruptions.** The engine's falling animation interrupts the
  rider pose while a pinned rider counts as airborne; this re-issues the pose
  when that happens.
- **Free camera.** Switch between first and third person while mounted without
  losing the pose.

### Why it exists

The two shipped Devilish riding mods each contain a `ridingAnim.lua`. They are
**byte-identical apart from the `rideg`/`rideh` group prefix** — 270 lines each,
with a fourteen-line diff, all cosmetic. There was never two designs, just one
file copied twice with a find-and-replace.

This consolidates them into one table-driven controller, so adding a creature is
a data change rather than another copy of the file.

---

## How it hooks in

It listens for your riding mod's mount and dismount events:

```lua
local BACKEND_EVENTS = {
    mounted = {
        "DETD_HorseRiding_Mounted",
        "DETD_GuarRiding_Mounted",
        "SimpleHorseBaseRideAttach",
    },
    dismounted = {
        "DETD_HorseRiding_Dismounted",
        "DETD_GuarRiding_Dismounted",
        "SimpleHorseBaseRideDetach",
    },
}
```

**Adding a backend is a data change**, not a code change — put its event names
in that table. The handler accepts the common spellings for the mount object
(`mount`, `horse`, `guar`, `creature`, `target`) and falls back to the generic
animation set rather than refusing to animate a mount it couldn't identify.

If your riding mod fires no events at all, [free ride](#free-ride) still works,
since that path owns its own activation.

---

## Controls

| Input | Effect |
|---|---|
| **X** | Free ride: mount the creature you're looking at, or dismount a free ride |
| **W / S** | Sets the rider pose to forward / reverse |
| **Shift** | Gallop pose (held with W) |
| **Space** | Jump pose (ground mounts only) |

W, S, Shift and Space only *select the pose*. Actual movement is your riding
mod's job. X only ends rides this mod started — a backend-owned ride must be
dismounted through that backend, or the two disagree about state.

---

## Performance

**Zero per-frame handlers.** Everything is reached from a discrete event:

| Event | Handler |
|---|---|
| Mounted / dismounted | Backend event handlers |
| Movement keys | `onKeyPress` / `onKeyRelease` |
| Jump clip finishing | The clip's own `stop` text key |
| Animation interrupted | `addAnimationEndedHandler` |
| Free-ride targeting | SharedRay's cached result — no cast issued |
| Perspective change | `AnimRefresh` (`TogglePOV` trigger + 1s backstop poll) |

Reading SharedRay costs nothing: the service already casts once per frame for
whoever is listening. This mod only raises the shared ray length so mounts stay
detectable at range.

Animation-ended recovery is burst-guarded. A per-frame poll is implicitly
rate-limited by the frame rate; an ended-handler is not, so a clip that ends
immediately (bad group name, missing text keys) would replay in a tight loop.
After five restarts in a second it stops and logs a hint.

---

## Mount types and animations

| Type | Notes |
|---|---|
| `horse` | Groups verified from the shipped mod |
| `guar` | Groups verified from the shipped mod |
| `boar` | |
| `nix` | |
| `strident` | |
| `kagouti` | |
| `skyrender` | Flying: no reverse, no jump |
| `netch` | Flying: no reverse, no jump |
| `silt_strider` | |

Five rider states — idle, walk, gallop, reverse, jump. A state's value is a
group name, a list to pick from, or `false`:

```lua
[STATE.IDLE]    = { "rideb1", "rideb1_alt" },  -- random on entry
[STATE.WALK]    = "rideb2",
[STATE.REVERSE] = false,                       -- no such state on this mount
```

`false` blocks the fallback, `nil` allows it. That distinction is why a flying
mount never inherits the generic jump clip and tries to hop.

### Bone groups and priority

The rider pose is applied to the **lower body and torso**, not the torso alone:

```lua
local RIDE_PRIORITY = {
    [anim.BONE_GROUP.LowerBody] = anim.PRIORITY.Scripted,
    [anim.BONE_GROUP.Torso]     = anim.PRIORITY.Weapon,
}
local RIDE_BLEND_MASK = anim.BLEND_MASK.LowerBody + anim.BLEND_MASK.Torso
```

The lower body is what actually makes the rider look *seated* rather than
standing in mid-air, so it runs at `Scripted` priority. The torso stays at
`Weapon` priority so weapon and spell animations keep control of the upper body,
and the arms are left out of the mask entirely so arm animations play untouched.

Worth knowing if you edit these: `BLEND_MASK` is a **bitmask** (LowerBody 1,
Torso 2, LeftArm 4, RightArm 8) while `BONE_GROUP` is a plain **enum**
(LowerBody 1, Torso 2, LeftArm 3, RightArm 4). Same names, different value
spaces — the mask is summed, the priority table is keyed. They are added rather
than bitwise-or'd because OpenMW runs LuaJIT, which has no `|` operator.

### Jump and text keys

Text key handlers must bind to a fixed group name at load time, so **every jump
variant across every mount type is registered once up front**. Lazy per-play
registration cannot work — the handler has to exist before the clip's stop key
fires. Suppressed states (`false`) are excluded, so flyers cost no registrations.

### Classification

Exact record IDs beat patterns. Verified IDs from the shipped ESPs:
`ttd_horseride`, `detd_guarride1`, `ttd_boarride`, `detd_boarnoride1`,
`ttd_nixride`, `detd_nixnoride`, `ttd_stridentride`, `detd_stridentnoride1`,
`detd_skybug_riding`. Everything else falls through ordered patterns, where
`siltstrider` is tested before `strider`.

### Placeholders

Group names outside horse and guar are **placeholders**, as are the three
`placeholder_*` creature IDs and the levitation spell ID. Replace them with real
names from your `.kf`. Each group needs matching start/stop text keys or
`playBlended` silently does nothing.

---

## Free ride

Mount **any** creature, with no script added to it and no ESP edit.

No steering — the creature keeps its own AI and you ride along. Enabled by
default, range 400 units, blacklist still applies.

Note this mod animates and poses you; if your backend isn't involved, nothing
pins you to the creature. Free ride here is the animation half of the feature.

---

## Camera freedom

You can switch perspective freely while mounted.

This is worth calling out because the mods this is descended from pin you to
first person and re-assert it on a timer. That trades a bug for a worse
restriction: you can no longer look at the animation you installed the mod for.

The bug being avoided is real. Switching perspective rebuilds the player's
animation object and drops scripted animations with it, so without handling the
rider pose simply vanishes on a POV press.

`AnimRefresh` is a small bundled service that notices the change and re-issues
the pose once the skeleton has settled — re-issuing immediately would only write
onto a skeleton about to be replaced.

Detection is event-first:

- a **`TogglePOV` trigger handler** catches deliberate presses instantly;
- a **once-per-second poll** in `onUpdate` backstops changes you did not ask for
  (vanity mode, preview hold, another mod calling `setMode`). A second of latency
  is fine there precisely because you did not press anything.

With no subscribers it does one count check per frame, and this mod unsubscribes
the moment you dismount. Switching perspective mid-jump drops back to the
locomotion pose rather than replaying the hop, since a one-shot clip cannot be
resumed part-way.

---

## Camera offset

Sitting on a mount raises your character well above normal standing height, so
default third person framing ends up looking down at the rider's head. this mod
lowers the focal point while mounted.

Configured under **Settings -> Scripts -> Animated Creature Riding**:

| Setting | Default | Effect |
|---|---|---|
| Adjust camera while mounted | on | Turn off to leave the camera exactly as normal |
| Vertical offset | **-75** | Negative lowers the camera |
| Horizontal offset | **0** | Positive shifts right of the rider, negative left |

Applies in third person only — it has no effect in first person, and control is
handed straight back to the engine the moment you switch or dismount. Changing a
value in the menu applies immediately rather than at the next mount.

The built-in camera script manages this offset too, so it is told to stand down
for the duration via `disableThirdPersonOffsetControl`, using this mod's name as
the tag so it cannot clash with another mod holding its own.

## Configuration

All at the top of `scripts/AnimatedCreatureRiding/ridingAnim.lua`:

- `RIDE_ANIM`, `FALLBACK_ANIM`, `USE_FALLBACK_ANIM`
- `MOUNT_TYPE_BY_RECORD`, `MOUNT_TYPE_PATTERNS`, `BLACKLIST`
- `FREE_RIDE_ENABLED`, `FREE_RIDE_KEY`, `FREE_RIDE_RANGE`
- `USE_LEVITATION`, `LEVITATION_SPELL_ID`
- `ALLOW_JUMP`, `RIDE_PRIORITY`, `RIDE_BLEND_MASK`
- `BACKEND_EVENTS`
- `DEBUG`

Camera offsets are in the in-game settings menu (see
[Camera offset](#camera-offset)).

Perspective-refresh timing (`SETTLE_DELAY`, `POLL_INTERVAL`) lives in
`scripts/AnimRefresh/AnimRefresh_v1.lua`.

---

## File layout

```
AnimatedCreatureRiding.omwscripts
scripts/
  SharedRay/SharedRay_v2.lua                  bundled shared service
  AnimRefresh/AnimRefresh_v1.lua              bundled shared service
  AnimatedCreatureRiding/ridingAnim.lua       the controller  (context: player)
```

SharedRay and AnimRefresh are **bundled, not dependencies**. Both version-guard
themselves, so if another mod in the suite ships a newer copy, only that one
runs. Ship them; don't worry about duplication.

---

## Compatibility

**Requires a riding backend.** On its own it animates nothing except free rides.

**Do not run alongside WhyWalk** — WhyWalk contains an equivalent controller and
the two will fight over the same pose.

**Replaces the per-mod `ridingAnim.lua`** in Devilish Horse and Guar Riding. If
you use this, those two files are redundant; leaving them enabled means two
controllers issuing poses at the same priority.

Compatible with anything else using SharedRay.

---

## Known limitations

- **Group names outside horse and guar are placeholders.**
- **One rider per mount**, no passengers, no NPC riders.
- **`ALLOW_JUMP` assumes a `space` key symbol** for the jump pose rather than
  reading your bound jump action.
- **Untested in-game.** Parse-checked with the real Lua 5.4 parser, validated
  against Cod3x for API and context legality, with unit tests on the data
  tables — but not ridden.

---

## Credits and sources

- **Devilish Horse Riding / Guar Riding** — the direct ancestor. Its
  `ridingAnim.lua` was already fully event-driven and is the healthiest file in
  either reference mod; this is that design generalised.
- **Sturdy Steed — Simple Horse Riding** — the finding that the mount's gait
  belongs to the engine's character controller, and that a pinned rider counts
  as airborne, so the falling animation interrupts the rider pose.
- **Boar / Nix / Strident / Sky Render Riding** — creature record IDs, read
  directly from the ESPs.
- **Sun's Dusk** — performance philosophy, and the perspective-change refresh
  technique in `p_backpacks.lua` that `AnimRefresh` is built on.
- **SharedRay** — the shared camera-ray service.
- **Cod3x** — LuaLS annotation stubs used to validate API calls and script
  context.
