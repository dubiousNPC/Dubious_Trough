"""Rebind a skinned Morrowind NIF to the pose its own node transforms describe.

WHY THIS EXISTS

A NiSkinData says, per bone, where that bone stood at the moment the mesh was
bound to it.  Morrowind's rule (io_scene_mw's NiGeometry.apply_skin is the
authority) is

    v_mesh_local = sum_i w_i * ( SkinData.matrix
                                 @ BoneWorldRelativeToSkinRoot_i
                                 @ bone_data_i.matrix
                                 @ v )

so the skin is only consistent with the vertices in the file if, at the pose
the vertices were authored in, that product is the identity for every bone.

A creature whose mesh was modelled directly over an animated donor skeleton has
its vertices authored in the *animated* pose, which is the pose the x.nif's own
node transforms hold.  Round-tripping such a model through a Blender importer
that re-derives bind poses from the donor's NiSkinData instead writes the
*donor's modelling pose*, and every vertex is then dragged by the difference
between the two - tens of units on a 240-unit creature.

This rewrites each bone_data so the file is bound in the pose its nodes
actually describe, and clears SkinData.matrix into them so the record matches
the vanilla convention.  Geometry, weights, bone lists, node transforms,
controllers and text keys are untouched, so a .kf authored against the same
skeleton stays valid.

    python rebind_skin.py --mw-lib <io_scene_mw>/lib in.nif out.nif
    python rebind_skin.py --mw-lib ... --check in.nif        # report only
"""

import argparse
import os
import shutil
import sys

import numpy as np


def import_es3(explicit=None):
    for path in (explicit, os.environ.get("IO_SCENE_MW_LIB", "")):
        if path and os.path.isdir(os.path.join(path, "es3")):
            sys.path.insert(0, os.path.abspath(path))
            break
    from es3 import nif
    return nif


def world_matrices(root):
    world = {root: np.asarray(root.matrix, dtype=np.float64)}
    parents = {}
    for parent, node in root.descendants_pairs(breadth_first=True):
        world[node] = world[parent] @ np.asarray(node.matrix, dtype=np.float64)
        parents[node] = parent
    return world, parents


def as_matrix(obj):
    m = np.identity(4)
    m[:3, :3] = np.asarray(obj.rotation, dtype=np.float64) * float(obj.scale)
    m[:3, 3] = np.asarray(obj.translation, dtype=np.float64)
    return m


def skin_prefix(shape, world, parents):
    """The constant part of the chain that sits in front of every bone.

        v_world = MeshNodeWorld @ SkinData.matrix @ inv(SkinRootWorld) @ ...

    The skin-root term appears only when the skin root is an ancestor of the
    mesh node, because that is exactly when OpenMW cancels those transforms
    (SceneUtil::RigGeometry::updateSkinToSkelMatrix walks the node path to the
    mesh and cancels nothing if the skin root is not on it).  A shape parked
    beside its skin root rather than under it therefore carries that frame
    twice, and the creature renders displaced from its own origin.
    """
    node = shape
    cancelled = np.identity(4)
    while node in parents:
        node = parents[node]
        if node is shape.skin.root:
            cancelled = np.linalg.inv(world[shape.skin.root])
            break
    return world[shape] @ as_matrix(shape.skin.data) @ cancelled


def residual_at_rest(shape, world, parents):
    """How far the file's own rest pose drags the mesh, in model units.

    Zero means the skin is bound in the pose the nodes describe.
    """
    skin = shape.skin
    vertices = np.asarray(shape.data.vertices, dtype=np.float64)
    prefix = skin_prefix(shape, world, parents)
    out = np.zeros_like(vertices)
    total = np.zeros(len(vertices))
    for bone, data in zip(skin.bones, skin.data.bone_data):
        if bone not in world:
            continue
        matrix = prefix @ world[bone] @ as_matrix(data)
        indices = data.vertex_weights["f0"].astype(int)
        weights = np.asarray(data.vertex_weights["f1"], dtype=np.float64)
        if not len(indices):
            continue
        source = vertices[indices]
        homogeneous = np.hstack([source, np.ones((len(source), 1))])
        out[indices] += (matrix @ homogeneous.T).T[:, :3] * weights[:, None]
        total[indices] += weights
    mask = total > 1e-9
    if not mask.any():
        return None
    out[mask] /= total[mask, None]
    return np.linalg.norm(out[mask] - vertices[mask], axis=1)


def rigid_residual(source, target):
    """RMS residual of the best rotation+translation taking source to target."""
    sc, tc = source.mean(0), target.mean(0)
    u, _, vt = np.linalg.svd((source - sc).T @ (target - tc))
    d = np.sign(np.linalg.det(u @ vt))
    rotation = (u @ np.diag([1.0, 1.0, d]) @ vt).T
    fitted = (rotation @ (source - sc).T).T + tc
    return float(np.sqrt(((fitted - target) ** 2).sum(1).mean()))


def pose_fit(shapes, world, parents, nif):
    """Which pose were these vertices authored in - the one the NiSkinData
    encodes, or the one the file's node transforms hold?

    A vertex cluster sits near the bone it is weighted to, so pair each bone's
    origin with the weighted centroid of its own vertices.  In the right pose
    those two point sets differ by one rigid transform; in the wrong pose they
    do not.  Fitting the whole set at once, across every shape in the file, is
    far steadier than measuring bone-by-bone distances, and it is frame- and
    origin-independent, which matters because the two poses are expressed in
    different frames.

    Returns (residual under the encoded bind, residual under the rest pose,
    number of pairs).
    """
    origins_bind, origins_rest, centroids = [], [], []

    for shape in shapes:
        skin = shape.skin
        vertices = np.asarray(shape.data.vertices, dtype=np.float64)
        prefix = skin_prefix(shape, world, parents)
        for bone, data in zip(skin.bones, skin.data.bone_data):
            if bone not in world:
                continue
            indices = data.vertex_weights["f0"].astype(int)
            weights = np.asarray(data.vertex_weights["f1"], dtype=np.float64)
            if len(indices) < 3 or weights.sum() <= 0:
                continue
            centroids.append(
                (vertices[indices] * weights[:, None]).sum(0) / weights.sum())
            # the bone's origin, carried into the vertices' own space
            origins_bind.append(np.linalg.inv(as_matrix(data))[:3, 3])
            origins_rest.append(np.linalg.inv(prefix @ world[bone])[:3, 3])

    if len(centroids) < 4:
        return None, None, len(centroids)
    centroids = np.array(centroids)
    return (rigid_residual(np.array(origins_bind), centroids),
            rigid_residual(np.array(origins_rest), centroids),
            len(centroids))


def rebind(shape, world, parents):
    """Set every bone_data so this shape is bound in the file's rest pose."""
    skin = shape.skin
    vertices = np.asarray(shape.data.vertices, dtype=np.float64)

    # Fold the skin transform into the bones and leave it identity, which is
    # what every vanilla Morrowind creature does.
    skin.data.matrix = np.identity(4)
    prefix = skin_prefix(shape, world, parents)

    missing = []
    for bone, data in zip(skin.bones, skin.data.bone_data):
        if bone not in world:
            missing.append(getattr(bone, "name", "?"))
            continue
        data.matrix = np.linalg.inv(prefix @ world[bone])
        indices = data.vertex_weights["f0"].astype(int)
        data.update_center_radius(vertices[indices])
    return missing


def describe(label, residuals, size):
    if residuals is None:
        return f"    {label:14} no weighted vertices"
    return (f"    {label:14} median {np.median(residuals):8.3f}  "
            f"p99 {np.percentile(residuals, 99):9.3f}  "
            f"max {residuals.max():9.3f} units  "
            f"({100 * residuals.max() / size:5.1f}% of the mesh)")


def donor_decision(shapes, nif, donor_path, donor_kf):
    """Decide from the donor the model was built over.

    A reskin is modelled on top of the donor as the modeller sees it on screen,
    so the new vertices occupy the same volume as the donor's geometry in
    whichever pose was on screen.  Deform the donor at the start of its own
    animation and compare bounding boxes with the raw vertices here: if they
    coincide, these vertices are in the animated pose, which is the pose the
    nodes hold, and the skin data is stale.

    This is direct evidence rather than a correlation, so it decides; the
    bone-to-vertex fit is only ever reported as a cross-check.
    """
    stream = nif.NiStream()
    stream.load(donor_path)
    world, donor_parents = world_matrices(stream.root)
    donor_shapes = [o for o in stream.objects_of_type(nif.NiTriBasedGeom)
                    if o.skin and "shadow" not in o.name.lower()]
    if not donor_shapes:
        return None, "donor has no skinned mesh"

    posed = world
    if donor_kf:
        kf = nif.NiStream()
        kf.load(donor_kf)
        names = [e.string_data for e in list(kf.root.extra_datas)[1:]]
        locals_by_name = {}
        for name, controller in zip(names, kf.root.controllers):
            data = controller.data
            if data is None:
                continue
            matrix = np.identity(4)
            rot = data.rotations
            if getattr(rot, "euler_data", ()):
                rot.convert_to_quaternions()
            if len(rot.keys):
                q = rot.values[0]
                w, x, y, z = (float(v) for v in q)
                n = w * w + x * x + y * y + z * z
                if n > 1e-12:
                    s = 2.0 / n
                    matrix[:3, :3] = np.array([
                        [1 - s * (y * y + z * z), s * (x * y - w * z), s * (x * z + w * y)],
                        [s * (x * y + w * z), 1 - s * (x * x + z * z), s * (y * z - w * x)],
                        [s * (x * z - w * y), s * (y * z + w * x), 1 - s * (x * x + y * y)],
                    ])
            if len(data.translations.keys):
                matrix[:3, 3] = data.translations.values[0]
            locals_by_name[name] = matrix

        def local_of(node):
            name = getattr(node, "name", "")
            if name in locals_by_name:
                return locals_by_name[name]
            return np.asarray(node.matrix, dtype=np.float64)

        posed = {stream.root: local_of(stream.root)}
        for parent, node in stream.root.descendants_pairs(breadth_first=True):
            posed[node] = posed[parent] @ local_of(node)

    moved = []
    for shape in donor_shapes:
        skin = shape.skin
        vertices = np.asarray(shape.data.vertices, dtype=np.float64)
        prefix = skin_prefix(shape, posed, donor_parents)
        out = np.zeros_like(vertices)
        total = np.zeros(len(vertices))
        for bone, data in zip(skin.bones, skin.data.bone_data):
            if bone not in posed:
                continue
            matrix = prefix @ posed[bone] @ as_matrix(data)
            indices = data.vertex_weights["f0"].astype(int)
            weights = np.asarray(data.vertex_weights["f1"], dtype=np.float64)
            if not len(indices):
                continue
            homogeneous = np.hstack([vertices[indices],
                                     np.ones((len(indices), 1))])
            out[indices] += (matrix @ homogeneous.T).T[:, :3] * weights[:, None]
            total[indices] += weights
        mask = total > 1e-9
        if mask.any():
            moved.append(out[mask])
        raw = vertices
    if not moved:
        return None, "donor would not deform"
    donor_posed = np.vstack(moved)
    donor_rest = np.vstack([np.asarray(s.data.vertices, dtype=np.float64)
                            for s in donor_shapes])
    here = np.vstack([np.asarray(s.data.vertices, dtype=np.float64)
                      for s in shapes])

    def box_gap(a, b):
        return float(max(np.abs(a.min(0) - b.min(0)).max(),
                         np.abs(a.max(0) - b.max(0)).max()))

    to_posed = box_gap(here, donor_posed)
    to_rest = box_gap(here, donor_rest)
    note = (f"donor box gap: to its animated pose {to_posed:7.2f} units, "
            f"to its own vertices {to_rest:7.2f} units")
    if to_posed < to_rest:
        return True, note
    return False, note


def process(path, out_path, nif, check_only, bound_in="auto",
            donor=None, donor_kf=None):
    stream = nif.NiStream()
    stream.load(path)
    world, parents = world_matrices(stream.root)
    shapes = [o for o in stream.objects_of_type(nif.NiTriBasedGeom) if o.skin]

    print(f"\n=== {os.path.basename(path)}")
    if not shapes:
        print("  no skinned meshes; nothing to do")
        if not check_only and out_path:
            shutil.copyfile(path, out_path)
        return False

    needs = None
    bind_fit, rest_fit, pairs = pose_fit(shapes, world, parents, nif)
    if bind_fit is None:
        print(f"  bone-to-vertex fit: only {pairs} pairs, not usable")
    else:
        print(f"  bone-to-vertex rigid fit over {pairs} pairs: "
              f"encoded bind {bind_fit:7.2f}, file rest pose {rest_fit:7.2f} "
              f"(weak cross-check only)")

    if donor:
        needs, note = donor_decision(shapes, nif, donor, donor_kf)
        print(f"  {note}")
        if needs is None:
            print("  donor gave no answer")
    if bound_in == "nodes":
        needs = True
    elif bound_in == "skindata":
        needs = False

    if needs is None:
        print("  cannot tell which pose the vertices were authored in. "
              "Pass --donor <original>.nif [--donor-kf <anim>.kf], "
              "or state it with --bound-in nodes|skindata.")
        for shape in shapes:
            size = float(np.linalg.norm(
                np.asarray(shape.data.vertices).max(0)
                - np.asarray(shape.data.vertices).min(0))) or 1.0
            print(f"  {shape.name!r}")
            print(describe("rest-pose drag",
                           residual_at_rest(shape, world, parents), size))
        return False

    print("  authored in the pose "
          + ("the NODES hold -> the skin data is stale, rebinding"
             if needs else
             "the SKIN DATA encodes -> already consistent, leaving alone"))

    for shape in shapes:
        vertices = np.asarray(shape.data.vertices, dtype=np.float64)
        size = float(np.linalg.norm(vertices.max(0) - vertices.min(0))) or 1.0
        print(f"  {shape.name!r}  ({len(vertices)} verts, "
              f"{len(shape.skin.bones)} bones, skin root "
              f"{getattr(shape.skin.root, 'name', '?')!r})")
        drag = residual_at_rest(shape, world, parents)
        print(describe("rest-pose drag", drag, size))
        if drag is not None and drag.max() < 1e-4:
            print("    already bound in the pose its nodes hold - nothing to do")
            continue
        if check_only or not needs:
            continue
        missing = rebind(shape, world, parents)
        if missing:
            print(f"    {len(missing)} bone(s) not in this file, left alone: "
                  f"{', '.join(missing[:4])}")
        print(describe("after rebind", residual_at_rest(shape, world, parents), size))

    if check_only or not needs:
        return False
    if out_path:
        stream.save(out_path)
        print(f"  written: {out_path}")
    return True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--mw-lib")
    parser.add_argument("--check", action="store_true",
                        help="report only, write nothing")
    parser.add_argument("--bound-in", choices=("auto", "nodes", "skindata"),
                        default="auto",
                        help="state which pose the vertices were authored in, "
                             "overriding the donor test")
    parser.add_argument("--donor", help="the model this one was built over")
    parser.add_argument("--donor-kf", help="the donor's animation")
    parser.add_argument("paths", nargs="+",
                        help="in.nif [out.nif]; with --check, any number of nifs")
    args = parser.parse_args()
    nif = import_es3(args.mw_lib)

    if args.check:
        for path in args.paths:
            process(path, None, nif, True, args.bound_in,
                    args.donor, args.donor_kf)
        return
    if len(args.paths) != 2:
        parser.error("give exactly in.nif and out.nif, or use --check")
    process(args.paths[0], args.paths[1], nif, False, args.bound_in,
            args.donor, args.donor_kf)


if __name__ == "__main__":
    main()
