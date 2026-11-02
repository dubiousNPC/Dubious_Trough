#!/usr/bin/env python3
"""check_declorder.py -- a file-level local used ABOVE its own declaration.

THE BUG THIS EXISTS FOR

In Lua a `local` comes into scope only after its statement. Code above it that
uses the same name does not see it -- the name resolves to a GLOBAL instead,
silently, in both directions:

    local function onMounted()
        reissueTotal = 0          -- writes the GLOBAL
    end

    local function report()
        if reissueTotal > 0 then  -- reads the GLOBAL
            ...
        end
    end

    local reissueTotal = 0        -- a DIFFERENT variable, 90 lines down

    handler(function() reissueTotal = reissueTotal + 1 end)  -- the local

WhyWalk shipped exactly that. The handler incremented the local, the report
read the global that another function had just zeroed, and the condition was
permanently `0 > 0`: a diagnostic that could not fire, in instrumentation added
specifically to measure a reported bug.

WHY NO OTHER CHECKER CATCHES IT

  * luacheck parses it; it is valid Lua.
  * globalcheck.py reports undeclared READS -- but the code above also WRITES
    the name, which creates the global, so the read is of something that
    exists.
  * check_names.py collects declarations for the whole file at once with no
    notion of position, so the name counts as declared everywhere.

Nothing models declaration ORDER, and the result is code that reads correctly,
raises no warning, and cannot work.

SCOPE OF THE CHECK

Only FILE-LEVEL locals -- a `local` at column 0. That is where this bug class
lives, because a file-level local is the only one a function defined earlier in
the file can plausibly mean to capture. Locals inside functions are indented
and are skipped.

Comments and string literals are stripped first, including the `\\n`-in-class
fix that globalcheck.py needed: without it an unbalanced quote eats to the next
quote and hides whole regions.

FALSE POSITIVES

A function parameter or an inner `local` of the same name shadows the file-level
one legitimately. That is reported as a warning rather than a failure, with both
line numbers, because telling the two apart needs real scope analysis. In
practice the name collision is worth looking at either way.

Usage:
    check_declorder.py <file.lua|dir> ...
"""
import os
import re
import sys

KEYWORDS = set('''and break do else elseif end false for function goto if in
local nil not or repeat return then true until while'''.split())


def strip(src):
    """Blank out comments and string bodies, PRESERVING line numbering."""
    def blank(m):
        return '\n' * m.group(0).count('\n')

    src = re.sub(r'--\[\[.*?\]\]', blank, src, flags=re.S)
    src = re.sub(r'\[\[.*?\]\]', blank, src, flags=re.S)
    src = re.sub(r'--[^\n]*', '', src)
    # \n inside the character class: an unbalanced quote must not consume the
    # rest of the file.
    src = re.sub(r'"(?:\\.|[^"\\\n])*"', '""', src)
    src = re.sub(r"'(?:\\.|[^'\\\n])*'", "''", src)
    return src


# A file-level `local` is one at column 0.
DECL = re.compile(r'^local\s+(?:function\s+)?([A-Za-z_][\w]*(?:\s*,\s*[A-Za-z_][\w]*)*)',
                  re.M)
# An indented `local`, i.e. one inside some block.
INNER_DECL = re.compile(r'^[ \t]+local\s+(?:function\s+)?([A-Za-z_][\w]*(?:\s*,\s*[A-Za-z_][\w]*)*)')
FUNCARGS = re.compile(r'\bfunction\b[^(\n]*\(([^)\n]*)\)')
# A bare name: not a field access (.x / :x).
NAME = re.compile(r'(?<![\w.:])([A-Za-z_][\w]*)')


def brace_depth_at_line(src):
    """Unclosed `{` depth at the START of each line (1-based index).

    Needed to tell a TABLE KEY from an assignment. Both look like `name =`,
    but only the assignment is a use of the variable:

        I.Settings.registerGroup {
            l10n = L10N,          -- KEY. not a use of a local called l10n
            settings = { ... },   -- KEY
        }
        l10n = core.l10n(L10N)    -- an assignment, and a real use

    Without this, every mod that registers settings reports its own option
    names as used-before-declaration -- which is what the first run of this
    tool did on boats_player.lua, three times.
    """
    depths = [0]
    depth = 0
    for line in src.split('\n'):
        depths.append(depth)
        for ch in line:
            if ch == '{':
                depth += 1
            elif ch == '}':
                depth = max(0, depth - 1)
    return depths


def is_table_key(text, m, depth):
    """True when this name occurrence is a key in a table constructor."""
    if depth <= 0:
        return False
    after = text[m.end():].lstrip()
    if not after.startswith('=') or after.startswith('=='):
        return False
    before = text[:m.start()].strip()
    return before in ('', '{', ',', '{,') or before.endswith((',', '{'))


def check(path):
    src = strip(open(path, encoding='utf-8', errors='replace').read())
    lines = src.split('\n')

    # line number (1-based) of each file-level declaration, first wins
    decl_line = {}
    for m in DECL.finditer(src):
        line = src.count('\n', 0, m.start()) + 1
        for n in m.group(1).split(','):
            n = n.strip()
            if n and n not in decl_line:
                decl_line[n] = line

    # names that are legitimately shadowed somewhere: inner locals and params
    shadowed = {}
    for i, text in enumerate(lines, 1):
        m = INNER_DECL.match(text)
        if m:
            for n in m.group(1).split(','):
                shadowed.setdefault(n.strip(), i)
        for fm in FUNCARGS.finditer(text):
            for n in fm.group(1).split(','):
                n = n.strip()
                if n and n != '...':
                    shadowed.setdefault(n, i)

    depths = brace_depth_at_line(src)

    findings = []
    for i, text in enumerate(lines, 1):
        if not text.strip():
            continue
        depth = depths[i] if i < len(depths) else 0
        seen = set()
        for m in NAME.finditer(text):
            n = m.group(1)
            if n in KEYWORDS or n not in decl_line or n in seen:
                continue
            d = decl_line[n]
            if i >= d:
                continue
            if is_table_key(text, m, depth):
                continue
            seen.add(n)
            findings.append((n, i, d, n in shadowed, shadowed.get(n)))

    return findings


def main(argv):
    files = []
    for arg in argv or ['.']:
        if os.path.isdir(arg):
            for root, _, names in os.walk(arg):
                files += [os.path.join(root, f) for f in names if f.endswith('.lua')]
        elif arg.endswith('.lua'):
            files.append(arg)
    files = sorted(set(files))
    if not files:
        sys.exit('no .lua files found')

    errors = warnings = 0
    for path in files:
        found = check(path)
        if not found:
            continue
        hard = [f for f in found if not f[3]]
        soft = [f for f in found if f[3]]
        print('%s' % path)
        for n, use, decl, _, _ in sorted(hard, key=lambda f: f[1]):
            print('    USED-BEFORE-DECL  %-22s used line %-5d declared line %d'
                  % (n, use, decl))
        for n, use, decl, _, sh in sorted(soft, key=lambda f: f[1]):
            print('    shadowed?         %-22s used line %-5d declared line %-5d'
                  ' (also a param/inner local near line %s)'
                  % (n, use, decl, sh))
        errors += len(hard)
        warnings += len(soft)

    print('\n%d file(s) checked, %d used-before-declaration, %d possible shadowing'
          % (len(files), errors, warnings))
    return 1 if errors else 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
