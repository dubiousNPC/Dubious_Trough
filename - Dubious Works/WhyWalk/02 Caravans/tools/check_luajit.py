#!/usr/bin/env python3
"""Reject Lua 5.3+ constructs that OpenMW's LuaJIT (Lua 5.1) runs differently or not at all.

    python3 -I tools/check_luajit.py FILE.lua ...

Why this exists: the test tools run on liblua5.4, the game runs LuaJIT. Where the two
languages disagree SILENTLY, every test passes and the game is wrong. The case that cost
this module a fortnight: `math.atan(y, x)` is a quadrant-aware arctangent in 5.3+, and in
LuaJIT the second argument is ignored -- measured in OpenMW 0.52, math.atan(1, -1) = 0.785.

Flagged:
  math.atan with two arguments  -> use math.atan2 (or `local atan2 = math.atan2 or math.atan`)
  //                            -> 5.3 integer division; LuaJIT: syntax error
  & | ~ << >> (binary)          -> 5.3 bitwise operators; LuaJIT: syntax error (use bit.*)
  math.type math.tointeger math.ult utf8. string.pack string.unpack string.packsize table.move
                                -> absent in LuaJIT: nil, raising only when reached
"""
import re
import sys

ABSENT = re.compile(r'\b(math\.type|math\.tointeger|math\.ult|utf8\.[A-Za-z_]+|string\.pack|'
                    r'string\.unpack|string\.packsize|table\.move)\b')


def strip(src):
    """Blank out comments and strings, keeping line structure."""
    out, i, n = [], 0, len(src)
    while i < n:
        c = src[i]
        if src.startswith('--', i):
            m = re.match(r'--\[(=*)\[', src[i:])
            if m:
                end = src.find(']' + m.group(1) + ']', i)
                end = n if end < 0 else end + len(m.group(1)) + 2
            else:
                end = src.find('\n', i)
                end = n if end < 0 else end
            out.append(re.sub(r'[^\n]', ' ', src[i:end])); i = end; continue
        m = re.match(r'\[(=*)\[', src[i:])
        if m:
            end = src.find(']' + m.group(1) + ']', i)
            end = n if end < 0 else end + len(m.group(1)) + 2
            out.append(re.sub(r'[^\n]', ' ', src[i:end])); i = end; continue
        if c in '"\'':
            j = i + 1
            while j < n and src[j] != c:
                j += 2 if src[j] == '\\' else 1
            out.append(' ' * (j + 1 - i)); i = j + 1; continue
        out.append(c); i += 1
    return ''.join(out)


def atan_two_args(code):
    """Line numbers of math.atan / a local alias of it called with a top-level comma."""
    aliases = {'math.atan'}
    for m in re.finditer(r'\blocal\s+([A-Za-z_][\w\s,]*)=\s*([^\n]+)', code):
        names = [x.strip() for x in m.group(1).split(',')]
        vals = [x.strip() for x in m.group(2).split(',')]
        for nm, val in zip(names, vals):
            if val == 'math.atan':
                aliases.add(nm)
    hits = []
    for alias in aliases:
        for m in re.finditer(r'(?<![\w.])' + re.escape(alias) + r'\s*\(', code):
            depth, j = 1, m.end()
            while j < len(code) and depth:
                ch = code[j]
                if ch in '([{':
                    depth += 1
                elif ch in ')]}':
                    depth -= 1
                elif ch == ',' and depth == 1:
                    hits.append(code.count('\n', 0, m.start()) + 1)
                    break
                j += 1
    return sorted(set(hits))


def check(path):
    code = strip(open(path, encoding='utf-8', errors='replace').read())
    found = []
    for ln in atan_two_args(code):
        found.append((ln, 'math.atan with two arguments: LuaJIT ignores the second (use math.atan2)'))
    for k, line in enumerate(code.split('\n'), 1):
        if '//' in line:
            found.append((k, '// is Lua 5.3 integer division; a syntax error in LuaJIT'))
        if re.search(r'<<|>>|[^~=<>]~[^=]|(?<![\w\s])\s*&|\w\s*&\s*\w|\w\s*\|\s*\w', line):
            found.append((k, 'bitwise operator is Lua 5.3; use the bit library in LuaJIT'))
        m = ABSENT.search(line)
        if m:
            found.append((k, f'{m.group(1)} does not exist in LuaJIT'))
    return found


def main():
    bad = 0
    for path in sys.argv[1:]:
        f = check(path)
        bad += bool(f)
        if f:
            for ln, msg in f:
                print(f'{path}:{ln}: {msg}')
        else:
            print(f'ok   {path}')
    print(f'\n{len(sys.argv) - 1} file(s) checked, {bad} with LuaJIT incompatibilities')
    sys.exit(1 if bad else 0)


if __name__ == '__main__':
    main()
