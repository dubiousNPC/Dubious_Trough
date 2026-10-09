# WhyWalk

An all-in-one animated creature riding engine for OpenMW 0.51+.

Mount a creature, steer it, and see your character actually sitting on it. One
mod covering every mount type instead of one mod per animal, driven by data
tables rather than duplicated scripts.

**Requires OpenMW 0.51 or newer.** Lua only — no ESP is required to run,
though one unlocks the preferred rider-placement backend (see
[Rider placement](#rider-placement)).

---

## Contents

- [What it does](#what-it-does)
- [Controls](#controls)
- [Performance](#performance)
- [Mount types and animations](#mount-types-and-animations)
- [Free ride](#free-ride)
- [Camera offset](#camera-offset)
- [Rider placement](#rider-placement)
- [Camera freedom](#camera-freedom)
- [Configuration](#configuration)
- [File layout](#file-layout)
- [Compatibility](#compatibility)
- [Known limitations](#known-limitations)
- [Silt striders](#silt-striders)
- [Credits and sources](#credits-and-sources)

---

## What it does

- **Mounts creatures.** Look at a rideable creature, press Activate, and you're
  on it. Targeting uses SharedRay, so no extra raycast is issued.
- **Steers them.** WASD with a gallop modifier and a jump. Steering is
  translated into the creature's own movement `controls`, so the engine moves
  it -- with its own gait animation, collision, gravity and step handling.
- **Animates the rider.** Lower-body and torso blended poses per mount type,
  with optional random variation. The lower body carries the seated pose; the
  torso stays at weapon priority so weapons and spells keep working.
- **Adjustable camera**, offset separately per perspective.
- **Rider faces the mount in third person**, so you can swing the camera around
  without the rider swivelling to follow it.
- **Classifies mounts automatically.** Eleven known record IDs read out of the
  shipped riding mods, plus ordered pattern matching for anything else.
- **Falls back gracefully.** Creatures with no packaged animation set get a
  generic rider pose rather than nothing.
- **Free ride.** Mount any creature at all, with no script added to it.
- **Rides unknown creatures sensibly.** A creature no profile covers gets its
  saddle height measured from its own bounding box, rather than inheriting a
  guar's.
- **Survives saves.** Control locks and levitation are recorded and undone on
  load rather than left dangling.

What it deliberately does *not* do:

- **It does not animate the mount's gait, and it does not move the mount
  itself.** Both are the engine's, reached by writing the creature's
  `controls`. This was not always true: WhyWalk used to teleport the mount to a
  computed position every frame, which meant the character controller was never
  asked to move it, never chose a locomotion group, and the creature rendered
  at bind pose -- the T-pose. Driving the controls is both less code and the
  only way to get the real gait.
- **It does not implement collision, gravity or ground-finding.** It used to
  attempt the third with a heightmap query and skip the first two entirely.
  All three now come from the engine, which is why mounts no longer walk
  through walls or sink on bridges.
- **It does not let you ride indoors by default.** Riding indoors works, but
  Morrowind's interiors are built for a walking player. There is a setting.

---

## Controls

| Input | While unmounted | While mounted |
|---|---|---|
| **Activate** (your bound key) | Mount the creature you're looking at | Dismount |
| **W / S** | — | Forward / reverse |
| **A / D** | — | Steer left / right |
| **Shift** | — | Gallop (held with W) |
| **Space** | — | Jump (ground mounts only) |
| **X** | — | Dismount |

Activate is read through OpenMW's trigger system, so it follows whatever you
have that action bound to. It is ignored while the HUD is hidden, so it won't
fire through menus and dialogue.

---

## Performance

This was the primary design constraint, and it is worth being specific about.

**One per-frame handler in the entire mod.** It lives in
`whywalk_global.lua`, and its first statement is:

```lua
if not session then return end
```

When nobody is riding, WhyWalk costs one nil check per frame. No actor scans,
no raycasts, no storage reads, no allocation.

For comparison, both reference implementations this was built from keep **three**
per-frame handlers alive and do real work in all of them whether or not a ride
is in progress.

Two decisions got it there:

**Input is event-driven.** The references poll WASD every frame and re-send
identical control values sixty times a second. WhyWalk tracks held state from
`onKeyPress`/`onKeyRelease` and sends a control event *only when intent
changes* — a handful of events per journey. The global script integrates
movement from the last known intent. The player script therefore has no
per-frame handler at all.

**One script on the creature, only while it is ridden.** `whywalk_mount.lua`
is registered `CUSTOM` and attached with `addScript` on mount, removed on
dismount, so an unridden creature carries no WhyWalk code whatsoever. While
ridden it runs one `onUpdate` that performs five field writes and no
allocation, no queries and no raycasts -- restating the controls, which is how
the engine consumes them, and that is the floor for a driven actor.

It replaces, per frame: two teleports, a heightmap query and a hand-integrated
gravity step. Devilish Guar Riding's equivalent does nine raycasts.

**What is genuinely irreducible:** there is no API in OpenMW Lua to parent one
object's transform to another. No attach, no `setParent`, and `Actor.setVelocity`
is not part of the documented API. Something has to place the rider every frame.
That is the one `onUpdate`, and everything else — input, targeting, animation,
mounting, dismounting — is event-driven.

**No ground probing at all any more.** `core.land.getHeightAt` is gone with
the movement simulation. It was a cheap heightmap read, which was its appeal,
but a heightmap knows nothing about bridges, floors or anything placed, and
returns nothing at all for interiors -- which is where the unbounded interior
fall came from.

**One-frame rider lag, by construction.** The mount is moved by the engine and
the rider is placed from the mount's actual position, so the rider can be one
frame behind. Handler order within a frame is not specified, so this is not
removable; it is also not visible, because the offset is constant rather than
varying. Devilish Guar Riding has the same split.

---

## Mount types and animations

Nine mount types plus a generic fallback:

| Type | Notes |
|---|---|
| `horse` | Animation groups verified from the shipped mod |
| `guar` | Animation groups verified from the shipped mod |
| `boar` | |
| `nix` | |
| `strident` | |
| `kagouti` | |
| `skyrender` | Flying: no reverse, no jump |
| `netch` | Flying: no reverse, no jump |
| `silt_strider` | Measurements from Immersive Travel; see [Silt striders](#silt-striders) |

Each type maps five rider states — idle, walk, gallop, reverse, jump — to
animation groups in `whywalk_shared.lua`.

**Group values can be a name, a list, or `false`:**

```lua
[S.IDLE]    = { "rideb1", "rideb1_alt" },  -- pick one at random on entry
[S.WALK]    = "rideb2",                    -- always this one
[S.REVERSE] = false,                       -- this mount has NO reverse state
```

`false` and `nil` mean different things. `false` is an explicit "this mount has
no such state" and blocks fallback — it's why a sky render never tries to hop.
`nil` means unspecified and *does* fall back to the generic set, so a mount can
leave an exotic state to the fallback without shipping a bespoke clip.

Variants resolve once on state entry, never mid-state. Re-rolling while a state
runs would restart the animation and produce a visible hitch.

### Vessel stances (WhyWalk Boats)

The same controller poses a boat pilot, from `VESSEL_STANCE` in
`whywalk_shared.lua`: **gondola** poles on `gondola1` and turns on
`gondolar` / `gondolal` (xGondola1.kf, looping between its loop keys),
**stand** uses `idle`, **sit** a floor-sitting group if a pack provides one.
A **rowing** stance is reserved and documented in the file. Driven by
`WhyWalk_AnimVesselStart` / `_AnimVesselHelm` / `_AnimVesselStop`; see
FIXES_2026-10-09.md.

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

### Classification

Exact record IDs win over patterns, because record names lie. Eleven IDs are
hardcoded, read directly out of the shipped riding mods' ESP and config files:
`ttd_horseride`, `detd_guarride1`, `ttd_boarride`, `detd_boarnoride1`,
`ttd_nixride`, `detd_nixnoride`, `ttd_stridentride`, `detd_stridentnoride1`,
`detd_skybug_riding`, plus placeholders.

Anything unlisted falls through nine ordered pattern groups. Order matters
where substrings nest — `siltstrider` is tested before `strider`.

A blacklist blocks specific records from ever being mountable, even under free
ride.

### Placeholders

Group names outside horse and guar are **placeholders**. So are the three
`placeholder_*` creature IDs and the levitation spell ID. They're structurally
correct and clearly marked; replace them with real names from your `.kf` before
shipping. Every group also needs matching start/stop text keys, or
`playBlended` silently does nothing.

---

## Free ride

Mount **any** creature with no script added to it and no ESP edit.

There is no steering — the creature keeps its own AI and you ride along. That
is the point. No control bridge, no mount script, no movement integration, so
it's by far the lowest-impact mode in the mod.

Enabled by default (`TUNING.freeRideEnabled`), range `TUNING.freeRideRange`
(400 units). Blacklisted creatures are still excluded.

---

## Camera offset

Your chosen perspective is honoured — WhyWalk never switches the camera. Instead
each view gets its own offset, configured under
**Settings -> Scripts -> WhyWalk**:

| Setting | Default | Effect |
|---|---|---|
| Adjust camera | on | Turn off to leave the camera exactly as normal |
| First person: vertical | **0** | Negative lowers the view |
| First person: horizontal | **0** | Positive shifts right, negative left |
| Third person: vertical | **-75** | Negative lowers the view |
| Third person: horizontal | **0** | Positive shifts right, negative left |

The two views need separate settings because they need different framing and use
different APIs — `setFirstPersonOffset` takes a 3d vector measured from the
character's head, `setFocalPreferredOffset` a 2d vector from the tracked
position. First person usually needs nothing since the camera already sits at
head height; third person frames from too high without help.

Only the active view is offset and the other is zeroed, so a stale value cannot
survive a perspective change. Vanity and preview modes are third-person-shaped
and take the third person offset. Changing a value in the menu applies
immediately.

The built-in camera script manages the third person offset too, so it is told to
stand down via `disableThirdPersonOffsetControl`, tagged with this mod's name so
it cannot clash with another mod holding its own.

### Rider body orientation

In **third person** the rider's body yaw is forced to the mount's, so the rider
stays seated facing forward however you swing the camera around. In **first
person** it is deliberately left alone: there the body yaw *is* the look
direction, and overwriting it every frame would fight mouse-look.

The perspective is relayed from the player script on change only, riding on the
same `AnimRefresh` notification the animation layer already uses rather than
adding a poll of its own. On the MWScript backend the angle is written every
tick and the gate lives in the script itself, where `PCGet3rdPerson` is free:

The complete script ships as `mwscript/dbs_ww_RiderPos.txt` — use that rather
than the excerpt below, which omits the declarations and assignments and will
not compile on its own:

```
Begin dbs_ww_RiderPos

float px
float py
float pz
float pa

if ( whywalk_active == 0 )
    return
endif

set px to whywalk_x
set py to whywalk_y
set pz to whywalk_z
player->SetPos X px
player->SetPos Y py
player->SetPos Z pz

if ( PCGet3rdPerson == 1 )
    set pa to whywalk_angle     ; degrees
    player->SetAngle Z pa
endif

End dbs_ww_RiderPos
```

It must be a **global** script (a Start Script in the CS), and the five globals
`whywalk_active`, `whywalk_x`, `whywalk_y`, `whywalk_z`, `whywalk_angle` must
exist in the ESP as type **Float**.

---

## Rider placement

Two backends, selected by `TUNING.riderBackend`:

**`"mwscript"` (default)** — Lua writes the target into MWScript global
variables (`whywalk_x/y/z`, `whywalk_angle`, `whywalk_active`) and a compiled MWScript in an
accompanying ESP does the `SetPos`. This is the preferred path because a
per-frame Lua player-teleport loop is documented by Devilish Horse/Guar Riding
as triggering an engine bug involving nearby NPCs.

**`"teleport"`** — pure Lua, no ESP needed. Works, but inherits that bug.

If the MWScript bridge is unavailable, WhyWalk falls through to teleport rather
than leaving the rider behind — a missing ESP degrades to the working-but-buggier
path, not to nothing.

**Levitation** (`TUNING.useLevitation`) suppresses rider gravity so it stops
dragging you down between placements. It does **not** move anything; it removes
a force that fights the placement. Recorded in the save and undone on load.

---

## Camera freedom

You can switch perspective freely while mounted.

This is worth calling out because the mod this is descended from pins you to
first person and re-asserts it on a timer. That trades a bug for a worse
restriction: you can no longer look at the animation you installed the mod for.

The bug being avoided is real — switching perspective rebuilds the player's
animation object and drops scripted animations with it. WhyWalk handles it with
`AnimRefresh`, a small bundled service that notices the change and re-issues the
pose after the skeleton has settled.

Detection is event-first: a `TogglePOV` trigger handler catches deliberate
presses instantly, and a once-per-second poll in `onUpdate` backstops changes
you didn't ask for (vanity mode, preview hold, another mod's `setMode`). With no
subscribers it does one count check per frame, and WhyWalk unsubscribes when you
dismount.

---

## Configuration

Everything tunable lives in `scripts/WhyWalk/whywalk_shared.lua`.

Camera offsets are in the in-game settings menu (see
[Camera offset](#camera-offset)); everything else is edited in the file.

**`TUNING`** — fallback animation on/off, free ride on/off and range,
levitation on/off and spell ID, rider backend choice, MWScript global names,
dismount clearance, drift resync threshold.

**`PROFILE`** — per mount type: saddle offset (forward/right/up), turn rate,
flying flag. Top speed, walk/reverse multipliers and the jump arc used to live
here and are gone: the engine owns movement, so a creature's speed is its own
Speed stat and its jump is the engine's jump. Missing fields
fall back to a shared default, so a new mount only needs the numbers that differ.

**`RIDE_ANIM` / `FALLBACK_ANIM`** — the animation tables described above.

**`MOUNT_TYPE_BY_RECORD` / `MOUNT_TYPE_PATTERNS` / `BLACKLIST`** —
classification.

`DEBUG = false` at the top of each script turns on diagnostic logging.

---

## File layout

```
WhyWalk.omwscripts
scripts/
  SharedRay/SharedRay_v2.lua        shared camera-ray service (bundled)
  AnimRefresh/AnimRefresh_v5.lua    perspective-change service (bundled)
  WhyWalk/
    whywalk_shared.lua              data + pure helpers    (context: none)
    whywalk_global.lua              orchestration, pin     (context: global)
    whywalk_player.lua              input, targeting       (context: player)
    whywalk_mount.lua               mount controls         (context: local)
    ridingAnim.lua                  rider animation        (context: player)
    (silt strider)                  notes only, see SILTSTRIDER_NOTES.md
```

`whywalk_shared.lua` has no `openmw.*` requires at all, so global, player and
any future script can all require it.

SharedRay and AnimRefresh are **bundled, not dependencies**. Both version-guard
themselves, so if another mod in the suite ships a newer copy, only that one
runs. Ship them; don't worry about duplication.

---

## Compatibility

**Do not run WhyWalk alongside another riding mod for the same mounts.** It is a
complete engine and will fight anything else trying to place the same rider.
That includes Devilish Horse/Guar Riding, Sturdy Steed, and
AnimatedCreatureRiding (which is the animation layer alone — see its README;
WhyWalk already contains an equivalent).

Compatible by design with anything using SharedRay, since that is a shared
service rather than a fork.

The mount records from the Boar, Nix, Strident and Sky Render riding ESPs are
recognised, so those creatures work as WhyWalk mounts if their ESPs are loaded.

---

## Known limitations

- **Animation groups outside horse and guar are placeholders.** The mod will
  run, but unresourced mounts fall back to the generic set, which is also a
  placeholder name.
- **The MWScript bridge needs an ESP** that doesn't ship here. Without it the
  mod silently uses the teleport backend.
- **AI suppression on the mount is unverified in game.** The port assumes
  `self:enableAI(false)` disables only the AI decision layer, leaving the
  character controller free to act on scripted `controls`. If a mount refuses
  to move, set `TUNING.suppressMountAI = false` -- steering will work and the
  creature's AI will fight it, which identifies the cause immediately.
- **Saddle height for unknown creatures is derived, not measured.** The
  bounding-box fallback reads only yaw-invariant parts of the box, and its one
  tuned constant was fitted to the guar. It prints the number it derived; put
  that in `PROFILE` to stop guessing.
- **No camera-follow steering.** Steering is A/D only; the mount does not turn
  to follow where you look in first person. Sturdy Steed does this, and notes it
  needs angular hysteresis (engage ~6 degrees, release ~1.5) or the engine
  blends turn animations into the gait and the walk degrades into a shuffle.
- **Single turn rate per mount.** Real turning radius grows with speed; this
  does not model that yet.
- **No passenger support.** One rider per mount.
- **No NPC riders.**
- **Free ride does not survive a save/load**, by design — there is no backend to
  restore the pin from.
- **Untested in-game.** Every script has been parse-checked with the real Lua
  5.4 parser and validated against the Cod3x API stubs for context legality and
  member existence, and the data tables have unit tests. That is not the same as
  having been ridden.

---

## Silt striders

`SILTSTRIDER_NOTES.md` is a **catalogue, not an implementation**. No script is
registered for striders, so the path costs nothing.

It used to be `whywalk_siltstrider.lua` -- a file that was 99% block comment
around an empty `return {}`, loaded by nothing. Same content, no longer
pretending to be code.

It records measured mount data (slot positions, offsets, sounds, node names),
sway constants, route network comparisons across two source mods, and an
assessment of which techniques transfer.

The conclusion recorded there: a silt strider is a **vehicle, not a mount** —
guide NPC, multiple passenger slots, fixed route, no player steering. Forcing it
into the single-saddle `PROFILE` model would distort both. When it ships it
wants a separate vehicle mode sharing WhyWalk's session, pin and animation
layers.

---

## Credits and sources

- **Devilish Horse Riding / Guar Riding** — the architectural baseline. Its
  `ridingAnim.lua` was already event-driven and is the direct ancestor of this
  mod's animation controller. Its config documents the engine bug that motivates
  the MWScript rider backend.
- **Sturdy Steed — Simple Horse Riding** — the finding that the mount's gait
  must be left to the engine's character controller, and that a pinned rider
  counts as airborne (so the falling animation interrupts the rider pose).
- **Rideable Silt Striders** (bensmodz) — `core.land.getHeightAt` for ground
  without raycasts, the MWScript-globals rider bridge, runtime record creation.
- **Immersive Travel** (rfuzzo) — measured silt strider dimensions, the
  `MountData` schema, sway constants, and route data.
- **Sun's Dusk** — the performance philosophy throughout, and the
  perspective-change refresh technique in `p_backpacks.lua` that `AnimRefresh`
  is built on.
- **SharedRay** — the shared camera-ray service.
- **Cod3x** — LuaLS annotation stubs used to validate every API call and script
  context in this mod.
