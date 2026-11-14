# WhyWalk Shipping

Ship travel that is sailed, not skipped. Talk to a shipmaster, pick a destination, and stand on deck while the ship sails Immersive Travel's route to the quay you paid for.

This is the first stage of a module for larger vessels. It makes Immersive Travel's Shipmaster routes work the way Caravans makes its Caravaner routes work, and lets you walk the deck while the ship sails. Steering a ship yourself, interiors and crew come later.

A WhyWalk module: load it **after `00 Core`**. Core carries the passenger (`WhyWalkRiderPin`) and poses them (`ridingAnim.lua`). Without Core it still sails, but the passenger is carried by teleport and isn't posed.

---

## Requirements

**UI Toolkit** ([Nexus 60303](https://www.nexusmods.com/morrowind/mods/60303)) for the destination menu, as Caravans uses. Without it the module stands down, the vanilla travel window works as normal, and the log says why.

Immersive Travel itself is **not** needed. Its route data is compiled into `shipping_routes.lua`, and the vessels are the vanilla meshes.

---

## What happens

1. **Talking to a shipmaster.** Activating any NPC who sells travel tells this module whether they are a *shipmaster*. That means class `Shipmaster`, or one of Immersive Travel's named exceptions (`rindral dralor`, who is a Rogue). Caravaners are never touched; Caravans handles them.
2. **Asking for routes.** The global script works out which of their destinations have a route (*Matching a route*) and which vessel sails it.
3. **The Travel menu.** When the Travel window opens, it is closed and replaced by a menu with:
   - one row per destination that has a route;
   - **Other destinations (n)…**, which reopens the engine's own travel window for the same shipmaster with this module standing aside.

   Nothing becomes unreachable.
4. **Departure.**
   - The fare is charged: the engine's own number, to the gold piece.
   - A vessel is spawned at the start of the route.
   - The shipmaster takes the helm.
   - You are put on the bow deck, facing forward. With *Walk the deck* on (the default) you can then go where you like aboard; see *Walking the deck*.
5. **The voyage.**
   - The ship leaves at walking pace, accelerates to the *Sailing speed* setting, and slows for tight turns.
   - Corners are rounded so a 2,400-unit hull swings wide.
   - The hull leans into turns.
   - You can look around; your view turns with the ship.
   - With *Walk the deck* off, you stay on the bow deck for the whole voyage.
6. **Arrival.**
   - You are put down **at the exact spot the shipmaster's travel record names**, which is where vanilla travel would put you.
   - The clock is topped up to vanilla's hours.
   - The shipmaster goes back to their post, and the vessel is parked out of sight.

**X** goes ashore early. Before half way you are put back on the quay you left, after it on the one you were bound for.

**A save taken at sea completes the voyage when loaded.** The fare is paid and the destination is known, so arriving is the honest outcome. The alternative is waking up in the sea.

**Resting or waiting aboard does the same.** A game-clock jump of more than an hour in one frame ends the voyage at its destination, and the top-up owes only what the rest didn't already pass.

**The vessel belongs to this module.** WhyWalk Boats claims any activator whose mesh it knows, and the longboat is one. Activating the hull under way used to hand Boats the helm while this module kept moving the same object, which showed as *Object is either removed or already in the process of teleporting* in OpenMW 0.52. Shipping's activation handler now stops that.

---

## Walking the deck (`shipping_deck.lua`)

Walk, run, jump, climb the quarterdeck: the ship carries you while you stand on it.

**How.** Each frame, the global script:
1. takes your offset from where the hull *was*, in the hull's own frame (heading **and** heel);
2. moves the hull;
3. puts you at the hull's new pose plus that offset, through Core's rider pin.

Your own walking since the last frame is already in your position, so it is kept. This is the pattern Watercraft and Ben's Skyships both use, measured on 2026-11-12 (see the deck-walking test report); the pose is a rigid transform, so it also holds through turns and while the hull heels.

**Who is carried** is decided by what you stand on, never by distance. The player script casts a ray from the knees to 300 units below the feet and tells the global script when the answer changes (`WWShipping_Footing`).

| footing | carried? |
|---|---|
| on the vessel | yes |
| off it, within 1.5 s of last standing on it, never in the water since | yes: a jump, or stepping down off the quarterdeck |
| in the water | no; after 2 s the crew haul you back to the bow deck |
| off it, dry (a sandbar) | no; after 1.5 + 4 s, the same |
| nothing reported yet | yes: a missing or older player script must not put you overboard |

Once you have been in the water, the 1.5-second grace no longer applies until you stand on the hull again. At the surface the engine's swimming flag flickers every frame, and without that rule the grace dragged a swimmer along with the ship one frame at a time.

**The ship does not wait for you.** It sails on at the same speed whether you are at your slot or not, unlike Watercraft's coasting-only deck.

**Off** (`Walk the deck` unchecked) pins you to the bow deck as before, posed.

---

## Matching a route (`shipping_stops.lua`)

Caravans gives every place one centre and matches anything within 15,000 units of it. Docks break that, as measured on the 140 Shipmaster files:

| | |
|---|---|
| one name, two quays | Almas Thirr's sea routes leave 13,500 units from its river routes |
| two names, one quay | Hlaalu Ferry / Maar-Bani Crossing are 278 apart; Llothanis / Llotharis are one place spelled two ways |
| neighbours | Vos and Tel Mora are 5,183 apart; the Vos quay for Tel Mora is 3,400 from the main one |

So each route is tested directly:
- its departure end must be within 8,000 units of the shipmaster;
- its arrival end must be within 8,000 of the destination point in the shipmaster's record;
- **its names must agree with the cells' names** when the cell's name is a route name.

Names bind because Immersive Travel's route names *are* cell names (it pairs routes with destinations by `cell.name`). Position alone put Sadrith Mora's Tel Mora passengers on the Sadrith Mora → Vos ship.

A route sailed in its authored direction beats one sailed backwards. A route missing in one direction is sailed backwards from the other.

**On vanilla data:**
- 21 of the 45 destinations the 15 vanilla shipmasters sell have a route. The other 24 go through *Other destinations*.
- Immersive Travel's Solstheim routes (Fort Frostmoth, Raven Rock) are drawn for a relocated Solstheim, 73,000 units from the vanilla one, so they never match vanilla shipmasters. That is correct: sailing them would end at sea.

---

## The vessels (`shipping_db.lua`)

| IT mount | vessel | mesh | origin | player slot | helm |
|---|---|---|---|---|---|
| `a_DE_ship` | Ship | vanilla `x/Ex_DE_ship.nif`, turned 180° | 20 below the route | bow deck, z 257 | quarterdeck, z 368 |
| `a_longboat` | Longboat | vanilla `x/Ex_longboat.nif`, turned 180° | 74 above the route | bow, z −57 | stern, z −58 |
| `a_telvboat` | (falls back to the longboat) | `x/dim_telvcatboat.nif`, not in vanilla | | | |

- **Same hulls as IT's.** IT's `_rot` meshes are the vanilla hulls turned half a turn and nothing else (their boxes are the vanilla boxes mirrored), so the vanilla meshes with `yawOffset = pi` sail without IT's assets.
- **Slot heights are measured,** by deck raycasts against the spawned hull in OpenMW 0.52. IT's heights put the player 2.7 units under the longboat's floor and the shipmaster 4.7 under the ship's quarterdeck. A pinned actor has to start each frame just above what they stand on.
- **Which vessel sails which route** is Immersive Travel's `override_mount` rule, resolved once by the importer and stored per route.

---

## Settings

Under **Shipping** on the WhyWalk page:

- **Animated voyages**: on. Off gives the ordinary travel window.
- **Sailing speed**: 1600 u/s in open water. The median route is about 100,000 units, so about a minute; the longest (Ebonheart ↔ Sadrith Mora, 449,000) is about five.
- **Advance the clock to match**: on. Tops up to vanilla's hours on arrival.
- **Walk the deck**: on. Off pins you to the bow deck for the voyage.
- **Seat the passenger**: off. Sits on deck if an animation pack provides a seated pose. Only with *Walk the deck* off.

### Fare and clock are vanilla's

- **Fare.** TravelWindow::addDestination and getBarterOffer, exactly: the 3D distance, `int(d / fTravelMult)`, followers, then `int(price × buyTerm)`. Checked against Gals Arethi's own window in Sadrith Mora: 44 / 58 / 26 / 52 gold, identical.
- **Hours.** Vanilla's straight-line hours, not the route's. A ship goes round the coast: Ebonheart → Sadrith Mora is 447,000 units of route against 186,000 straight, so charging the route would cost 27 hours where vanilla charges 11.

---

## Files

```
WhyWalk_Shipping.omwscripts
scripts/WhyWalk/Shipping/
  shipping_routes.lua   GENERATED route geometry + vessel per route (context: none)
  shipping_path.lua     the route walker; a COPY of caravans_path.lua (context: none)
  shipping_stops.lua    which route serves a guide and destination  (context: none)
  shipping_deck.lua     who is carried while walking, and the carry  (context: none)
  shipping_db.lua       vessels, slots, ramps, fare, hours           (context: none)
  shipping_global.lua   the voyage                                   (context: global)
  shipping_player.lua   interception, menu, settings, pose           (context: player)
tools/
  import_routes.py      regenerates shipping_routes.lua from Immersive Travel
  test_shipping.lua     41 checks: data, matching vs an independent Python
                        implementation over every vanilla shipmaster,
                        vessels, the voyage profile on every route, fare,
                        and who the deck carries
  test_intercept.lua    20 checks on Caravans' engine model: the menu,
                        "Other destinations", booking, aboard, no UI Toolkit
  fixture_vanilla.lua   the vanilla shipmasters and their destinations
  check_shared.py       fails if shipping_path.lua drifts from Caravans' copy
  check_all.sh          everything above plus the suite's static checks
```

**The walker is a copy, deliberately.** It is pure and module-agnostic, and one copy per module means neither module needs the other. `check_shared.py` turns drift into a test failure. Moving it to Core would remove the copy, at the price of making Core a hard dependency of both modules.

### Regenerating the routes

```
python3 tools/import_routes.py "<Immersive Travel>/MWSE/mods/rfuzzo/ImmersiveTravel" scripts/WhyWalk/Shipping/shipping_routes.lua
```

The importer:
- lower-cases names;
- keeps the longer file of any duplicate pair;
- removes repeated points;
- drops any route with an out-and-back spike: a turn over 150° between two legs each over 5× the route's median leg. Caravans' "longest leg over 10× the median" rule condemns good sea routes, whose open-water legs are long and straight.

---

## Known limitations

- **The vessel is spawned, not the ship moored at the quay.** There is a moored hull within about 400–1,500 units of 14 of the 15 vanilla shipmasters (the list is in the data report). Sailing *that* ship is the natural next step.
- **Deck walking is tested with Core's MWScript pin.** Without Core's plugin the pin falls back to a Lua teleport every frame; see the test report for how that behaves.
- **Followers and other NPCs are not carried** when they walk the deck; only the player is.
- **No collision.** Routes are authored to clear the coast, and nothing checks.
  - **Land.** Sampled every 64 units against vanilla terrain, 7 of the 69 routes in vanilla's area cross land:
    - Fort Frostmoth ↔ Raven Rock (5,120 units, relocated Solstheim anyway);
    - five Ebonheart / Old Ebonheart / Andothren legs (1,216–2,944 units each), around (2,400–5,800, −120,000) south of Ebonheart, where Tamriel Rebuilt's terrain may differ;
    - Ebonheart → Tel Branora, a vanilla pair (1,280 units, ground up to +36 at (38,555, −116,920)).
  - **Shallow water.** Several more run through water shallower than the hull's draft, which shows as the keel in the sea bed.
  - The full list is in the data report.
- **Followers are not carried.** The fare is charged for none, as Caravans does. The engine charges for followers and teleports them with you; *Other destinations* still does.
- **Passenger slots 2–5 are measured but unused.**
