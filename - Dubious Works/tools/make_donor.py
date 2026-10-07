"""Builds a per-file leg donor for ReAnimation's FBA compatibility merge.

Why this exists
---------------
`build_compat.py` takes one donor kf (FBA's `xbase_anim.1st.kf`) for every file it
converts, and `fba_merge.their_group_for` finds the donor group by longest prefix. That
works for ReAnimation, whose groups are named after vanilla ones. It does not work for a
mod that introduces groups vanilla has no name for: the Katars set's `katar` and
`kataralt` match nothing in FBA, so those files are left unmerged and keep their
1st-person legs, which do not move.

The Katars set ships its own 3rd-person animations, and those carry authored legs and
real root motion for every katar group, at exactly the same timing as the 1st-person
ones. They are a better donor than FBA's generic groups on both counts:

  * content - measured against the mod's own 3rd-person legs, FBA's `runleft` differs by
    4 deg and `walkleft` by 2.9 deg, so both are the same vanilla-derived leg animation.
  * timing - the mod runs its locomotion at a 1.0667 s cycle where vanilla runs 0.933 s.
    Taking legs from FBA means a stretched loop with an uncorrected phase offset (the
    88 deg measured on `runforward`); taking them from the mod's own 3rd person makes the
    merge's loop-to-loop warp the identity map.

So each source file gets its own donor: FBA's kf, which supplies the 141 fallback groups
the merge indexes unconditionally (`idle = their_groups[idle_group_for(...)]` is not
guarded), with the matching 3rd-person katar tracks appended after it under the exact
group name the source uses. Exact-name match then fires and no prefix guessing happens.

The `katar1h` files are the one case needing more than a rename: they have no 3rd-person
counterpart, and their loop is an exact whole number of the shorter cycle (3 for run and
walk, 2 for sneak - verified by self-similarity, P/3 error 0.00 deg). Left alone the
merge would stretch one donor loop across all three and run the legs at a third speed, so
the donor loop is repeated to match, accumulating root motion across the repeats.
"""
import os
import sys

TOOLS = os.environ.get('FBACOMPAT_TOOLS')
if TOOLS and TOOLS not in sys.path:
    sys.path.insert(0, TOOLS)

import fba_merge
import nifkf

E = fba_merge.E

# Keeps the appended tracks clear of the donor's own timeline, so nothing interpolates
# across the join. Any value past the longest interpolation span would do.
GAP = 10.0
LOCOMOTION_KEYS = ('start', 'loop start', 'loop stop', 'stop')


def group_span(kf, name):
    """(first, last) marker time of `name`, and its loop window."""
    markers = kf.groups()[name]
    first = min(t for t, _ in markers)
    last = max(t for t, _ in markers)
    keys = fba_merge.group_keys(fba_merge.text_lines(kf), name)
    loop_start = keys.get('loop start', keys.get('start', first))
    loop_stop = keys.get('loop stop', keys.get('stop', last))
    return first, last, loop_start, loop_stop


def key_times(data, lo, hi):
    """The track's own key times within [lo, hi], with both ends included."""
    times = set()
    if data.rot_type == 4:
        for axis in data.xyz:
            times |= {t for t, _, _ in axis['keys']}
    else:
        times |= {t for t, _, _ in data.quat_keys}
    times |= {t for t, _, _ in data.trans['keys']}
    inside = sorted(t for t in times if lo - 1e-6 <= t <= hi + 1e-6)
    return sorted(set([lo] + inside + [hi]))


def is_locomotion(name):
    return bool(fba_merge.LOCOMOTION.match(name))


def donor_group_for(our_name, their_groups):
    """The 3rd-person group this source group takes its legs from.

    Exact name first. Otherwise drop a trailing `1h`: the Katars set's one-handed
    movement files are 1st-person only and reuse the two-handed cycle's legs.
    """
    if our_name in their_groups:
        return our_name
    if our_name.endswith('1h') and our_name[:-2] in their_groups:
        return our_name[:-2]
    return None


def repeats_for(our_kf, our_name, their_kf, their_name):
    """How many donor loops our loop spans, for locomotion; 1 for everything else."""
    if not (is_locomotion(our_name) and is_locomotion(their_name)):
        return 1
    _, _, our_ls, our_lp = group_span(our_kf, our_name)
    _, _, their_ls, their_lp = group_span(their_kf, their_name)
    our_period = our_lp - our_ls
    their_period = their_lp - their_ls
    if their_period <= 0 or our_period <= 0:
        return 1
    return max(1, int(round(our_period / their_period)))


def append_group(donor, src, our_name, their_name, repeats, offset):
    """Copies `their_name`'s tracks out of `src` into `donor` at `offset`, `repeats` times.

    Returns the text-key lines to add, as (time, "Group: Key"). Only bones the donor
    already has are written; the merge reads the lower body and spine from the donor, and
    FBA's kf carries all of those.
    """
    first, last, loop_start, loop_stop = group_span(src, their_name)
    period = loop_stop - loop_start
    loco = is_locomotion(our_name) and repeats > 1

    # Repeats only make sense over the loop window; a still group is copied whole.
    window = (loop_start, loop_stop) if loco else (first, last)
    lo, hi = window

    root = src.data('Bip01')
    cycle = tuple(b - a for a, b in zip(E.translation(root, lo), E.translation(root, hi)))

    for bone, index in donor.bone_data.items():
        if bone not in src.bone_data:
            continue
        dst = donor.blocks[index][1]
        if dst.rot_type == 4:
            # Appending quaternion keys to an XYZ track is not representable; FBA's kf has
            # no such track, so this is a guard rather than a case.
            raise ValueError('donor track for %r is XYZ-interpolated, cannot append' % bone)
        source = src.data(bone)
        for cycle_index in range(repeats):
            base = offset + cycle_index * (hi - lo)
            shift = tuple(c * cycle_index for c in cycle) if bone == 'Bip01' else (0.0, 0.0, 0.0)
            times = key_times(source, lo, hi)
            if cycle_index and times:
                times = times[1:]  # the previous cycle already wrote this instant
            for t in times:
                out_t = base + (t - lo)
                rotation = E.qnorm(E.rotation(source, t))
                translation = E.translation(source, t)
                dst.quat_keys.append((out_t, rotation, ()))
                dst.trans['keys'].append(
                    (out_t, tuple(x + s for x, s in zip(translation, shift)), ()))

    total = repeats * (hi - lo)
    label = our_name.title()
    lines = []
    if loco:
        lines.append((offset, '%s: Start' % label))
        lines.append((offset, '%s: Loop Start' % label))
        lines.append((offset + total, '%s: Loop Stop' % label))
        lines.append((offset + total, '%s: Stop' % label))
    else:
        for t, key in src.groups()[their_name]:
            lines.append((offset + (t - lo), '%s: %s' % (label, key.title())))

    # The footstep markers inside the window come too, remapped onto each repeat: they are
    # what `fba_merge.Group` reads step phases from, and without them on the donor side the
    # merge falls back to stretching loop to loop. Requires the source to spell them
    # `SoundGen` rather than `SoundGenRef` - see fix_soundgen.py.
    footsteps = set()
    for t, key in src.groups().get('soundgen', []):
        if not lo - 1e-6 <= t <= hi + 1e-6:
            continue
        for cycle_index in range(repeats):
            out_t = offset + cycle_index * (hi - lo) + (t - lo)
            footsteps.add((round(out_t, 6), 'SoundGen: %s' % key.title()))
    lines += sorted(footsteps)

    return lines, total


def build(source_path, third_person_path, fba_path, out_path):
    """Writes a donor kf for `source_path`. Returns [(our_group, their_group, repeats)]."""
    ours = nifkf.KF.load(source_path)
    donor = nifkf.KF.load(fba_path)
    third = nifkf.KF.load(third_person_path) if third_person_path else None

    their_groups = third.groups() if third else {}
    offset = max(t for t, _ in donor.text_keys()) + GAP
    added = []
    lines = []

    for our_name in sorted(ours.groups()):
        if our_name in fba_merge.NOT_GROUPS or our_name.startswith('soundgen'):
            continue
        their_name = donor_group_for(our_name, their_groups)
        if their_name is None:
            continue
        repeats = repeats_for(ours, our_name, third, their_name)
        group_lines, length = append_group(donor, third, our_name, their_name, repeats, offset)
        lines += group_lines
        offset += length + GAP
        added.append((our_name, their_name, repeats))

    if lines:
        keys = donor.blocks[donor.textkey_block][1]['keys']
        merged = {}
        for t, text in lines:
            merged.setdefault(round(t, 6), []).append(text)
        for t in sorted(merged):
            keys.append((t, '\r\n'.join(merged[t])))

    donor.save(out_path)
    return added
