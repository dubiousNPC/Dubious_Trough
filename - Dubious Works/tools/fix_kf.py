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


def fix_root(input_path, output_path, root_name=DEFAULT_ROOT, extra_renames=None, quiet=False):
    data = open(input_path, "rb").read()
    read_header(data)
    records = find_string_extra_data(data)

    if not records:
        print(f"  {os.path.basename(input_path)}: no animation targets found, skipped")
        return False

    renames = dict(extra_renames or {})
    current_root = records[0][2]

    if current_root != root_name:
        renames[current_root] = root_name
    elif not renames:
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
# Job 2: remove bones that do not exist in the skeleton (needs pyffi)
# ---------------------------------------------------------------------------

def remove_bones(input_path, output_path, bone_names):
    try:
        import time
        if not hasattr(time, "clock"):
            time.clock = time.perf_counter   # pyffi predates its removal in 3.8
        from pyffi.formats.nif import NifFormat
    except ImportError:
        print("ERROR: --remove-bones needs pyffi.  pip install pyffi", file=sys.stderr)
        print("       pyffi requires Python 3.8-3.11. The root rename does not need it.",
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
                        help="comma-separated bone names to strip entirely (requires pyffi)")
    parser.add_argument("--list", action="store_true", help="print the target list and exit")
    parser.add_argument("--batch", action="store_true",
                        help="treat input as a folder and process every .kf inside")
    args = parser.parse_args()

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
        changed = 0
        for name in sorted(os.listdir(args.input)):
            if not name.lower().endswith(".kf") or name.lower().endswith(".fixed.kf"):
                continue
            source = os.path.join(args.input, name)
            destination = os.path.join(args.input, name[:-3] + ".fixed.kf")
            try:
                if fix_root(source, destination, args.root, extra_renames, quiet=True):
                    changed += 1
            except (ValueError, RuntimeError) as error:
                print(f"  {name}: {error}", file=sys.stderr)
        print(f"\n{changed} file(s) rewritten.")
        return 0

    output = args.output or (args.input[:-3] + ".fixed.kf")
    if os.path.abspath(output) == os.path.abspath(args.input):
        parser.error("refusing to overwrite the input; choose a different output path")

    if args.remove_bones:
        staging = output + ".tmp"
        if remove_bones(args.input, staging, args.remove_bones.split(",")):
            fix_root(staging, output, args.root, extra_renames)
            os.remove(staging)
        else:
            fix_root(args.input, output, args.root, extra_renames)
    else:
        fix_root(args.input, output, args.root, extra_renames)

    return 0


if __name__ == "__main__":
    sys.exit(main())
