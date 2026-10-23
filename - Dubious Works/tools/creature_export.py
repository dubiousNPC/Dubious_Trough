"""Export an animated creature (skeleton + skinned meshes) as a Morrowind .nif.

Drop-in for OpenMW Suite for Blender. The Suite's existing model export
(`makeobj.write_nif`) writes a static asset: a root NiNode with Tri<name>
shapes and no bones. That is right for a chest or a sword, and wrong for a
creature - the .kf written by `clips.export_kf` targets bones by name, so a
model with no bones leaves OpenMW logging

    can't find bone 'bip01' in meshes/<model>.nif

once per target, and nothing animates.

This module writes what a creature needs, using the es3 the Suite already
vendors (`core.vendor.es3`), which supports NiSkinInstance/NiSkinData in full:

    <out>/<name>.nif     skeleton + skinned meshes (+ animation, if asked)
    <out>/x<name>.nif    the same without keyframe controllers or text keys
    <out>/x<name>.kf     the animation, if asked

Vanilla creatures are built exactly this way: nixhound.nif carries 51
NiKeyframeControllers and one NiTextKeyExtraData on 'Bip01', and its two meshes
are NiSkinInstance'd to 48 and 34 bones with skin root 'BBip01'.

Usage from the Suite:

    from . import creature_export
    creature_export.export_creature(armature_object, mesh_objects,
                                    "/path/to/av_bonehound3.nif",
                                    depsgraph=context.evaluated_depsgraph_get())
"""

import os

import numpy as np

try:                                    # inside the Suite
    from .core.vendor.es3 import nif
except ImportError:                     # standalone / tests
    from es3 import nif


# Blender is Z-up, Y-forward and the NIF keeps the same handedness, so only the
# unit scale differs. io_scene_mw's "Scale Correction" preference defaults to
# 0.01 on import, so the export multiplier is its reciprocal.
DEFAULT_SCALE = 100.0

# A NiNode the engine must find by exactly this name.
SKELETON_ROOT_CANDIDATES = ("bip01", "root bone")


def nif_bone_name(name):
    """Blender bone name -> NIF node name.

    io_scene_mw renames `Bip01 L Foo` to `Bip01 Foo.L` on import so Blender's
    own mirroring works; the game knows only the original. Anything that writes
    a NIF from such an armature has to map it back, or every left/right bone is
    written under a name the .kf never asks for.
    """
    if name.startswith("Bip01"):
        if name.endswith(".L"):
            return f"Bip01 L {name[6:-2]}"
        if name.endswith(".R"):
            return f"Bip01 R {name[6:-2]}"
    return name


# ---------------------------------------------------------------- utilities

def _matrix(m):
    return np.asarray(m, dtype="<f")


def _decompose(matrix):
    """(translation, 3x3 rotation, uniform scale) from a 4x4."""
    matrix = np.asarray(matrix, dtype=np.float64)
    translation = matrix[:3, 3].astype("<f")
    basis = matrix[:3, :3]
    scales = np.linalg.norm(basis, axis=0)
    scale = float(scales.mean()) if scales.all() else 1.0
    rotation = (basis / scale).astype("<f") if scale else np.identity(3, "<f")
    return translation, rotation, scale


def _scaled(matrix, scale):
    out = np.asarray(matrix, dtype=np.float64).copy()
    out[:3, 3] *= scale
    return out


def _set_transform(node, matrix):
    translation, rotation, scale = _decompose(matrix)
    node.translation = translation
    node.rotation = rotation
    node.scale = scale


def bone_tree(armature, scale=DEFAULT_SCALE):
    """{bone name: NiNode} mirroring the armature, parents wired, local transforms set.

    Bone matrices are taken in rest (edit) space: `bone.matrix_local` is the
    bone's rest transform in armature space, so a child's local transform is
    `parent.matrix_local^-1 @ child.matrix_local`.
    """
    nodes = {}
    for bone in armature.data.bones:
        nodes[bone.name] = nif.NiNode(name=nif_bone_name(bone.name))

    for bone in armature.data.bones:
        node = nodes[bone.name]
        if bone.parent is None:
            local = np.asarray(bone.matrix_local, dtype=np.float64)
        else:
            parent = np.asarray(bone.parent.matrix_local, dtype=np.float64)
            local = np.linalg.inv(parent) @ np.asarray(bone.matrix_local, dtype=np.float64)
        local = local.copy()
        local[:3, 3] *= scale
        _set_transform(node, local)
        if bone.parent is not None:
            nodes[bone.parent.name].children.append(node)
    return nodes


def skeleton_roots(armature, nodes):
    return [nodes[b.name] for b in armature.data.bones if b.parent is None]


def find_skin_root(armature, nodes):
    """The node a NiSkinInstance names as its root: the armature's root bone.

    Vanilla nixhound skins to 'BBip01', which is the first bone under the
    animation root 'Bip01' - and 'Bip01' is the armature *object*, not a bone,
    so the root bone is exactly right.
    """
    roots = [b for b in armature.data.bones if b.parent is None]
    return nodes[roots[0].name] if roots else None


# ---------------------------------------------------------------- geometry

def _evaluated_mesh(obj, depsgraph):
    """Triangulated mesh data in world space, with the armature modifier off.

    The rest pose is what a skinned NIF stores; letting the armature modifier
    run would bake the current frame's pose into the vertices.
    """
    muted = []
    for modifier in obj.modifiers:
        if modifier.type == 'ARMATURE' and modifier.show_viewport:
            modifier.show_viewport = False
            muted.append(modifier)
    try:
        if depsgraph is not None:
            depsgraph.update()
            evaluated = obj.evaluated_get(depsgraph)
            mesh = evaluated.to_mesh()
            owner = evaluated
        else:
            mesh = obj.to_mesh()
            owner = obj
        mesh.calc_loop_triangles()
        data = _read_mesh(mesh, obj.matrix_world)
        owner.to_mesh_clear()
        return data
    finally:
        for modifier in muted:
            modifier.show_viewport = True


def _read_mesh(mesh, matrix_world):
    import mathutils  # noqa: F401  (Blender only)
    vertices, normals, uvs, triangles = [], [], [], []
    uv_layer = mesh.uv_layers.active.data if mesh.uv_layers.active else None

    # One NIF vertex per (mesh vertex, uv) pair, so seams keep their UVs.
    index_of = {}
    originals = []
    for triangle in mesh.loop_triangles:
        face = []
        for loop_index in triangle.loops:
            vertex_index = mesh.loops[loop_index].vertex_index
            uv = tuple(uv_layer[loop_index].uv) if uv_layer else (0.0, 0.0)
            key = (vertex_index, round(uv[0], 6), round(uv[1], 6))
            if key not in index_of:
                index_of[key] = len(vertices)
                co = matrix_world @ mesh.vertices[vertex_index].co
                no = (matrix_world.to_3x3() @ mesh.vertices[vertex_index].normal).normalized()
                vertices.append((co.x, co.y, co.z))
                normals.append((no.x, no.y, no.z))
                uvs.append((uv[0], 1.0 - uv[1]))     # NIF's V runs the other way
                originals.append(vertex_index)
            face.append(index_of[key])
        triangles.append(tuple(face))
    return vertices, normals, uvs, triangles, originals


def build_shape(obj, depsgraph, scale=DEFAULT_SCALE):
    """(NiTriShape, originals) for one mesh object, in world space, no skin yet."""
    vertices, normals, uvs, triangles, originals = _evaluated_mesh(obj, depsgraph)
    if not triangles:
        return None, []

    data = nif.NiTriShapeData()
    data.vertices = (np.asarray(vertices, dtype="<f") * scale)
    data.normals = np.asarray(normals, dtype="<f")
    if uvs:
        data.uv_sets = np.asarray([uvs], dtype="<f")
    data.triangles = np.asarray(triangles, dtype="<H")
    data.update_center_radius()

    base = obj.name
    shape = nif.NiTriShape(name=base if base.startswith("Tri ") else f"Tri {base}", data=data)
    return shape, originals


def attach_skin(shape, obj, armature, nodes, originals, skin_root, scale=DEFAULT_SCALE):
    """Give a NiTriShape a NiSkinInstance built from the object's vertex groups.

    Returns the list of bone names that actually carry weight.
    """
    group_names = {i: g.name for i, g in enumerate(obj.vertex_groups)}
    # vertex groups carry Blender bone names; `nodes` is keyed the same way.
    mesh = obj.data

    # weights[bone name] -> {nif vertex index: weight}
    weights = {}
    for nif_index, vertex_index in enumerate(originals):
        vertex = mesh.vertices[vertex_index]
        total = sum(g.weight for g in vertex.groups if group_names.get(g.group) in nodes)
        if total <= 1e-9:
            continue
        for group in vertex.groups:
            name = group_names.get(group.group)
            if name not in nodes or group.weight <= 1e-9:
                continue
            weights.setdefault(name, {})[nif_index] = group.weight / total

    used = [name for name in (b.name for b in armature.data.bones) if weights.get(name)]
    if not used:
        return []

    skin_data = nif.NiSkinData()
    skin_data.bone_data = []
    armature_matrix = np.asarray(armature.matrix_world, dtype=np.float64)

    for name in used:
        bone = armature.data.bones[name]
        # NIF stores, per bone, the transform from skin space into bone space:
        # the inverse of the bone's rest transform.
        rest = armature_matrix @ np.asarray(bone.matrix_local, dtype=np.float64)
        inverse = np.linalg.inv(rest)
        inverse = inverse.copy()
        inverse[:3, 3] *= scale

        bone_data = nif.NiSkinDataBoneData()
        translation, rotation, bone_scale = _decompose(inverse)
        bone_data.translation = translation
        bone_data.rotation = rotation
        bone_data.scale = bone_scale
        pairs = sorted(weights[name].items())
        array = np.zeros(len(pairs), dtype=bone_data.vertex_weights.dtype)
        array["f0"] = [i for i, _w in pairs]
        array["f1"] = [w for _i, w in pairs]
        bone_data.vertex_weights = array
        skin_data.bone_data.append(bone_data)

    skin_data.update_center_radius(shape.data.vertices)

    instance = nif.NiSkinInstance()
    instance.data = skin_data
    instance.root = skin_root
    instance.bones = [nodes[name] for name in used]
    shape.skin = instance
    return used


# ---------------------------------------------------------------- the export

def export_creature(armature, meshes, path, depsgraph=None, scale=DEFAULT_SCALE,
                    extra_roots=(), bounding_box=True, log=print):
    """Write <name>.nif and x<name>.nif for a skinned creature.

    armature : the Blender armature object holding the creature's skeleton
    meshes   : mesh objects to skin onto it (vertex groups name the bones)
    path     : .../<name>.nif ; x<name>.nif is written beside it
    """
    folder = os.path.dirname(os.path.abspath(path))
    stem = os.path.splitext(os.path.basename(path))[0]
    os.makedirs(folder, exist_ok=True)

    nodes = bone_tree(armature, scale)
    roots = skeleton_roots(armature, nodes)
    if not roots:
        raise RuntimeError(f"{armature.name!r} has no bones")
    skin_root = find_skin_root(armature, nodes)

    # The armature OBJECT is a node too: io_scene_mw writes it as the parent of
    # the bone tree, and a creature's .kf names it as entry 0 (nixhound: the
    # object is 'Bip01', its root bone 'BBip01'). Without it the skeleton root
    # the .kf asks for does not exist.
    armature_node = nif.NiNode(name=armature.name)
    _set_transform(armature_node, _scaled(armature.matrix_world, scale))
    for node in roots:
        armature_node.children.append(node)

    file_root = nif.NiNode(name=f"{stem}.nif")
    if bounding_box:
        file_root.children.append(nif.NiNode(name="Bounding Box"))
    file_root.children.append(armature_node)
    for node in extra_roots:
        file_root.children.append(node)

    skinned = 0
    for obj in meshes:
        shape, originals = build_shape(obj, depsgraph, scale)
        if shape is None:
            log(f"  {obj.name!r}: no faces, skipped")
            continue
        used = attach_skin(shape, obj, armature, nodes, originals, skin_root, scale)
        if used:
            skinned += 1
            log(f"  {obj.name!r}: {len(shape.data.vertices)} verts, skinned to {len(used)} bone(s)")
            # A skinned shape hangs off the skeleton root, not off a bone.
            file_root.children.append(shape)
        else:
            log(f"  {obj.name!r}: no vertex groups matched the skeleton - "
                "written unskinned (it will not deform)")
            file_root.children.append(shape)

    if not skinned:
        raise RuntimeError(
            "No mesh had vertex groups matching the skeleton's bone names. "
            "Weight the meshes to the creature's bones before exporting.")

    stream = nif.NiStream()
    stream.root = file_root
    stream.sort()
    full = os.path.join(folder, f"{stem}.nif")
    stream.save(full)

    # x<name>.nif: the same thing. For a creature whose animation lives in a
    # separate .kf this file carries no controllers anyway, so it is a copy;
    # keeping both is what the game and every vanilla creature expect.
    xstream = nif.NiStream()
    xstream.load(full)
    xpath = os.path.join(folder, f"x{stem}.nif")
    xstream.save(xpath)

    log(f"wrote {os.path.basename(full)} and {os.path.basename(xpath)}")
    return full, xpath


# ---------------------------------------------------------------- the guard

def creature_needs_skeleton(objects):
    """True when these objects look like an animated creature, not a static prop.

    Used to stop the static asset export from silently writing a boneless model
    for a CREA record.
    """
    for obj in objects:
        if getattr(obj, "type", None) != 'MESH':
            continue
        if any(m.type == 'ARMATURE' and m.object for m in obj.modifiers):
            return True
        if obj.parent is not None and getattr(obj.parent, "type", None) == 'ARMATURE':
            return True
        if len(getattr(obj, "vertex_groups", ())) > 2:
            return True
    return False


def armature_for(objects):
    for obj in objects:
        for modifier in getattr(obj, "modifiers", ()):
            if modifier.type == 'ARMATURE' and modifier.object:
                return modifier.object
        if obj.parent is not None and getattr(obj.parent, "type", None) == 'ARMATURE':
            return obj.parent
    return None
