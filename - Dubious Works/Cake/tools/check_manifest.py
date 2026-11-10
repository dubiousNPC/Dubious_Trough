#!/usr/bin/env python3
"""check_manifest.py MANIFEST.omwscripts... -- what a manifest promises must be there.

1. Every listed script exists next to the manifest. OpenMW only logs
   "Can't start ...; Resource ... not found" and carries on, so a missing file
   is silent in play. CAKE shipped `AnimRefresh_v3.lua` in its manifest while
   bundling only `AnimRefresh_v6.lua`, and nothing checked.
2. No path is declared under two flags ("Flags mismatch" is fatal at startup).
3. The file's `---@omw-context` annotation agrees with its flag, so the
   context checks run against the context the engine will actually use.
"""
import collections, os, re, sys

CONTEXT = {'GLOBAL': {'global'}, 'MENU': {'menu'}, 'PLAYER': {'player', 'local|player'},
           'NPC': {'local', 'local|player'}, 'CREATURE': {'local'}, 'CUSTOM': {'local', 'local|player'}}

fail = 0
for path in sys.argv[1:]:
    base = os.path.dirname(os.path.abspath(path))
    flags = collections.defaultdict(set)
    for line in open(path, encoding='utf-8'):
        line = line.split('#')[0].strip()
        if ':' not in line:
            continue
        flag, script = (x.strip() for x in line.split(':', 1))
        for f in flag.upper().split(','):
            flags[script].add(f.strip())
    print('%s: %d script(s)' % (os.path.basename(path), len(flags)))
    for script, fs in sorted(flags.items()):
        full = os.path.join(base, script)
        if not os.path.isfile(full):
            fail += 1
            print('  MISSING         %s' % script)
            continue
        if len(fs) > 1 and not all(f in ('NPC', 'CREATURE', 'PLAYER', 'CUSTOM') for f in fs):
            fail += 1
            print('  FLAGS MISMATCH  %s  declared as %s' % (script, ', '.join(sorted(fs))))
        head = open(full, encoding='utf-8').read(400)
        m = re.search(r'---@omw-context\s+(\S+)', head)
        ctx = m.group(1) if m else None
        for f in fs:
            if ctx is None or ctx not in CONTEXT.get(f, {ctx}):
                fail += 1
                print('  CONTEXT         %s  is %s but annotated %s' % (script, f, ctx))
print('%d problem(s)' % fail)
sys.exit(1 if fail else 0)
