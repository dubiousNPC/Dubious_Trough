# Building Lua-tracked HUD widgets for OpenMW

A guide to the mod format and texture toolchain developed for MoonHUD and
BSCompass, and how to reuse both for other on-screen elements.

The two existing widgets look unrelated — one shows moon phases, the other a
rotating compass — but they are the same machine with different data plugged in.
This document describes that machine so a third, fourth or tenth widget costs a
day rather than a fortnight.

---

## Contents

1. [What the pattern is for](#1-what-the-pattern-is-for)
2. [Anatomy of a widget mod](#2-anatomy-of-a-widget-mod)
3. [The tracker: getting a value](#3-the-tracker-getting-a-value)
4. [Settings: presets and bundled renderers](#4-settings-presets-and-bundled-renderers)
5. [The HUD: the performance contract](#5-the-hud-the-performance-contract)
6. [The atlas contract](#6-the-atlas-contract)
7. [Toolchain reference](#7-toolchain-reference)
8. [Verification](#8-verification)
9. [Worked example: a fatigue dial](#9-worked-example-a-fatigue-dial)
10. [Hard-won notes](#10-hard-won-notes)

---

## 1. What the pattern is for

Any HUD element where:

- some game value changes over time,
- that value maps onto a **small set of discrete visual states**, and
- you want it drawn from artwork rather than text.

Moon phase → 8 states. Compass heading → 36 or 360 states. Fatigue → however
many frames you draw. Weather, day/night, disease, encumbrance, spell readiness,
faction standing all fit.

It is *not* the right pattern for continuously interpolated visuals — a smooth
sweeping bar with no quantisation is better served by resizing a single texture
than by an atlas. The atlas approach wins when each state is a distinct drawing.

### Why quantisation is a feature

Both existing widgets exploit it. BSCompass swaps texture only when the heading
crosses into a new frame — with 36 frames that is once per 10° of turn, and never
at all while standing still. The visual is "smooth enough" and the per-frame cost
collapses to an integer compare. Choose the smallest frame count that looks right,
not the largest you can generate.

---

## 2. Anatomy of a widget mod

```
MyWidget/
  mywidget.omwscripts          manifest: MENU renderers, then PLAYER scripts
  scripts/
    SuperSettingsRenderers/    bundled verbatim, never edited
    mywidget/
      MW_constants.lua         data, model, atlas layout — no side effects
      MW_tracker.lua           PLAYER: reads the game, exposes an interface
      MW_settings.lua          settings definitions, mirrored into globals
      MW_hud.lua               PLAYER: the widget itself
      MW_border.lua            shared border templates (copied unchanged)
  textures/mywidget/           atlases and panel art
  dev/
    load_check.lua             stubbed OpenMW, executes the scripts
    check_all.sh               runs everything
    test_*.lua                 model tests
  README.md
```

### The manifest

```
# Renderers first: a renderer must exist by the time a settings group names it.
# demoSettings.lua is deliberately not listed; it only adds a demo page.
MENU: scripts/SuperSettingsRenderers/SuperSlider6.lua
MENU: scripts/SuperSettingsRenderers/SuperColorPicker4.lua
MENU: scripts/SuperSettingsRenderers/SuperKeybind2.lua
MENU: scripts/SuperSettingsRenderers/SuperSelect3.lua
MENU: scripts/SuperSettingsRenderers/optionalRenderer1.lua

PLAYER: scripts/mywidget/MW_tracker.lua
PLAYER: scripts/mywidget/MW_hud.lua
```

`#` comments are legal in `.omwscripts`; OpenMW's Lua documentation shows them.
Order determines load order, and **MENU entries must precede PLAYER entries**.

Bundling the renderers means the settings page has no external dependency. If
another installed mod bundles the same ones, both register — that is harmless. A
duplicate `registerRenderer` is logged and ignored. A duplicate settings **group**
is fatal, which is why group keys are namespaced `Settings<ModName><Group>`.

### Why the tracker and the HUD are separate scripts

The tracker answers "what is the value". The HUD answers "how does it look".
Splitting them means:

- other mods can consume your data through the interface without your UI,
- the HUD can be rewritten without touching the model,
- the model is testable offline, because it has no UI dependencies.

MoonHUD's tracker is used by its HUD but exposes `daysUntil`, `isShadeDay` and
`upcomingShades` for anything else that wants them.

---

## 3. The tracker: getting a value

### Tier your fallbacks to match reality

The instinct is to write one call and trust it. Most OpenMW APIs are conditional.
`core.weather.getCurrentMoons()` returns `nil` in interiors and inactive cells —
which is most of play — so MoonHUD needs four tiers:

| Tier | `source` | When | Accuracy |
|---|---|---|---|
| 1 | `engine` | active exterior cell | exact |
| 2 | `projected` | interior, with a prior reading | exact while calibrated |
| 3 | `formula` | no reading yet | correct phase, boundary may be a day out |
| 4 | `fixture` | day index unavailable | recorded observation table |

**Match the tier depth to the data.** Player stats are always readable, so a
fatigue widget needs one tier. Weather needs two. Anything derived from an
active-cell query needs three or four. Do not build four tiers out of habit.

Always report which tier answered. Both widgets expose it as a debug setting, and
it is the first thing you want when something looks wrong in game.

### Self-calibration

When a fallback needs a constant you cannot read directly, derive it from the
authoritative source while that source is available.

MoonHUD's day counter differs from the engine's `DaysPassed` by an unknown but
constant offset. Rather than guess, it keeps a candidate set of all 24 possible
offsets and intersects it against every real reading. It converges within a day or
two of outdoor play and is persisted in the save.

Two things that pattern taught:

- **Know your information limit.** Sampling only at one time of day leaves *two*
  adjacent candidates standing forever, because "offset K, rolled over" and
  "offset K+1, not yet" predict identical output. That is not a bug to fix; it is
  the data being insufficient. Report it (`getStatus().exact`) rather than
  pretending to a precision you do not have.
- **Handle contradiction.** If the candidate set empties — console time travel, a
  transplanted save — restart calibration from the current reading instead of
  serving stale values.

### Interface shape

```lua
local interface   -- forward declaration: the methods call each other, and a
                  -- local is only in scope AFTER its declaring statement

interface = {
    version = C.VERSION,
    getValue = function() ... end,
    getStatus = function() ... end,   -- diagnostics: tier, calibration, raw input
    constants = C,
}

return {
    interfaceName = 'MyWidget',
    interface = interface,
    engineHandlers = {
        onInit = onLoad, onLoad = onLoad,
        onSave = function() return saveData end,
    },
}
```

The forward declaration is not stylistic. Writing `local interface = { ... }` and
referring to `interface` inside those functions binds to a **global** that is nil,
and it fails only when called.

Send an event on change so consumers do not have to poll:

```lua
self:sendEvent('MyWidget_Changed', { from = old, to = new })
```

---

## 4. Settings: presets and bundled renderers

### Mirror settings into globals

Every setting is copied into a global of the same name, and the HUD reads the
global. A `storage` lookup per frame is far more expensive than a global read, and
`onFrame` is the hot path.

```lua
local function readAllSettings()
    for _, template in pairs(settingsTemplate) do
        local section = storage.playerSection(template.key)
        for _, entry in pairs(template.settings) do
            local val = section:get(entry.key)
            if val == nil then val = entry.default end
            _G[entry.key] = normalise(entry.key, val)
        end
    end
end
```

Then subscribe, and split changes into three classes:

| Class | Response |
|---|---|
| **RETILE** — atlas path, frame count, cell size | rebuild the texture array, then rebuild the tree |
| **REBUILD** — border, padding, layout, shape | rebuild the element tree |
| everything else | poke `props` on the live element |

Getting this wrong is not subtle: change the atlas and forget to retile and you
keep showing frames cut from the old sheet.

### Presets over paths

Do not make users type VFS paths. Give a `select` of bundled options plus
`Custom`, and keep the list in constants so the settings page and the resolver
cannot drift:

```lua
-- MW_constants.lua
M.TEXTURE_DIR = 'textures/mywidget/'
M.ATLAS_PRESETS = { 'dial_brass', 'dial_iron', 'dial_bone' }

function M.presetPath(name)
    if name == nil or name == '' or name == 'Custom' or name == 'None' then
        return nil
    end
    return M.TEXTURE_DIR .. name .. '.png'
end
```

Where presets differ in *geometry*, not just art, put the geometry in the preset.
BSCompass does this because its sheets genuinely differ — 36 frames in one column
versus 360 in thirty — and no user should have to keep those in sync by hand:

```lua
ATLAS_PRESETS = {
    ['BSCompasAtlas']     = { path = ..., frames = 36,  cols = 1,  cell = 88 },
    ['BSCompasAtlas_360'] = { path = ..., frames = 360, cols = 30, cell = 88 },
}
```

### The renderer helper block

If you use SuperSettingsRenderers, this block goes at the top of every settings
file. `SUPER = true` is safe **because the renderers are bundled**:

```lua
local SUPER = true
local R_SLIDER = SUPER and 'SuperSlider6'      or 'number'
local R_SELECT = SUPER and 'SuperSelect3'      or 'select'
local R_COLOR  = SUPER and 'SuperColorPicker4' or 'textLine'

local function sliderArg(min, max, step, unit)
    if SUPER then
        return { min = min, max = max, step = step or 1, unit = unit or '',
                 showResetButton = true, tinyReset = true, width = 200 }
    end
    return { min = min, max = max }
end

local function selectArg(items)
    if SUPER then return { items = items, l10n = 'none', width = 170 } end
    return { disabled = false, l10n = 'none', items = items }
end
```

Copying settings between mods without this block is exactly how MoonHUD once shipped
calling a nil `sliderArg`, which killed the script — no settings page, no widget.

---

## 5. The HUD: the performance contract

`onFrame` runs every frame for every player. Six rules, all load-bearing:

**1. Build every texture once.** Never call `ui.texture` in `onFrame`. Cut all
frames at load into a flat array:

```lua
function rebuildTiles()
    local geo = atlasGeometry()
    tiles = {}
    for i = 0, geo.frames - 1 do
        local row, col = math.floor(i / geo.cols), i % geo.cols
        local ok, tex = pcall(ui.texture, {
            path   = geo.path,
            offset = v2(col * geo.cell, row * geo.cell),
            size   = v2(geo.cell, geo.cell),
        })
        tiles[i + 1] = ok and tex or nil
    end
end
```

**2. Gate on a single boolean.** When hidden — indoors, HUD toggled off, menu open
— return after one test. Recompute that boolean on `UiModeChanged`, not per frame.

**3. Early-out when nothing changed.** Compute the frame index, compare, return if
equal. This is the common case.

**4. Allocate nothing.** No `util.vector2`, no closures, no string concatenation,
no table literals in the hot path. Locals and numbers only.

**5. Only `:update()` on actual change.** It is the expensive call.

**6. Offer a sample interval.** Turning is continuous, so checking every second or
third frame is imperceptible and does proportional work.

The whole of BSCompass's hot path:

```lua
local function onFrame()
    if not hudActive then return end                    -- 2
    frameCountdown = frameCountdown - 1                 -- 6
    if frameCountdown > 0 then return end
    frameCountdown = SAMPLE_EVERY or 2

    local tile = tileForHeading(headingDegrees())       -- 4
    if tile == currentTile then return end              -- 3

    local tex = tiles[tile + 1]                         -- 1
    if tex == nil then return end
    currentTile = tile
    compassImage.props.resource = tex
    compassHud:update()                                 -- 5
end
```

Prefer cheap reads: `camera.getYaw()` is a scalar, where
`camera.viewportToWorldVector()` does a matrix transform and degenerates at
extreme pitch.

---

## 6. The atlas contract

### Layout

Frames are read **row-major**: `index = row * cols + col`. A vertical strip is the
`cols = 1` case, so one code path covers both. Frame 0 is the zero state — north
for a compass, full for a moon, empty for a meter.

Multi-subject sheets add rows: MoonHUD is 8 columns × 3 rows, row 0 Masser, row 1
Secunda, row 2 the Shade indicator.

### Texture size is a hard limit

**16384px on most hardware.** This is not theoretical:

| Frames | Cell | As a strip | Verdict |
|---|---|---|---|
| 36 | 88 | 88 × 3168 | fine |
| 360 | 88 | 88 × **31680** | impossible |
| 360 | 88 | 2640 × 1056 (30 cols) | fine |

Anything past roughly 180 frames must be a grid. `expand_compass_atlas` refuses to
write an oversized strip rather than producing a file that fails silently on
someone else's GPU.

### Art rules that survive downsampling

Atlases are drawn supersampled and reduced. **Anything thinner than about 0.05 ×
the cell disappears.** Two variants once shipped visually identical because their
outline and ring were sub-pixel after reduction; both needed roughly doubling.

Related: **make asymmetric things obviously asymmetric.** A near-symmetric compass
needle rotates correctly and is still unreadable, because you cannot tell which end
is north. Differentiate by shape *and* colour — BSCompass's north is a wide kite in
the bright texture, south a narrow spike in the bezel texture.

Keep art clear of the cell edge. Celestial tick marks that reached the boundary
chained all eight moons into one dashed line across the strip.

### Rotation direction

For a world-fixed marker, the frame index must advance as the heading **decreases**:

```lua
frame = (frames - round(heading / step)) % frames
```

Note the subtraction. The naive `round(heading / step)` is backwards: a marker fixed
in the world rotates counter-clockwise on screen as you turn clockwise. Provide an
`Invert Rotation` setting anyway, so wrong-handed artwork is a tick rather than a
patch.

### Overlays

When a sheet animates only a moving part — a needle over a static frame — express
placement as **fractions**, not pixels, so it survives any display size:

| Setting | Meaning |
|---|---|
| Pivot X / Y | where the frame centre sits, as a percentage of overlay size |
| Frame Scale | frame size as a percentage of overlay width |
| Overlay Layer | static art behind the moving part, or in front |

Derive those by measuring the source art rather than eyeballing. For the DBS
compass the pivot was at (919.5, 803) of a 1785 × 1610 canvas with the cell covering
a 242px box, giving 51.5% / 49.9% / 13.6% — which composited within 0.2px of how the
two source files align natively.

---

## 7. Toolchain reference

`generate_hud_atlases.sh` is sourceable or standalone. Set `MAGICK=` to point at
ImageMagick 7 if `magick` is not on your path.

```sh
source ./generate_hud_atlases.sh
```

### Generic

| Function | Purpose |
|---|---|
| `generate_atlas <cols> <rows> <out> <tile>...` | montage tiles into a grid |
| `generate_progressive_atlas -i -o -r -c [-m] [-w] [-d]` | build frames by progressively transforming one source |
| `expand_compass_atlas -i -o --in-frames --out-frames [--in-cols] [--out-cols]` | resample an atlas to a different frame count |

`generate_progressive_atlas` has three modes and is the most reusable function here:

| Flags | Behaviour | Use for |
|---|---|---|
| *(none)* | progressively `-roll` the source | scrolling and cycling strips |
| `-m` | progressively blacken a growing slice | fill meters |
| `-m -d` | delete that slice instead | transparent meters |
| `-w` | operate on width instead of height | horizontal bars |

### Subject-specific

| Function | Purpose |
|---|---|
| `generate_moon_phase` / `generate_moon_atlas` | lunar phases with real terminator geometry |
| `generate_shade_indicator` | lit/dim state marker |
| `generate_compass_dial` / `generate_compass_atlas` | bezel, face and needle, any frame count and column count |
| `generate_panel_circle` / `generate_panel_ring` | plate and ring for circular panels |
| `generate_panel_background` | `stone` and `linen` panel fills |
| `generate_moonhud_panels` | all four MoonHUD panel textures |

These are worth reading as templates even for unrelated subjects. `generate_moon_phase`
shows mask composition — build a shape mask, build a lit mask, combine, use as alpha —
which generalises to any two-state-per-pixel drawing.

> **Duplicate function warning.** The file contains both `expand_compass_atlas` and an
> older `generate_expanded_atlas`. They are not equivalent. Tested against the real
> 36-frame sheet, `expand_compass_atlas` preserves all 36 source frames bit-exact;
> `generate_expanded_atlas` preserves **0 of 36**, with differences up to 226 levels.
> Use `expand_compass_atlas`. Treat the older one as superseded.

### Theming

`generate_menu.sh` (with `patch_generate_menu.sh` applied) builds a full menu texture
set from three hex colours, and calls into this file so each theme also gets its
widget atlases. It already emits the border textures your widget's `MW_border.lua`
loads — `menu_thin_border_*` and `menu_thick_border_*` — so every theme reskins your
widget's frame for free.

To make your own artwork theme-aware, take the noise textures as arguments the way
the existing generators do:

```sh
generate_my_widget() {
    local face_texture="$1"   # noise_base.dds      -- primary/background
    local accent_texture="$2" # noise_highlight.dds -- secondary/accent
    ...
}
```

Then a theme drives your widget with no extra work.

---

## 8. Verification

**`luac -p` is not enough.** It checks syntax. It will happily pass a call to a nil
global, which is precisely how both widgets once shipped broken — the settings page
and the widget both vanish, because a load-time error stops the whole file.

`dev/load_check.lua` stubs the OpenMW API, executes the scripts for real, runs
`onInit` and `onFrame`, and reports what was registered:

```sh
texlua dev/load_check.lua . scripts/mywidget/MW_tracker.lua scripts/mywidget/MW_hud.lua
```

It also cross-checks the renderer bundle: a renderer named by a setting must be
**both present on disk and listed as a MENU script**. Shipping the file without the
manifest entry is silent breakage, so those are verified separately, and the
file-without-manifest case is a hard error.

`PRESEED` forces settings values so code paths behind a non-default preset actually
execute:

```sh
PRESEED="ATLAS_PRESET=dial_iron,LAYOUT=Triangle" texlua dev/load_check.lua . ...
```

`dev/check_all.sh` drives all of it: model tests, the bundled renderers, then every
preset and layout combination. Run it after editing anything under `scripts/`.

When extending the harness, expect to add stubs — that is normal and does not mean
the mod is broken. Confirm which side is at fault before "fixing" working code.
Stubs already needed: vector arithmetic metamethods, `content:insert`,
`ui._getMenuTransparency`, `scripts.omw.mwui.constants`, `storage:setLifeTime`,
`I.MWUI`, `core.l10n`, `input.CONTROLLER_BUTTON`, `ui.screenSize`.

---

## 9. Worked example: a fatigue dial

A dial that fills as fatigue drops. It exercises `generate_progressive_atlas`, which
neither existing widget uses.

### Decide the states

Fatigue is continuous 0–1. Twenty frames gives 5% granularity — plenty, and it means
the texture swaps at most twenty times across a full drain.

### Generate the atlas

Draw one full dial, then let the toolchain produce the intermediate frames:

```sh
source ./generate_hud_atlases.sh

# The full state: a ring in the accent colour.
magick -size 128x128 xc:none \
    -fill none -stroke "#caa560" -strokewidth 14 \
    -draw "circle 64,64 64,10" \
    -define dds:mipmaps=0 -define dds:compression=None dial_full.png

# 20 frames, blackening from the top down: frame 0 full, frame 19 empty.
generate_progressive_atlas -i dial_full.png -o fatigue_atlas.png -r 4 -c 5 -m
```

That is a 4 × 5 grid of 128px cells — 640 × 512, comfortably inside limits. Use
`-m -d` instead if you want the drained portion transparent rather than black.

Verified: the commands above produce a 640 × 512 sheet whose remaining gold pixels
fall monotonically from 5101 at frame 0 to 0 at frame 19.

### Constants

```lua
M.TEXTURE_DIR = 'textures/fatiguehud/'
M.ATLAS = { path = M.TEXTURE_DIR .. 'fatigue_atlas.png',
            frames = 20, cols = 5, cell = 128 }

--- Fraction 0..1 to frame index. Frame 0 is full.
function M.frameForFraction(f, frames)
    if f ~= f then return 0 end                     -- NaN guard
    f = math.max(0, math.min(1, f))
    local i = math.floor((1 - f) * (frames - 1) + 0.5)
    return math.max(0, math.min(frames - 1, i))
end
```

Verified across 1001 inputs: always in range, all 20 frames reachable, monotonic,
and the clamps and NaN guard behave.

### Tracker

Player stats are always readable, so **one tier is correct here**. Do not invent
fallbacks the data does not need:

```lua
local function fatigueFraction()
    local ok, dyn = pcall(types.Actor.stats.dynamic.fatigue, self)
    if not ok or dyn == nil then return nil end
    local base = dyn.base
    if base == nil or base <= 0 then return nil end
    return dyn.current / base
end
```

Return `nil` rather than a guess when the read fails, and let the HUD decide
whether to hide.

### HUD

Identical to BSCompass's hot path, with one difference worth noting: fatigue changes
constantly in combat, so a stale-value early-out matters more than a sample interval.
The frame index only moves every 5% of fatigue, so the early-out does the work.

```lua
local function onFrame()
    if not hudActive then return end
    local f = I.FatigueTracker.getFraction()
    if f == nil then return end
    local frame = C.frameForFraction(f, C.ATLAS.frames)
    if frame == currentFrame then return end
    currentFrame = frame
    dialImage.props.resource = tiles[frame + 1]
    dialHud:update()
end
```

### Reuse the rest

Copy `MW_settings.lua` wholesale and change the group keys and entries; copy
`MW_border.lua` unchanged; copy `dev/load_check.lua` and `dev/check_all.sh` and edit
the script paths. The panel, border, position, opacity and visibility settings all
work as-is, because none of them know what the widget displays.

---

## 10. Hard-won notes

Each of these cost real debugging time.

### Lua and OpenMW

| Note |
|---|
| `local interface = { ... }` — methods referring to `interface` inside bind to a nil **global**. Forward-declare. |
| `luac -p` does not catch nil globals. Use the load harness. |
| A load-time error takes out the settings page **and** the widget. Missing settings page is the symptom to look for. |
| Duplicate `registerRenderer` is logged and ignored. Duplicate settings **group** is fatal — namespace group keys. |
| MENU entries must precede PLAYER entries in `.omwscripts`. `#` comments are legal. |
| A bundled renderer must be on disk **and** in the manifest. Either alone fails silently. |
| `core.weather.getCurrentMoons()` returns `nil` in interiors and inactive cells. Assume any active-cell query can. |
| Read settings from mirrored globals, not `storage`, in `onFrame`. |

### Layout

| Note |
|---|
| A circle enclosing a box needs the **diagonal**, `sqrt(w² + h²)`, not `max(w, h)`. A 40 × 124 stack needs 130, not 175. |
| Size text cells from the longest string the settings can produce. `FONT_SIZE * 5` assumes five characters; "Waning Crescent" is fifteen. |
| Centre content on a circular plate for every layout, not just the one you tested. |

### ImageMagick

| Note |
|---|
| `-compose Overlay` **preserves black**. Any theme with a black primary gets a flat panel. Use a linear blend: `-compose Mathematics -define compose:args="0,0.30,0.80,-0.12"`. |
| `trap ... EXIT` inside `$( )` fires when the substitution subshell ends and deletes your temp directory. Set a global from a plain statement instead. |
| A vertical roll must use the image **height**. Using width only closes the loop on square inputs. |
| When resampling an atlas, rotate from the **nearest** source frame, not from frame 0 — bounded blur, and source frames stay bit-exact. |
| `magick compare -metric AE` is the honest diff. Comparing RGB in fully transparent pixels reports differences that do not exist. |

### Process

| Note |
|---|
| Render it and look. Clipped labels, indistinguishable variants and chained tick marks were all invisible in code review. |
| Then measure it, because looking is also unreliable — an arrow I judged misaligned was correct to 0.2px. |
| Verify the measurement tool before trusting the measurement. A "36/36 frames differ" result and a needle rotation that seemed 4% slow were both broken checks, not broken output. |
| Test the negative case. A check that has never failed has not been shown to work. |

---

## Summary

Four files and one contract:

- **constants** hold the model and the atlas geometry, with no side effects
- **tracker** turns the game into a value, with tiers matched to what the API
  actually guarantees, and reports which tier answered
- **settings** mirror into globals and split changes into retile, rebuild, or poke
- **hud** builds every texture once, gates on a boolean, early-outs on no change,
  and allocates nothing per frame

The atlas contract is row-major indexing, frame 0 as the zero state, and a hard
16384px ceiling that forces grids past ~180 frames.

Everything else — borders, panels, presets, position, opacity, the check harness —
is subject-agnostic and copies across unchanged.
