#!/usr/bin/env python3
"""check_i18n.py <package dir> - every t('key') used in the Lua code must exist in stagehand/lang/en.lua.

Reports missing keys (exit 1) and unused keys (informational). Part of the static gate before a leg run.
"""
import os
import re
import sys


def main():
    root = sys.argv[1] if len(sys.argv) > 1 else 'Stagehand'
    lang = os.path.join(root, 'stagehand', 'lang', 'en.lua')
    if not os.path.isfile(lang):
        print('check_i18n: no %s' % lang)
        return 1
    defined = set(re.findall(r"^M\['([^']+)'\]\s*=", open(lang, encoding='utf-8').read(), re.M))
    used = {}
    for dirpath, _, files in os.walk(root):
        for f in files:
            if not f.endswith('.lua') or dirpath.endswith('lang'):
                continue
            path = os.path.join(dirpath, f)
            text = open(path, encoding='utf-8').read()
            for m in re.finditer(r"\bt\(\s*'([a-z0-9_.]+)'", text):
                used.setdefault(m.group(1), set()).add(os.path.relpath(path, root))
    missing = sorted(k for k in used if k not in defined)
    # keys the code builds at runtime from the schema (labels, tooltips, values, groups): never "unused"
    dynamic = ('cfg.',)
    unused = sorted(k for k in defined if k not in used and not k.startswith(dynamic))
    for k in missing:
        print('check_i18n: MISSING %s (used in %s)' % (k, ', '.join(sorted(used[k]))))
    if unused:
        print('check_i18n: unused keys: %s' % ', '.join(unused))
    print('check_i18n: %d keys used, %d defined, %d missing' % (len(used), len(defined), len(missing)))
    return 1 if missing else 0


if __name__ == '__main__':
    sys.exit(main())
