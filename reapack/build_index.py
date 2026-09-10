#!/usr/bin/env python3
"""build_index.py [--out index.xml] [--url-base URL | --commit SHA] [--time ISO] [--check]

Writes the ReaPack repository index for Stagehand from the header of Stagehand/Stagehand.lua (@description,
@version, @author, @provides, @link, @about, @changelog): one package "Stagehand.lua" in category "Stagehand" whose
sources are every file @provides names (globs expanded against the package folder), with the [main] launchers marked
as actions. Standard library only (the Ruby reapack-index is not needed); the GitHub Actions workflow runs it on every
push to main with --commit $GITHUB_SHA so the source URLs pin the commit. --url-base points the sources elsewhere
(a LAN HTTP server for an install test: <base>/Stagehand/<file>). --check validates the header and the file list
without writing. Exit: 0 ok, 1 a provided file is missing or the header is incomplete.
"""
import argparse
import datetime
import glob
import os
import re
import sys
import urllib.parse
from xml.sax.saxutils import escape, quoteattr

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PKG_DIR = 'Stagehand'
PKG_FILE = 'Stagehand.lua'
INDEX_NAME = 'Stagehand'
REPO = 'https://github.com/b451c/Stagehand'


def parse_header(path):
    h = {'provides': [], 'links': [], 'about': [], 'changelog': []}
    block = None
    for ln in open(path, encoding='utf-8'):
        if not ln.startswith('--'):
            break
        body = ln[2:].rstrip('\n')
        m = re.match(r'\s*@(\w+)(?:\s+(.*))?$', body)
        if m and m.group(1) in ('description', 'version', 'author', 'provides', 'link', 'about', 'changelog'):
            key, val = m.group(1), (m.group(2) or '').strip()
            if key in ('provides', 'about', 'changelog'):
                block = key
                if val:
                    h[block].append(val)
            elif key == 'link':
                block = None
                lm = re.match(r'(.*?)\s+(https?://\S+)$', val) or re.match(r'()(https?://\S+)$', val)
                if lm:
                    h['links'].append((lm.group(1).strip() or lm.group(2), lm.group(2)))
            else:
                block = None
                h[key] = val
            continue
        if block:
            text = body[3:] if body.startswith('   ') else body.strip()
            if block == 'provides':
                if text.strip():
                    h['provides'].append(text.strip())
            else:
                h[block].append(text.rstrip())
    return h


def expand_provides(provides, pkg_dir):
    """[(relative path, is_main)] in header order, globs expanded and sorted"""
    out, seen = [], set()
    for entry in provides:
        main = entry.startswith('[main]')
        pattern = entry[6:].strip() if main else entry
        if any(c in pattern for c in '*?['):
            matches = sorted(glob.glob(os.path.join(pkg_dir, pattern), recursive=True))
            files = [os.path.relpath(m, pkg_dir).replace(os.sep, '/') for m in matches if os.path.isfile(m)]
        else:
            files = [pattern]
        for f in files:
            if f not in seen:
                seen.add(f)
                out.append((f, main))
    return out


def to_rtf(lines):
    """the @about block (a little Markdown) as the RTF ReaPack shows in its about dialog"""
    def esc(s):
        s = s.replace('\\', '\\\\').replace('{', '\\{').replace('}', '\\}')
        return ''.join(c if ord(c) < 128 else '\\u%d?' % ord(c) for c in s)
    paras, cur = [], []
    for ln in lines + ['']:
        if ln.strip() == '':
            if cur:
                paras.append(' '.join(cur))
                cur = []
        else:
            cur.append(ln.strip())
    out = ['{\\rtf1\\ansi\\deff0{\\fonttbl{\\f0 \\fswiss Helvetica;}}\\widowctrl\\hyphauto']
    for p in paras:
        if p.startswith('# '):
            out.append('{\\pard \\ql \\f0 \\sa180 \\li0 \\fi0 \\b \\fs36 %s\\par}' % esc(p[2:]))
        elif p.startswith('## '):
            out.append('{\\pard \\ql \\f0 \\sa180 \\li0 \\fi0 \\b \\fs28 %s\\par}' % esc(p[3:]))
        else:
            out.append('{\\pard \\ql \\f0 \\sa180 \\li0 \\fi0 %s\\par}' % esc(p))
    out.append('}')
    return '\n'.join(out)


def build(h, files, url_base, when, commit):
    def url(rel):
        return '%s/%s/%s' % (url_base.rstrip('/'), PKG_DIR, urllib.parse.quote(rel))
    x = ['<?xml version="1.0" encoding="utf-8"?>']
    x.append('<index version="1" name=%s%s>' % (quoteattr(INDEX_NAME), (' commit=%s' % quoteattr(commit)) if commit else ''))
    x.append('  <category name=%s>' % quoteattr(PKG_DIR))
    x.append('    <reapack name=%s type="script" desc=%s>' % (quoteattr(PKG_FILE), quoteattr(h.get('description', ''))))
    x.append('      <metadata>')
    x.append('        <description><![CDATA[%s]]></description>' % to_rtf(h['about']))
    for label, href in h['links']:
        x.append('        <link rel="website" href=%s>%s</link>' % (quoteattr(href), escape(label)))
    x.append('      </metadata>')
    x.append('      <version name=%s author=%s time=%s>' % (quoteattr(h['version']), quoteattr(h.get('author', '')), quoteattr(when)))
    if h['changelog']:
        x.append('        <changelog><![CDATA[%s]]></changelog>' % '\n'.join(h['changelog']).strip())
    for rel, main in files:
        attrs = ' main="main"' if main else ''
        if rel != PKG_FILE:
            attrs += ' file=%s' % quoteattr(rel)
        x.append('        <source%s>%s</source>' % (attrs, escape(url(rel))))
    x.append('      </version>')
    x.append('    </reapack>')
    x.append('  </category>')
    x.append('  <metadata>')
    x.append('    <description><![CDATA[%s]]></description>' % to_rtf(h['about']))
    for label, href in h['links']:
        x.append('    <link rel="website" href=%s>%s</link>' % (quoteattr(href), escape(label)))
    x.append('  </metadata>')
    x.append('</index>')
    return '\n'.join(x) + '\n'


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--out', default=os.path.join(ROOT, 'index.xml'))
    ap.add_argument('--url-base', default=None, help='default: %s/raw/main (or /raw/<commit> with --commit)' % REPO)
    ap.add_argument('--commit', default=None)
    ap.add_argument('--time', default=None, help='ISO 8601 UTC time of the version (default: now)')
    ap.add_argument('--check', action='store_true')
    a = ap.parse_args()
    pkg_dir = os.path.join(ROOT, PKG_DIR)
    h = parse_header(os.path.join(pkg_dir, PKG_FILE))
    missing_keys = [k for k in ('description', 'version', 'author') if not h.get(k)]
    if missing_keys or not h['provides']:
        print('header incomplete: missing %s' % (missing_keys or ['provides']))
        return 1
    files = expand_provides(h['provides'], pkg_dir)
    if files[0][0] != PKG_FILE:
        files = [(PKG_FILE, True)] + [f for f in files if f[0] != PKG_FILE]
    absent = [f for f, _ in files if not os.path.isfile(os.path.join(pkg_dir, f))]
    mains = sum(1 for _, m in files if m)
    print('%s %s by %s: %d files (%d actions), %d links, about %d lines, changelog %d lines' % (
        h['description'].split(' - ')[0], h['version'], h['author'], len(files), mains, len(h['links']), len(h['about']), len(h['changelog'])))
    if absent:
        print('MISSING: ' + ', '.join(absent))
        return 1
    # every file under the package folder should be provided (a forgotten module breaks a fresh install)
    on_disk = set()
    for dp, dn, fn in os.walk(pkg_dir):
        dn[:] = [d for d in dn if d != '__pycache__']
        for f in fn:
            if f != '.DS_Store' and not f.endswith('.pyc'):
                on_disk.add(os.path.relpath(os.path.join(dp, f), pkg_dir).replace(os.sep, '/'))
    extra = sorted(on_disk - set(f for f, _ in files))
    if extra:
        print('NOT PROVIDED (in the folder, not in @provides): ' + ', '.join(extra))
        return 1
    if a.check:
        print('index check ok')
        return 0
    base = a.url_base or ('%s/raw/%s' % (REPO, a.commit or 'main'))
    when = a.time or datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    xml = build(h, files, base, when, a.commit)
    with open(a.out, 'w', encoding='utf-8') as f:
        f.write(xml)
    print('%s written (%d KB, sources at %s)' % (os.path.relpath(a.out, ROOT), len(xml.encode('utf-8')) // 1024, base))
    return 0


if __name__ == '__main__':
    sys.exit(main())
