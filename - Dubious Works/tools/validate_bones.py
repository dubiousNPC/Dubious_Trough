"""Validates each .kf's referenced bones against a reference kf for the same skeleton.

The reference is FBA's own animation for that rig: a full-body animation authored against
the real skeleton, so its bone list is a sound lower bound on what the rig has. A bone the
reference lacks is either injected by a mod .nif (valid) or a phantom (one warning per
load, forever).
"""
import os, sys, collections
sys.path.insert(0, os.environ['FBACOMPAT_TOOLS'])
import nifkf

FBA = sys.argv[1]
TREE = sys.argv[2]
INJECTED = set(a.strip().lower() for a in sys.argv[3].split(',') if a.strip()) if len(sys.argv) > 3 else set()

# animations/<folder> -> FBA's kf for that skeleton
REF = {
    'xbase_anim':         'xbase_anim.kf',
    'xbase_anim.1st':     'xbase_anim.1st.kf',
    'xbase_anim_female':  'xbase_anim_female.kf',
    'xbase_anim_female.1st': 'xbase_anim_female.1st.kf',
    'xbase_animkna':      'xbase_animkna.kf',
    'xbase_animkna.1st':  'xbase_animkna.1st.kf',
}

for folder in sorted(os.listdir(TREE)):
    d = os.path.join(TREE, folder)
    if not os.path.isdir(d):
        continue
    ref_name = REF.get(folder)
    if ref_name is None:
        print('######## %s   (no reference skeleton known)' % folder)
        continue
    ref_path = os.path.join(FBA, ref_name)
    if not os.path.isfile(ref_path):
        print('######## %s   (reference %s not present)' % (folder, ref_name))
        continue
    ref = {b.strip().lower() for b in nifkf.KF.load(ref_path).bone_data}
    print('######## %s   reference %s (%d bones)' % (folder, ref_name, len(ref)))
    for f in sorted(os.listdir(d)):
        if not f.lower().endswith('.kf'):
            continue
        kf = nifkf.KF.load(os.path.join(d, f))
        unknown = sorted(b for b in kf.bone_data if b.strip().lower() not in ref)
        injected = [b for b in unknown if b.strip().lower() in INJECTED]
        phantom = [b for b in unknown if b.strip().lower() not in INJECTED]
        status = 'clean' if not phantom else '%d UNKNOWN' % len(phantom)
        print('  %-26s bones=%-3d %-12s' % (f, len(kf.bone_data), status))
        if phantom:
            print('      ' + ', '.join(b.replace('Bip01 ', '') for b in phantom))
        if injected:
            print('      injected ok: ' + ', '.join(injected))
