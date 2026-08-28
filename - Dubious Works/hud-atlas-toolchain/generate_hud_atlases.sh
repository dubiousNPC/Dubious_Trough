#!/usr/bin/env bash
#
# generate_hud_atlases.sh
#
# Builds the texture atlases the Lua HUD widgets consume, in the same palette as
# the menu textures. Source it from generate_menu.sh, or run it standalone after
# the noise textures exist.
#
#   generate_moon_atlas       MoonHUD      8 cols x 3 rows   (Masser / Secunda / Shade)
#   generate_compass_atlas    BSCompass    1 col  x 36 rows
#   generate_progressive_atlas             a port of make_atlas.ps1
#   generate_atlas                         montage a list of tiles into a grid
#
# Everything is drawn by tiling the noise textures rather than filling flat
# colour, matching generate_menu.sh, so the atlases pick up each theme's grain.
#
# Requires ImageMagick 7 (magick). Set MAGICK=/path/to/magick to override.

set -euo pipefail

MAGICK="${MAGICK:-magick}"
NOCOMPRESS="-define dds:mipmaps=0 -define dds:compression=None"

# Scratch directory, cleaned up on exit.
ATLAS_TMP=""
_atlas_cleanup() { [ -n "$ATLAS_TMP" ] && [ -d "$ATLAS_TMP" ] && rm -rf "$ATLAS_TMP"; }
# Sets $ATLAS_TMP. Call this as a statement, never inside $( ), or the EXIT trap
# fires when the substitution subshell ends and deletes the directory underneath
# you. That is exactly the bug this shape avoids.
_atlas_init() {
    if [ -z "$ATLAS_TMP" ] || [ ! -d "$ATLAS_TMP" ]; then
        ATLAS_TMP="$(mktemp -d "${TMPDIR:-/tmp}/hud_atlas_XXXXXX")"
        trap _atlas_cleanup EXIT INT TERM
    fi
}

# ---------------------------------------------------------------------------
# Generic helpers
# ---------------------------------------------------------------------------

# generate_atlas <cols> <rows> <output> <tile>...
#
# Montages tiles left-to-right, top-to-bottom. This is the same montage call
# make_atlas.ps1 ends on, pulled out so anything can use it.
generate_atlas() {
    local cols="$1"; shift
    local rows="$1"; shift
    local output="$1"; shift

    $MAGICK montage "$@" \
        -tile "${cols}x${rows}" \
        -geometry +0+0 \
        -background none \
        $NOCOMPRESS \
        "$output"
}

# generate_progressive_atlas -i <input> -o <output> -r <rows> -c <cols> [-m] [-w] [-d]
#
# Port of make_atlas.ps1. Three modes:
#
#   default   progressively -roll the source, for scrolling or cycling strips
#   -m        progressively blacken a growing slice, for fill meters
#   -m -d     progressively delete that slice instead, for transparent meters
#   -w        operate on width instead of height
#
# Two fixes over the original:
#   * the roll step used the image WIDTH to scroll VERTICALLY, which only
#     produced a clean loop on square inputs. It now uses the axis it scrolls.
#   * the stray debug `Write-Host $keepHeight` is gone.
generate_progressive_atlas() {
    local input="" output="" rows=0 cols=0
    local mask="false" mask_width="false" mask_remove="false"

    while [[ "$#" -gt 0 ]]; do
        case $1 in
            -i|--input)  input="$2";  shift ;;
            -o|--output) output="$2"; shift ;;
            -r|--rows)   rows="$2";   shift ;;
            -c|--cols)   cols="$2";   shift ;;
            -m|--mask)   mask="true" ;;
            -w|--width)  mask_width="true" ;;
            -d|--delete) mask_remove="true" ;;
            *) echo "generate_progressive_atlas: unknown parameter $1" >&2; return 1 ;;
        esac
        shift
    done

    if [ -z "$input" ] || [ -z "$output" ] || [ "$rows" -le 0 ] || [ "$cols" -le 0 ]; then
        echo "generate_progressive_atlas: need -i, -o, -r and -c" >&2
        return 1
    fi
    if [ ! -f "$input" ]; then
        echo "generate_progressive_atlas: input '$input' not found" >&2
        return 1
    fi

    _atlas_init
    local tmp="$ATLAS_TMP/prog_$$"
    mkdir -p "$tmp"

    local total=$((rows * cols))
    local denom=$((total > 1 ? total - 1 : 1))

    local w h
    w=$($MAGICK identify -format "%w" "$input")
    h=$($MAGICK identify -format "%h" "$input")
    local extent="${w}x${h}"

    local files=()
    local i
    for (( i = 0; i < total; i++ )); do
        local tile="$tmp/tile_$(printf '%04d' "$i").png"

        if [ "$mask" != "true" ]; then
            # Scroll along the axis we are actually scrolling.
            local span=$h
            local roll="+0+"
            if [ "$mask_width" == "true" ]; then span=$w; roll="+"; fi
            local amount=$(( i * span / denom ))
            if [ "$mask_width" == "true" ]; then
                $MAGICK "$input" -roll "+${amount}+0" $NOCOMPRESS "$tile"
            else
                $MAGICK "$input" -roll "+0+${amount}" $NOCOMPRESS "$tile"
            fi

        elif [ "$i" -eq 0 ]; then
            cp -f "$input" "$tile"

        else
            local pct=$(( i * 100 / denom ))

            if [ "$mask_remove" == "true" ]; then
                local keep gravity crop
                if [ "$mask_width" == "true" ]; then
                    keep=$(( w - (pct * w / 100) )); gravity="East"
                    crop="${keep}x${h}+$(( w - keep ))+0"
                else
                    keep=$(( h - (pct * h / 100) )); gravity="South"
                    crop="${w}x${keep}+0+$(( h - keep ))"
                fi
                if [ "$keep" -le 0 ] || [ "$i" -eq $((total - 1)) ]; then
                    $MAGICK -size "$extent" canvas:transparent $NOCOMPRESS "$tile"
                else
                    $MAGICK "$input" -crop "$crop" +repage \
                        -background none -gravity "$gravity" -extent "$extent" \
                        $NOCOMPRESS "$tile"
                fi
            else
                local cut crop
                if [ "$mask_width" == "true" ]; then
                    cut=$(( pct * w / 100 )); crop="${cut}x${h}+0+0"
                else
                    cut=$(( pct * h / 100 )); crop="${w}x${cut}+0+0"
                fi
                if [ "$cut" -le 0 ]; then
                    cp -f "$input" "$tile"
                else
                    $MAGICK "$input" \
                        \( -clone 0 -crop "$crop" +repage -fill black -colorize 100% \) \
                        -compose darken -composite \
                        $NOCOMPRESS "$tile"
                fi
            fi
        fi

        files+=("$tile")
    done

    generate_atlas "$cols" "$rows" "$output" "${files[@]}"
    rm -rf "$tmp"
}

# ---------------------------------------------------------------------------
# Moon phases
# ---------------------------------------------------------------------------

# Ring order, matching MWRender::MoonState::Phase and MH_constants.lua:
#   0 Full  1 WaningGibbous  2 ThirdQuarter  3 WaningCrescent
#   4 New   5 WaxingCrescent 6 FirstQuarter  7 WaxingGibbous
#
# Phase angle is index * 45 degrees, 0 at full and 180 at new. The terminator is
# a half-ellipse whose x semi-axis is r*cos(angle): positive bulges outward for a
# gibbous, negative bites inward for a crescent. Indices 1-3 are lit on the LEFT,
# 5-7 on the RIGHT.

# generate_moon_phase <lit_texture> <dark_texture> <size> <ring_index> <output>
generate_moon_phase() {
    local lit_texture="$1"
    local dark_texture="$2"
    local size="$3"
    local index="$4"
    local output="$5"

    _atlas_init
    local tmp="$ATLAS_TMP"
    local c=$(( size / 2 ))
    local r=$(( size / 2 - 2 ))
    local top=$(( c - r ))

    local disc="$tmp/disc_${size}.png"
    if [ ! -f "$disc" ]; then
        $MAGICK -size "${size}x${size}" xc:black -fill white \
            -draw "circle $c,$c $c,$top" "$disc"
    fi

    local lit_mask="$tmp/litmask_${index}_${size}.png"

    if [ "$index" -eq 0 ]; then
        cp -f "$disc" "$lit_mask"                       # full
    elif [ "$index" -eq 4 ]; then
        $MAGICK -size "${size}x${size}" xc:black "$lit_mask"   # new
    else
        # Signed semi-axis, and which side is lit.
        local a waning
        a=$(awk -v r="$r" -v i="$index" \
            'BEGIN { printf "%d", r * cos(i * 45 * 3.14159265358979 / 180) }')
        waning=$(( index < 4 ? 1 : 0 ))

        local abs_a=${a#-}
        [ -z "$abs_a" ] && abs_a=0

        # The lit half, clipped to the disc.
        local half="$tmp/half.png"
        if [ "$waning" -eq 1 ]; then
            $MAGICK -size "${size}x${size}" xc:black -fill white \
                -draw "rectangle 0,0 $c,$size" "$half"
        else
            $MAGICK -size "${size}x${size}" xc:black -fill white \
                -draw "rectangle $c,0 $size,$size" "$half"
        fi

        # The terminator ellipse.
        local ell="$tmp/ell.png"
        $MAGICK -size "${size}x${size}" xc:black -fill white \
            -draw "ellipse $c,$c $abs_a,$r 0,360" "$ell"

        if [ "$a" -ge 0 ]; then
            # Gibbous: the ellipse adds to the lit half.
            $MAGICK "$half" "$ell" -compose Lighten -composite \
                "$disc" -compose Multiply -composite "$lit_mask"
        else
            # Crescent: the ellipse eats into the lit half.
            $MAGICK "$half" \( "$ell" -negate \) -compose Darken -composite \
                "$disc" -compose Multiply -composite "$lit_mask"
        fi
    fi

    # Dark disc, then the lit part over it.
    $MAGICK \
        \( -size "${size}x${size}" xc:none -tile "$dark_texture" \
           -draw "rectangle 0,0 $size,$size" \
           "$disc" -alpha off -compose CopyOpacity -composite \) \
        \( -size "${size}x${size}" xc:none -tile "$lit_texture" \
           -draw "rectangle 0,0 $size,$size" \
           "$lit_mask" -alpha off -compose CopyOpacity -composite \) \
        -compose Over -composite \
        -background none $NOCOMPRESS "$output"
}

# generate_shade_indicator <lit_texture> <dark_texture> <size> <active> <output>
#
# Row 2 of the MoonHUD atlas. A disc with a vertical beam through it, bright when
# the Shade of the Revenant is up and dim otherwise.
generate_shade_indicator() {
    local lit_texture="$1"
    local dark_texture="$2"
    local size="$3"
    local active="$4"
    local output="$5"

    _atlas_init
    local tmp="$ATLAS_TMP"
    local c=$(( size / 2 ))
    local r=$(( size / 2 - 2 ))
    local top=$(( c - r ))
    local beam=$(( size / 9 ))

    local texture="$dark_texture"
    local beam_alpha=25
    if [ "$active" == "true" ]; then
        texture="$lit_texture"
        beam_alpha=75
    fi

    local disc="$tmp/disc_${size}.png"
    if [ ! -f "$disc" ]; then
        $MAGICK -size "${size}x${size}" xc:black -fill white \
            -draw "circle $c,$c $c,$top" "$disc"
    fi

    $MAGICK \
        \( -size "${size}x${size}" xc:none -tile "$texture" \
           -draw "rectangle 0,0 $size,$size" \) \
        \( -size "${size}x${size}" xc:black \
           -fill "gray($beam_alpha%)" \
           -draw "rectangle $(( c - beam )),0 $(( c + beam )),$size" \
           -blur 0x2 \) \
        -compose Screen -composite \
        "$disc" -alpha off -compose CopyOpacity -composite \
        -background none $NOCOMPRESS "$output"
}

# generate_moon_atlas <lit_texture> <dark_texture> <cell> <output>
#
# 8 columns x 3 rows. Row 0 Masser, row 1 Secunda, row 2 the Shade indicator
# (cell 0 lit, cells 1-7 dim so any index is safe). Matches MH_constants.ATLAS_ROW.
generate_moon_atlas() {
    local lit_texture="$1"
    local dark_texture="$2"
    local cell="${3:-64}"
    local output="${4:-moon_atlas.dds}"

    _atlas_init
    local tmp="$ATLAS_TMP/moon_$$"
    mkdir -p "$tmp"

    local tiles=()
    local row i

    # The unlit limb has to read as shadow whatever the palette is, so it is the
    # given dark texture knocked well down rather than used at full value. Taking
    # a raw theme colour here leaves the "dark" side as bright as the lit one.
    $MAGICK "$dark_texture" -modulate 32,60,100 "$tmp/shadow.png"

    # Masser reads warmer, Secunda cooler. Both derive from the theme palette.
    for row in masser secunda; do
        if [ "$row" == "masser" ]; then
            $MAGICK "$lit_texture" -modulate 100,120,92 "$tmp/lit_$row.png"
        else
            $MAGICK "$lit_texture" -modulate 108,55,105 "$tmp/lit_$row.png"
        fi
        for (( i = 0; i < 8; i++ )); do
            generate_moon_phase "$tmp/lit_$row.png" "$tmp/shadow.png" "$cell" "$i" \
                "$tmp/${row}_${i}.png"
            tiles+=("$tmp/${row}_${i}.png")
        done
    done

    generate_shade_indicator "$lit_texture" "$tmp/shadow.png" "$cell" true  "$tmp/shade_on.png"
    generate_shade_indicator "$lit_texture" "$tmp/shadow.png" "$cell" false "$tmp/shade_off.png"
    tiles+=("$tmp/shade_on.png")
    for (( i = 1; i < 8; i++ )); do tiles+=("$tmp/shade_off.png"); done

    generate_atlas 8 3 "$output" "${tiles[@]}"
    rm -rf "$tmp"
}

# ---------------------------------------------------------------------------
# Compass dial
# ---------------------------------------------------------------------------

# generate_compass_dial <face_texture> <bezel_texture> <needle_texture> <cell> <frames> <output>
#
# A vertical strip, one frame per 360/frames degrees, north first. The needle
# rotates CLOCKWISE by that step per frame index, which is what BSCompass's
# default mapping expects:
#
#     frame = (frames - round(heading / step)) % frames
#
# At frame 0 the long arm points UP, so it reads as a north-pointing needle when
# you are facing north. Note that differs from BSCompasAtlas.png, whose long arm
# points south; both work, the mapping only cares about rotation direction.
generate_compass_dial() {
    local face_texture="$1"
    local bezel_texture="$2"
    local needle_texture="$3"
    local cell="${4:-88}"
    local frames="${5:-36}"
    local output="${6:-compass_atlas.dds}"
    # Columns in the output sheet. 1 is the vertical strip BSCompass has always
    # used; anything past ~180 frames needs a grid to stay inside texture limits.
    local cols="${7:-1}"

    _atlas_init
    local tmp="$ATLAS_TMP/compass_$$"
    mkdir -p "$tmp"

    # Rotation pivot. This MUST be (cell-1)/2, not cell/2: for an 88px cell the
    # pixel centre is 43.5, not 44. Rotating about a point half a pixel off makes
    # the art precess in a small circle as the angle sweeps, which reads as a
    # visible wobble -- barely noticeable at 10 degree steps, obvious at 1.
    local c
    c=$(awk -v n="$cell" 'BEGIN { printf "%.1f", (n - 1) / 2 }')
    local r=$(( cell / 2 - 1 ))
    local face_r=$(( r * 82 / 100 ))
    local top=$(( c - r ))
    local face_top=$(( c - face_r ))

    # Bezel ring plus recessed face.
    $MAGICK \
        \( -size "${cell}x${cell}" xc:none -tile "$bezel_texture" \
           -draw "rectangle 0,0 $cell,$cell" \) \
        \( -size "${cell}x${cell}" xc:black -fill white \
           -draw "circle $c,$c $c,$top" \) \
        -alpha off -compose CopyOpacity -composite \
        \( -size "${cell}x${cell}" xc:none -tile "$face_texture" \
           -draw "rectangle 0,0 $cell,$cell" \
           -modulate 78,100,100 \
           \( -size "${cell}x${cell}" xc:black -fill white \
              -draw "circle $c,$c $c,$face_top" \) \
           -alpha off -compose CopyOpacity -composite \) \
        -compose Over -composite \
        -background none "$tmp/dial.png"

    # A static index notch at the top of the bezel, marking the way you are facing.
    local notch=$(( cell * 6 / 100 )); [ "$notch" -lt 2 ] && notch=2
    $MAGICK "$tmp/dial.png" \
        -tile "$needle_texture" \
        -draw "polygon $(( c - notch )),0 $(( c + notch )),0 $c,$(( notch * 2 ))" \
        -background none "$tmp/dial_marked.png"

    # Needle. The two arms are deliberately different shapes and different
    # textures: a symmetric needle is unreadable at HUD size, you cannot tell
    # which end is north. North is a wide kite in the bright texture, south a
    # narrow spike in the bezel texture.
    local tip=$(( c - face_r + 3 ))
    local tail=$(( c + face_r * 52 / 100 ))
    local halfw=$(( cell * 8 / 100 ));      [ "$halfw" -lt 2 ] && halfw=2
    local tailw=$(( cell * 4 / 100 ));      [ "$tailw" -lt 1 ] && tailw=1
    local shoulder=$(( c + cell * 4 / 100 ))
    local hub=$(( cell * 5 / 100 ));        [ "$hub" -lt 2 ] && hub=2

    $MAGICK -size "${cell}x${cell}" xc:none \
        -tile "$bezel_texture" \
        -draw "polygon $c,$tail $(( c + tailw )),$c $(( c - tailw )),$c" \
        -tile "$needle_texture" \
        -draw "polygon $c,$tip $(( c + halfw )),$shoulder $c,$(( shoulder + 2 )) $(( c - halfw )),$shoulder" \
        -draw "circle $c,$c $(( c + hub )),$c" \
        -background none "$tmp/needle.png"

    local step
    step=$(awk -v f="$frames" 'BEGIN { printf "%.6f", 360.0 / f }')

    local tiles=()
    local i
    for (( i = 0; i < frames; i++ )); do
        local angle
        angle=$(awk -v s="$step" -v i="$i" 'BEGIN { printf "%.4f", s * i }')

        # SRT with a positive angle rotates clockwise, and keeps the canvas size.
        $MAGICK "$tmp/dial_marked.png" \
            \( "$tmp/needle.png" -virtual-pixel none \
               -distort SRT "$c,$c 1 $angle $c,$c" \) \
            -compose Over -composite \
            -background none $NOCOMPRESS "$tmp/frame_$(printf '%03d' "$i").png"

        tiles+=("$tmp/frame_$(printf '%03d' "$i").png")
    done

    local rows=$(( (frames + cols - 1) / cols ))
    generate_atlas "$cols" "$rows" "$output" "${tiles[@]}"
    rm -rf "$tmp"
}

# generate_compass_atlas <cell> <frames> <output>
#
# Convenience wrapper using the theme's noise textures, the way generate_menu.sh
# names them.
generate_compass_atlas() {
    local cell="${1:-88}"
    local frames="${2:-36}"
    local output="${3:-compass_atlas.dds}"
    local cols="${4:-1}"
    generate_compass_dial noise_base.dds noise_highlight.dds noise_active.dds \
        "$cell" "$frames" "$output" "$cols"
}

# generate_expanded_atlas -i <in> -o <out> -n <src frames> -m <dst frames>
#                         [--in-cols N] [--out-cols N] [--cell N]
#
# Resamples a rotating atlas to a different frame count. The usual use is taking
# a 36-frame compass strip up to 360 for smooth motion:
#
#   generate_expanded_atlas -i BSCompasAtlas.png -o compass360.png \
#       -n 36 -m 360 --cell 88 --out-cols 30
#
# For each output frame it picks the NEAREST source frame and rotates it by the
# residual, so the error is never more than half a source step: +/-5 degrees for
# 36 sources, and zero on every tenth frame where a source lands exactly. That
# beats interpolating between neighbours, which would ghost the needle.
#
# Rotating the whole cell also turns the bezel, which is invisible for the ring
# and tick artwork these atlases use. If your bezel has an asymmetric feature,
# generate from source art instead of expanding.
#
# 360 frames of 88px will not fit in a single column: 88 x 31680 exceeds the
# 16384 texture limit on most hardware. Hence --out-cols. BSCompass reads grid
# atlases via its Atlas Columns setting.
generate_expanded_atlas() {
    local input="" output="" n=0 m=0 in_cols=1 out_cols=0 cell=0

    while [[ "$#" -gt 0 ]]; do
        case $1 in
            -i|--input)    input="$2";    shift ;;
            -o|--output)   output="$2";   shift ;;
            -n|--src)      n="$2";        shift ;;
            -m|--dst)      m="$2";        shift ;;
            --in-cols)     in_cols="$2";  shift ;;
            --out-cols)    out_cols="$2"; shift ;;
            --cell)        cell="$2";     shift ;;
            *) echo "generate_expanded_atlas: unknown parameter $1" >&2; return 1 ;;
        esac
        shift
    done

    if [ -z "$input" ] || [ -z "$output" ] || [ "$n" -le 0 ] || [ "$m" -le 0 ]; then
        echo "generate_expanded_atlas: need -i, -o, -n and -m" >&2
        return 1
    fi
    [ ! -f "$input" ] && { echo "generate_expanded_atlas: '$input' not found" >&2; return 1; }

    local iw ih
    iw=$($MAGICK identify -format "%w" "$input")
    ih=$($MAGICK identify -format "%h" "$input")
    if [ "$cell" -le 0 ]; then cell=$(( iw / in_cols )); fi

    local in_rows=$(( (n + in_cols - 1) / in_cols ))
    if [ $(( in_cols * cell )) -gt "$iw" ] || [ $(( in_rows * cell )) -gt "$ih" ]; then
        echo "generate_expanded_atlas: ${in_cols}x${in_rows} cells of ${cell}px do not fit in ${iw}x${ih}" >&2
        return 1
    fi

    # Default to a grid roughly twice as wide as tall, which keeps both
    # dimensions well inside the usual 16384 limit.
    if [ "$out_cols" -le 0 ]; then
        out_cols=$(awk -v m="$m" 'BEGIN { printf "%d", int(sqrt(m * 2) + 0.5) }')
        [ "$out_cols" -lt 1 ] && out_cols=1
        while [ $(( m % out_cols )) -ne 0 ] && [ "$out_cols" -lt "$m" ]; do
            out_cols=$(( out_cols + 1 ))
        done
    fi
    local out_rows=$(( (m + out_cols - 1) / out_cols ))

    _atlas_init
    local tmp="$ATLAS_TMP/expand_$$"
    mkdir -p "$tmp"

    # Rotation pivot. This MUST be (cell-1)/2, not cell/2: for an 88px cell the
    # pixel centre is 43.5, not 44. Rotating about a point half a pixel off makes
    # the art precess in a small circle as the angle sweeps, which reads as a
    # visible wobble -- barely noticeable at 10 degree steps, obvious at 1.
    local c
    c=$(awk -v n="$cell" 'BEGIN { printf "%.1f", (n - 1) / 2 }')
    local files=()
    local j
    for (( j = 0; j < m; j++ )); do
        # Nearest source frame, and the residual rotation to make up the rest.
        local src residual
        src=$(awk -v j="$j" -v n="$n" -v m="$m" \
            'BEGIN { s = int(j * n / m + 0.5) % n; printf "%d", s }')
        residual=$(awk -v j="$j" -v n="$n" -v m="$m" -v s="$src" \
            'BEGIN { printf "%.5f", j * 360.0 / m - s * 360.0 / n }')

        local sc=$(( src % in_cols ))
        local sr=$(( src / in_cols ))
        local tile="$tmp/f_$(printf '%05d' "$j").png"

        $MAGICK "$input" \
            -crop "${cell}x${cell}+$(( sc * cell ))+$(( sr * cell ))" +repage \
            -virtual-pixel none \
            -distort SRT "$c,$c 1 $residual $c,$c" \
            -background none $NOCOMPRESS "$tile"

        files+=("$tile")
    done

    generate_atlas "$out_cols" "$out_rows" "$output" "${files[@]}"
    rm -rf "$tmp"
    echo "expanded $n -> $m frames, ${out_cols}x${out_rows} grid of ${cell}px -> $output"
}

# expand_compass_atlas -i <in> -o <out> --in-frames N --out-frames M
#                      [--in-cols C] [--out-cols C] [--cell S]
#
# Resamples an existing compass atlas to a different frame count. The usual job
# is 36 -> 360, i.e. one frame per degree instead of per ten.
#
# It does NOT simply rotate frame 0 through 360 degrees. For each target frame it
# picks the NEAREST source frame and applies only the leftover rotation, so the
# worst rotation any pixel sees is half a source step (5 degrees for 36 -> 360)
# rather than up to 180. Source frames land on themselves untouched. That keeps
# whatever per-frame detail the original art has and minimises resampling blur.
#
# Output columns matter. A 360-frame vertical strip at 88px is 31680px tall,
# which is past the maximum texture size on essentially every GPU, so anything
# above about 180 frames has to be a grid. Default is 30 columns, matching the
# layout DBS_CompassARROWAtlas.png uses.
expand_compass_atlas() {
    local input="" output=""
    local in_frames=36 out_frames=360
    local in_cols=1 out_cols=30 cell=0
    local mode="single" src_frame=0 pivot=""

    while [[ "$#" -gt 0 ]]; do
        case $1 in
            -i|--input)      input="$2";      shift ;;
            -o|--output)     output="$2";     shift ;;
            --in-frames)     in_frames="$2";  shift ;;
            --out-frames)    out_frames="$2"; shift ;;
            --in-cols)       in_cols="$2";    shift ;;
            --out-cols)      out_cols="$2";   shift ;;
            --cell)          cell="$2";       shift ;;
            --mode)          mode="$2";       shift ;;
            --source-frame)  src_frame="$2";  shift ;;
            --pivot)         pivot="$2";      shift ;;
            *) echo "expand_compass_atlas: unknown parameter $1" >&2; return 1 ;;
        esac
        shift
    done

    if [ "$mode" != "single" ] && [ "$mode" != "nearest" ]; then
        echo "expand_compass_atlas: --mode must be single or nearest" >&2
        return 1
    fi

    if [ -z "$input" ] || [ -z "$output" ]; then
        echo "expand_compass_atlas: need -i and -o" >&2
        return 1
    fi
    if [ ! -f "$input" ]; then
        echo "expand_compass_atlas: input '$input' not found" >&2
        return 1
    fi

    _atlas_init
    local tmp="$ATLAS_TMP/expand_$$"
    mkdir -p "$tmp"

    local aw ah
    aw=$($MAGICK identify -format "%w" "$input")
    ah=$($MAGICK identify -format "%h" "$input")

    local in_rows=$(( (in_frames + in_cols - 1) / in_cols ))
    if [ "$cell" -le 0 ]; then
        cell=$(( aw / in_cols ))
        local cell_h=$(( ah / in_rows ))
        if [ "$cell" -ne "$cell_h" ]; then
            echo "expand_compass_atlas: cells are ${cell}x${cell_h}, not square." >&2
            echo "  Check --in-frames and --in-cols against the ${aw}x${ah} sheet." >&2
            return 1
        fi
    fi

    local out_rows=$(( (out_frames + out_cols - 1) / out_cols ))
    local out_w=$(( cell * out_cols ))
    local out_h=$(( cell * out_rows ))
    if [ "$out_w" -gt 16384 ] || [ "$out_h" -gt 16384 ]; then
        echo "expand_compass_atlas: output would be ${out_w}x${out_h}." >&2
        echo "  That is past the usual 16384px texture limit. Raise --out-cols." >&2
        return 1
    fi

    echo "  ${in_frames} frames (${in_cols} cols) -> ${out_frames} frames" \
         "(${out_cols} cols), ${cell}px cells, ${out_w}x${out_h}"

    # Slice the source once.
    local si
    for (( si = 0; si < in_frames; si++ )); do
        local sr=$(( si / in_cols )) sc=$(( si % in_cols ))
        $MAGICK "$input" -crop "${cell}x${cell}+$(( sc * cell ))+$(( sr * cell ))" +repage \
            "$tmp/src_$(printf '%04d' "$si").png"
    done

    # Rotation pivot. This MUST be (cell-1)/2, not cell/2: for an 88px cell the
    # pixel centre is 43.5, not 44. Rotating about a point half a pixel off makes
    # the art precess in a small circle as the angle sweeps, which reads as a
    # visible wobble -- barely noticeable at 10 degree steps, obvious at 1.
    local c
    c=$(awk -v n="$cell" 'BEGIN { printf "%.1f", (n - 1) / 2 }')
    local px py
    if [ -n "$pivot" ]; then
        px="${pivot%%,*}"; py="${pivot##*,}"
    else
        px="$c"; py="$c"
    fi

    local files=()
    local i reused=0
    for (( i = 0; i < out_frames; i++ )); do
        local nearest residual
        if [ "$mode" == "single" ]; then
            # Every output frame is the SAME source frame rotated. Hand-drawn or
            # separately rendered source frames each carry their own small
            # positional error; picking a different source every few frames makes
            # those errors switch in and out, which reads as a periodic wobble.
            # Taking one frame throughout costs more resampling but the motion is
            # perfectly smooth, and a circular bezel does not care that it turns.
            nearest="$src_frame"
            residual=$(awk -v i="$i" -v n="$src_frame" -v inf="$in_frames" -v outf="$out_frames" \
                'BEGIN { d = i * 360.0 / outf - n * 360.0 / inf;
                         while (d > 180) d -= 360; while (d < -180) d += 360;
                         printf "%.5f", d }')
        else
            # Nearest source frame, and the leftover rotation in degrees. Keeps
            # per-frame art detail and leaves source frames bit-exact, at the cost
            # of a discontinuity wherever the chosen source changes.
            nearest=$(awk -v i="$i" -v inf="$in_frames" -v outf="$out_frames" \
                'BEGIN { printf "%d", int(i * inf / outf + 0.5) % inf }')
            residual=$(awk -v i="$i" -v n="$nearest" -v inf="$in_frames" -v outf="$out_frames" \
                'BEGIN { d = i * 360.0 / outf - n * 360.0 / inf;
                         while (d > 180) d -= 360; while (d < -180) d += 360;
                         printf "%.5f", d }')
        fi

        local tile="$tmp/out_$(printf '%04d' "$i").png"
        local isZero
        isZero=$(awk -v r="$residual" 'BEGIN { print (r < 0.0005 && r > -0.0005) ? 1 : 0 }')
        if [ "$isZero" -eq 1 ]; then
            cp -f "$tmp/src_$(printf '%04d' "$nearest").png" "$tile"
            reused=$(( reused + 1 ))
        else
            $MAGICK "$tmp/src_$(printf '%04d' "$nearest").png" \
                -virtual-pixel none -filter Lanczos \
                -distort SRT "$px,$py 1 $residual $px,$py" \
                -background none "$tile"
        fi
        files+=("$tile")
    done

    echo "  mode=$mode, $reused of $out_frames frames copied without resampling"
    generate_atlas "$out_cols" "$out_rows" "$output" "${files[@]}"
    rm -rf "$tmp"
}

# expand_compass_layered -i <atlas> -p <plate> -o <out> --in-frames N
#                        --out-frames M [--in-cols C] [--out-cols C] [--mode ...]
#                        [--threshold PCT]
#
# The right way to expand a dial whose bezel and glass are STATIC and whose
# needle is the only moving part.
#
# expand_compass_atlas rotates the whole cell, which turns the bezel and the
# glass highlight with the needle -- obviously wrong on artwork like
# BSCompasAtlas, where the needle is meant to sweep behind a fixed glass front.
#
# This takes the needle-less plate as a second input, isolates the needle from
# each source frame by differencing against it, rotates only that, and
# recomposites over the untouched plate. The bezel never moves.
#
#   --mode nearest  (default) each output frame takes the NEAREST source needle
#                   and rotates it by the remainder, at most half a source step.
#                   Preserves per-frame hand-drawn shading, which is the whole
#                   point of pixel art like this.
#   --mode single   every frame from one source needle. Smoothest motion, but
#                   every frame then carries the same shading.
#
# --threshold is the difference level, in percent, above which a pixel counts as
# needle rather than plate. Edges are kept soft: the difference magnitude becomes
# the alpha, so anti-aliased pixels blend rather than stair-step.
expand_compass_layered() {
    local input="" plate="" output=""
    local in_frames=36 out_frames=360
    local in_cols=1 out_cols=30 cell=0
    local mode="nearest" threshold=12 src_frame=0 inner=36

    while [[ "$#" -gt 0 ]]; do
        case $1 in
            -i|--input)     input="$2";      shift ;;
            -p|--plate)     plate="$2";      shift ;;
            -o|--output)    output="$2";     shift ;;
            --in-frames)    in_frames="$2";  shift ;;
            --out-frames)   out_frames="$2"; shift ;;
            --in-cols)      in_cols="$2";    shift ;;
            --out-cols)     out_cols="$2";   shift ;;
            --cell)         cell="$2";       shift ;;
            --mode)         mode="$2";       shift ;;
            --source-frame) src_frame="$2";  shift ;;
            --threshold)    threshold="$2";  shift ;;
            --inner-radius) inner="$2";      shift ;;
            *) echo "expand_compass_layered: unknown parameter $1" >&2; return 1 ;;
        esac
        shift
    done

    if [ -z "$input" ] || [ -z "$plate" ] || [ -z "$output" ]; then
        echo "expand_compass_layered: need -i, -p and -o" >&2
        return 1
    fi
    for f in "$input" "$plate"; do
        if [ ! -f "$f" ]; then
            echo "expand_compass_layered: '$f' not found" >&2
            return 1
        fi
    done

    _atlas_init
    local tmp="$ATLAS_TMP/layered_$$"
    mkdir -p "$tmp"

    local aw ah
    aw=$($MAGICK identify -format "%w" "$input")
    ah=$($MAGICK identify -format "%h" "$input")
    local in_rows=$(( (in_frames + in_cols - 1) / in_cols ))
    [ "$cell" -le 0 ] && cell=$(( aw / in_cols ))

    local pw ph
    pw=$($MAGICK identify -format "%w" "$plate")
    ph=$($MAGICK identify -format "%h" "$plate")
    if [ "$pw" -ne "$cell" ] || [ "$ph" -ne "$cell" ]; then
        echo "expand_compass_layered: plate is ${pw}x${ph}, cells are ${cell}x${cell}." >&2
        echo "  The plate must be one cell, aligned with the sheet." >&2
        return 1
    fi

    local out_rows=$(( (out_frames + out_cols - 1) / out_cols ))
    local out_w=$(( cell * out_cols )) out_h=$(( cell * out_rows ))
    if [ "$out_w" -gt 16384 ] || [ "$out_h" -gt 16384 ]; then
        echo "expand_compass_layered: output would be ${out_w}x${out_h}, past the" >&2
        echo "  usual 16384px texture limit. Raise --out-cols." >&2
        return 1
    fi

    echo "  ${in_frames} -> ${out_frames} frames, ${cell}px cells, ${out_w}x${out_h}"
    echo "  mode=$mode, plate held static, needle isolated at ${threshold}% difference"

    # Clip the needle to the inner disc. Without this the difference picks up
    # the bezel too -- the source frames' bezels differ slightly from the plate --
    # and compositing that back means the bezel changes whenever the chosen
    # source frame does, which is the flicker this whole function exists to stop.
    local ic ir
    ic=$(awk -v n="$cell" 'BEGIN { printf "%.1f", (n - 1) / 2 }')
    ir=$(awk -v n="$cell" -v p="$inner" 'BEGIN { printf "%.1f", n * p / 100 }')
    $MAGICK -size "${cell}x${cell}" xc:black -fill white \
        -draw "circle $ic,$ic $ic,$(awk -v a="$ic" -v b="$ir" 'BEGIN{printf "%.1f", a-b}')" \
        -blur 0x0.5 "$tmp/inner.png"

    # Isolate the needle from every source frame once.
    local si
    for (( si = 0; si < in_frames; si++ )); do
        local sr=$(( si / in_cols )) sc=$(( si % in_cols ))
        local frame="$tmp/frame_$(printf '%03d' "$si").png"
        $MAGICK "$input" -crop "${cell}x${cell}+$(( sc * cell ))+$(( sr * cell ))" +repage "$frame"
        # Difference against the plate becomes the needle's alpha, so edges stay soft.
        $MAGICK "$frame" "$plate" -compose Difference -composite \
            -colorspace Gray -level "${threshold}%,$(( threshold + 18 ))%" \
            "$tmp/inner.png" -compose Multiply -composite \
            "$tmp/mask_$(printf '%03d' "$si").png"
        $MAGICK "$frame" "$tmp/mask_$(printf '%03d' "$si").png" \
            -alpha off -compose CopyOpacity -composite \
            -background none "$tmp/needle_$(printf '%03d' "$si").png"
    done

    local c
    c=$(awk -v n="$cell" 'BEGIN { printf "%.1f", (n - 1) / 2 }')

    local files=() i exact=0
    for (( i = 0; i < out_frames; i++ )); do
        local nearest residual
        if [ "$mode" == "single" ]; then
            nearest="$src_frame"
        else
            nearest=$(awk -v i="$i" -v inf="$in_frames" -v outf="$out_frames" \
                'BEGIN { printf "%d", int(i * inf / outf + 0.5) % inf }')
        fi
        residual=$(awk -v i="$i" -v n="$nearest" -v inf="$in_frames" -v outf="$out_frames" \
            'BEGIN { d = i * 360.0 / outf - n * 360.0 / inf;
                     while (d > 180) d -= 360; while (d < -180) d += 360;
                     printf "%.5f", d }')

        local tile="$tmp/out_$(printf '%04d' "$i").png"
        local isZero
        isZero=$(awk -v r="$residual" 'BEGIN { print (r < 0.0005 && r > -0.0005) ? 1 : 0 }')

        if [ "$isZero" -eq 1 ]; then
            # On a source angle the needle needs no rotation, so its pixels
            # survive exactly. It still goes through the plate rather than being
            # copied whole: the source frames' own bezels differ slightly from
            # the plate, and mixing the two makes the bezel flicker every time
            # the output crosses a source angle.
            $MAGICK "$plate" "$tmp/needle_$(printf '%03d' "$nearest").png" \
                -compose Over -composite \
                -background none $NOCOMPRESS "$tile"
            exact=$(( exact + 1 ))
        else
            $MAGICK "$plate" \
                \( "$tmp/needle_$(printf '%03d' "$nearest").png" \
                   -virtual-pixel none -filter Lanczos \
                   -distort SRT "$c,$c 1 $residual $c,$c" \) \
                -compose Over -composite \
                -background none $NOCOMPRESS "$tile"
        fi
        files+=("$tile")
    done

    echo "  $exact of $out_frames needles used without rotation"
    generate_atlas "$out_cols" "$out_rows" "$output" "${files[@]}"
    rm -rf "$tmp"
}

# ---------------------------------------------------------------------------
# MoonHUD panel textures
# ---------------------------------------------------------------------------
# The circular plate, its ring, and the rectangular panel fills. MoonHUD tints
# these at runtime via props.color, so generating them in the theme palette and
# leaving the tint white gives a themed panel with no settings changes.

# generate_panel_circle <texture> <size> <output>
# Soft-edged plate with a gentle radial falloff, so it reads as recessed.
generate_panel_circle() {
    local texture="$1"
    local size="${2:-256}"
    local output="${3:-panel_circle.dds}"

    _atlas_init
    local c=$(( size / 2 ))
    local r=$(( size / 2 - 2 ))
    local top=$(( c - r ))

    $MAGICK \
        \( -size "${size}x${size}" xc:none -tile "$texture" \
           -draw "rectangle 0,0 $size,$size" \
           -size "${size}x${size}" "radial-gradient:white-gray(62%)" \
           -compose Multiply -composite \) \
        \( -size "${size}x${size}" xc:black -fill white \
           -draw "circle $c,$c $c,$top" -blur 0x1 \) \
        -alpha off -compose CopyOpacity -composite \
        -background none $NOCOMPRESS "$output"
}

# generate_panel_ring <texture> <size> <thickness> <output>
# Ring with a transparent centre. Two concentric lines rather than one flat band,
# which is what stops it reading as a plain circle at HUD size.
generate_panel_ring() {
    local texture="$1"
    local size="${2:-256}"
    local thickness="${3:-0}"
    local output="${4:-panel_circle_border.dds}"

    _atlas_init
    local c=$(( size / 2 ))
    local outer=$(( size / 2 - 2 ))
    [ "$thickness" -le 0 ] && thickness=$(( size * 7 / 100 ))
    [ "$thickness" -lt 2 ] && thickness=2
    local inner=$(( outer - thickness ))
    local hair=$(( inner - thickness / 2 ))
    [ "$hair" -lt 4 ] && hair=4

    local tmp="$ATLAS_TMP"

    # Band mask: filled outer disc minus filled inner disc, plus a hairline.
    $MAGICK -size "${size}x${size}" xc:black \
        -fill white -draw "circle $c,$c $c,$(( c - outer ))" \
        -fill black -draw "circle $c,$c $c,$(( c - inner ))" \
        -fill white -draw "circle $c,$c $c,$(( c - hair ))" \
        -fill black -draw "circle $c,$c $c,$(( c - hair + 2 ))" \
        -blur 0x0.6 "$tmp/ring_mask.png"

    # A little top-lit shading so the band has some relief.
    $MAGICK \
        \( -size "${size}x${size}" xc:none -tile "$texture" \
           -draw "rectangle 0,0 $size,$size" \
           -size "${size}x${size}" "gradient:white-gray(55%)" \
           -compose Multiply -composite \) \
        "$tmp/ring_mask.png" \
        -alpha off -compose CopyOpacity -composite \
        -background none $NOCOMPRESS "$output"
}

# generate_panel_background <texture> <size> <style> <output>
# Opaque tile for the rectangular panel. style is stone or linen.
generate_panel_background() {
    local texture="$1"
    local size="${2:-256}"
    local style="${3:-stone}"
    local output="${4:-panel_bg.dds}"

    _atlas_init
    local tmp="$ATLAS_TMP"

    if [ "$style" == "linen" ]; then
        # Fine crosshatch: noise smeared along each axis in turn.
        $MAGICK -size "${size}x${size}" xc:gray50 +noise Gaussian -attenuate 0.5 \
            -colorspace Gray -motion-blur 0x3+0 "$tmp/warp.png"
        $MAGICK -size "${size}x${size}" xc:gray50 +noise Gaussian -attenuate 0.5 \
            -colorspace Gray -motion-blur 0x3+90 "$tmp/weft.png"
        $MAGICK "$tmp/warp.png" "$tmp/weft.png" -compose Overlay -composite \
            -normalize -level 25%,75% "$tmp/grain.png"
    else
        # Mottled stone: coarse blurred noise, contrast pushed.
        $MAGICK -size "${size}x${size}" xc:gray50 +noise Gaussian -attenuate 1.0 \
            -colorspace Gray -blur 0x2 -normalize \
            -sigmoidal-contrast 6x50% -level 20%,80% "$tmp/grain.png"
    fi

    # Overlay is the obvious choice here and it is wrong: it preserves black, so
    # any theme with a black primary (Royale, Cobalt, Mono) produced a completely
    # flat panel. This is a linear blend instead, 0.30*grain + 0.80*base - 0.12,
    # which keeps the grain visible whatever the base luminance.
    $MAGICK \
        \( -size "${size}x${size}" xc:none -tile "$texture" \
           -draw "rectangle 0,0 $size,$size" \) \
        "$tmp/grain.png" \
        -compose Mathematics -define compose:args="0,0.30,0.80,-0.12" -composite \
        -alpha set -background none -flatten $NOCOMPRESS "$output"
}

# generate_moonhud_panels <plate_texture> <ring_texture> <size>
# All four MoonHUD panel textures in one call, named as MoonHUD expects.
generate_moonhud_panels() {
    local plate_texture="${1:-noise_base.dds}"
    local ring_texture="${2:-noise_highlight.dds}"
    local size="${3:-256}"

    generate_panel_circle     "$plate_texture" "$size"        panel_circle.dds
    generate_panel_ring       "$ring_texture"  "$size" 0      panel_circle_border.dds
    generate_panel_background "$plate_texture" "$size" stone  panel_bg_stone.dds
    generate_panel_background "$plate_texture" "$size" linen  panel_bg_linen.dds
}

# ---------------------------------------------------------------------------
# Standalone entry point
# ---------------------------------------------------------------------------
# Sourced: just defines the functions. Executed: builds both atlases from the
# noise textures in the current directory.

if [ "${BASH_SOURCE[0]}" == "${0}" ]; then
    for t in noise_base.dds noise_highlight.dds noise_active.dds; do
        if [ ! -f "$t" ]; then
            echo "error: $t not found. Run generate_menu.sh first, or source this file." >&2
            exit 1
        fi
    done

    echo "Generating moon atlas..."
    generate_moon_atlas noise_highlight.dds noise_base.dds 64 moon_atlas.dds

    echo "Generating compass atlas..."
    generate_compass_atlas 88 36 compass_atlas.dds

    echo "Generating MoonHUD panels..."
    generate_moonhud_panels noise_base.dds noise_highlight.dds 256

    echo "Done: moon_atlas.dds, compass_atlas.dds, panel_circle.dds,"
    echo "      panel_circle_border.dds, panel_bg_stone.dds, panel_bg_linen.dds"
fi
