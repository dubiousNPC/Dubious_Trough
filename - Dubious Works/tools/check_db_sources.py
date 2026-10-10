#!/usr/bin/env python3
"""check_db_sources.py -- every `src:` provenance in boats_db.lua must still
equal the value extracted into data/boats_sources.json.

A hand-maintained table drifts from its source silently; this makes the drift
a failure. `derived:` and `pref:` entries are listed, not checked -- they are
judgements, and the doc shows them for a human to judge.

Run from the module root:  python3 tools/check_db_sources.py
"""
import json
import math
import os
import re
import subprocess
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..')


def load_db():
    out = subprocess.run([sys.executable, '-I', 'tools/luarun.py', 'tools/dump_db.lua'],
                         cwd=ROOT, capture_output=True, text=True, check=True).stdout
    return json.loads(out)


SOURCES = json.load(open(os.path.join(ROOT, 'data', 'boats_sources.json')))
DB = load_db()


def resolve(path):
    node = SOURCES
    # mesh keys contain dots and slashes ('x/ex_gondola_01_rot.nif'): match greedily
    parts = path.split('.')
    i = 0
    while i < len(parts):
        for j in range(len(parts), i, -1):
            key = '.'.join(parts[i:j])
            if isinstance(node, dict) and key in node:
                node = node[key]
                i = j
                break
        else:
            raise KeyError(path)
    return node


def scalar(node):
    if isinstance(node, dict):
        return node.get('value', node.get('raw'))
    return node


OPS = {'abs': abs, 'neg': lambda x: -x, 'half': lambda x: x / 2, 'x2': lambda x: x * 2,
       'x3': lambda x: x * 3, 'x0.6': lambda x: x * 0.6}


def close(a, b, rel=2e-3, absolute=0.06):
    return abs(a - b) <= max(absolute, rel * max(abs(a), abs(b)))


def hull_from_collision(node, yaw_offset, water_offset):
    lo, hi = node['min'], node['max']
    if abs(yaw_offset - math.pi) < 1e-6:   # bow at -Y
        bow, stern = -lo[1], hi[1]
    else:
        bow, stern = hi[1], -lo[1]
    return {'bow': bow, 'stern': stern, 'halfBeam': max(-lo[0], hi[0]), 'draft': -lo[2] - water_offset}


def field(vessel, name):
    if name in vessel:
        return vessel[name]
    return vessel.get('motion', {}).get(name)


problems, checked, judged = [], 0, []
for vid, prov in DB['PROVENANCE'].items():
    vessel = DB['VESSELS'][vid]
    for name, spec in prov.items():
        m = re.match(r'src:([\w./-]+?)(?:\|([\w.]+))?(?::|$)', spec)
        if not m:
            judged.append((vid, name, spec))
            continue
        path, op = m.group(1), m.group(2)
        try:
            node = resolve(path)
        except KeyError:
            problems.append('%s.%s: source path not found: %s' % (vid, name, path))
            continue
        mine = field(vessel, name)
        checked += 1

        if name == 'hull':
            want = hull_from_collision(node, 0.0, vessel['waterOffset'])
            for k, v in want.items():
                if not close(mine[k], v):
                    problems.append('%s.hull.%s = %s, collision box gives %.1f' % (vid, k, mine[k], v))
            continue
        if name == 'anchor':
            if path.endswith('pilotSeat'):
                seat = node['raw']
                want = {'x': 0, 'y': 0, 'z': seat['z'] - vessel['waterOffset']}
            elif isinstance(node, list):
                want = {'x': node[0], 'y': node[1], 'z': node[2]}
            else:
                want = node
            for k in 'xyz':
                if not close(mine[k], want[k]):
                    problems.append('%s.anchor.%s = %s, source gives %s' % (vid, k, mine[k], want[k]))
            continue
        if name == 'sound':
            want = node if isinstance(node, str) else (node[0] if node else None)
            if mine != want:
                problems.append('%s.sound = %r, source gives %r' % (vid, mine, want))
            continue

        want = scalar(node)
        if op:
            want = OPS[op](want)
        if not isinstance(mine, (int, float)) or not close(mine, want):
            problems.append('%s.%s = %r, source %s gives %r' % (vid, name, mine, path, want))

for p in problems:
    print('MISMATCH ' + p)
print('%d traced value(s) checked, %d mismatch(es); %d derived/preference entries not machine-checked'
      % (checked, len(problems), len(judged)))
sys.exit(1 if problems else 0)
