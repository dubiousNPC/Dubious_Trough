"""Does this creature actually animate correctly?  Measured against its donor.

WHY A DONOR IS NEEDED

There is no mesh-internal test for "is the skinning right", because correct
skinning deliberately changes the shape: a creature posed from its modelling
pose into a walk cycle legitimately moves its limbs by tens of units.  Vanilla
nixhound scores as badly as a broken model on every such metric I tried -
displacement, edge-length ratio, residual from a rigid fit - so all of them are
worthless as a pass/fail.  Two of them passed a creature that turned out to be
three times its own width in game.

What does work: a reskinned creature is modelled on top of a donor, so at the
instant it was modelled its surface coincides with the donor's.  Drive both with
the same animation and measure, at each time, how far each of this model's
vertices sits from the nearest donor vertex.  Correct weights and a correct bind
hold that distance where it starts.  A wrong bind puts it at a hundred units
from the first frame; wrong weights let it grow as the clip plays.  Both failure
modes are visible, and they are distinguishable.

    python verify_creature.py --mw-lib <io_scene_mw>/lib \
        --donor nixhound.nif --donor-kf xnixhound.kf \
        --nif xav_bonehound3.nif --kf xav_bonehound3.kf
"""

import argparse
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))


def import_es3(explicit=None):
    for path in (explicit, os.environ.get("IO_SCENE_MW_LIB", "")):
        if path and os.path.isdir(os.path.join(path, "es3")):
            sys.path.insert(0, os.path.abspath(path))
            break
    from es3 import nif
    return nif


def quat_to_matrix(q):
    w, x, y, z = (float(v) for v in q)
    n = w * w + x * x + y * y + z * z
    if n < 1e-12:
        return np.identity(3)
    s = 2.0 / n
    return np.array([
        [1 - s * (y * y + z * z), s * (x * y - w * z), s * (x * z + w * y)],
        [s * (x * y + w * z), 1 - s * (x * x + z * z), s * (y * z - w * x)],
        [s * (x * z - w * y), s * (y * z + w * x), 1 - s * (x * x + y * y)],
    ])


def interpolate(keys, values, t, rotation=False):
    times = keys[:, 0]
    if t <= times[0]:
        return values[0]
    if t >= times[-1]:
        return values[-1]
    j = int(np.searchsorted(times, t))
    i = j - 1
    span = times[j] - times[i]
    f = 0.0 if span <= 0 else (t - times[i]) / span
    a = np.asarray(values[i], dtype=np.float64)
    b = np.asarray(values[j], dtype=np.float64)
    if rotation:
        if np.dot(a, b) < 0:
            b = -b
        q = a + (b - a) * f
        norm = np.linalg.norm(q)
        return q / norm if norm > 1e-12 else a
    return a + (b - a) * f


def kf_locals(kf_stream, t):
    """{node name: 4x4 local matrix}, every controller sampled at the same time."""
    root = kf_stream.root
    names = [e.string_data for e in root.extra_datas if hasattr(e, "string_data")]
    out = {}
    for name, controller in zip(names, root.controllers):
        data = controller.data
        if data is None:
            continue
        matrix = np.identity(4)
        rot = data.rotations
        if getattr(rot, "euler_data", ()):
            rot.convert_to_quaternions()
        if len(rot.keys):
            matrix[:3, :3] = quat_to_matrix(
                interpolate(rot.keys, rot.values, t, rotation=True))
        if len(data.translations.keys):
            matrix[:3, 3] = interpolate(
                data.translations.keys, data.translations.values, t)
        if len(data.scales.keys):
            matrix[:3, :3] *= float(interpolate(
                data.scales.keys, data.scales.keys[:, 1:2], t)[0])
        out[name] = matrix
    return out


def posed_world(stream, locals_by_name):
    def local(node):
        name = getattr(node, "name", "")
        if name in locals_by_name:
            return locals_by_name[name]
        return np.asarray(node.matrix, dtype=np.float64)

    world = {stream.root: local(stream.root)}
    parents = {}
    for parent, node in stream.root.descendants_pairs(breadth_first=True):
        world[node] = world[parent] @ local(node)
        parents[node] = parent
    return world, parents


def deform(stream, nif, world, parents, skip_shadow=True):
    """Every skinned vertex in world space, the way the engine places it."""
    chunks = []
    for shape in stream.objects_of_type(nif.NiTriBasedGeom):
        skin = getattr(shape, "skin", None)
        if not skin:
            continue
        if skip_shadow and "hadow" in shape.name:
            continue

        # MeshNodeWorld @ SkinData.matrix @ inv(SkinRootWorld, when the skin
        # root is an ancestor of the mesh node) - see rebind_skin.skin_prefix
        node, cancelled = shape, np.identity(4)
        while node in parents:
            node = parents[node]
            if node is skin.root:
                cancelled = np.linalg.inv(world[skin.root])
                break
        overall = np.identity(4)
        overall[:3, :3] = (np.asarray(skin.data.rotation, dtype=np.float64)
                           * float(skin.data.scale))
        overall[:3, 3] = np.asarray(skin.data.translation, dtype=np.float64)
        prefix = world[shape] @ overall @ cancelled

        vertices = np.asarray(shape.data.vertices, dtype=np.float64)
        acc = np.zeros_like(vertices)
        total = np.zeros(len(vertices))
        for bone, data in zip(skin.bones, skin.data.bone_data):
            if bone not in world:
                continue
            bind = np.identity(4)
            bind[:3, :3] = (np.asarray(data.rotation, dtype=np.float64)
                            * float(data.scale))
            bind[:3, 3] = np.asarray(data.translation, dtype=np.float64)
            matrix = prefix @ world[bone] @ bind
            indices = data.vertex_weights["f0"].astype(int)
            weights = np.asarray(data.vertex_weights["f1"], dtype=np.float64)
            if not len(indices):
                continue
            homogeneous = np.hstack([vertices[indices],
                                     np.ones((len(indices), 1))])
            acc[indices] += (matrix @ homogeneous.T).T[:, :3] * weights[:, None]
            total[indices] += weights
        mask = total > 1e-9
        acc[mask] /= total[mask, None]
        if mask.any():
            chunks.append(acc[mask])
    return np.vstack(chunks) if chunks else None


def at_time(path, kf_path, t, nif):
    stream = nif.NiStream()
    stream.load(path)
    locals_by_name = {}
    if kf_path:
        kf = nif.NiStream()
        kf.load(kf_path)
        locals_by_name = kf_locals(kf, t)
    world, parents = posed_world(stream, locals_by_name)
    return deform(stream, nif, world, parents)


def nearest_distances(points, cloud, block=200):
    out = np.empty(len(points))
    for start in range(0, len(points), block):
        chunk = points[start:start + block]
        out[start:start + block] = np.sqrt(
            ((chunk[:, None, :] - cloud[None, :, :]) ** 2).sum(-1)).min(1)
    return out


def clip_times(path, nif, count=6):
    kf = nif.NiStream()
    kf.load(path)
    times = []
    for controller in kf.root.controllers:
        data = controller.data
        if data is None:
            continue
        for block in (data.translations, data.rotations, data.scales):
            if len(block.keys):
                times.extend([block.keys[0, 0], block.keys[-1, 0]])
    lo, hi = (min(times), max(times)) if times else (0.0, 0.0)
    return [lo + (hi - lo) * i / (count - 1) for i in range(count)]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--mw-lib")
    parser.add_argument("--donor", required=True)
    parser.add_argument("--donor-kf")
    parser.add_argument("--nif", required=True)
    parser.add_argument("--kf", required=True)
    args = parser.parse_args()
    nif = import_es3(args.mw_lib)

    times = clip_times(args.kf, nif)
    print(f"{os.path.basename(args.nif)} against {os.path.basename(args.donor)}, "
          f"both driven by their own animation\n")
    print(f"{'t':>8}  {'median':>9} {'p95':>9} {'max':>10}   "
          f"{'extent':>22}  {'donor extent':>22}")

    first = None
    worst = 0.0
    for t in times:
        mine = at_time(args.nif, args.kf, t, nif)
        donor = at_time(args.donor, args.donor_kf, t, nif)
        if mine is None or donor is None:
            print("  one of the models has no skinned geometry")
            return 2
        d = nearest_distances(mine, donor)
        median = float(np.median(d))
        if first is None:
            first = median
        worst = max(worst, abs(median - first))
        print(f"{t:8.2f}  {median:9.3f} {float(np.percentile(d, 95)):9.3f} "
              f"{d.max():10.3f}   {str(np.round(mine.max(0) - mine.min(0), 1)):>22}"
              f"  {str(np.round(donor.max(0) - donor.min(0), 1)):>22}")

    size = float(np.linalg.norm(donor.max(0) - donor.min(0)))
    print()
    # A wrong bind shows as a large offset from the very first frame; wrong
    # weights show as that offset growing as the clip plays.
    if first > 0.05 * size:
        print(f"FAIL  sits {first:.1f} units off the donor from the first frame "
              f"({100 * first / size:.0f}% of its own size) - the bind pose and "
              f"the geometry disagree")
        return 1
    if worst > 0.02 * size:
        print(f"FAIL  drifts {worst:.1f} units off the donor as the clip plays - "
              f"the weights do not follow the skeleton")
        return 1
    print(f"PASS  stays within {first:.3f} units of the donor throughout "
          f"(drift {worst:.3f} units on a {size:.0f}-unit creature)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
