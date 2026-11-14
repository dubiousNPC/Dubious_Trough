#!/usr/bin/env python3
"""check_enums.py -- a member that an engine enum does not have.

THE BUG THIS EXISTS FOR

    local RIDE_PRIORITY = {
        [anim.BONE_GROUP.LowerBody] = anim.PRIORITY.Scripted,
        [anim.BONE_GROUP.Torso]     = anim.PRIORITY.Weapon,
        [anim.BONE_GROUP.Arms]      = anim.PRIORITY.Weapon,   -- no such member
    }

BONE_GROUP has LowerBody, Torso, LeftArm and RightArm. It is an engine
userdata enum, not a Lua table, and it RAISES on an unknown name rather than
returning nil:

    Can't start L@0x1[scripts/whywalk/ridinganim.lua]; Lua error:
    [string "scripts/whywalk/ridinganim.lua"]:102: Key not found: Arms

A load failure, not a warning. ridingAnim.lua never started, so nothing in the
suite animated -- no rider pose, no vessel pose, no caravan passenger. One bad
key cost every animation in the mod.

WHY NO OTHER CHECKER CATCHES IT

Every one of them passed on that file:

    luacheck         valid Lua
    check_names      `anim` is declared; the field is not checked
    check_declorder  declaration order is fine
    globalcheck      no undeclared global read
    check_handlers   handler tables are fine
    check_load       the harness stubs openmw.*, so the stub answers `Arms`
    ctxcheck         `animation` is permitted in this context
    api_sweep        nothing unrecognised at module level
    check_anims      not an animation GROUP name

check_load comes closest and is the most misleading: its stubs return
something for any key, which is exactly the behaviour the engine does not
have.

THIS IS THE THIRD TIME

The same family has bitten this project three times: an engine value
annotated as a table in Cod3x, used as if it were one.

    I.UI.MODE               `type(M) ~= 'table'` was always true, so the
                            travel interception stood down on every menu
    types.Creature.records  `pairs()` found nothing, so no strider creature
                            was ever found and the vehicle could not animate
    anim.BONE_GROUP         `.Arms` raised at load

WHAT IS CHECKED

Cod3x declares each enum as

    ---@class openmw.animation.BoneGroupValues
    ---@field LowerBody openmw.animation.BoneGroupLowerBody
    ...
    ---@type openmw.animation.BoneGroupValues
    animation.BONE_GROUP = nil

so the member list is recoverable. Every `<local>.<CONST>.<Member>` in the
source is resolved through the file's own `require` lines and checked against
that list.

Only ALL_CAPS constants are examined. A lower-case field is an ordinary table
or function and is none of this checker's business.

Usage:
    check_enums.py <cod3x-dir> <file.lua|dir> ...
"""
import os
import re
import sys

# ---------------------------------------------------------------------------
# the enum members Cod3x declares
# ---------------------------------------------------------------------------

CLASS_RE = re.compile(r'^---@class\s+([\w.]+)\s*$', re.M)
FIELD_RE = re.compile(r'^---@field\s+(\w+)')
TYPED_RE = re.compile(
    r'^---@type\s+([\w.]+)\s*\n([\w.]+)\.([A-Z][A-Z0-9_]*)\s*=\s*nil', re.M)


def load_enums(cod3x):
    """{ 'openmw.animation': { 'BONE_GROUP': {members} } }"""
    classes = {}        # class name -> set of field names
    enums = {}          # module -> const -> members

    files = []
    for root, _, names in os.walk(cod3x):
        files += [os.path.join(root, n) for n in names if n.endswith('.lua')]

    texts = {}
    for path in files:
        texts[path] = open(path, encoding='utf-8', errors='replace').read()

    # pass 1: every ---@class and the ---@field lines that follow it
    for text in texts.values():
        lines = text.split('\n')
        for i, line in enumerate(lines):
            m = CLASS_RE.match(line)
            if not m:
                continue
            fields = set()
            for nxt in lines[i + 1:]:
                fm = FIELD_RE.match(nxt)
                if fm:
                    fields.add(fm.group(1))
                elif not nxt.startswith('---'):
                    break
            if fields:
                classes[m.group(1)] = fields

    # pass 2: `---@type <class>` immediately above `<module>.<CONST> = nil`
    for text in texts.values():
        for m in TYPED_RE.finditer(text):
            cls, mod, const = m.group(1), m.group(2), m.group(3)
            if cls not in classes:
                continue
            # `animation.BONE_GROUP` in openmw/animation.lua -> openmw.animation
            enums.setdefault('openmw.' + mod, {})[const] = classes[cls]
            enums.setdefault(mod, {})[const] = classes[cls]

    return enums


# ---------------------------------------------------------------------------
# the source side
# ---------------------------------------------------------------------------

REQUIRE_RE = re.compile(
    r"""^\s*local\s+(\w+)\s*=\s*require\(\s*['"]([\w.]+)['"]\s*\)""", re.M)
# <alias>.<CONST>.<Member>
USE_RE = re.compile(r'\b(\w+)\.([A-Z][A-Z0-9_]*)\.(\w+)')


def _blank(m):
    return '\n' * m.group(0).count('\n')


def strip_comments(src):
    """Blank comments only. STRINGS SURVIVE, preserving line count.

    Two stages, because the require() paths and the enum uses need different
    things. The first version did both at once and silently broke itself:
    blanking string bodies turned every `require('openmw.animation')` into
    `require('')`, so no alias was ever resolved, so nothing was ever checked
    -- a checker that reported 0 findings on the very bug it was written for.
    Caught only because it was run against that bug before being trusted.
    """
    src = re.sub(r'--\[\[.*?\]\]', _blank, src, flags=re.S)
    src = re.sub(r'--[^\n]*', '', src)
    return src


def strip_strings(src):
    """Blank string bodies, preserving line count. For scanning enum uses."""
    src = re.sub(r'\[\[.*?\]\]', _blank, src, flags=re.S)
    # \n inside the class: an unbalanced quote must not eat the rest of the
    # file, which is the fix globalcheck.py needed for the same regex.
    src = re.sub(r'"(?:\\.|[^"\\\n])*"', '""', src)
    src = re.sub(r"'(?:\\.|[^'\\\n])*'", "''", src)
    return src


def check(path, enums):
    raw = open(path, encoding='utf-8', errors='replace').read()
    nocomments = strip_comments(raw)

    # Aliases from text that still HAS its strings.
    aliases = {m.group(1): m.group(2) for m in REQUIRE_RE.finditer(nocomments)}
    if not aliases:
        return []

    # Uses from text that has neither comments nor string bodies, so a module
    # name mentioned in prose cannot be read as code.
    src = strip_strings(nocomments)

    findings = []
    for i, line in enumerate(src.split('\n'), 1):
        for m in USE_RE.finditer(line):
            alias, const, member = m.group(1), m.group(2), m.group(3)
            module = aliases.get(alias)
            if not module:
                continue
            members = enums.get(module, {}).get(const)
            if not members:
                continue
            if member not in members:
                findings.append((i, '%s.%s.%s' % (alias, const, member),
                                 sorted(members)))
    return findings


def main(argv):
    if len(argv) < 2:
        sys.exit(__doc__.strip().split('\n')[-1])

    cod3x, targets = argv[0], argv[1:]
    enums = load_enums(cod3x)
    n_enums = sum(len(v) for k, v in enums.items() if k.startswith('openmw.'))
    if not n_enums:
        sys.exit('no enums found in %s -- is that the Cod3x directory?' % cod3x)

    files = []
    for arg in targets:
        if os.path.isdir(arg):
            for root, _, names in os.walk(arg):
                files += [os.path.join(root, n)
                          for n in names if n.endswith('.lua')]
        elif arg.endswith('.lua'):
            files.append(arg)
    files = sorted(set(files))
    if not files:
        sys.exit('no .lua files found')

    total = 0
    for path in files:
        found = check(path, enums)
        if not found:
            continue
        print(path)
        for line, used, members in found:
            print('    line %-5d NO SUCH MEMBER  %-34s has: %s'
                  % (line, used, ', '.join(members)))
        total += len(found)

    print('\npolicy: %d enum(s) from %s' % (n_enums, cod3x))
    print('%d file(s) checked, %d bad member(s)' % (len(files), total))
    return 1 if total else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
