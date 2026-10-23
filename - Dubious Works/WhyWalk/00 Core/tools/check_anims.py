#!/usr/bin/env python3
"""check_anims.py -- every animation group a script plays must exist in a .kf.

`animation.playBlended` on a group the actor's skeleton does not define is a
SILENT no-op (RESEARCH 3.2): no error, no clip, and the actor keeps whatever
pose it had. A group missing from one skeleton folder and present in the others
is worse still, because it works for you and not for half your players.

This reads text keys out of every .kf under animations/ -- OpenMW takes the
group name from the part before the colon in a text key, so `dbssit4: start`
declares group `dbssit4` -- and cross-references them against the group-name
string literals in the Lua.

It also reports FOLDER coverage, because the usual failure is not a typo but a
skeleton variant nobody made files for: OpenMW resolves additional animation
sources per skeleton, so a female actor looks in animations/xbase_anim_female/
and does not fall back to animations/xbase_anim/.

Usage:
    check_anims.py <mod-dir> [--groups NAME,NAME] [--skeletons a,b,c] [--strict]
"""
import os
import re
import struct
import sys
import glob

# The four skeletons a humanoid-facing mod normally has to cover.
DEFAULT_SKELETONS = ['xbase_anim', 'xbase_anim.1st',
                     'xbase_anim_female', 'xbase_animkna']

TEXTKEY = re.compile(r'^([A-Za-z][\w ]*?)\s*:\s*(start|stop|loop start|loop stop)\b',
                     re.IGNORECASE)


def kf_strings(path):
    data = open(path, 'rb').read()
    out, i = [], 0
    while i < len(data) - 4:
        n = struct.unpack_from('<I', data, i)[0]
        if 2 <= n <= 256 and i + 4 + n <= len(data):
            s = data[i + 4:i + 4 + n]
            if all(32 <= c < 127 or c in (10, 13) for c in s):
                out.append(s.decode('ascii', 'replace'))
                i += 4 + n
                continue
        i += 1
    return out


INCOMPLETE = []
DUPLICATED = []


def kf_groups(path):
    """Group names declared by text keys in this .kf -- COMPLETE groups only.

    A group needs both `start` and `stop`, and its `loop start`/`loop stop`
    must come as a pair. A misspelt prefix splits one group into two broken
    ones: xGondola1.kf shipped as `godola1: start / loop start / loop stop`
    plus `gondola1: stop`, and the old "any key declares the group" rule
    passed `gondola1` while neither name could play. Incomplete groups are
    reported and not counted as declared.

    DUPLICATES are reported too, and that check exists because this tool
    missed one. It collected keys into a SET, so a group declared twice --
    two complete start/stop cycles under one name -- collapsed to a single
    entry and passed as healthy. xRowing1.kf shipped exactly that: five
    sequential segments, of which two were both called `rowingr`, and the
    left-turn stroke had no name of its own. A group cannot have two start
    keys and play both, so one segment is unreachable and the author's intent
    is silently lost -- the same failure as the godola1 typo wearing a
    different hat.

    Counting keys instead of setting them is the whole fix.
    """
    keys = {}
    for s in kf_strings(path):
        for line in s.splitlines():
            m = TEXTKEY.match(line.strip())
            if m:
                g = m.group(1).strip().lower()
                keys.setdefault(g, {})
                k = m.group(2).lower()
                keys[g][k] = keys[g].get(k, 0) + 1
    groups = set()
    for g, counts in keys.items():
        missing = [x for x in ('start', 'stop') if x not in counts]
        unpaired = ('loop start' in counts) != ('loop stop' in counts)
        if missing or unpaired:
            INCOMPLETE.append((os.path.relpath(path), g, sorted(counts)))
            continue
        groups.add(g)
        # More than one start/stop cycle under one name.
        cycles = min(counts.get('start', 0), counts.get('stop', 0))
        if cycles > 1:
            DUPLICATED.append((os.path.relpath(path), g, cycles,
                               ', '.join('%s x%d' % (k, n)
                                         for k, n in sorted(counts.items()))))
    return groups


def lua_group_candidates(root, known):
    """Where each known group name is referenced in the Lua."""
    hits = {}
    for p in glob.glob(os.path.join(root, 'scripts', '**', '*.lua'), recursive=True):
        for lineno, line in enumerate(open(p, encoding='utf-8'), 1):
            if line.lstrip().startswith('--'):
                continue
            for m in re.finditer(r'''["']([\w]+)["']''', line):
                name = m.group(1).lower()
                if name in known:
                    hits.setdefault(name, []).append(
                        (os.path.relpath(p, root), lineno))
    return hits


# Vanilla animation groups the BASE GAME supplies. This package does not ship
# them, so no .kf here declares them and the unresolved check below must not
# flag them. Not exhaustive -- it covers what these scripts actually reach for.
VANILLA_GROUPS = {
    'idle', 'idle2', 'idle3', 'idle4', 'idle5', 'idle6', 'idle7', 'idle8', 'idle9',
    'walkforward', 'walkback', 'walkleft', 'walkright',
    'runforward', 'runback', 'runleft', 'runright',
    'swimwalkforward', 'swimrunforward',
    'sneakforward', 'sneakback',
    'jump', 'jumpstart', 'jumploop', 'jumpland',
    'death1', 'death2', 'death3', 'death4', 'death5',
    'hit1', 'hit2', 'hit3', 'hit4', 'hit5', 'knockdown', 'knockout',
    'attack1', 'attack2', 'attack3', 'spellcast', 'shield', 'torch',
    'sitcrossedlegs', 'sitchair', 'sitbed', 'vasittingfloor',
}

# Where a group NAME plausibly appears in the Lua: the tables that map a state
# to a clip. A string literal anywhere else is far more likely to be an event
# name, a setting key or a record id, so the unresolved check is scoped to
# these rather than guessing from the shape of the word.
GROUP_TABLE_HINTS = (
    'RIDE_ANIM', 'FALLBACK_ANIM', 'HORSE_ANIM', 'VESSEL_GROUP',
    'VESSEL_STANCE_BY_NAME', 'GAIT', 'FALLBACK',
)


def lua_unresolved(root, declared):
    """Group names the Lua plays that NOTHING declares and no skeleton has.

    THIS CHECK EXISTS BECAUSE THE TOOL MISSED A SHIPPED BUG.

    It reported coverage for every group the .kf files DECLARE, which is the
    forward direction, and said nothing about the reverse: a name the scripts
    hand to playBlended that no clip defines. `playBlended` on a group the
    skeleton does not have is a silent no-op, so such a name resolves fine,
    passes every nil check, plays nothing, and reports nothing.

    WhyWalk shipped FALLBACK_ANIM as ride_generic_idle / _walk / _gallop /
    _reverse / _jump -- five names that exist in no file anywhere -- plus six
    mount types whose whole sets were placeholders (rideb1, riden1, rides1,
    ridek1, ridefly1, ridenetch1). Every creature outside horse and guar
    therefore rode in bind pose, and this tool said "0 group(s) unplayable".

    Scoped to the state->clip tables (GROUP_TABLE_HINTS) by scanning from a
    hint line to the end of its table, because a bare string literal elsewhere
    in the scripts is usually an event name or a record id.
    """
    unresolved = {}
    for p in glob.glob(os.path.join(root, 'scripts', '**', '*.lua'), recursive=True):
        lines = open(p, encoding='utf-8').readlines()
        depth, active = 0, False
        for lineno, line in enumerate(lines, 1):
            code = line.split('--', 1)[0] if not line.lstrip().startswith('--') else ''
            if not active and any(h in line for h in GROUP_TABLE_HINTS) and '=' in line:
                active, depth = True, 0
            if active:
                for m in re.finditer(r'''["']([\w]+)["']''', code):
                    name = m.group(1).lower()
                    if name in declared or name in VANILLA_GROUPS:
                        continue
                    # A group name in these tables is the only thing that
                    # belongs there, so anything unaccounted for is suspect.
                    unresolved.setdefault(name, []).append(
                        (os.path.relpath(p, root), lineno))
                depth += code.count('{') - code.count('}')
                if depth <= 0 and '{' in ''.join(lines[max(0, lineno - 1):lineno]):
                    active = False
                elif depth <= 0:
                    active = False
    return unresolved


def main(argv):
    declared, skeletons = set(), list(DEFAULT_SKELETONS)
    strict = False
    args, i = [], 0
    while i < len(argv):
        if argv[i] == '--strict':
            strict = True
            i += 1
        elif argv[i] == '--groups' and i + 1 < len(argv):
            declared |= {x.strip().lower() for x in argv[i + 1].split(',') if x.strip()}
            i += 2
        elif argv[i] == '--skeletons' and i + 1 < len(argv):
            skeletons = [x.strip() for x in argv[i + 1].split(',') if x.strip()]
            i += 2
        else:
            args.append(argv[i])
            i += 1
    root = args[0] if args else '.'

    anim_root = os.path.join(root, 'animations')
    present = {d: {} for d in skeletons}
    extra_dirs = []
    if os.path.isdir(anim_root):
        for d in sorted(os.listdir(anim_root)):
            full = os.path.join(anim_root, d)
            if not os.path.isdir(full):
                continue
            files = {os.path.basename(f): kf_groups(f)
                     for f in sorted(glob.glob(os.path.join(full, '*.kf')))}
            if d in present:
                present[d] = files
            else:
                extra_dirs.append(d)

    print('animation folders expected: %s' % ', '.join(skeletons))
    for d in skeletons:
        files = present[d]
        if not os.path.isdir(os.path.join(anim_root, d)):
            print('  ABSENT    %-20s no such folder' % d)
        else:
            allg = set().union(*files.values()) if files else set()
            print('  %-9s %-20s %d file(s), %d group(s)'
                  % ('ok', d, len(files), len(allg)))
    if extra_dirs:
        print('  (also present, not checked: %s)' % ', '.join(extra_dirs))

    # A group is only usable on a skeleton whose folder declares it.
    per_skel = {d: (set().union(*present[d].values()) if present[d] else set())
                for d in skeletons}
    everywhere = set().union(*per_skel.values()) if per_skel else set()

    print('\ngroups declared by the shipped .kf files: %d' % len(everywhere))
    for g in sorted(everywhere):
        missing_in = [d for d in skeletons if g not in per_skel[d]]
        flag = 'ALL' if not missing_in else 'missing in ' + ', '.join(missing_in)
        print('  %-24s %s' % (g, flag))

    problems = 0
    if declared:
        print('\ngroups the scripts play:')
        hits = lua_group_candidates(root, declared)
        for g in sorted(declared):
            where = hits.get(g)
            loc = ('%s:%d' % where[0]) if where else 'not referenced in Lua'
            missing_in = [d for d in skeletons if g not in per_skel[d]]
            if not missing_in:
                print('  ok        %-24s %s' % (g, loc))
            else:
                problems += 1
                print('  MISSING   %-24s absent from: %s  (%s)'
                      % (g, ', '.join(missing_in), loc))

    if INCOMPLETE:
        print('\nINCOMPLETE groups (not playable; check the text-key spelling):')
        for path, g, k in INCOMPLETE:
            print('  %-14s keys %-40s %s' % (g, ', '.join(k), path))
        problems += len(INCOMPLETE)

    if DUPLICATED:
        print('\nDUPLICATED groups (two or more segments share one name, so'
              ' only one is reachable):')
        for path, g, cycles, counts in DUPLICATED:
            print('  %-14s %d cycles  [%s]  %s' % (g, cycles, counts, path))
        problems += len(DUPLICATED)

    # Everything any skeleton folder declares, plus any --groups override.
    declared_all = everywhere | declared
    unresolved = lua_unresolved(root, declared_all)
    if unresolved:
        print('\nUNRESOLVED group names -- the Lua names these, no .kf declares'
              ' them, and they are not vanilla. playBlended will do nothing,'
              ' silently.')
        print('  These are a FAILURE only if nothing else covers them. WhyWalk'
              ' falls back to the horse')
        print('  set (whywalk_shared.resolveAnim, which tests each candidate'
              ' with animation.hasGroup),')
        print('  so the names below are documented placeholders rather than'
              ' dead ends. Pass --strict to')
        print('  count them. What is NOT survivable is an unresolved name in a'
              ' table with no fallback,')
        print('  which is why the list is printed in full either way.\n')
        for name in sorted(unresolved):
            where = unresolved[name]
            loc = ', '.join('%s:%d' % w for w in where[:3])
            if len(where) > 3:
                loc += ', +%d more' % (len(where) - 3)
            print('  %-24s %s' % (name, loc))
        if strict:
            problems += len(unresolved)
        else:
            print('\n  (%d placeholder name(s); not counted -- use --strict)'
                  % len(unresolved))

    print('\n%d group(s) unplayable on at least one skeleton' % problems)
    return 1 if problems else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
