"""Put the original texture paths back after a round trip through Blender.

io_scene_mw normalises every NiSourceTexture filename on export: it lowercases
it and prefixes "textures\\".  Morrowind and OpenMW already resolve texture
names relative to Textures/, so a path that comes back as
"textures\\ashvigil\\av_bonehound.dds" is looked for at
Textures/textures/ashvigil/... and the creature renders untextured.

This copies the strings from the file the textures were working in, matched on
base name, and leaves everything else alone.

    python restore_texture_paths.py --mw-lib <io_scene_mw>/lib \
        --from original.nif target.nif [target.nif ...]
"""

import argparse
import ntpath
import os
import sys


def import_es3(explicit=None):
    for path in (explicit, os.environ.get("IO_SCENE_MW_LIB", "")):
        if path and os.path.isdir(os.path.join(path, "es3")):
            sys.path.insert(0, os.path.abspath(path))
            break
    from es3 import nif
    return nif


def originals(path, nif):
    stream = nif.NiStream()
    stream.load(path)
    out = {}
    for texture in stream.objects_of_type(nif.NiSourceTexture):
        name = getattr(texture, "filename", None)
        if name:
            out[ntpath.basename(name).lower()] = name
    return out


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--mw-lib")
    parser.add_argument("--from", dest="source", required=True)
    parser.add_argument("targets", nargs="+")
    args = parser.parse_args()
    nif = import_es3(args.mw_lib)

    wanted = originals(args.source, nif)
    print(f"{len(wanted)} texture path(s) in {os.path.basename(args.source)}:")
    for key, value in sorted(wanted.items()):
        print(f"  {value}")

    for target in args.targets:
        stream = nif.NiStream()
        stream.load(target)
        changed = 0
        for texture in stream.objects_of_type(nif.NiSourceTexture):
            name = getattr(texture, "filename", None)
            if not name:
                continue
            key = ntpath.basename(name).lower()
            if key in wanted and wanted[key] != name:
                texture.filename = wanted[key]
                changed += 1
        if changed:
            stream.save(target)
        print(f"  {os.path.basename(target)}: {changed} path(s) restored")


if __name__ == "__main__":
    main()
