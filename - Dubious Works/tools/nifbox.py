"""Minimal Morrowind NIF (4.0.0.2) geometry extents: walks NiNode/NiTriShape
hierarchy from the root, applies transforms, reports render-geometry AABB in
model space, separately from RootCollisionNode geometry."""
import struct, sys, re, math
KNOWN = re.compile(rb'^(Ni[A-Za-z]+|RootCollisionNode|AvoidNode|BSFurnitureMarker)$')
def blocks(d):
    hdr = d.find(b'\n')  # header line
    i = hdr + 1 + 4  # version
    nblocks = struct.unpack_from('<I', d, i)[0]; i += 4
    starts = []
    j = i
    while j < len(d) - 8 and len(starts) < nblocks:
        n = struct.unpack_from('<I', d, j)[0]
        if 4 <= n <= 40:
            s = d[j+4:j+4+n]
            if KNOWN.match(s) and (j == i or starts):
                starts.append((j, s.decode())); j += 4 + n; continue
        j += 1
    return nblocks, starts
def mat(r): return [r[0:3], r[3:6], r[6:9]]
def mul(a, b): return [[sum(a[i][k]*b[k][j] for k in range(3)) for j in range(3)] for i in range(3)]
def app(m, v): return [sum(m[i][k]*v[k] for k in range(3)) for i in range(3)]
def parse(path):
    d = open(path, 'rb').read()
    nb, st = blocks(d)
    if len(st) != nb: print('  WARN block count', nb, len(st))
    B = {}
    for idx, (off, typ) in enumerate(st):
        p = off + 4 + len(typ)
        def rd(fmt):
            nonlocal p
            v = struct.unpack_from(fmt, d, p); p += struct.calcsize(fmt); return v
        b = {'type': typ}
        if typ in ('NiNode', 'RootCollisionNode', 'NiTriShape', 'NiBSAnimationNode', 'NiBSParticleNode', 'AvoidNode', 'NiTriStrips'):
            n, = rd('<I'); b['name'] = d[p:p+n].decode('latin1'); p += n
            rd('<ii'); rd('<H')
            b['t'] = rd('<3f'); b['r'] = mat(rd('<9f')); b['s'], = rd('<f'); rd('<3f')
            np_, = rd('<I'); rd('<%di' % np_)
            hb, = rd('<I')
            if hb: rd('<I'); rd('<3f'); rd('<9f'); rd('<3f')
            if typ in ('NiTriShape', 'NiTriStrips'):
                b['data'], = rd('<i'); rd('<i')
            else:
                nc, = rd('<I'); b['children'] = rd('<%di' % nc); ne, = rd('<I'); rd('<%di' % ne)
        elif typ in ('NiTriShapeData', 'NiTriStripsData'):
            nv, = rd('<H'); hv, = rd('<I')
            b['verts'] = [rd('<3f') for _ in range(nv)] if hv else []
        B[idx] = b
    return B
def extents(B):
    out = {'render': [], 'collision': []}
    def walk(i, m, t, s, coll):
        b = B.get(i)
        if not b or 'r' not in b: return
        nm = mul(m, b['r']); nt = [t[k] + s*app(m, b['t'])[k] for k in range(3)]; ns = s*b['s']
        c = coll or b['type'] == 'RootCollisionNode'
        if b['type'] in ('NiTriShape', 'NiTriStrips'):
            db = B.get(b['data'])
            if db:
                for v in db['verts']:
                    w = app(nm, v); out['collision' if c else 'render'].append([nt[k] + ns*w[k] for k in range(3)])
        for ch in b.get('children', ()):
            if ch >= 0: walk(ch, nm, nt, ns, c)
    I = [[1,0,0],[0,1,0],[0,0,1]]
    walk(0, I, [0,0,0], 1.0, False)
    return out
def box(pts):
    if not pts: return None
    return [round(min(p[k] for p in pts), 1) for k in range(3)], [round(max(p[k] for p in pts), 1) for k in range(3)]
if __name__ == '__main__':
    for path in sys.argv[1:]:
        B = parse(path); e = extents(B)
        r, c = box(e['render']), box(e['collision'])
        root = B[0]
        print(path.split('/')[-1])
        print('   root type=%s rotZ(deg)=%.1f trans=%s' % (root['type'], math.degrees(math.atan2(root['r'][1][0], root['r'][0][0])) if 'r' in root else 0, root.get('t')))
        print('   render    min=%s max=%s  verts=%d' % (r[0], r[1], len(e['render'])) if r else '   render none')
        print('   collision min=%s max=%s  verts=%d' % (c[0], c[1], len(e['collision'])) if c else '   collision none (all render geometry collides)')
