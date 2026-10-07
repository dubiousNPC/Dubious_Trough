"""Renames `SoundGenRef:` footstep markers to `SoundGen:` in Morrowind .kf text keys.

The Katars animation set labels its footstep markers `SoundGenRef: Left` / `Right`.
Vanilla, FBA's `xbase_anim.1st.kf` and ReAnimation's own 96 animations all use
`SoundGen:` - ReAnimation in 20 of its 96 files, FBA throughout.

Two things go wrong with the `Ref` spelling, one certain and one near-certain:

  * ReAnimation's `fba_merge` only reads step phases from a group literally named
    `soundgen` (`if g != 'soundgen' ... continue`), and its `NOT_GROUPS` filter only
    excludes `soundgen` and `sound`. So `soundgenref` is taken for an animation group:
    the merge finds no footsteps on either side and falls back to stretching loop to
    loop, and the markers are laid out as a segment of their own, which moves them
    outside every movement group in the converted file. Measured on the Katars set:
    24 "no usable step markers" warnings and 4 "no 3rd-person group matches its name".

  * The engine reads footstep sounds off `SoundGen:` keys, so footsteps are unlikely to
    fire for these animations at all. That part is inferred from the convention rather
    than read out of the engine source, which was not available here - but the fix is the
    same either way, and it is the spelling every other animation in the stack uses.

Renaming is purely textual: `nifkf` parses the text key block, so nothing else in the
file moves. Writes `<name>.kf` into the output folder, leaving the inputs untouched.

Usage:
    python3 -I fix_soundgen.py <in dir> <out dir> [--dry-run]
"""
import argparse
import os
import sys

TOOLS = os.environ.get('FBACOMPAT_TOOLS')
if TOOLS and TOOLS not in sys.path:
    sys.path.insert(0, TOOLS)

import nifkf

WRONG = 'SoundGenRef:'
RIGHT = 'SoundGen:'


def fix_file(path, out_path, dry_run=False):
    """Returns the number of marker lines renamed."""
    kf = nifkf.KF.load(path)
    keys = kf.blocks[kf.textkey_block][1]['keys']
    renamed = 0
    for index, (time, text) in enumerate(keys):
        if WRONG.lower() not in text.lower():
            continue
        lines = []
        for line in text.split('\n'):
            stripped = line.lstrip()
            if stripped.lower().startswith(WRONG.lower()):
                prefix = line[:len(line) - len(stripped)]
                lines.append(prefix + RIGHT + stripped[len(WRONG):])
                renamed += 1
            else:
                lines.append(line)
        keys[index] = (time, '\n'.join(lines))
    if renamed and not dry_run:
        kf.save(out_path)
    return renamed


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('source')
    parser.add_argument('destination')
    parser.add_argument('--dry-run', action='store_true')
    args = parser.parse_args()

    if not args.dry_run:
        os.makedirs(args.destination, exist_ok=True)

    total = 0
    touched = 0
    for name in sorted(os.listdir(args.source)):
        if not name.lower().endswith('.kf'):
            continue
        source = os.path.join(args.source, name)
        destination = os.path.join(args.destination, name)
        renamed = fix_file(source, destination, args.dry_run)
        if renamed:
            print('  %-30s %d marker(s) renamed' % (name, renamed))
            total += renamed
            touched += 1
        elif not args.dry_run:
            # Unchanged files still belong in a complete output folder.
            with open(source, 'rb') as src, open(destination, 'wb') as dst:
                dst.write(src.read())
    print('%d marker(s) in %d file(s)%s' % (total, touched, ' (dry run)' if args.dry_run else ''))
    return 0


if __name__ == '__main__':
    sys.exit(main())
