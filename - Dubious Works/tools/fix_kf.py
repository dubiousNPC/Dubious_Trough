#!/usr/bin/env python3
"""fix_kf.py v2 — repair Morrowind .kf animation files.

Two jobs, one script.

1. Fix the skeleton root name (no dependencies).

   Entry 0 of a .kf's NiStringExtraData chain is the skeleton root. Morrowind
   expects "Bip01". A .kf exported from Blender takes that name from the
   *armature object's* name, so a beast rig called "Khajiit Armature" produces:

       Warning: addAnimSource: can't find bone 'khajiit armature' in
       meshes/xbase_animkna.1st.nif

   The root is renamed, never removed — removing it would drop root motion.

2. Remove references to bones that do not exist in the skeleton (needs pyffi).

   The original job: strip 3ds Max Biped leftovers such as Finger02, Finger3*,
   Finger4* and Toe0 that produce one warning each on every load.

Usage
    # rename the root to Bip01 (auto-detects any wrong root)
    python fix_kf.py in.kf out.kf

    # rename to something else
    python fix_kf.py in.kf out.kf --root "Bip01"

    # inspect without writing
    python fix_kf.py in.kf --list

    # also strip phantom bones (requires pyffi, Python 3.8-3.11)
    python fix_kf.py in.kf out.kf --remove-bones "Bip01 L Finger02,Bip01 R Toe0"

    # batch a whole folder in place-ish (writes *.fixed.kf beside each input)
    python fix_kf.py animations/ --batch

Verify the result with --list: entry 0 should read 'Bip01'.
"""

import argparse
import os
import struct
import sys

DEFAULT_ROOT = "Bip01"
TYPE_NAME = b"NiStringExtraData"


# ---------------------------------------------------------------------------
# Raw .kf reading — no external dependencies
# ---------------------------------------------------------------------------

def read_header(data):
    """Return (version, block_count, offset_after_header)."""
    newline = data.find(b"\n")
    if newline < 0 or not data.startswith(b"NetImmerse File Format"):
        raise ValueError("not a NetImmerse/Gamebryo file")
    offset = newline + 1
    version, = struct.unpack_from("<I", data, offset)
    block_count, = struct.unpack_from("<I", data, offset + 4)
    return version, block_count, offset + 8


def find_string_extra_data(data):
    """Locate every NiStringExtraData record.

    Yields (string_offset, string_length, text). string_offset points at the
    uint32 length prefix, so a rewrite replaces from there.

    Record layout in NIF 4.0.0.2:
        uint32 type_name_length, char type_name[]
        int32  next_extra_data      (link)
        uint32 bytes_remaining      (0 in practice, not a length)
        uint32 string_length, char string[]
    """
    records = []
    index = 0
    while True:
        index = data.find(TYPE_NAME, index)
        if index < 0:
            break
        # A genuine block header is preceded by its own length as uint32.
        if index >= 4:
            name_length, = struct.unpack_from("<I", data, index - 4)
            if name_length == len(TYPE_NAME):
                pointer = index + len(TYPE_NAME) + 4 + 4   # skip link + bytes_remaining
                string_length, = struct.unpack_from("<I", data, pointer)
                if 0 < string_length < 1024 and pointer + 4 + string_length <= len(data):
                    text = data[pointer + 4:pointer + 4 + string_length].decode("latin-1")
                    records.append((pointer, string_length, text))
        index += 1
    return records


def list_targets(path):
    data = open(path, "rb").read()
    version, block_count, _ = read_header(data)
    records = find_string_extra_data(data)
    print(f"{path}")
    print(f"  version 0x{version:08x}   blocks {block_count}   targets {len(records)}   {len(data)} bytes")
    for position, (_offset, _length, text) in enumerate(records):
        note = ""
        if position == 0:
            note = "   <-- skeleton root" + ("" if text == DEFAULT_ROOT else "   *** WRONG ***")
        print(f"  [{position:3}] {text!r}{note}")
    return records


# ---------------------------------------------------------------------------
# Job 1: rename the skeleton root
# ---------------------------------------------------------------------------

def rename_targets(data, renames):
    """Rebuild the file with the given {old: new} target renames applied.

    Records are rewritten back to front so earlier offsets stay valid. Only the
    length prefix and the string bytes change; NIF 4.0.0.2 parses sequentially
    and stores no absolute offsets, and `bytes_remaining` is 0 rather than a
    length, so nothing else needs adjusting.
    """
    records = find_string_extra_data(data)
    applied = []
    output = bytearray(data)

    for offset, length, text in reversed(records):
        if text not in renames:
            continue
        replacement = renames[text]
        encoded = replacement.encode("latin-1")
        output[offset:offset + 4 + length] = struct.pack("<I", len(encoded)) + encoded
        applied.append((text, replacement))

    return bytes(output), list(reversed(applied))


def looks_like_a_rig_bone(name):
    """True when entry 0 names a bone the skeleton really has, rather than a stray
    armature-object name.

    The auto-detect must not fire on these. A kf that animates only the upper body can
    legitimately start at `Bip01 Spine1`, and renaming that to `Bip01` does not fix
    anything - it applies the chest's animation to the root bone, which is a silent
    break in a file the engine was perfectly happy with. The giveaway is that a real
    bone produces no `can't find bone` warning in the first place, so there is nothing
    to repair; `Khajiit Armature` does.
    """
    lowered = name.strip().lower()
    return lowered == "bip01" or lowered.startswith("bip01 ")


def fix_root(input_path, output_path, root_name=DEFAULT_ROOT, extra_renames=None, quiet=False,
             force=False):
    data = open(input_path, "rb").read()
    read_header(data)
    records = find_string_extra_data(data)

    if not records:
        print(f"  {os.path.basename(input_path)}: no animation targets found, skipped")
        return False

    renames = dict(extra_renames or {})
    current_root = records[0][2]

    if current_root != root_name and current_root not in renames:
        if looks_like_a_rig_bone(current_root) and not force:
            if not quiet:
                print(f"  {os.path.basename(input_path)}: root is {current_root!r}, which is a real "
                      f"rig bone - not renaming (use --rename {current_root}={root_name} or "
                      f"--force-root if you are sure)")
            if not renames:
                return False
        else:
            renames[current_root] = root_name
    elif current_root == root_name and not renames:
        if not quiet:
            print(f"  {os.path.basename(input_path)}: root is already {root_name!r}, nothing to do")
        return False

    result, applied = rename_targets(data, renames)
    if not applied:
        if not quiet:
            print(f"  {os.path.basename(input_path)}: nothing matched, nothing written")
        return False

    with open(output_path, "wb") as handle:
        handle.write(result)

    for old, new in applied:
        print(f"  {os.path.basename(input_path)}: {old!r} -> {new!r}")

    verify = find_string_extra_data(open(output_path, "rb").read())
    if verify[0][2] != root_name:
        raise RuntimeError(f"verification failed: root is {verify[0][2]!r}, expected {root_name!r}")
    if len(verify) != len(records):
        raise RuntimeError(f"verification failed: {len(verify)} targets, expected {len(records)}")

    print(f"  {os.path.basename(input_path)}: wrote {output_path} "
          f"({len(records)} targets intact, root verified)")
    return True


# ---------------------------------------------------------------------------
# Job 2: remove bones that do not exist in the skeleton
#
# Two backends. `nifkf` is ReAnimation's own .kf parser (Sources/Tools/FBACompat),
# preferred because it is a single file with no dependencies and runs on any Python 3.
# pyffi is the original backend, kept as a fallback; it has no distribution for Python
# 3.12+ and `pip install pyffi` fails outright there, which made this job unusable.
# ---------------------------------------------------------------------------

PHANTOM_FINGERS = [
    "Bip01 %s Finger%s" % (side, joint)
    for side in ("L", "R")
    # The Morrowind rig has three fingers per hand with one sub-joint each
    # (Finger0/01, Finger1/11, Finger2/21). Everything below is a 3ds Max Biped
    # leftover: second sub-joints, and fingers 3 and 4 entirely.
    for joint in ("02", "12", "22", "3", "31", "32", "4", "41", "42")
]


def _import_nifkf():
    """nifkf from beside this script, from $FBACOMPAT_TOOLS, or already importable."""
    for candidate in (os.environ.get("FBACOMPAT_TOOLS"), os.path.dirname(os.path.abspath(__file__))):
        if candidate and os.path.isfile(os.path.join(candidate, "nifkf.py")):
            if candidate not in sys.path:
                sys.path.insert(0, candidate)
            break
    import nifkf
    return nifkf


def remove_bones_nifkf(input_path, output_path, bone_names):
    """Drops each named bone's (string, controller, keyframe data) triple.

    A .kf holds two parallel chains off the NiSequenceStreamHelper: extra data (the text
    keys, then one NiStringExtraData per bone name) and controllers (one
    NiKeyframeController per bone, in the same order). Removing a bone means unlinking
    one entry from each chain and dropping its keyframe data, then rebuilding the block
    list and remapping every index that pointed into it.

    The only indices in the file are helper.extra/ctrl, the `next` links, and
    NiKeyframeController.data; `target` is -1 throughout a .kf, and the footer names
    block 0 as the only root, which never moves. So no other fixups are needed.
    """
    nifkf = _import_nifkf()
    kf = nifkf.KF.load(input_path)
    wanted = {name.strip().lower() for name in bone_names if name.strip()}

    helper = kf.blocks[0][1]

    def chain(start):
        out = []
        index = start
        while index >= 0:
            out.append(index)
            index = kf.blocks[index][1]["next"]
        return out

    extra_chain = chain(helper["extra"])
    ctrl_chain = chain(helper["ctrl"])
    name_blocks = [i for i in extra_chain if kf.blocks[i][0] == "NiStringExtraData"]

    if len(name_blocks) != len(ctrl_chain):
        print("ERROR: %s: %d bone names vs %d controllers; refusing to guess the pairing."
              % (os.path.basename(input_path), len(name_blocks), len(ctrl_chain)), file=sys.stderr)
        return False

    drop = set()
    removed = []
    for name_index, ctrl_index in zip(name_blocks, ctrl_chain):
        value = kf.blocks[name_index][1]["value"]
        if value.strip().lower() not in wanted:
            continue
        removed.append(value)
        drop.add(name_index)
        drop.add(ctrl_index)
        data = kf.blocks[ctrl_index][1]["data"]
        if data >= 0:
            drop.add(data)

    if not removed:
        print("  %s: none of those bones are referenced" % os.path.basename(input_path))
        return False

    # Relink both chains in their original order, skipping what goes.
    for name, start in (("extra", extra_chain), ("ctrl", ctrl_chain)):
        kept = [i for i in start if i not in drop]
        if not kept:
            print("ERROR: %s: removing those bones would empty the %s chain."
                  % (os.path.basename(input_path), name), file=sys.stderr)
            return False
        for a, b in zip(kept, kept[1:]):
            kf.blocks[a][1]["next"] = b
        kf.blocks[kept[-1]][1]["next"] = -1
        helper[name] = kept[0]

    keep = [i for i in range(len(kf.blocks)) if i not in drop]
    remap = {old: new for new, old in enumerate(keep)}
    kf.blocks = [kf.blocks[i] for i in keep]

    def fix(payload, field):
        if payload[field] >= 0:
            payload[field] = remap[payload[field]]

    for block_type, payload in kf.blocks:
        if block_type == "NiSequenceStreamHelper":
            fix(payload, "extra")
            fix(payload, "ctrl")
        elif block_type in ("NiTextKeyExtraData", "NiStringExtraData"):
            fix(payload, "next")
        elif block_type == "NiKeyframeController":
            fix(payload, "next")
            fix(payload, "data")

    kf.save(output_path)

    check = nifkf.KF.load(output_path)
    still_there = sorted(b for b in check.bone_data if b.strip().lower() in wanted)
    if still_there:
        raise RuntimeError("verification failed: %s still referenced" % ", ".join(still_there))

    print("  %s: removed %d bone(s): %s"
          % (os.path.basename(input_path), len(removed), ", ".join(removed)))
    return True


def remove_bones(input_path, output_path, bone_names):
    try:
        _import_nifkf()
    except ImportError:
        pass
    else:
        return remove_bones_nifkf(input_path, output_path, bone_names)

    try:
        import time
        if not hasattr(time, "clock"):
            time.clock = time.perf_counter   # pyffi predates its removal in 3.8
        from pyffi.formats.nif import NifFormat
    except ImportError:
        print("ERROR: --remove-bones needs either nifkf.py (ReAnimation's "
              "Sources/Tools/FBACompat, pass it as $FBACOMPAT_TOOLS) or pyffi.", file=sys.stderr)
        print("       pyffi has no distribution for Python 3.12+. The root rename needs neither.",
              file=sys.stderr)
        return False

    wanted = {name.strip().lower() for name in bone_names if name.strip()}

    stream = NifFormat.Data()
    with open(input_path, "rb") as handle:
        stream.read(handle)

    root = stream.roots[0]

    def as_text(value):
        if isinstance(value, bytes):
            return value.decode("latin-1").rstrip("\x00")
        return str(value).rstrip("\x00")

    string_chain, node = [], root.extra_data
    while node:
        string_chain.append(node)
        node = node.next_extra_data

    controller_chain, node = [], root.controller
    while node:
        controller_chain.append(node)
        node = node.next_controller

    if len(string_chain) != len(controller_chain):
        print(f"ERROR: {len(string_chain)} string entries vs {len(controller_chain)} controllers; "
              "refusing to guess the pairing.", file=sys.stderr)
        return False

    keep_strings, keep_controllers, removed = [], [], []
    for extra, controller in zip(string_chain, controller_chain):
        name = as_text(extra.string_data)
        if name.lower() in wanted:
            removed.append(name)
        else:
            keep_strings.append(extra)
            keep_controllers.append(controller)

    if not removed:
        print(f"  {os.path.basename(input_path)}: none of those bones are referenced")
        return False

    for index, extra in enumerate(keep_strings):
        extra.next_extra_data = keep_strings[index + 1] if index + 1 < len(keep_strings) else None
    for index, controller in enumerate(keep_controllers):
        controller.next_controller = keep_controllers[index + 1] if index + 1 < len(keep_controllers) else None

    root.extra_data = keep_strings[0] if keep_strings else None
    root.controller = keep_controllers[0] if keep_controllers else None

    with open(output_path, "wb") as handle:
        stream.write(handle)

    print(f"  {os.path.basename(input_path)}: removed {len(removed)} bone(s): {', '.join(removed)}")
    return True


# ---------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(
        description="Repair Morrowind .kf files: fix the skeleton root name, "
                    "and optionally strip references to bones the skeleton lacks.")
    parser.add_argument("input", help=".kf file, or a folder when using --batch")
    parser.add_argument("output", nargs="?", help="output .kf (defaults to <input>.fixed.kf)")
    parser.add_argument("--root", default=DEFAULT_ROOT,
                        help=f"expected skeleton root name (default {DEFAULT_ROOT})")
    parser.add_argument("--rename", action="append", default=[], metavar="OLD=NEW",
                        help="rename any other target; repeatable")
    parser.add_argument("--remove-bones", default="",
                        help="comma-separated bone names to strip entirely")
    parser.add_argument("--phantom-fingers", action="store_true",
                        help="strip the 18 3ds Max Biped finger joints the Morrowind rig lacks "
                             "(Finger02/12/22 and Finger3*/Finger4*, both hands)")
    parser.add_argument("--force-root", action="store_true",
                        help="rename entry 0 even when it names a real rig bone (see "
                             "looks_like_a_rig_bone); almost always the wrong thing to do")
    parser.add_argument("--list", action="store_true", help="print the target list and exit")
    parser.add_argument("--batch", action="store_true",
                        help="treat input as a folder and process every .kf inside")
    parser.add_argument("--out-dir", metavar="DIR",
                        help="with --batch, write same-named files into DIR (copying the ones that "
                             "needed nothing) instead of *.fixed.kf beside each input")
    args = parser.parse_args()

    remove = [b for b in args.remove_bones.split(",") if b.strip()]
    if args.phantom_fingers:
        remove += PHANTOM_FINGERS

    extra_renames = {}
    for pair in args.rename:
        if "=" not in pair:
            parser.error(f"--rename expects OLD=NEW, got {pair!r}")
        old, new = pair.split("=", 1)
        extra_renames[old] = new

    if args.list:
        if os.path.isdir(args.input):
            for name in sorted(os.listdir(args.input)):
                if name.lower().endswith(".kf"):
                    list_targets(os.path.join(args.input, name))
                    print()
        else:
            list_targets(args.input)
        return 0

    if args.batch:
        if not os.path.isdir(args.input):
            parser.error("--batch expects a folder")
        if args.out_dir:
            os.makedirs(args.out_dir, exist_ok=True)
        changed = 0
        total = 0
        for name in sorted(os.listdir(args.input)):
            if not name.lower().endswith(".kf") or name.lower().endswith(".fixed.kf"):
                continue
            total += 1
            source = os.path.join(args.input, name)
            if args.out_dir:
                destination = os.path.join(args.out_dir, name)
            else:
                destination = os.path.join(args.input, name[:-3] + ".fixed.kf")
            try:
                touched = False
                if remove:
                    staging = destination + ".tmp"
                    if remove_bones(source, staging, remove):
                        touched = True
                        # The rename runs over the stripped file, so one pass does both.
                        if not fix_root(staging, destination, args.root, extra_renames, quiet=True, force=args.force_root):
                            os.replace(staging, destination)
                        else:
                            os.remove(staging)
                if not touched:
                    touched = fix_root(source, destination, args.root, extra_renames, quiet=True, force=args.force_root)
                if touched:
                    changed += 1
                elif args.out_dir:
                    # Keep the output folder a complete, drop-in replacement.
                    with open(source, "rb") as src, open(destination, "wb") as dst:
                        dst.write(src.read())
            except (ValueError, RuntimeError) as error:
                print(f"  {name}: {error}", file=sys.stderr)
        print(f"\n{changed} of {total} file(s) rewritten.")
        return 0

    output = args.output or (args.input[:-3] + ".fixed.kf")
    if os.path.abspath(output) == os.path.abspath(args.input):
        parser.error("refusing to overwrite the input; choose a different output path")

    if remove:
        staging = output + ".tmp"
        if remove_bones(args.input, staging, remove):
            # fix_root writes nothing when there is nothing to rename, which is the normal
            # case here, so the stripped file has to be promoted rather than discarded.
            if fix_root(staging, output, args.root, extra_renames, force=args.force_root):
                os.remove(staging)
            else:
                os.replace(staging, output)
        else:
            fix_root(args.input, output, args.root, extra_renames, force=args.force_root)
    else:
        fix_root(args.input, output, args.root, extra_renames, force=args.force_root)

    return 0


if __name__ == "__main__":
    sys.exit(main())
