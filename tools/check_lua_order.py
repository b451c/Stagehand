#!/usr/bin/env python3
"""check_lua_order.py - flag local functions that are called before they are defined.

Lua resolves names at compile time. Inside a function body, a `local function later()` that is
declared further DOWN the file is not in scope yet, so `later()` compiles as a call to the GLOBAL
`later`, which is nil when the code runs:

    local function a() return b() end   -- 'b' here is the global b (nil)
    local function b() return 1 end
    a()   --> attempt to call a nil value (global 'b')

The crash only shows on the code path that runs, so a static check is the cheap way to catch it
before a script is shipped to a leg or to users (two start-up crashes in the source job came from
exactly this). This checker is deliberately textual: it does not model block scope.

Usage:  check_lua_order.py FILE.lua [FILE.lua ...]
Exit:   0 = clean, prints "OK (n local functions)"
        1 = at least one finding (FILE:LINE: 'name' is called before its definition ...)
        2 = usage or read error

What counts:
  definition  = `local function NAME`, `local NAME = function`, or a forward declaration
                `local NAME` / `local A, NAME` (the earliest one wins)
  call        = NAME followed by `(`, `{`, a string literal or a long string, not preceded by
                `.` or `:` (field and method calls are ignored) and not the `function NAME(`
                of the definition itself
Comments and string bodies are blanked before scanning (newlines kept, so line numbers hold).
Only names that have a local function definition somewhere in the file are checked.
"""
import re
import sys


def blank_comments_and_strings(src):
    """Return src with comment bodies and string contents replaced by spaces.

    Delimiters (quotes, long brackets) are kept so that `f"x"` and `f[[x]]` still look like calls.
    Newlines are always kept so line numbers stay valid.
    """
    out = []
    i = 0
    n = len(src)

    def long_bracket_level(pos):
        # at src[pos] == '[' : return level if this opens a long bracket [=*[, else -1
        j = pos + 1
        while j < n and src[j] == '=':
            j += 1
        if j < n and src[j] == '[':
            return j - pos - 1
        return -1

    def skip_long(pos, level, keep_delims):
        # pos points at the opening '[' ; returns index after the closing bracket
        close = ']' + '=' * level + ']'
        start = pos + level + 2
        end = src.find(close, start)
        if end < 0:
            end = n
        body = src[start:end]
        if keep_delims:
            out.append('[' + '=' * level + '[')
        else:
            out.append(' ' * (level + 2))
        out.append(''.join('\n' if c == '\n' else ' ' for c in body))
        if end < n:
            out.append(close if keep_delims else ' ' * len(close))
            return end + len(close)
        return n

    while i < n:
        c = src[i]
        if c == '-' and src.startswith('--', i):
            # comment: long or short
            if i + 2 < n and src[i + 2] == '[':
                level = long_bracket_level(i + 2)
                if level >= 0:
                    out.append('  ')
                    i = skip_long(i + 2, level, keep_delims=False)
                    continue
            end = src.find('\n', i)
            if end < 0:
                end = n
            out.append(' ' * (end - i))
            i = end
            continue
        if c == '[':
            level = long_bracket_level(i)
            if level >= 0:
                i = skip_long(i, level, keep_delims=True)
                continue
            out.append(c)
            i += 1
            continue
        if c == '"' or c == "'":
            quote = c
            out.append(c)
            i += 1
            while i < n and src[i] != quote:
                if src[i] == '\\' and i + 1 < n:
                    out.append('  ' if src[i + 1] != '\n' else ' \n')
                    i += 2
                    continue
                out.append('\n' if src[i] == '\n' else ' ')
                i += 1
            if i < n:
                out.append(quote)
                i += 1
            continue
        out.append(c)
        i += 1
    return ''.join(out)


DEF_LOCAL_FUNCTION = re.compile(r'\blocal\s+function\s+([A-Za-z_]\w*)')
DEF_LOCAL_ASSIGN_FUNCTION = re.compile(r'\blocal\s+([A-Za-z_]\w*)\s*=\s*function\b')
DECL_LOCAL = re.compile(r'\blocal\s+(?!function\b)([A-Za-z_]\w*(?:\s*,\s*[A-Za-z_]\w*)*)')
CALL = re.compile(r'(?<![\w.:])([A-Za-z_]\w*)\s*(?:\(|\{|"|\'|\[=*\[)')


def line_of(text, pos):
    return text.count('\n', 0, pos) + 1


def check_file(path):
    """Return (findings, local_function_count). findings = list of (line, name, def_line)."""
    with open(path, 'r', encoding='utf-8', errors='replace') as fh:
        src = fh.read()
    text = blank_comments_and_strings(src)

    first_def = {}      # name -> offset of the earliest definition or forward declaration
    local_funcs = set()
    for m in DEF_LOCAL_FUNCTION.finditer(text):
        local_funcs.add(m.group(1))
        first_def.setdefault(m.group(1), m.start(1))
        first_def[m.group(1)] = min(first_def[m.group(1)], m.start(1))
    for m in DEF_LOCAL_ASSIGN_FUNCTION.finditer(text):
        local_funcs.add(m.group(1))
        first_def[m.group(1)] = min(first_def.get(m.group(1), m.start(1)), m.start(1))
    for m in DECL_LOCAL.finditer(text):
        for name in re.split(r'\s*,\s*', m.group(1)):
            if name in local_funcs:
                first_def[name] = min(first_def.get(name, m.start(1)), m.start(1))

    findings = []
    reported = set()
    for m in CALL.finditer(text):
        name = m.group(1)
        if name not in local_funcs or name in reported:
            continue
        # skip the `function NAME(` of a definition
        before = text[:m.start(1)].rstrip()
        if before.endswith('function'):
            continue
        if m.start(1) < first_def[name]:
            reported.add(name)
            findings.append((line_of(text, m.start(1)), name, line_of(text, first_def[name])))
    findings.sort()
    return findings, len(local_funcs)


def main(argv):
    if len(argv) < 2 or argv[1] in ('-h', '--help'):
        print(__doc__.strip())
        return 2
    total_funcs = 0
    total_findings = 0
    for path in argv[1:]:
        try:
            findings, count = check_file(path)
        except OSError as exc:
            print('%s: cannot read: %s' % (path, exc), file=sys.stderr)
            return 2
        total_funcs += count
        total_findings += len(findings)
        for line, name, def_line in findings:
            print("%s:%d: '%s' is called before its definition (defined at line %d)" % (path, line, name, def_line))
    if total_findings:
        print('FAIL: %d use-before-definition finding(s) in %d file(s)' % (total_findings, len(argv) - 1))
        return 1
    print('OK (%d local functions)' % total_funcs)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
