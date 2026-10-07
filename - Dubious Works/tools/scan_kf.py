"""Scans .kf files for a wrong skeleton root and for references to bones the Morrowind
rig does not have, which are the two things that produce `addAnimSource: can't find bone`
on every load."""
import os, re, struct, sys

TYPE_NAME = b"NiStringExtraData"

# Valid finger joints on the Morrowind rig, read off FBA's own xbase_anim.1st.kf:
# three fingers per hand, one sub-joint each.
VALID_FINGERS = {'finger0','finger01','finger1','finger11','finger2','finger21'}
# 3ds Max Biped leftovers: second sub-joints, and fingers 3 and 4 entirely.
PHANTOM_RE = re.compile(r'^bip01 [lr] (finger(0|1|2)2|finger[34]\d*)$')

def targets(path):
    d=open(path,'rb').read()
    out=[]; i=0
    while True:
        i=d.find(TYPE_NAME,i)
        if i<0: break
        if i>=4:
            n,=struct.unpack_from("<I",d,i-4)
            if n==len(TYPE_NAME):
                p=i+len(TYPE_NAME)+8
                L,=struct.unpack_from("<I",d,p)
                if 0<L<1024 and p+4+L<=len(d):
                    out.append(d[p+4:p+4+L].decode('latin-1'))
        i+=1
    return out

def scan(path):
    t=targets(path)
    if not t: return None
    root=t[0]
    phantom=sorted({b for b in t[1:] if PHANTOM_RE.match(b.strip().lower())})
    return root, phantom, len(t)

rows=[]
for base in sys.argv[1:]:
    for dirpath,_,files in os.walk(base):
        for f in sorted(files):
            if not f.lower().endswith('.kf'): continue
            p=os.path.join(dirpath,f)
            r=scan(p)
            if r is None: continue
            root,phantom,n=r
            if root!='Bip01' or phantom:
                rows.append((p,root,phantom,n))
print("%-46s %-18s %-5s %s" % ("file","root","tgts","phantom bones"))
for p,root,phantom,n in rows:
    print("%-46s %-18s %-5d %s" % (os.path.basename(p), repr(root), n,
          ("%d: %s" % (len(phantom), ", ".join(b.replace('Bip01 ','') for b in phantom))) if phantom else "-"))
print("\n%d file(s) need attention" % len(rows))
