"""Rebuild a rigid (unskinned) creature mesh as a skinned creature on a donor skeleton.

The case this solves: a creature model exported through a *static asset* path
(OpenMW Suite's makeobj / "export selected as object") comes out as a bare root
NiNode with Tri<name> shapes and no bones at all. Its .kf then targets 51 bones
that do not exist, OpenMW logs "can't find bone 'bip01'" for every one, and
nothing animates.

If the mesh was modelled on the donor creature's rest pose - the usual way, and
checkable by comparing world bounding boxes - the donor's own skin weights can
be transferred onto it, which is what this does:

    donor.nif   (vanilla, skinned, has the skeleton)
    rigid.nif   (your mesh, no bones)
        -> <out>/<name>.nif, x<name>.nif, x<name>.kf

Run inside Blender:

    blender -b --factory-startup --python reskin_creature.py -- \
        --donor nixhound.nif --mesh av_bonehound3.nif --name av_bonehound3 --out ./out
"""

import argparse
import os
import sys

import bpy
from mathutils import Vector


# ---------------------------------------------------------------- helpers

def parse_args():
    argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
    p = argparse.ArgumentParser(prog="reskin_creature.py")
    p.add_argument("--donor", required=True, help="vanilla skinned .nif supplying skeleton + weights")
    p.add_argument("--mesh", required=True, help="your unskinned .nif")
    p.add_argument("--name", required=True, help="output stem, e.g. av_bonehound3")
    p.add_argument("--out", required=True, help="output folder")
    p.add_argument("--addon", default="io_scene_mw", help="io_scene_mw module name")
    p.add_argument("--scripts", help="scripts dir holding addons/io_scene_mw")
    p.add_argument("--keep-donor-mesh", action="store_true",
                   help="keep the donor's own meshes in the output (debug)")
    p.add_argument("--save-blend", help="also save the assembled .blend here")
    return p.parse_args(argv)


def enable_addon(module, scripts=None):
    if scripts:
        entry = bpy.context.preferences.filepaths.script_directories.new()
        entry.name, entry.directory = "reskin", scripts
        addons = os.path.join(scripts, "addons")
        if addons not in sys.path:
            sys.path.append(addons)
        bpy.utils.refresh_script_paths()
    import addon_utils
    if addon_utils.enable(module, default_set=True, handle_error=None) is None:
        raise RuntimeError(f"could not enable {module!r}")


def clear_scene():
    for obj in list(bpy.data.objects):
        bpy.data.objects.remove(obj, do_unlink=True)


def world_bbox(objects):
    lo = Vector((1e18,) * 3)
    hi = Vector((-1e18,) * 3)
    for obj in objects:
        if obj.type != 'MESH':
            continue
        for corner in obj.bound_box:
            world = obj.matrix_world @ Vector(corner)
            for i in range(3):
                lo[i] = min(lo[i], world[i])
                hi[i] = max(hi[i], world[i])
    return lo, hi


def select_only(objects, active=None):
    bpy.ops.object.select_all(action='DESELECT')
    for obj in objects:
        obj.select_set(True)
    bpy.context.view_layer.objects.active = active or (objects[0] if objects else None)


# ---------------------------------------------------------------- the work

def transfer_weights(source_mesh, target, armature):
    """Copy the donor's vertex groups onto `target` by nearest surface point.

    Vertex groups must exist on the target before the Data Transfer modifier
    runs: with layers_vgroup_select_dst='NAME' it matches by name and will not
    create them, so a target with no groups silently receives nothing.
    """
    bone_names = [b.name for b in armature.data.bones]
    present = {vg.name for vg in target.vertex_groups}
    for name in bone_names:
        if name not in present:
            target.vertex_groups.new(name=name)

    select_only([target], active=target)
    modifier = target.modifiers.new(name="WeightTransfer", type='DATA_TRANSFER')
    modifier.object = source_mesh
    modifier.use_vert_data = True
    modifier.data_types_verts = {'VGROUP_WEIGHTS'}
    modifier.vert_mapping = 'POLYINTERP_NEAREST'      # interpolate across the nearest face
    modifier.layers_vgroup_select_src = 'ALL'
    modifier.layers_vgroup_select_dst = 'NAME'
    bpy.ops.object.modifier_apply(modifier=modifier.name)

    # Drop groups that ended up with no influence anywhere, so the exported
    # NiSkinInstance lists only bones that actually move this mesh.
    used = set()
    for vertex in target.data.vertices:
        for group in vertex.groups:
            if group.weight > 1e-6:
                used.add(target.vertex_groups[group.group].name)
    for vertex_group in list(target.vertex_groups):
        if vertex_group.name not in used:
            target.vertex_groups.remove(vertex_group)
    return used


def normalize_weights(target):
    select_only([target], active=target)
    bpy.ops.object.mode_set(mode='OBJECT')
    for vertex in target.data.vertices:
        total = sum(g.weight for g in vertex.groups)
        if total <= 1e-9:
            continue
        for group in vertex.groups:
            group.weight = group.weight / total


def unweighted_vertices(target):
    return [v.index for v in target.data.vertices
            if sum(g.weight for g in v.groups) <= 1e-9]


def main():
    args = parse_args()
    enable_addon(args.addon, args.scripts)
    os.makedirs(args.out, exist_ok=True)

    # --- donor -------------------------------------------------------------
    clear_scene()
    bpy.ops.import_scene.mw(filepath=os.path.abspath(args.donor))
    donor_meshes = [o for o in bpy.data.objects if o.type == 'MESH']
    armatures = [o for o in bpy.data.objects if o.type == 'ARMATURE']
    if not armatures:
        raise RuntimeError(f"{args.donor} has no armature; it cannot be a donor")
    armature = armatures[0]
    if not donor_meshes:
        raise RuntimeError(f"{args.donor} has no meshes to take weights from")
    source_mesh = max(donor_meshes, key=lambda o: len(o.data.vertices))
    donor_lo, donor_hi = world_bbox(donor_meshes)
    print(f"donor: armature {armature.name!r} with {len(armature.data.bones)} bones; "
          f"weights from {source_mesh.name!r} ({len(source_mesh.vertex_groups)} groups)")

    donor_names = {o.name for o in donor_meshes}

    # --- the rigid mesh ----------------------------------------------------
    bpy.ops.import_scene.mw(filepath=os.path.abspath(args.mesh))
    new_meshes = [o for o in bpy.data.objects
                  if o.type == 'MESH' and o.name not in donor_names]
    if not new_meshes:
        raise RuntimeError(f"{args.mesh} contributed no meshes")
    mesh_lo, mesh_hi = world_bbox(new_meshes)

    donor_size = tuple(round(donor_hi[i] - donor_lo[i], 3) for i in range(3))
    mesh_size = tuple(round(mesh_hi[i] - mesh_lo[i], 3) for i in range(3))
    print(f"donor world bbox size {donor_size}")
    print(f"mesh  world bbox size {mesh_size}")
    drift = max(abs(mesh_lo[i] - donor_lo[i]) for i in range(3))
    span = max(donor_size) or 1.0
    if drift > 0.25 * span:
        print(f"WARNING: the mesh sits {drift:.3f} from the donor (span {span:.3f}). "
              "Weight transfer assumes the mesh was modelled on the donor's rest pose.")

    # --- transfer ----------------------------------------------------------
    for target in new_meshes:
        # Drop any parent (the static exporter's root empty) but keep the
        # world position, then bind to the donor armature.
        world = target.matrix_world.copy()
        target.parent = None
        target.matrix_world = world

        used = transfer_weights(source_mesh, target, armature)
        normalize_weights(target)
        stray = unweighted_vertices(target)
        print(f"  {target.name!r}: {len(target.data.vertices)} verts -> {len(used)} bone(s)"
              + (f"; {len(stray)} vertex(es) got no weight" if stray else ""))
        if stray:
            # Anchor leftovers to the nearest donor vertex's heaviest bone so no
            # vertex is left behind at the origin when the creature moves.
            fallback = armature.data.bones[0].name
            heaviest = {}
            for vertex in source_mesh.data.vertices:
                best = max(vertex.groups, key=lambda g: g.weight, default=None)
                if best is not None:
                    heaviest[vertex.index] = source_mesh.vertex_groups[best.group].name
            import mathutils
            tree = mathutils.kdtree.KDTree(len(source_mesh.data.vertices))
            for vertex in source_mesh.data.vertices:
                tree.insert(source_mesh.matrix_world @ vertex.co, vertex.index)
            tree.balance()
            for index in stray:
                point = target.matrix_world @ target.data.vertices[index].co
                _co, nearest, _dist = tree.find(point)
                name = heaviest.get(nearest, fallback)
                group = target.vertex_groups.get(name) or target.vertex_groups.new(name=name)
                group.add([index], 1.0, 'REPLACE')

        target.parent = armature
        target.matrix_parent_inverse = armature.matrix_world.inverted()
        modifier = target.modifiers.new(name="Armature", type='ARMATURE')
        modifier.object = armature

    if not args.keep_donor_mesh:
        for obj in donor_meshes:
            bpy.data.objects.remove(obj, do_unlink=True)

    if args.save_blend:
        bpy.ops.wm.save_as_mainfile(filepath=os.path.abspath(args.save_blend))

    # --- export ------------------------------------------------------------
    # Everything under the armature, selected, exported as one creature. The
    # x.nif / x.kf pair comes from extract_keyframe_data.
    targets = [o for o in bpy.data.objects if o.type in ('MESH', 'ARMATURE', 'EMPTY')]
    select_only(targets, active=armature)
    full = os.path.join(os.path.abspath(args.out), f"{args.name}.nif")
    bpy.ops.export_scene.mw(filepath=full, use_selection=True,
                            export_animations=True, extract_keyframe_data=True)
    print(f"\nwrote {full}")
    for name in (f"{args.name}.nif", f"x{args.name}.nif", f"x{args.name}.kf"):
        path = os.path.join(args.out, name)
        print(f"  {'OK ' if os.path.exists(path) else 'MISSING'} {name}"
              + (f"  {os.path.getsize(path)} bytes" if os.path.exists(path) else ""))


if __name__ == "__main__":
    main()
