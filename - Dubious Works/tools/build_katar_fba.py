"""Runs ReAnimation's FBA compatibility build over the Katars animation set.

This is `build_compat.main()` with one change: the donor kf is built per file by
`make_donor`, instead of being FBA's kf for every file. Everything else - the rig-pose
reference, the merge, the chest lean pass, the warning report - is the tool's own code,
called in the tool's own order, so the result is what `build_compat.py` would produce if
FBA happened to ship the katar groups.

Usage:
  FBACOMPAT_TOOLS=<...>/Sources/Tools/FBACompat \
  python3 -I build_katar_fba.py --fba DIR --anims DIR --third DIR --out DIR [--lean D]
"""
import argparse
import math
import os
import sys

TOOLS = os.environ['FBACOMPAT_TOOLS']
sys.path.insert(0, TOOLS)
# -I drops the script's own directory, and make_donor lives beside this file.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import build_compat
import fba_merge
import fba_posture
import nifkf

import make_donor


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--fba', required=True, help="FBA's folder or its xbase_anim.1st.kf")
    parser.add_argument('--anims', required=True, help='1st-person animations to convert')
    parser.add_argument('--third', required=True, help="the mod's own 3rd-person animations")
    parser.add_argument('--out', required=True)
    parser.add_argument('--donors', help='keep the generated donor kfs here')
    parser.add_argument('--lean', type=float, default=build_compat.LEAN)
    parser.add_argument('--hip-motion', type=float, default=build_compat.HIP_MOTION)
    parser.add_argument('--sway', type=float, default=build_compat.SWAY)
    parser.add_argument('--idle-when-feet-lift', default='y')
    parser.add_argument('-v', '--verbose', action='store_true')
    args = parser.parse_args()

    fba_kf = args.fba
    if os.path.isdir(fba_kf):
        fba_kf = build_compat.find_file(fba_kf, 'xbase_anim.1st.kf')
    if not fba_kf or not os.path.isfile(fba_kf):
        sys.exit('No xbase_anim.1st.kf under %s' % args.fba)

    fba_merge.VERBOSE = args.verbose
    fba_posture.TILT = math.radians(args.lean)
    fba_merge.HIP_MOTION = args.hip_motion
    fba_merge.SWAY = args.sway
    fba_merge.IDLE_WHEN_FEET_LIFT = args.idle_when_feet_lift.lower().startswith('y')

    names = sorted(n for n in os.listdir(args.anims) if n.lower().endswith('.kf'))
    os.makedirs(args.out, exist_ok=True)
    donor_dir = args.donors or os.path.join(args.out, '_donors')
    os.makedirs(donor_dir, exist_ok=True)

    reference_name, reference = build_compat.find_reference(args.anims, names)
    print('\nrig pose from %s; lean %.1f deg, hip motion %.2f, spine swing %.2f, '
          'idle legs where feet lift: %s'
          % (reference_name, args.lean, args.hip_motion, args.sway,
             'yes' if fba_merge.IDLE_WHEN_FEET_LIFT else 'no'))

    # Which 3rd-person file donates to which source file. Same name first; the 1st-person
    # only `1h` movement files fall back to the set's two-handed cycle.
    third_files = {n for n in os.listdir(args.third) if n.lower().endswith('.kf')}

    def third_for(name):
        if name in third_files:
            return name
        stripped = name.replace('1h', '', 1)
        return stripped if stripped in third_files else None

    merged = set()
    plan = {}
    for index, name in enumerate(names, 1):
        third = third_for(name)
        donor = os.path.join(donor_dir, name)
        if third is None:
            print('%3d/%d  %s   no 3rd-person donor, FBA groups only' % (index, len(names), name))
            added = make_donor.build(os.path.join(args.anims, name), None, fba_kf, donor)
        else:
            added = make_donor.build(os.path.join(args.anims, name),
                                     os.path.join(args.third, third), fba_kf, donor)
        plan[name] = (third, added)

        fba_merge.info('== merge ' + name)
        segments = fba_merge.build(os.path.join(args.anims, name), donor,
                                   os.path.join(args.out, name), reference)
        if segments is not None:
            if fba_merge.VERBOSE:
                fba_merge.report(segments)
            merged.add(name)
        if not fba_merge.VERBOSE:
            detail = ', '.join('%s<-%s%s' % (a, b, '' if r == 1 else ' x%d' % r)
                               for a, b, r in added) or '-'
            print('%3d/%d  %-26s %s' % (index, len(names), name, detail))

    leaned = 0
    for name in names:
        kf = nifkf.KF.load(os.path.join(args.out if name in merged else args.anims, name))
        changed = False
        if fba_posture.has_chest(kf):
            fallbacks = fba_posture.lean(kf, reference)
            if fallbacks:
                fba_merge.info('   %s: %s from %s' % (name, ', '.join(fallbacks), reference_name))
            leaned += 1
            changed = True
        else:
            fba_merge.info('   does not rotate the chest, not leaned: ' + name)
        if changed or name in merged:
            kf.save(os.path.join(args.out, name))

    print('\nmerged %d of %d kfs, leaned %d by %.1f deg'
          % (len(merged), len(names), leaned, args.lean))
    if fba_merge.WARNINGS:
        print('\n%d warnings - left as they were:' % len(fba_merge.WARNINGS))
        for warning in fba_merge.WARNINGS:
            print('  ' + warning)
    else:
        print('no warnings')

    unmerged = [n for n in names if n not in merged]
    if unmerged:
        print('\nnot merged (%d): %s' % (len(unmerged), ', '.join(unmerged)))
    return 0


if __name__ == '__main__':
    sys.exit(main())
