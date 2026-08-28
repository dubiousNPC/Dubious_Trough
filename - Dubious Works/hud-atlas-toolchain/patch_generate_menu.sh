#!/usr/bin/env bash
#
# patch_generate_menu.sh
#
# Applies five fixes to generate_menu.sh, and hooks in the HUD atlas generator.
# Idempotent: run it twice and the second run reports everything already applied.
# Writes generate_menu.sh.bak before touching anything.
#
#   1  shebang says sh, the script is bash throughout
#   2  generate_text_image leaks four globals
#   3  duplicate -t|--texture case
#   4  -pk and -sk write to a variable nothing reads
#   5  hook generate_hud_atlases.sh in before the textures are moved
#
# Usage: ./patch_generate_menu.sh [path/to/generate_menu.sh]

set -euo pipefail

TARGET="${1:-generate_menu.sh}"

if [ ! -f "$TARGET" ]; then
    echo "error: $TARGET not found" >&2
    exit 1
fi

python3 - "$TARGET" <<'PYEOF'
import sys, shutil, os

path = sys.argv[1]
src = open(path, encoding='utf-8').read()
orig = src
applied, skipped = [], []


def swap(name, old, new, count=1, guard=None):
    """Replace old with new.

    `guard` is a marker that only exists once the fix is in. Some of these
    replacements leave their own search pattern intact, so without a guard a
    second run would apply them again.
    """
    global src
    if guard is not None and guard in src:
        skipped.append(f"{name} (already applied)")
        return
    if old not in src:
        if new in src:
            skipped.append(f"{name} (already applied)")
        else:
            skipped.append(f"{name} (PATTERN NOT FOUND - check manually)")
        return
    src = src.replace(old, new, count)
    applied.append(name)


# --- 1. shebang -------------------------------------------------------------
# Arrays, [[ ]], local, $RANDOM, ${var,,} and pipefail are all bash. Under a real
# POSIX sh (dash, which is /bin/sh on Debian and Ubuntu) this dies at the first
# array assignment.
swap("1. shebang -> bash",
     "#!/usr/bin/env sh\n",
     "#!/usr/bin/env bash\n")

# --- 2. leaking globals in generate_text_image ------------------------------
# prefix, texture, state and buttonsecondarycolor were never declared local, so
# they persisted between calls. The journal loop only worked because it inherited
# -sc from the esc-menu loop above it. Defaults preserve that behaviour while
# making each call self-contained.
swap("2. generate_text_image locals",
     '''    local colortexture="noise_base.dds"
    local font="MysticCards"''',
     '''    local prefix=""
    local texture=""
    local state=".dds"
    local buttonsecondarycolor="${secondary_color:-#00ff99}"
    local colortexture="noise_base.dds"
    local font="MysticCards"''',
     guard='local buttonsecondarycolor=')

# --- 3. duplicate case arm --------------------------------------------------
_dup = '''            -t|--texture)
                if [[ -n "$2" ]]; then
                    texture="$2"
                    shift
                fi
                ;;
            -t|--texture)
                if [[ -n "$2" ]]; then
                    texture="$2"
                    shift
                fi
                ;;
'''
_single = '''            -t|--texture)
                if [[ -n "$2" ]]; then
                    texture="$2"
                    shift
                fi
                ;;
'''
swap("3. duplicate -t|--texture case", _dup, _single)

# --- 4. kerning flags -------------------------------------------------------
# Both wrote to `kerning`. The two places that consume kerning at top level read
# $primarykerning and $secondarykerning, so -pk and -sk silently did nothing.
swap("4a. -pk writes primarykerning",
     '''        -pk|--primary-kerning)
            if [[ -n "$2" ]]; then
                kerning="$2"
                shift
            fi
            ;;''',
     '''        -pk|--primary-kerning)
            if [[ -n "$2" ]]; then
                primarykerning="$2"
                shift
            fi
            ;;''')

swap("4b. -sk writes secondarykerning",
     '''        -sk|--secondary-kerning)
            if [[ -n "$2" ]]; then
                kerning="$2"
                shift
            fi
            ;;''',
     '''        -sk|--secondary-kerning)
            if [[ -n "$2" ]]; then
                secondarykerning="$2"
                shift
            fi
            ;;''')

# --- 5. HUD atlas hook ------------------------------------------------------
swap("5. hook generate_hud_atlases.sh",
     '''mkdir -p Textures
mv *dds Textures/''',
     '''# HUD widget atlases, drawn from this theme's noise textures. Optional, so
# generate_menu.sh still runs standalone if the generator is not alongside it.
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$_here/generate_hud_atlases.sh" ]; then
    # shellcheck source=generate_hud_atlases.sh
    source "$_here/generate_hud_atlases.sh"
    generate_moon_atlas noise_highlight.dds noise_base.dds 64 moon_atlas.dds
    generate_compass_atlas 88 36 compass_atlas.dds
else
    echo "note: generate_hud_atlases.sh not found, skipping HUD atlases"
fi

mkdir -p Textures
mv *dds Textures/''',
     guard="generate_hud_atlases.sh")

if src == orig:
    print("Nothing to do, everything already applied.")
else:
    shutil.copy2(path, path + ".bak")
    open(path, "w", encoding="utf-8").write(src)
    print(f"Backup written to {path}.bak")

print()
for a in applied:
    print(f"  applied  {a}")
for s in skipped:
    print(f"  skipped  {s}")

if any("NOT FOUND" in s for s in skipped):
    sys.exit(2)
PYEOF

echo
if bash -n "$TARGET"; then
    echo "bash -n $TARGET: OK"
else
    echo "WARNING: $TARGET no longer parses. Restore from $TARGET.bak" >&2
    exit 1
fi
