"""Check that a skinned creature's mesh actually follows its skeleton.

Imports a .nif pair, steps through the animation, and measures how far each
mesh's evaluated vertices move between frames. A mesh whose weights failed to
transfer stays put while the bones move - this catches that, which a structural
check of the file cannot.

    blender -b --factory-startup --python check_deform.py -- \
        --nif av_bonehound3.nif [--compare nixhound.nif] [--frames 12]
"""

import argparse
import os
import sys

import bpy


def parse_args():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    p = argparse.ArgumentParser(prog="check_deform.py")
    p.add_argument("--nif", required=True)
    p.add_argument("--compare", help="a reference .nif to measure against")
    p.add_argument("--frames", type=int, default=12, help="samples across the action")
    p.add_argument("--scripts", help="scripts dir holding addons/io_scene_mw")
    p.add_argument("--min-motion", type=float, default=1e-4,
                   help="a mesh moving less than this across the clip is considered static")
    return p.parse_args(argv)


def enable_addon(scripts=None):
    if scripts:
        entry = bpy.context.preferences.filepaths.script_directories.new()
        entry.name, entry.directory = "deform", scripts
        addons = os.path.join(scripts, "addons")
        if addons not in sys.path:
            sys.path.append(addons)
        bpy.utils.refresh_script_paths()
    import addon_utils
    addon_utils.enable("io_scene_mw", default_set=True, handle_error=None)


def clear_scene():
    for obj in list(bpy.data.objects):
        bpy.data.objects.remove(obj, do_unlink=True)


def evaluated_points(obj, depsgraph):
    """World-space vertex positions after modifiers (the armature) are applied."""
    evaluated = obj.evaluated_get(depsgraph)
    mesh = evaluated.to_mesh()
    try:
        matrix = evaluated.matrix_world
        return [matrix @ v.co.copy() for v in mesh.vertices]
    finally:
        evaluated.to_mesh_clear()


def measure(path, frames, scripts_done=False):
    clear_scene()
    bpy.ops.import_scene.mw(filepath=os.path.abspath(path))
    meshes = [o for o in bpy.data.objects if o.type == 'MESH']
    armatures = [o for o in bpy.data.objects if o.type == 'ARMATURE']
    if not armatures:
        return None, "no armature in the file"
    armature = armatures[0]

    action = armature.animation_data.action if armature.animation_data else None
    if action is None:
        return None, "the armature carries no action"
    start, end = (int(round(v)) for v in action.frame_range)
    if end <= start:
        return None, f"empty frame range {start}..{end}"

    step = max(1, (end - start) // max(1, frames - 1))
    sample_frames = list(range(start, end + 1, step))[:frames]

    depsgraph = bpy.context.evaluated_depsgraph_get()
    first = {}
    travel = {o.name: 0.0 for o in meshes}
    previous = {}
    for frame in sample_frames:
        bpy.context.scene.frame_set(frame)
        depsgraph = bpy.context.evaluated_depsgraph_get()
        for obj in meshes:
            points = evaluated_points(obj, depsgraph)
            if obj.name not in first:
                first[obj.name] = points
                previous[obj.name] = points
                continue
            moved = max((a - b).length for a, b in zip(points, previous[obj.name],))
            travel[obj.name] = max(travel[obj.name], moved)
            previous[obj.name] = points

    spread = {}
    for obj in meshes:
        bpy.context.scene.frame_set(sample_frames[-1])
        depsgraph = bpy.context.evaluated_depsgraph_get()
        last = evaluated_points(obj, depsgraph)
        spread[obj.name] = max((a - b).length for a, b in zip(last, first[obj.name]))

    info = {
        "armature": armature.name,
        "bones": len(armature.data.bones),
        "frames": (start, end),
        "sampled": sample_frames,
        "meshes": {o.name: {
            "verts": len(o.data.vertices),
            "groups": len(o.vertex_groups),
            "has_armature_modifier": any(m.type == 'ARMATURE' for m in o.modifiers),
            "max_step": travel[o.name],
            "start_to_end": spread[o.name],
        } for o in meshes},
    }
    return info, None


def main():
    args = parse_args()
    enable_addon(args.scripts)

    info, error = measure(args.nif, args.frames)
    print(f"\n=== {os.path.basename(args.nif)}")
    if error:
        print(f"  FAIL: {error}")
        sys.exit(1)
    print(f"  armature {info['armature']!r}, {info['bones']} bones, frames {info['frames'][0]}..{info['frames'][1]}")

    failures = []
    for name, m in info["meshes"].items():
        verdict = "moves" if m["max_step"] > args.min_motion else "STATIC"
        if verdict == "STATIC":
            failures.append(name)
        print(f"  {name!r:30} verts={m['verts']:5} groups={m['groups']:3} "
              f"armature_mod={'y' if m['has_armature_modifier'] else 'n'} "
              f"max_step={m['max_step']:.4f} start_to_end={m['start_to_end']:.4f}  {verdict}")

    if args.compare:
        ref, ref_error = measure(args.compare, args.frames)
        print(f"\n=== reference {os.path.basename(args.compare)}")
        if ref_error:
            print(f"  (skipped: {ref_error})")
        else:
            for name, m in ref["meshes"].items():
                print(f"  {name!r:30} verts={m['verts']:5} max_step={m['max_step']:.4f} "
                      f"start_to_end={m['start_to_end']:.4f}")
            ours = max(v["max_step"] for v in info["meshes"].values())
            theirs = max(v["max_step"] for v in ref["meshes"].values())
            ratio = ours / theirs if theirs else 0
            print(f"\n  peak motion: ours {ours:.4f} vs reference {theirs:.4f}  (ratio {ratio:.2f})")
            if not 0.2 <= ratio <= 5.0:
                print("  WARNING: motion scale differs from the reference by more than 5x")

    print()
    if failures:
        print(f"FAIL: {len(failures)} mesh(es) do not move with the skeleton: {failures}")
        sys.exit(1)
    print("PASS: every mesh deforms with the skeleton")
    sys.exit(0)


if __name__ == "__main__":
    main()
