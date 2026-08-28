#!/usr/bin/env bash
#
# generate_all_menus.sh
#
# Builds every theme. Same output as the original: one directory per theme, each
# containing a Textures/ folder. Rewritten as a table so adding a theme is one
# line rather than a six-line copy-paste block.
#
# Each row is:  name | flags passed to generate_menu.sh
#
# Usage:
#   ./generate_all_menus.sh              build every theme
#   ./generate_all_menus.sh Cobalt Mono  build only the named themes
#   KEEP_GOING=1 ./generate_all_menus.sh continue past a failing theme

set -euo pipefail

THEMES=(
    "ArcaneEnergy|-p AA00FF -t 5500AA -s E040FB"
    "MysticOcean|-p 0074d9 -s 001f3f -t 7fdbff"
    "momw|-p 222 -s 444 -t 333"
    "Prim|-p f1ecf6 -s 7a49a5 -t d7c8e4"
    "PickleRick|-p a3ffb4 -t 4974a5 -s 304c36"
    "White-Rose|-p 843c54 -t 5c2a3a -s 271219"
    "Beige|-p ffa500 -t 4974a5 -s fff6e5"
    "America|-p fff -t f00 -s 00f"
    "Rose|"
    "Royale|-p 000 -t 180e21 -s 492b63"
    "Blood-Raven|-p ff0000 -t 190000 -s 000000"
    "Mono|-p 000 -s 333 -t fff"
    "VeryDark|-p fff -s 333 -t 111"
    "Cobalt|-p 000000 -s 0066ff -t 002866 -pts 14"
    "IndustrialSteel|-t 3d3d3d -s 7f8c8d -p bdc3c7"
)

wanted=("$@")

want_theme() {
    [ ${#wanted[@]} -eq 0 ] && return 0
    local t
    for t in "${wanted[@]}"; do
        [ "$t" == "$1" ] && return 0
    done
    return 1
}

built=0
failed=()

for row in "${THEMES[@]}"; do
    name="${row%%|*}"
    flags="${row#*|}"

    want_theme "$name" || continue

    echo "=== $name ==="

    # shellcheck disable=SC2086
    if rm -rf "$name" \
        && ./generate_menu.sh $flags \
        && mkdir -p "$name" \
        && mv Textures "$name"
    then
        built=$((built + 1))
    else
        echo "!!! $name failed" >&2
        failed+=("$name")
        [ -n "${KEEP_GOING:-}" ] || exit 1
    fi
done

echo
echo "Built $built theme(s)."
if [ ${#failed[@]} -gt 0 ]; then
    echo "Failed: ${failed[*]}" >&2
    exit 1
fi

if [ ${#wanted[@]} -gt 0 ] && [ "$built" -eq 0 ]; then
    echo "No theme matched: ${wanted[*]}" >&2
    echo "Known themes:" >&2
    for row in "${THEMES[@]}"; do echo "  ${row%%|*}" >&2; done
    exit 1
fi
