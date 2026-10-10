# WhyWalk Boats

A WhyWalk module for piloting small craft yourself: rowboats, gondolas,
longboats. Walk up to a boat on the water, press Activate, and you're at the
helm.

**Requires WhyWalk `00 Core`, loaded first.** The module's settings go on
Core's WhyWalk page, and it uses Core's bundled SharedRay and AnimRefresh when
they're there. It needs no ESP.

---

## Install

The module uses the same numbered-folder layout as Core:

```
WhyWalk/
  00 Core/     <- data path 1, content WhyWalk.omwscripts (+ WhyWalk.omwaddon)
  01 Boats/    <- data path 2, content WhyWalk_Boats.omwscripts
```

In `openmw.cfg`:

```
data="…/WhyWalk/00 Core"
data="…/WhyWalk/01 Boats"
content=WhyWalk.omwaddon
content=WhyWalk.omwscripts
content=WhyWalk_Boats.omwscripts
```

## Controls

| Input | Effect |
|---|---|
| **Activate** on a boat on the water | Take the helm |
| **Forward / Back** (your bindings, analogue on a gamepad) | Row ahead / astern. Speed builds and fades; let go and the boat coasts. |
| **Left / Right** | Rudder. Most boats need way on to turn. A rowboat can spin in place on its oars. |
| **Mouse** | Look anywhere. The boat holds its course. |
| **X**, or **Activate the boat** you're in | Go ashore. You step onto the nearest dock or bank, or over the side if there's nothing to stand on. |

Steering can be switched to **Follow view** in the settings. The boat then
turns toward wherever you look, the way Your Own Gondola works.

## Which boats

Any boat sitting on the water whose mesh is listed in
`boats_db.MODELS`: vanilla rowboats, gondolas and longboats, Immersive
Travel's re-oriented copies of those meshes, Your Own Gondola's
gondola, the Telvanni catboat mesh, and Stormrider's fishing boat
mesh.

- **Scenery boats** (statics) are taken over. The static is hidden and a plain
  activator copy is put exactly where it was. The copy stays where you leave it
  and is saved like any other object.
- **Your Own Gondola's** gondola is taken over the same way. Its script only
  holds the boat at sea level and rocks it, both of which this module does
  itself.
- **Boats another mod sails are left alone.** That covers Immersive Travel's
  mounts (the `a_*`/`c_*` records and your `dbs_gondola_01_bal` and
  `rp_ex_gondola_fancy_tra`), and Stormrider's boats and ships, which run on
  their own globals. Any other activator with a script is also refused, with a
  log line saying how to opt it in.
- **Beached boats** are refused, and so are boats with no water under them.
- A static whose mesh *looks* like a boat but isn't listed gets one log line
  naming the mesh, so you can add it.

### Adding a boat

Add its mesh to `MODELS` in `scripts/WhyWalk/Boats/boats_db.lua`:

```lua
['x/my_skiff.nif'] = { vessel = 'rowboat', yawOffset = math.pi },
```

- `vessel` is the movement profile to use.
- `yawOffset` is `0` when the mesh's bow points along +Y and `math.pi` when it
  points along −Y. Vanilla-orientation meshes are −Y.
- `origin` is only needed when the mesh's origin isn't at the hull's
  reference point. See the `gv_gondola.nif` entry for an example.

Leave `hull` out for a new vessel. It's measured from the bounding box on
first boarding and printed to the log, so you can paste the numbers back in.

---

## How it works

### You move, the boat follows (from Your Own Gondola)

While you're at the helm you have **Water Walking** (applied record-free, the
way Core applies levitation). The **engine moves you** through your own
movement controls, and the boat is placed under you every frame. Because you
are a real actor moving through the world, collision with docks, rocks,
bridges and the shore comes from the engine, just as Core gets collision for
mounts from the engine since its controls port. There's no rider pin and no
per-frame player teleport, so the NPC bug Devilish warns about can't happen.

Unlike Your Own Gondola, the boat keeps **its own heading**. Its velocity is
re-expressed as forward/strafe controls relative to wherever *you* face, so
you can look around freely while the boat holds its line. When the boat turns,
the turn is added to your view (`yawChange`) so you turn with it, as Core does
for riders.

### The feel (from Skyships, Stormrider, Aetherius's Outpost)

- **Speed** accelerates and brakes at per-vessel rates and coasts with
  exponential drag. Skyships provides the shape, Stormrider the small-boat
  rates, and Aetherius's Outpost the coasting drag (0.99 per frame at 60 fps,
  0.603 /s).
- **Turning** eases the yaw rate toward the rudder, so turns start and stop
  softly (Skyships). Rudder authority grows with speed from a per-vessel
  `pivot` value: Stormrider allows no turning at rest, and oars can spin a
  rowboat in place. Astern, the rudder works the other way round.
- **The bumper.** Ten times a second the hull probes ahead: a ray at deck
  height for docks and walls, one below the waterline for rocks, and the
  heightmap for shoals and beaches (the look-ahead idea Skyships uses for
  terrain). Speed is capped so the hull can still stop before whatever it
  found, so the boat slides up to a jetty instead of hitting it.
- **Collisions the bumper missed.** If the engine stops you and you cover
  less than a quarter of the commanded distance for 0.15 s, the boat's way
  comes off.
- **Turning about the middle.** A helmsman at the stern swings sideways when
  the boat turns (`v = forward·speed + ω×r`), so the hull pivots about its
  centre and not about you.
- **Motion** (cosmetic): a sway roll that leans into turns (Immersive Travel's
  constants) plus a slow triangle-wave pitch (Your Own Gondola's 2° rocking).

### The pilot's pose

Core's `ridingAnim.lua` plays it, from `whywalk_shared.VESSEL_STANCE`; the
Boats module only says which stance and what the helm is doing. Gondolas pole
on **gondola1**, swapping to **gondolar** / **gondolal** while the rudder is
over, each looping between its `loop start` / `loop stop` keys. Longboats,
the catboat and the fishing boat stand (`idle`) -- a longboat's pilot stands at
the guide slot, which is the helmsman's station, so its oarsmen are not the
player.

The rowboat **rows**: `rowingidle` with the oars shipped, `rowing1` pulling
ahead, `rowslow` pulling gently, and `rowingl` / `rowingr` for one oar while
turning. Astern ships the oars, because the clip has no backing stroke and
rowing forwards while sliding backwards would look worse than drifting.

The pose follows the rudder and throttle the pilot is giving, sent on change
only; a change within 0.3 s of the last switch is deferred, not dropped, so a
tapped rudder does not flicker.

The one thing taken from the hull rather than the pilot's hands is the speed
**band** -- whether the boat is making way or barely moving -- which picks
`rowslow` over `rowing1`. The oars are what made the boat fast, so the stroke
should match how it is actually moving. Two thresholds
(`poseFastAbove` 0.55, `poseSlowBelow` 0.35 of `maxSpeed`), because the band is
crossed on every departure and every stop and one threshold would flicker.

### Speed delivery and the gain loop

The mapping assumed, from OpenMW's character controller: the player moves at
`speed × max(|movement|, |sideMovement|)` along the normalised control vector,
and analogue values of 0.5 or less are doubled while walking.
`boats_physics.controlsFor` inverts that mapping exactly, and the tests check
it at any facing.

A slow **closed-loop gain** compares how far you actually travelled with what
was asked for and trims the difference. If the engine's mapping turns out to
be different, the boat still sails at the right speed, and the log says so
once.

Faster than walking pace means running, and running costs fatigue: rowing is
work. Near exhaustion the boat is held to walking pace, so a long crossing
ends slowly rather than with you knocked down.

### Per-frame cost

| When | Global | Player |
|---|---|---|
| Not at a helm | one nil check | one boolean check |
| At the helm | one boat teleport | controls restated, plus probes at 10 Hz (≤ 2 rays + ≤ 3 heightmap reads) |

Heading changes reach the global script only when the heading moves by more
than 0.003 rad or the turn direction flips. A straight course sends nothing.

### Files

```
WhyWalk_Boats.omwscripts
scripts/WhyWalk/Boats/
  boats_db.lua        the database: vessels, provenance, meshes, records, poses   (none)
  boats_physics.lua   equations of motion, pure and unit-tested                    (none)
  boats_global.lua    boarding, takeover copies, boat placement, leaving           (global)
  boats_player.lua    helm input, integration, bumper, leaving, settings           (player)
l10n/WhyWalkBoats/en.yaml
data/boats_sources.json   every source number, extracted (generated)
BOATS_DATABASE.md         the database as tables, with provenance (generated)
tools/                    generator, checks, tests
```

## The movement database

`BOATS_DATABASE.md` has every vessel's numbers and the provenance of each one.
It also catalogues all the source data: every Immersive Travel mount, all 12
Stormrider vessels with wind/sail fields, Skyships, Aetherius's Outpost,
Rideable Silt Striders, Your Own Gondola, and hull measurements read
from the NIFs.

Every number in `boats_db.lua` is either:

- `src:` traced to a value in `data/boats_sources.json`. `tools/check_db_sources.py`
  fails if one drifts. This has been mutation-tested: changing a traced value
  fails the check.
- `derived:` computed from traced values, with the working shown.
- `pref:` a design choice, labelled as one.

To regenerate from the reference mods, extract the uploads into one folder and
run:

```
python3 tools/build_boats_sources.py <extracted-dir> <Stormrider.json>
sh tools/check_all.sh [cod3x-dir]
```

### What the sources established

- **Which end is the bow can't be read from the mesh.** The gondola's narrow
  end is its stern. It's read from how each mod moves the mesh instead:
  Immersive Travel moves `_rot` meshes along +Y, and Stormrider sets
  `object angle = travel − 180`. The `_rot` meshes are the vanilla meshes
  turned 180° about the origin; `KS_SR_Ship.nif` and `Ex_DE_ship_rot.nif`
  negate exactly.
- **Your Own Gondola's mesh is Immersive Travel's gondola re-origined.** The
  extents are identical, shifted by (0, −81.5, −38.7). So YOG's "player at the
  boat origin, boat at z 0" is the same spot as IT's gondola with a +40
  offset. The two mods agree to within 1.3 units.
- **Lua teleports evidently don't carry actors standing on the moved
  object.** Skyships teleports its ship and then moves the deck walker itself
  every frame; if the engine also carried them, they would move twice, and
  Skyships works. This matters here: if a pilot standing on a deck were
  dragged along by the boat being placed under them, follow-the-pilot would
  run away. Watch for it in testing anyway (see below).

## Settings (Settings → Scripts → WhyWalk → Boats)

| Setting | Default | |
|---|---|---|
| Steering | Rudder | or Follow view (Your Own Gondola's model) |
| Turn view with the boat | on | rudder steering only |
| Boat motion | on | sway, rocking, lean |
| Use boats in the world | on | take over scenery boats |
| Show controls when boarding | on | |
| Quiet the water | on | mutes water-walking footsteps, as Your Own Gondola does |

## Compatibility

- **WhyWalk Core.** You can't board while mounted. Mounting a creature
  from the boat hands control to Core cleanly: Core's movement override is
  left alone, and the boat stays where it was.
- **Immersive Travel, Stormrider.** Their boats are never touched (see
  `boats_db.RECORDS`). Scenery boats are separate references, so taking one
  over doesn't affect their routes.
- **Your Own Gondola.** Its gondola becomes a WhyWalk boat when you board it.
- **Skyships / Aetherius's Outpost.** No overlap. Those mods sail their own
  ships.

## Not yet verified in game

Everything has been parse-, load-, context- and handler-checked, and the
physics and both scripts run against an engine model in the tests. These
points depend on engine behaviour that can only be confirmed by sailing:

1. **Movement mapping.** The speed formula above. The gain loop corrects it,
   and the log reports it if it's wrong.
2. **`yawChange` adds to mouse-look** when written from `onUpdate`. If the
   view doesn't turn with the boat, that's the cause; the boat still steers
   correctly.
3. **`castRay` with a list for `ignore`.** Skyships passes a list to
   `castRenderingRay`.
4. **The takeover copy's model path.** `createRecord`'s prefixing is still an
   open question on 0.52. The copy checks the stored model and prints if it
   differs, which answers the question.
5. **The floor-sitting pose** `vasittingfloor` only exists if an animation pack
   provides it. Otherwise the pilot stands. The first missing group is logged
   once.
6. **Footstep sound ids** `FootWaterLeft` / `FootWaterRight`, taken from
   Your Own Gondola's `stopsound` lines.
7. **No deck carry.** Sail a longboat (its helm is on a raised deck) at full
   way. If the pilot races ahead and keeps accelerating, the engine is
   carrying them with the boat. Report it; the fix is the fallback design
   below.

## Fallback design, if follow-the-pilot misbehaves

If test 7 fails, swap who leads. The global integrates the boat from the helm
(speed and heading are already sent on change), and the pilot station-keeps
with a P-controller toward the anchor, read off the boat's position each
frame: `command = v + k·(station − pilot)`.

- With engine carry, the error settles at `−v/k` (the pilot leads slightly).
- Without engine carry, the error settles at 0.

Either way the result is stable. A collision then shows up as station error
growing past a threshold. The boat stops, and is re-placed so the station sits
on the pilot. This variant was not chosen as the default because
follow-the-pilot is simpler and has a shipping precedent (Your Own Gondola).

## Known limitations

- One pilot, no passengers. The database carries Immersive Travel's
  passenger slots for when there are.
- No sailing physics yet. Stormrider's wind, polar and sail data is in the
  database. The fishing boat sails at its no-wind base speed.
- Boats can't pass through load doors. Going through one leaves the boat
  outside, level, where you left it.
- The vanilla rowboat and the catboat have no hull measurement in the sources,
  so they're measured from the bounding box on first boarding.

## Credits

- **Your Own Gondola** (GrumblingVomit): the pilot-moves, boat-follows model,
  the rocking and the footstep muting.
- **Skyships** (bensmodz): the motion feel, the eased turning, the terrain
  look-ahead, and the evidence about deck carry.
- **Stormrider / Stormrider Expanded** (Kellick Stormcrow, SuperCrumpets): the
  small-boat speeds, turn rates, accel/decel and seat heights, and the ship
  catalogue.
- **Immersive Travel** (rfuzzo): mount measurements, slots, sway constants
  and the `_rot` meshes.
- **Aetherius's Outpost**: momentum with drag on every axis, the coasting
  reference.
- **Rideable Silt Striders** (bensmodz): the floor-sitting pose name, the
  speed-approach model.
- **WhyWalk Core**: the session/pin/animation patterns, SharedRay,
  AnimRefresh, and the toolchain.
