# WhyWalk Caravans

Animated silt strider travel. Talk to a caravaner, pick a destination from the
usual list, and ride the journey instead of skipping it.

A WhyWalk module: load it **after `00 Core`**. Its settings sit on Core's
WhyWalk page, and Core's `ridingAnim.lua` already resolves a sitting pose for
the `SILT_STRIDER` mount type — which is exactly what `SILTSTRIDER_NOTES.md`
predicted when it said *"the rider animation layer needs no change"*.

---

## What it is, and why it isn't a mount

`SILTSTRIDER_NOTES.md`, IMPLEMENTATION NOTE:

> A silt strider is a vehicle, not a mount, and the difference matters. It has
> a guide NPC, multiple passengers, a fixed route, and no player steering
> on-route. That is a different mode from "mount a creature and steer it", and
> shoehorning it into PROFILE/saddle would distort both.

So this is a **vehicle** mode with its own data table: `slots[]` instead of a
single saddle, a guide slot for the caravaner, and a route walker instead of
steering input. Core's `PROFILE` is untouched.

| | mount (Core) | vehicle (here) |
|---|---|---|
| moved by | `controls.*`, engine walks it | placed along a route polyline |
| gait animation | engine picks it | played explicitly |
| steering | player | none; the route decides |
| occupants | one rider | player slot + guide slot (+2 unused passenger slots) |
| collision | engine | none — the route is authored to clear terrain |

### Why it is placed rather than driven

Core's 2026-10-08 controls port exists because writing `controls.movement` is
the right answer for a steered creature. A route vehicle is the opposite case,
and the route data says so: the Caravaner points sit at z values of 1300–2600,
with the mount data carrying `offset: -1220` and the service
`ground_offset: 1025`. Those are **body** positions on an authored path — the
strider's feet are 1200 units below the line it follows. There is nothing to
steer a walker along.

The consequence is the one the T-pose taught in 2026-10-04: a placed creature
is never asked to move, so it never picks a gait, so `caravans_vehicle.lua`
plays one by hand. With `loops = 999999`, not `-1` — the third time that
constant has come up.

---

## Requirements

**UI Toolkit** ([Nexus 60303](https://www.nexusmods.com/morrowind/mods/60303))
for the destination menu. It is an **optional** dependency: without it the
module stands down and vanilla travel is untouched. Nothing breaks, you simply
get the ordinary travel window.

Routes cover vanilla Vvardenfell plus the Tamriel Rebuilt mainland and Telvanni
Isles destinations the source data had. A destination with no route always falls
back to ordinary travel, so **nothing becomes unreachable** regardless of load
order.

---

## How the travel menu is intercepted

By watching the UI **mode**, as an event.

```lua
eventHandlers = { UiModeChanged = onUiModeChanged }
```

When the mode becomes `I.UI.MODE.Travel`, the module decides whether it can
take over; if it can, it closes the engine's travel window with
`I.UI.removeMode` and shows its own menu.

**`I.UI.MODE` is not a table.** It is a read-only userdata proxy: index it
(`I.UI.MODE.Travel`), never `type()`-check or `pairs()` it. The 2026-10-23
build gated on `type(I.UI.MODE) ~= 'table'`, which is always true in the
engine, so it stood down on every travel menu — that was the "no indication of
travel ui functioning" report. See `FIX_2026-10-28.md`, which also corrects the
conclusion `FIX_2026-10-23.md` drew about `I.UI.WINDOW`.

Everything the current mechanism rests on comes from working code rather than
from a reading of the docs: `UiModeChanged`'s `{ oldMode, newMode }` payload
(AnimRefresh v5 reads exactly those), `I.UI.MODE.Travel` (Ben's Rideable Silt
Striders keys its whole mod off it), and `I.UI.removeMode`.

Still event-driven. Ben's mod reaches the same moment with a per-frame
`if I.UI.getMode() == I.UI.MODE.Travel`, which spends a frame handler for the
whole game to catch a menu opened twice an hour.

**Two orderings matter.** The window is closed only *after* a menu is known to
be buildable, because once it is gone the player cannot be handed back to it.
And the close happens *before* the popup is shown, because UIToolkit's `Popups`
adds its own UI mode only when the stack is empty — showing first would leave
the menu under Travel mode and then pull Travel out from under it, giving a
visible but unclickable window. Both are asserted in
`tools/test_intercept.lua`.

**If it cannot help, the vanilla menu is left alone — and the log says why.**
No UI Toolkit, no guide, a guide at no known stop, or no imported route from
here, and the engine's own travel window stays up and works. Each reason is
printed once per session as `[WhyWalk Caravans] vanilla travel window kept: …`,
so a stand-down is never silent. The module never leaves the player unable to
travel.

**The guide is latched at activation.** `UiModeChanged` carries no target, so
the mode change cannot say *who* you are talking to. The global script watches
NPC activation instead, which is sound because activating an NPC is the only
way to reach their travel topic. Nearest-travel-selling-actor is the fallback.

**If `MODE.Travel` is ever missing**, the player script errors at load,
loudly, rather than standing down in silence.

---

## Where everything sits, and which way it faces

One origin. `bodyOrigin(s, z)` is `z - bodyOffset`, and the vehicle, the
player, the guide and the dismount all measure from it. They did not, once:
`placeVehicle` took the route point while the occupants took the offset
origin, and the strider stood 1220 units high with its feet at the rider's
waist (`FIX_2026-10-29.md`).

The **driver sits in front**. Immersive Travel's slot data has it the other
way round; `caravans_db.lua` swaps the two y values and says so.

The **player's yaw is a delta, the guide's is a heading.** Teleporting an
absolute rotation onto the player every frame welds the camera to the
strider's nose, because in third person the body yaw and the camera yaw are
the same number. The change in heading is applied instead, so the body turns
with the strider and mouse-look survives -- the same fix as Core's rider pin.
The guide has no camera, so they just face forward.

The **player is posed through Core**, with `WhyWalk_AnimVesselStart`
`{ stance = 'passenger' }` on departure and `WhyWalk_AnimVesselStop` on
arrival, abort and load. The stance resolves `rasit2` (xRAsit1 pack), then a
floor sit, then vanilla idle -- `animation.hasGroup` decides, because
`playBlended` on a missing group is a silent no-op. Core's layer also
re-asserts the pose when the engine interrupts it, which happens constantly
here: a passenger teleported along a route counts as airborne.

Two events per journey. Nothing per frame.

---

## Ending a journey takes a frame of its own

An object can be teleported once per frame. The teardown teleports all three
bodies and `onUpdate` has already teleported all three, so running it inline
raised `Object is either removed or already in the process of teleporting` at
its first statement and aborted the handler halfway through -- vehicle not
parked, guide not released, player not put down, no ARRIVED event
(`FIX_2026-10-29b.md`).

So `endJourney` only records a request; `finishJourney` runs from the top of
the next `onUpdate`, before anything has moved. That also covers the abort
path, which arrives as an event in a frame where the bodies are already
placed.

## The player is pinned, not teleported

Through Core's `WhyWalkRiderPin` interface, which moves the player with
MWScript `SetPos`.

A teleport fires `onTeleported` on every player script in the load order, so
carrying the player by teleport delivers sixty of those a second to every
other mod. Three broke under it in one session: one restored the camera on
every teleport and locked the view to first person for whole journeys, one's
`onTeleported` handler raised, one's queued VFX cleanup errored.

Core's pin exists for this hazard already and comes with its stale-ESP probe,
its liveness check and its automatic fall-through to a teleport, so an install
without a compiled `WhyWalkRiderPin` behaves exactly as before. Which path is
in use is logged once per session; grep for `carried by`.

Only the player is pinned. The vehicle, the guide, boarding, dismounting and
parking are still teleports.

---

## Destinations and fares come from the game, not a table

`types.NPC.record(guide).travelDestinations` gives the real destination list —
`cellId`, `position`, `rotation` — and `servicesOffered.Travel` says who sells
travel. So the menu shows whatever that caravaner actually offers, including
destinations added by mods this module has never heard of.

What the route database supplies is the thing the engine does not have: the
**shape of the path** between two places. 47 routes, 2150 points, imported from
Immersive Travel's Caravaner set.

**Places are matched by position, not by name.** An exterior destination's
`cellId` is an engine id, not "Balmora", so the global script resolves the
guide's position (origin) and each destination's position to the nearest route
stop, within 15000 units (`caravans_stops.lua`). Stop centres are the median of
every route endpoint naming that stop. At load, any route whose ends are not at
its named stops is dropped and the reverse direction is used instead; on the
shipped data that is `suran -> balmora`, which ends ~47500 units from Balmora,
and the log reports it every load.

Fares use **OpenMW's own travel price formula**, reimplemented from the engine
source Immersive Travel cites (`mwgui/travelwindow.cpp`,
`mwmechanics/mechanicsmanagerimp.cpp`). `SILTSTRIDER_NOTES` recommends it over
Ben's hardcoded per-route gold because *"it is the engine's actual maths"*:
disposition, independently-capped luck/personality/mercantile terms, both
parties' fatigue, `fTravelMult`, and `(1 + followers)`. The gold is moved from
player to guide, as the engine does.

---

## Settings

Under **Caravans** on the WhyWalk page.

- **Animated caravan travel** — on by default. Off restores the ordinary menu.
- **Strider speed** — world units/second, default 1400. The imported routes
  average ~99,000 units and the longest (Vivec → Seyda Neen) is 204,000, so
  1400 gives a **71-second mean journey and 146 seconds at worst**.
- **Advance the clock to match** — on by default. See below.

### The clock

Ordinary travel advances the clock by `distance / fTravelTimeMult` — about 8
hours for Balmora → Ald-ruhn. An animated journey passes *real* time instead,
which at a 30× timescale is well under an hour of game time. Left alone, riding
would be a stealth buff to travel.

So with the setting on, the **remainder** is added on arrival: vanilla's hours,
less whatever the journey already consumed, never negative. Turn it off if you
would rather the journey cost only the time it took.

Travel time is computed from the **route** length rather than the straight
line, which is a deliberate divergence from the engine: the strider walks the
route, so the route is the distance actually covered, and it is always the
longer of the two.

---

## Files

```
WhyWalk_Caravans.omwscripts
scripts/WhyWalk/Caravans/
  caravans_routes.lua    GENERATED route geometry        (context: none)
  caravans_path.lua      the route walker, pure          (context: none)
  caravans_db.lua        vehicle/slot data, the fare     (context: none)
  caravans_global.lua    the journey                     (context: global)
  caravans_player.lua    interception, menu, settings    (context: player)
  caravans_vehicle.lua   the vehicle's gait              (context: local)
tools/
  import_routes.py       regenerates caravans_routes.lua
  test_caravans.lua      78 assertions against the real data
  test_intercept.lua     74 assertions: the menu, and a real journey
                         driven through the real global script
```

Three of the six files have no `openmw` requires at all, so the route walker
and the fare are testable outside the engine — and they are, against the
shipped route data rather than a mock.

### Regenerating the route data

```
tools/import_routes.py <ImmersiveTravel>/Caravaner  scripts/WhyWalk/Caravans/caravans_routes.lua
```

The importer drops the two empty source files (`Necrom_Sailen`,
`Sailen_Bosmora`) that `SILTSTRIDER_NOTES` warns *"would teleport the strider to
origin"*, keeps the longer of any duplicate, and folds every key to lower case.

Routes are stored **one direction only**, as flat `x,y,z` arrays. The walker
traverses backwards when asked for the other direction — which is not only a
size saving: the source is genuinely one-directional in places (there is a
`balmora_vivec` and no `vivec_balmora`), and reversal covers every one of those
gaps including the two dropped files.

---

## Known limitations

- **The vehicle is a spawned object, not the strider at the stop.** Taking the
  level designer's strider away for the journey would leave a hole and strand
  anything scripted to it. Ben's mod spawns its own; this does too, and
  `SILTSTRIDER_NOTES` lists that technique as the thing worth taking from it.
- **It prefers a creature record and falls back to an activator.** Ben's mod
  spawns an Activator, which moves but cannot animate — its strider's legs
  never move. This searches `types.Creature.records` for one whose **mesh**
  looks like a silt strider and clones it, so the gait can play. Matched on
  mesh rather than record id deliberately: `c_siltstrider` is Immersive
  Travel's id, not a vanilla one. With no such creature in the load order it
  logs a line and falls back; the journey still works, the legs do not move.
- **A journey does not survive a save.** Loading aborts it and puts you down.
  A route position, a spawned object and two teleported actors would all have
  to agree after a load, and the failure mode if they do not is a player
  stranded 1200 units up. The guide **is** persisted and returned to their post,
  because otherwise a mid-journey save would leave the caravaner standing in
  the wilderness for the rest of the save.
- **No collision on-route.** The routes are authored to clear terrain; nothing
  checks. This is the same trade the source made.
- **Passenger slots 2 and 3 are recorded but unoccupied.** The measurements are
  there (`+/-81` on X); nothing rides in them yet.
- **Departing clears every UI mode**, including the dialogue window the travel
  topic was reached through. Interception removes only the Travel mode, so
  without this the journey would begin with the caravaner's dialogue still open
  over the view.
- **Cell-name matching is a straight lower-case fold.** Travel destination cell
  ids are matched against route keys directly, which works because an exterior
  destination's cell id *is* the place name. A destination whose id carries a
  suffix the route files do not will simply miss and fall back to ordinary
  travel.

---

## Credits

- **Immersive Travel** (rfuzzo) — the route point sets, the mount and slot
  measurements, the sway constants, and the travel price formula. Per
  `SILTSTRIDER_NOTES`, its *data* is excellent and none of its movement code
  transfers: it is written in per-frame steps assuming 60fps.
- **Rideable Silt Striders** (bensmodz) — runtime record creation
  (`createRecordDraft` → `createRecord` → `createObject`), and the demonstration
  that a spawned vehicle is the right unit of work.
- **UI Toolkit** — the modal destination menu.
