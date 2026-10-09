"""Do the extended finger tracks actually animate, or are they constant filler?

Decides whether removing them loses anything. A track with one key, or whose rotation
never departs from its first value, carries no animation.
"""
import os, sys
sys.path.insert(0, os.environ['FBACOMPAT_TOOLS'])
import nifkf, fba_merge
E = fba_merge.E

EXTENDED = {('bip01 %s finger%s' % (s, j))
            for s in ('l', 'r') for j in ('02','12','22','3','31','32','4','41','42')}
BASE = {('bip01 %s finger%s' % (s, j))
        for s in ('l', 'r') for j in ('0','01','1','11','2','21')}

def span(kf):
    ts = [t for t, _ in kf.text_keys()]
    return min(ts), max(ts)

def swing(kf, bone, n=48):
    d = kf.data(bone)
    nkeys = len(d.quat_keys) if d.rot_type != 4 else sum(len(a['keys']) for a in d.xyz)
    t0, t1 = span(kf)
    rots = [E.rotation(d, t0 + (t1 - t0) * i / n) for i in range(n + 1)]
    return nkeys, max(E.qangle(rots[0], r) for r in rots)

print("%-28s %-10s %-26s %-26s" % ("file", "folder", "extended fingers", "base fingers"))
for base in sys.argv[1:]:
    for dirpath, _, files in os.walk(base):
        folder = os.path.basename(dirpath)
        for f in sorted(files):
            if not f.lower().endswith('.kf'):
                continue
            kf = nifkf.KF.load(os.path.join(dirpath, f))
            ext = [(b,) + swing(kf, b) for b in kf.bone_data if b.strip().lower() in EXTENDED]
            bas = [(b,) + swing(kf, b) for b in kf.bone_data if b.strip().lower() in BASE]
            if not ext and not bas:
                continue
            def fmt(rows):
                if not rows:
                    return "-"
                keys = max(r[1] for r in rows)
                mx = max(r[2] for r in rows)
                return "%2d tracks, %d keys, %6.2f deg" % (len(rows), keys, mx)
            print("%-28s %-10s %-26s %-26s" % (f, folder, fmt(ext), fmt(bas)))
