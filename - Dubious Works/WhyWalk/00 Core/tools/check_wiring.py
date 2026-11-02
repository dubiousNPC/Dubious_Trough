#!/usr/bin/env python3
"""Interface-wiring check for an OpenMW Lua mod.

A script only publishes its interface if a manifest registers it. A consumer
that guards with `if I.X and I.X.method` then degrades silently when it is not
registered, so the feature simply never exists and nothing says so -- the
failure mode this suite has hit repeatedly.

Reports:
  1. providers shipped but registered by no manifest
  2. interfaces consumed with no provider registered here (fine for a genuine
     optional dependency on another mod; a defect when the provider is shipped)
  3. manifest lines naming a file that is not in the tree
  4. registered scripts whose declared @omw-context disagrees with the manifest

usage: wiring.py <mod root>      (walks for *.omwscripts and scripts/**/*.lua)
"""
import os, re, sys

root = sys.argv[1]

def strip(src):
    out, i, n, q = [], 0, len(src), None
    while i < n:
        c = src[i]
        if q:
            if c == '\\' and i + 1 < n: out.append(src[i:i+2]); i += 2; continue
            out.append(c)
            if c == q: q = None
            i += 1; continue
        if src.startswith('--', i):
            m = re.match(r'--\[(=*)\[', src[i:])
            if m:
                close = ']' + m.group(1) + ']'
                j = src.find(close, i); j = n if j < 0 else j + len(close)
                out.append(''.join(ch if ch == '\n' else ' ' for ch in src[i:j])); i = j; continue
            j = src.find('\n', i); j = n if j < 0 else j
            out.append(' ' * (j - i)); i = j; continue
        if c in ('"', "'"): q = c
        out.append(c); i += 1
    return ''.join(out)

manifests, luafiles = [], []
for dp, _, names in os.walk(root):
    for nm in names:
        p = os.path.join(dp, nm)
        if nm.endswith('.omwscripts'): manifests.append(p)
        elif nm.endswith('.lua') and os.sep + 'tools' + os.sep not in p: luafiles.append(p)

# manifest: context -> relative script path
registered = {}          # normalised 'scripts/...' path -> (context, manifest)
for mp in manifests:
    base = os.path.dirname(mp)
    with open(mp, encoding='utf-8', errors='replace') as f:
        for ln, line in enumerate(f, 1):
            line = line.split('#')[0].strip()
            m = re.match(r'(MENU|GLOBAL|PLAYER|CUSTOM|LOAD|NPC|CREATURE|ACTIVATOR|CONTAINER|DOOR|ITEM)\s*:\s*(\S+)', line)
            if not m: continue
            ctx, rel = m.group(1), m.group(2).replace('\\', '/')
            registered[rel.lower()] = (ctx, mp, ln, base)

providers, consumers = {}, {}
for p in luafiles:
    with open(p, encoding='utf-8', errors='replace') as f:
        src = f.read()
    code = strip(src)
    m = re.search(r'interfaceName\s*=\s*[\'"]([\w]+)[\'"]', code)
    if m: providers[m.group(1)] = p
    for cm in re.finditer(r'\bI\.([A-Z]\w+)', code):
        consumers.setdefault(cm.group(1), set()).add(p)

def rel_of(p):
    """the 'scripts/...' tail a manifest would name"""
    q = p.replace('\\', '/')
    i = q.lower().rfind('/scripts/')
    return q[i+1:].lower() if i >= 0 else os.path.basename(q).lower()

print('=== 1. providers shipped but not registered by any manifest ===')
n = 0
for iface, p in sorted(providers.items()):
    if rel_of(p) not in registered:
        used_by = sorted(os.path.basename(c) for c in consumers.get(iface, ()))
        print('  %-18s %s' % (iface, os.path.relpath(p, root)))
        print('%s  consumed by: %s' % (' ' * 20, ', '.join(used_by) or '(nothing here)'))
        n += 1
print('  %d unregistered provider(s)' % n)

print('\n=== 2. interfaces consumed with no provider registered here ===')
n = 0
for iface, users in sorted(consumers.items()):
    p = providers.get(iface)
    if p is not None and rel_of(p) in registered: continue
    shipped = ' (SHIPPED but unregistered)' if p else ' (external)'
    print('  %-22s%s  used by %s' % (iface, shipped,
          ', '.join(sorted(os.path.basename(u) for u in users))))
    n += 1
print('  %d interface(s)' % n)

print('\n=== 3. manifest lines naming a missing file ===')
n = 0
for rel, (ctx, mp, ln, base) in sorted(registered.items()):
    if not os.path.exists(os.path.join(base, rel)):
        hit = any(rel_of(p) == rel for p in luafiles)
        if not hit:
            print('  %s:%d  %s: %s' % (os.path.basename(mp), ln, ctx, rel)); n += 1
print('  %d missing' % n)

print('\n=== 4. declared @omw-context vs the manifest ===')
OK = {'MENU': {'menu'}, 'GLOBAL': {'global'}, 'PLAYER': {'player'},
      'CUSTOM': {'local', 'custom'}, 'LOAD': {'load', 'global'}}
n = 0
for p in luafiles:
    rel = rel_of(p)
    if rel not in registered: continue
    ctx = registered[rel][0]
    with open(p, encoding='utf-8', errors='replace') as f:
        head = f.read(400)
    m = re.search(r'---@omw-context\s+([\w |]+)', head)
    if not m: continue
    declared = {d.strip() for d in m.group(1).split('|')}
    allowed = OK.get(ctx, set())
    if allowed and not (declared & allowed):
        print('  %-28s manifest %s, declares %s' % (
              os.path.basename(p), ctx, '|'.join(sorted(declared)))); n += 1
print('  %d disagreement(s)' % n)
