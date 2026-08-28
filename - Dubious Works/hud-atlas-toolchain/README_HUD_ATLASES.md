# HUD atlas generation

Extends the menu texture pipeline to build the atlases the Lua HUD widgets read,
so a theme's palette drives the moon phases and compass dial as well as the menus.

## Files

| File | What it is |
|---|---|
| `generate_hud_atlases.sh` | **New.** Moon and compass atlases, plus a shell port of `make_atlas.ps1`. Sourceable or standalone. |
| `patch_generate_menu.sh` | **New.** Applies five fixes to your `generate_menu.sh` and hooks the generator in. Idempotent, backs up first. |
| `generate_all_menus.sh` | **Rewritten.** Same output, table-driven, can build a subset. |

## Quick start

```sh
cp generate_hud_atlases.sh patch_generate_menu.sh /path/to/your/menu/scripts/
cd /path/to/your/menu/scripts/
./patch_generate_menu.sh
./generate_all_menus.sh Cobalt
```

You get `Cobalt/Textures/` containing the usual menu textures plus
`moon_atlas.dds` (512×192) and `compass_atlas.dds` (88×3168).

Point the mods at them:

- **MoonHUD** → Settings → Moons → Atlas Path → `textures/moon_atlas.dds`
- **BSCompass** → Settings → Compass → Atlas Path → `textures/compass_atlas.dds`

Or drop them in `textures/moonhud/` and `textures/bscompass/` to keep the defaults.

## The thing you already had

`generate_menu.sh` was already generating your HUD border textures. Line 566:

```sh
generate_frame_textures 512 512 1 noise_active.dds noise_highlight.dds "menu_thin_border"
generate_frame_textures 512 512 2 noise_active.dds noise_highlight.dds "menu_thick_border"
```

`BSC_border.lua` / `TH_makeborder.lua` load:

```lua
local borderSidePattern   = 'textures/menu_%s_border_%s.dds'
local borderCornerPattern = 'textures/menu_%s_border_%s_corner.dds'
```

Exact match, `thin`/`thick` included. Every theme already reskins the borders on
MoonHUD, BSCompass, TimeHUD and LocationHUD. This work just extends that to the
artwork inside them.

---

## `generate_hud_atlases.sh`

### `generate_moon_atlas <lit> <dark> <cell> <output>`

8 columns × 3 rows, matching `MH_constants.ATLAS_ROW`: Masser, Secunda, Shade
indicator. Column order is the engine phase index — Full, WaningGibbous,
ThirdQuarter, WaningCrescent, New, WaxingCrescent, FirstQuarter, WaxingGibbous.

Phase geometry is the real thing, not hand-drawn approximations. The terminator
is a half-ellipse with x semi-axis `r·cos(index × 45°)`: positive bulges outward
for a gibbous, negative bites inward for a crescent. Measured against theory on
the generated output:

| Phase | Generated | Theory |
|---|---|---|
| Full | 100.0% | 100% |
| Waning Gibbous | 86.1% | 85.4% |
| Third Quarter | 51.1% | 50% |
| Waning Crescent | 14.1% | 14.6% |
| New | 0.0% | 0% |

Lit sides verified: indices 1–3 left, 5–7 right.

Row 2 is the Shade of the Revenant indicator — cell 0 lit, cells 1–7 dim, so
indexing that row with anything is safe.

The unlit limb is the dark texture knocked down to 32% value. Using a raw theme
colour leaves the "dark" side as bright as the lit one, which is what the first
draft did and it looked wrong on every palette.

### `generate_compass_dial <face> <bezel> <needle> <cell> <frames> <output>`

Vertical strip, north first, one frame per `360/frames` degrees. The needle
rotates **clockwise** by that step per frame index, which is what BSCompass's
default mapping expects:

```lua
frame = (frames - round(heading / step)) % frames
```

Verified on flat-colour output to remove noise contamination: **worst error 3.76°,
mean 1.77°**, with frames 0 and 9 exact. That residual is polygon rasterisation at
88px and sits well inside a 10° bucket.

Two deliberate choices:

- **The arms are different shapes and different textures.** A symmetric needle is
  unreadable at HUD size — you cannot tell which end is north. North is a wide kite
  in the bright texture, south a narrow spike in the bezel texture.
- **At frame 0 the long arm points up**, so it reads as a north-pointing needle
  when you face north. `BSCompasAtlas.png` is the other way round — its long arm
  points south. Both work; the mapping only cares about rotation direction. If you
  swap between them you should not need to touch **Invert Rotation**.

Also draws a static index notch at the top of the bezel marking the way you face.

### `expand_compass_atlas -i <in> -o <out> --in-frames N --out-frames M`

Resamples an existing compass atlas to a different frame count. The usual job is
**36 → 360**, one frame per degree instead of per ten.

```sh
expand_compass_atlas -i BSCompasAtlas.png -o BSCompasAtlas_360.png \
    --in-frames 36 --in-cols 1 --out-frames 360 --out-cols 30
```

It does not simply rotate frame 0 through a full circle. For each target frame it
picks the **nearest source frame** and applies only the leftover rotation, so the
worst rotation any pixel sees is half a source step — 5° for 36 → 360, not up to
180°. Source frames land on themselves and are copied untouched.

Verified on the real sheet: all **36 source frames survive bit-exact**, and an
interpolated frame matches an independently rotated reference exactly
(`magick compare -metric AE` returns 0).

**Output columns are not optional above ~180 frames.** A 360-frame vertical strip
at 88px is **31680px tall**, past the maximum texture size on essentially every
GPU. The function refuses to write one and tells you to raise `--out-cols`.
30 columns gives 2640×1056, which is comfortable. This is why
`DBS_CompassARROWAtlas.png` is a grid rather than a strip.

`generate_compass_dial` and `generate_compass_atlas` now take a trailing column
count too, so themed dials can be generated at 360 steps directly:

```sh
generate_compass_atlas 88 360 compass_atlas.dds 30
```

### `expand_compass_layered -i <atlas> -p <plate> -o <out> ...`

For a dial whose bezel and glass are **static** and whose needle is the only
moving part. This is the usual case for hand-drawn compass art.

```sh
expand_compass_layered -i BSCompasAtlas.png -p BSCompasEmpty.png \
    -o BSCompasAtlas_360.png --in-frames 36 --out-frames 360 --out-cols 30
```

`expand_compass_atlas` rotates the whole cell, which turns the bezel and the
glass highlight along with the needle. On `BSCompasAtlas` that is plainly wrong:
the needle is meant to sweep *behind* a fixed glass front.

This takes the needle-less plate as a second input, isolates the needle from each
source frame by differencing against it, rotates only that, and recomposites over
the untouched plate.

| Option | Default | Purpose |
|---|---|---|
| `--mode nearest` | default | each frame takes the **nearest** hand-drawn needle and rotates it by the remainder — preserves per-frame shading |
| `--mode single` | | every frame from one needle — smoother, but the shading stops changing |
| `--threshold` | 12 | difference percentage above which a pixel counts as needle |
| `--inner-radius` | 36 | percent of the cell the needle is clipped to |

Two things had to be got right, both found by measuring:

- **Every frame must go through the plate**, including the ones needing no
  rotation. Copying the original frame whole for those looks free, but the source
  frames' bezels differ slightly from the plate, so the bezel flickered every
  time the output crossed a source angle.
- **The needle mask must be clipped to the inner disc.** Without it the
  difference picks up bezel variation too, and compositing that back makes the
  bezel change whenever the chosen source frame does.

With both in place the bezel is bit-identical across all 360 frames — measured
maximum deviation **0**. Needle rotation comes out at -1.002 degrees per frame,
against a target of -1.

Choosing between the two expanders: use **layered** when the artwork has a fixed
frame or housing, and **`expand_compass_atlas`** when the whole cell is meant to
turn, such as a plain rotationally-symmetric dial.

### `generate_moonhud_panels <plate> <ring> <size>`

The four MoonHUD panel textures in one call, named as MoonHUD expects:
`panel_circle.dds`, `panel_circle_border.dds`, `panel_bg_stone.dds`,
`panel_bg_linen.dds`. MoonHUD tints these at runtime, so generating them in the
theme palette and leaving the tint white gives a themed panel with no settings
changes.

Individually: `generate_panel_circle`, `generate_panel_ring`,
`generate_panel_background` (styles `stone` and `linen`).

One trap worth recording. The obvious way to apply grain to a coloured base is
`-compose Overlay`, and it is wrong: Overlay preserves black, so every theme with
a black primary — Royale, Cobalt, Mono, Blood-Raven — produced a completely flat
panel. The generator uses a linear blend instead:

```
-compose Mathematics -define compose:args="0,0.30,0.80,-0.12"
```

which is `0.30*grain + 0.80*base - 0.12`. Measured grain standard deviation across
palettes afterwards: 8.7 to 16.6, against 0.0 with Overlay on a black base.

### `generate_progressive_atlas -i <in> -o <out> -r <rows> -c <cols> [-m] [-w] [-d]`

Shell port of `make_atlas.ps1`, so the whole pipeline runs on one interpreter.
Same three modes:

| Flags | Behaviour |
|---|---|
| *(none)* | progressively `-roll` the source — scrolling and cycling strips |
| `-m` | progressively blacken a growing slice — fill meters |
| `-m -d` | delete that slice instead — transparent meters |
| `-w` | operate on width instead of height |

Two fixes over the original:

- **The roll step used the image width to scroll vertically.** `$scrollAmount` was
  computed from `$OrigWidth` and then applied as `+0+$scrollAmount`, so the loop
  only closed cleanly on square inputs. It now uses whichever axis it is scrolling.
- The stray `Write-Host $keepHeight` debug line is gone.

### `generate_atlas <cols> <rows> <output> <tile>...`

The montage call, pulled out so anything can use it.

---

## `patch_generate_menu.sh`

| # | Fix |
|---|---|
| 1 | **Shebang said `sh`, the script is bash throughout** — arrays, `[[ ]]`, `local`, `$RANDOM`, `${var,,}`, `pipefail`. Verified: `dash -n` fails at line 346, `bash -n` passes. On Debian and Ubuntu, where `/bin/sh` is dash, it died immediately. |
| 2 | **`generate_text_image` leaked four globals.** `prefix`, `texture`, `state` and `buttonsecondarycolor` were never `local`, so they persisted between calls — the journal loop only worked because it inherited `-sc` from the esc-menu loop above it. Now local, with defaults that preserve the existing behaviour. |
| 3 | **Duplicate `-t\|--texture` case.** The second was unreachable. |
| 4 | **`-pk` and `-sk` silently did nothing.** Both wrote to `kerning`; the two places that consume it read `$primarykerning` and `$secondarykerning`. |
| 5 | Hooks `generate_hud_atlases.sh` in before the textures are moved. Guarded, so `generate_menu.sh` still runs standalone. |

Idempotent — run it as many times as you like. Writes `generate_menu.sh.bak`
first and runs `bash -n` on the result.

Two things it deliberately leaves alone: `hex_to_rgb` and
`generate_color_noise_texture` are defined and never called, but they are harmless
and you may want them. And `-ns|--no-stroke` consumes an argument rather than
being a plain flag — odd, but the call sites pass `-ns true` consistently, so
changing it would break them.

---

## A word on `generate_fucked.sh`

It uses `mv`, not `cp`. It **removes** the donor file from the other theme's
`Textures` directory, so repeated runs progressively gut every theme you built.

Its self-exclusion guard also cannot fire: it compares `$dir` (relative,
`../../Rose/`) against `$current_dir/` (absolute), which are never equal, so a
theme can cannibalise itself.

Fine as a joke tool on throwaway output — just regenerate afterwards. Change `mv`
to `cp` if you want it non-destructive.

---

## Requirements

- **ImageMagick 7** (`magick`). Set `MAGICK=/path/to/magick` to override. The
  scripts use IM7 syntax throughout, as `generate_menu.sh` already did.
- `awk` for the trigonometry, `mktemp`, and bash 4+.
- `generate_menu.sh` additionally needs `MysticCards.ttf` in the working
  directory.

Temp files go to `mktemp -d` and are cleaned up on exit, including on interrupt.

> One trap worth knowing about if you extend these: do not call the temp-dir
> helper inside `$( )`. The `trap ... EXIT` fires when the substitution subshell
> ends and deletes the directory out from under you. That is why `_atlas_init`
> sets a global and is called as a statement.
