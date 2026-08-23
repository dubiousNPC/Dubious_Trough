# BSCompass

A dial compass HUD for OpenMW, driven by a vertical texture atlas.

Built to sit alongside TimeHUD and LocationHUD — same settings layout, same
drag-and-scroll gestures, same border textures.

---

## Install

Copy the `BSCompass` folder into your data directories, then in the launcher:

1. **Data Files → Data Directories** → add the folder containing `BSCompass`
2. **Data Files → Content Files** → tick `bscompass.omwscripts`

Settings live under **Options → Scripts → BSCompass**.

### Dependencies

**SuperSettingsRenderers** — for the sliders, selects and colour wheel on the
settings page. If you don't have it, open `scripts/bscompass/BSC_settings.lua` and
change one line near the top:

```lua
local SUPER = false
```

That falls the page back to OpenMW's built-in renderers. Nothing else changes.

Nothing else is required.

---

## A note on ErnCompass

You asked for ErnCompass as a dependency. It can't be one in the literal sense —
`compass_p.lua` returns only `engineHandlers` and `eventHandlers`, with no
`interfaceName` and no `interface` table, so there is nothing for another script to
`require` or call. It's a self-contained widget, not a library.

So BSCompass is standalone. What it does take from ErnCompass:

- the same heading convention, so the two always agree on which way you're facing
- the same drag-to-move and scroll-to-resize gestures
- the same `HUDTransparencyChange` event handling, so both fade together
- the same "outdoors only" default

**They coexist happily.** ErnCompass gives you the 16-wind text (`NNE`), BSCompass
gives you the dial. Run both if you want both, or just this one.

One deliberate difference: ErnCompass reads the heading with
`camera.viewportToWorldVector()`, which does a matrix transform and degenerates when
you look straight up or down. BSCompass uses `camera.getYaw()`, a scalar read that is
both cheaper and well-defined at every pitch.

---

## Performance

This was the brief, so here's exactly what it does per frame.

**Cost when hidden** — indoors, HUD toggled off, or in a menu — is one boolean test
and a return. No heading read, no arithmetic, no allocation.

**Cost when visible**, per frame:

1. Decrement a counter. If it hasn't hit zero, return. (`Sample Every N Frames`,
   default 2.)
2. One `camera.getYaw()`, one modulo, one floor. All scalar.
3. Compare against the current frame index. **If unchanged, return** — this is the
   common case.
4. Only on change: assign a texture reference and call `:update()`.

With a 36-frame atlas each frame covers 10°, so step 4 fires once per 10° of turn.
Standing still it never fires at all.

**What is not done per frame:**

- `ui.texture` is never called. All 36 textures are built once at load and cached in
  a flat array. Rebuilt only if you change an atlas setting.
- No table is allocated in `onFrame`. No `util.vector2`, no closures, no string
  concatenation.
- Settings are read from Lua globals, not from `storage`, because a storage lookup
  per frame is far more expensive than a global read. The settings module mirrors
  them into globals on change.
- The element tree is never rebuilt while running. Style changes poke `props`
  directly; only structural changes (border, padding, lock) rebuild.

If you want it cheaper still, raise `Sample Every N Frames`. At 3 the compass is
still visually smooth and does a third of the sampling work.

---

## The atlas

`textures/bscompass/BSCompasAtlas.png` is **88 × 3168** — a vertical strip of 36
frames, 88 × 88 each, top to bottom, starting at north.

Each frame is 10° of heading. The needle rotates clockwise by exactly 10° per frame
index; measured across all 36 frames the mean is **−10.00°** and the loop closes at
exactly −360°.

To use your own strip, set **Atlas Path**, **Atlas Tile Count** and **Atlas Tile
Size**. Any frame count works — 8, 16, 64, 360 — as long as the frames are evenly
spaced and frame 0 is north.

### Which way does it turn?

The mapping is:

```lua
frame = (tileCount - round(headingDegrees / step)) % tileCount
```

Note the **subtraction**. A world-fixed marker has to rotate *counter*-clockwise on
screen as you turn clockwise. Since this artwork's needle rotates clockwise with
increasing frame index, the index has to advance as the heading *decreases*.

Sanity check in game: **face north, then turn right. The needle should swing left.**
If it swings right, tick **Invert Rotation** and it's fixed.

For what it's worth, the artwork's long arm points **south**, not north — frame 0
(facing north) has it pointing down, frame 18 (facing south) has it pointing up.
That's consistent at all four cardinals and across the full sweep, so it's the
design, not an indexing error. If you expected the long arm to be the north head,
that's the thing to look at first.

---

## Settings

### General

| Setting | Default | Notes |
|---|---|---|
| HUD Display | Always | Always / Interface Only / Hide on Interface / Hide on Dialogue Only / Never |
| Lock Position | off | Disables click-and-drag |
| X / Y Position | top right | Also set by dragging |
| Only display outdoors | **on** | Also means zero per-frame work indoors |

### Compass

| Setting | Default | Notes |
|---|---|---|
| Size | 88 px | Atlas tile is 88, so 88 is 1:1 |
| Opacity | 1.0 | |
| Tint | white | Multiplied over the artwork |
| Facing Source | Camera | Camera follows the view (incl. third person); Body follows the character |
| Invert Rotation | off | Flip if the needle turns the wrong way |
| Heading Offset | 0° | Rotates the artwork, for atlases that don't start at north |
| **Sample Every N Frames** | 2 | Raise to do less work |
| Atlas Path / Tile Count / Tile Size | bundled / 36 / 88 | |

### Frame

Background on/off and opacity, border on/off, style (thin / normal / thick /
verythick), colour, padding. Border textures and styles are shared with TimeHUD,
LocationHUD and Quickloot. Both background and border default **off**, since the
artwork already has its own bezel.

---

## Tests

`dev/test_heading.lua` verifies the heading maths offline — **97 assertions**, no
game needed:

- the atlas rotates −10.00° per frame and closes a full −360°
- every frame is reachable and covers exactly 10° of heading
- a world-fixed marker counter-rotates correctly at all 36 headings
- the four cardinals, and that the needle tracks south to within 1.8° across the
  full sweep
- inverted mapping is an exact mirror
- heading offset shifts the right way
- 4-, 8-, 16-, 32-, 64- and 360-frame atlases all use every frame

Run with any Lua 5.3+:

```bash
lua dev/test_heading.lua
```

`dev/` is not loaded by the game and can be deleted.

---

## Credits

- Border template module reused unchanged from TimeHUD / LocationHUD
  (`TH_makeborder.lua`).
- Structure and gesture handling follow TimeHUD and ErnCompass.
- The pre-built-texture-array approach is the one Talk To The Hand uses for its own
  compass, which is the right way to do this.
- `BSCompasAtlas.png` is yours; it ships here unmodified.
