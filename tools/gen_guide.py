#!/usr/bin/env python3
"""gen_guide.py [--src docs/user-guide.md] [--out docs/guide.html] [--version X] [--check]

Builds the GitHub Pages guide (one self-contained HTML page: dark theme in Stagehand's design tokens, IBM Plex from
Google Fonts, a sidebar generated from the chapters) from the Markdown user guide. The Markdown stays the source:
`## Chapter` becomes a sidebar group, `### Section` a link, `![caption](images/x.png)` a figure, fenced code, tables,
lists and inline code / bold / links are converted; nothing else is interpreted. --check exits 1 when guide.html is
older than the source (the harness gate). The version comes from Stagehand/Stagehand.lua (@version) unless given.
"""
import argparse
import html
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO = 'https://github.com/b451c/Stagehand'
INDEX = 'https://raw.githubusercontent.com/b451c/Stagehand/main/index.xml'

CSS = r"""
*,*::before,*::after{box-sizing:border-box;margin:0;padding:0}
:root{--bg:#171A21;--panel:#20242E;--panel2:#2A2F3B;--line:#39404F;--hover:#323949;--sel:#3A4256;
  --text:#E9EDF3;--muted:#8D95A7;--dim:#4A5163;--accent:#3AD1FF;--accent2:#FFB347;--ok:#6FE39A;--warn:#F5E663;--danger:#FF5A5A;
  --accent-glow:rgba(58,209,255,.10);--font:'IBM Plex Sans',system-ui,-apple-system,sans-serif;--mono:'IBM Plex Mono',Menlo,Consolas,monospace;
  --radius:6px;--sidebar-w:270px}
html{scroll-behavior:smooth;font-size:15px}
body{font-family:var(--font);background:var(--bg);color:var(--text);line-height:1.7;-webkit-font-smoothing:antialiased}
::selection{background:#1b6f8c;color:#fff}
a{color:var(--accent);text-decoration:none}a:hover{text-decoration:underline}
.layout{display:flex;min-height:100vh}
.sidebar{position:fixed;top:0;left:0;width:var(--sidebar-w);height:100vh;background:var(--panel);border-right:1px solid var(--line);overflow-y:auto;z-index:100;padding:22px 0 40px;scrollbar-width:thin;scrollbar-color:var(--line) transparent}
.sidebar-header{padding:0 20px 16px;border-bottom:1px solid var(--line);margin-bottom:12px}
.sidebar-logo{font-size:1.15rem;font-weight:700;color:#fff;letter-spacing:-.02em}.sidebar-logo span{color:var(--accent)}
.sidebar-version{font-size:.72rem;color:var(--muted);margin-top:2px;font-family:var(--mono)}
.sidebar-links{padding:0 20px 12px;font-size:.78rem;color:var(--muted)}.sidebar-links a{color:var(--muted)}.sidebar-links a:hover{color:var(--accent)}
.nav-group{margin-bottom:6px}
.nav-group-title{display:block;font-size:.72rem;font-weight:600;text-transform:uppercase;letter-spacing:.08em;color:var(--muted);padding:8px 20px 3px}
.nav-group-title:hover{color:var(--text);text-decoration:none}
.nav-link{display:block;padding:4px 20px 4px 30px;font-size:.82rem;color:var(--muted);border-left:2px solid transparent}
.nav-link:hover{color:var(--text);background:var(--hover);text-decoration:none}
.nav-link.active,.nav-group-title.active{color:var(--accent);border-left-color:var(--accent);background:var(--accent-glow)}
.content{margin-left:var(--sidebar-w);flex:1;max-width:860px;padding:44px 56px 120px}
h1{font-size:2.1rem;font-weight:700;letter-spacing:-.03em;margin-bottom:6px;color:#fff}h1 span{color:var(--accent)}
.subtitle{font-size:1rem;color:var(--muted);margin-bottom:28px;font-weight:300}
h2{font-size:1.4rem;font-weight:600;letter-spacing:-.02em;margin:56px 0 14px;padding-bottom:10px;border-bottom:1px solid var(--line);color:#fff;scroll-margin-top:24px}
h3{font-size:1.05rem;font-weight:600;margin:30px 0 10px;color:var(--text);scroll-margin-top:24px}
h2:first-of-type{margin-top:28px}
p{margin:0 0 14px;color:var(--text)}
ul,ol{margin:6px 0 16px;padding-left:24px}li{margin-bottom:5px}li::marker{color:var(--dim)}li>ul,li>ol{margin:4px 0 4px}
code{font-family:var(--mono);font-size:.84em;background:var(--panel2);padding:2px 6px;border-radius:3px;color:#cfe9ff}
pre{background:var(--panel);border:1px solid var(--line);border-radius:var(--radius);padding:14px 16px;margin:12px 0 20px;overflow-x:auto;font-size:.82rem;line-height:1.55}
pre code{background:none;padding:0;color:var(--text);font-size:inherit}
table{width:100%;border-collapse:collapse;margin:14px 0 24px;font-size:.86rem}
thead th{text-align:left;font-weight:600;font-size:.72rem;text-transform:uppercase;letter-spacing:.06em;color:var(--muted);padding:8px 12px;border-bottom:2px solid var(--line)}
tbody td{padding:7px 12px;border-bottom:1px solid var(--line);vertical-align:top}tbody tr:hover{background:var(--hover)}
td:first-child{white-space:nowrap;color:#fff}
.table-wrap{overflow-x:auto}
figure{margin:18px 0 26px}figure img{max-width:100%;border-radius:var(--radius);border:1px solid var(--line);display:block}
figure.narrow img{max-width:min(100%,460px)}figure.mid img{max-width:min(100%,720px)}
figcaption{font-size:.8rem;color:var(--muted);margin-top:8px}
.figrow{display:flex;gap:16px;flex-wrap:wrap;margin:18px 0 26px}.figrow figure{margin:0;flex:1 1 300px}.figrow figure img{max-width:100%}
.hero{background:var(--panel);border:1px solid var(--line);border-radius:var(--radius);padding:18px 22px;margin:0 0 26px;font-size:.92rem;color:var(--text)}
.hero b{color:#fff}
.chips{display:flex;gap:8px;flex-wrap:wrap;margin:0 0 26px}.chip{font-size:.72rem;font-weight:600;padding:3px 10px;border-radius:12px;background:var(--accent-glow);color:var(--accent);border:1px solid rgba(58,209,255,.25);text-transform:uppercase;letter-spacing:.03em}
.note{padding:12px 16px;border-radius:var(--radius);margin:14px 0 22px;font-size:.88rem;background:rgba(255,179,71,.07);border-left:3px solid var(--accent2)}
hr{border:none;border-top:1px solid var(--line);margin:40px 0}
.footer{text-align:center;color:var(--dim);font-size:.8rem;margin-top:60px;padding-top:28px;border-top:1px solid var(--line)}.footer a{color:var(--muted)}
.scroll-top{position:fixed;bottom:22px;right:22px;width:38px;height:38px;background:var(--panel);border:1px solid var(--line);border-radius:50%;display:flex;align-items:center;justify-content:center;color:var(--accent);font-size:1.1rem;cursor:pointer;opacity:0;transition:opacity .3s;z-index:200}
.scroll-top.visible{opacity:1}
@media(max-width:900px){.sidebar{display:none}.content{margin-left:0;padding:24px 18px 80px;max-width:100%}}
"""

JS = r"""
const links=[...document.querySelectorAll('.sidebar a[href^="#"]')];
const targets=links.map(a=>document.getElementById(a.getAttribute('href').slice(1))).filter(Boolean);
function mark(){let cur=null;const y=window.scrollY+90;for(const t of targets){if(t.offsetTop<=y)cur=t;}
 links.forEach(a=>a.classList.toggle('active',cur&&a.getAttribute('href')==='#'+cur.id));
 document.getElementById('top').classList.toggle('visible',window.scrollY>600);}
window.addEventListener('scroll',mark,{passive:true});mark();
document.getElementById('top').addEventListener('click',()=>window.scrollTo({top:0,behavior:'smooth'}));
"""


def slug(s):
    s = re.sub(r'[^a-z0-9]+', '-', s.lower()).strip('-')
    return s or 'section'


def inline(text):
    """HTML-escape, then code spans, bold, italic, links (code spans are protected from the other rules)."""
    parts = re.split(r'(`[^`]+`)', text)
    out = []
    for p in parts:
        if p.startswith('`') and p.endswith('`') and len(p) > 1:
            out.append('<code>%s</code>' % html.escape(p[1:-1]))
            continue
        p = html.escape(p, quote=False)
        p = re.sub(r'\[([^\]]+)\]\((https?://[^)\s]+|[^)\s]+)\)', lambda m: '<a href="%s">%s</a>' % (m.group(2), m.group(1)), p)
        p = re.sub(r'\*\*(.+?)\*\*', r'<strong>\1</strong>', p)
        p = re.sub(r'(?<![\w*])\*(?!\s)(.+?)(?<!\s)\*(?![\w*])', r'<em>\1</em>', p)
        out.append(p)
    return ''.join(out)


def table_html(rows):
    cells = [[c.strip() for c in r.strip().strip('|').split('|')] for r in rows]
    if len(cells) >= 2 and all(re.fullmatch(r':?-{2,}:?', c) for c in cells[1]):
        head, body = cells[0], cells[2:]
    else:
        head, body = None, cells
    h = ['<div class="table-wrap"><table>']
    if head:
        h.append('<thead><tr>%s</tr></thead>' % ''.join('<th>%s</th>' % inline(c) for c in head))
    h.append('<tbody>')
    for r in body:
        h.append('<tr>%s</tr>' % ''.join('<td>%s</td>' % inline(c) for c in r))
    h.append('</tbody></table></div>')
    return '\n'.join(h)


ITEM = re.compile(r'^(\s*)([-*]|\d+[.)])\s+(.*)$')


def list_html(lines):
    """one list from item lines (continuations already joined); nesting by indent (2+ spaces)"""
    items = []
    for ln in lines:
        m = ITEM.match(ln)
        depth = len(m.group(1)) // 2
        items.append((depth, m.group(2), m.group(3)))
    out = []

    def emit(start, depth):
        tag = 'ol' if items[start][1][0].isdigit() else 'ul'
        out.append('<%s>' % tag)
        i = start
        while i < len(items) and items[i][0] >= depth:
            d, _, text = items[i]
            if d == depth:
                out.append('<li>%s' % inline(text))
                i += 1
                if i < len(items) and items[i][0] > depth:
                    i = emit(i, items[i][0])
                out.append('</li>')
            else:
                i += 1
        out.append('</%s>' % tag)
        return i
    emit(0, items[0][0])
    return '\n'.join(out)


def convert(md):
    """-> (title, intro_html, sections) ; sections = [{title, id, html, subs:[(title,id)]}]"""
    lines = md.split('\n')
    title = 'Stagehand user guide'
    sections = []
    cur = None
    buf = []          # html of the current section (or the intro)
    intro = []
    i = 0

    def target():
        return buf if cur is not None else intro
    while i < len(lines):
        ln = lines[i]
        if ln.startswith('# ') and not cur:
            title = ln[2:].strip()
            i += 1
            continue
        if ln.startswith('## '):
            if cur is not None:
                cur['html'] = '\n'.join(buf)
                sections.append(cur)
            t = ln[3:].strip()
            cur = {'title': t, 'id': slug(t), 'subs': []}
            buf = ['<h2 id="%s">%s</h2>' % (cur['id'], inline(t))]
            i += 1
            continue
        if ln.startswith('### '):
            t = ln[4:].strip()
            sid = (cur['id'] + '-' if cur else '') + slug(t)
            if cur:
                cur['subs'].append((t, sid))
            target().append('<h3 id="%s">%s</h3>' % (sid, inline(t)))
            i += 1
            continue
        if ln.startswith('```'):
            code = []
            i += 1
            while i < len(lines) and not lines[i].startswith('```'):
                code.append(lines[i])
                i += 1
            i += 1
            target().append('<pre><code>%s</code></pre>' % html.escape('\n'.join(code)))
            continue
        if ln.lstrip().startswith('|'):
            rows = []
            while i < len(lines) and lines[i].lstrip().startswith('|'):
                rows.append(lines[i])
                i += 1
            target().append(table_html(rows))
            continue
        m = re.match(r'^!\[([^\]]*)\]\(([^)\s]+)\)(?:\{([^}]*)\})?\s*$', ln)
        if m:
            cls = m.group(3) or ''
            target().append('<figure class="%s"><img src="%s" alt="%s" loading="lazy"><figcaption>%s</figcaption></figure>' % (
                html.escape(cls), m.group(2), html.escape(m.group(1)), inline(m.group(1))))
            i += 1
            continue
        if ITEM.match(ln):
            items = []
            while i < len(lines):
                l2 = lines[i]
                if ITEM.match(l2):
                    items.append(l2)
                    i += 1
                elif l2.strip() and l2.startswith(' ') and items:
                    items[-1] += ' ' + l2.strip()
                    i += 1
                elif not l2.strip() and i + 1 < len(lines) and ITEM.match(lines[i + 1]) and lines[i + 1].startswith(' '):
                    i += 1
                else:
                    break
            target().append(list_html(items))
            continue
        if ln.strip() == '':
            i += 1
            continue
        if ln.startswith('> '):
            q = []
            while i < len(lines) and lines[i].startswith('>'):
                q.append(lines[i].lstrip('> '))
                i += 1
            target().append('<div class="note">%s</div>' % inline(' '.join(q)))
            continue
        para = [ln.strip()]
        i += 1
        while i < len(lines) and lines[i].strip() and not re.match(r'^(#{1,3} |```|\s*\||!\[|> )', lines[i]) and not ITEM.match(lines[i]):
            para.append(lines[i].strip())
            i += 1
        target().append('<p>%s</p>' % inline(' '.join(para)))
    if cur is not None:
        cur['html'] = '\n'.join(buf)
        sections.append(cur)
    return title, '\n'.join(intro), sections


def package_version():
    p = os.path.join(ROOT, 'Stagehand', 'Stagehand.lua')
    try:
        for ln in open(p, encoding='utf-8'):
            m = re.match(r'--\s*@version\s+(\S+)', ln)
            if m:
                return m.group(1)
    except OSError:
        pass
    return 'dev'


def build(md, version):
    title, intro, sections = convert(md)
    nav = []
    for s in sections:
        nav.append('<div class="nav-group"><a class="nav-group-title" href="#%s">%s</a>' % (s['id'], html.escape(s['title'])))
        for t, sid in s['subs']:
            nav.append('<a class="nav-link" href="#%s">%s</a>' % (sid, html.escape(t)))
        nav.append('</div>')
    chips = ''.join('<a class="chip" href="#%s">%s</a>' % (s['id'], html.escape(s['title'])) for s in sections)
    body = '\n'.join(s['html'] for s in sections)
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Stagehand for REAPER - User Guide</title>
<meta name="description" content="Stagehand for REAPER 7: session navigator, showcase director with glow and captions, recorder companions, session overview, stems and agent access. The user guide.">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link href="https://fonts.googleapis.com/css2?family=IBM+Plex+Sans:wght@300;400;500;600;700&family=IBM+Plex+Mono:wght@400;500&display=swap" rel="stylesheet">
<style>{CSS}</style>
</head>
<body>
<div class="layout">
<nav class="sidebar" id="sidebar">
  <div class="sidebar-header">
    <div class="sidebar-logo">Stage<span>hand</span></div>
    <div class="sidebar-version">v{html.escape(version)} - user guide</div>
  </div>
  <div class="sidebar-links"><a href="{REPO}">GitHub</a> &middot; <a href="{REPO}/releases">Releases</a> &middot; <a href="{REPO}/blob/main/docs/config-reference.md">Config reference</a></div>
{chr(10).join(nav)}
</nav>
<main class="content">
<h1>Stage<span>hand</span> user guide</h1>
<p class="subtitle">Session navigator, showcase director, glow and captions, recorder companions, session overview, stems and agent access for REAPER 7 - one ReaScript package.</p>
<div class="hero"><b>Install through ReaPack:</b> Extensions &gt; ReaPack &gt; Import repositories, paste <code>{INDEX}</code>, then Browse packages and install <b>Stagehand</b> (ReaImGui is pulled in as a dependency; js_ReaScriptAPI and SWS are optional and unlock the glow, the window layout, the overview geometry and the support links).</div>
<div class="chips">{chips}</div>
{intro}
{body}
<div class="footer">Stagehand is a <a href="https://falami.studio">falami.studio</a> tool by Bartosz Sroczynski &middot; MIT licence &middot; <a href="{REPO}">{REPO.replace('https://', '')}</a><br>
Support the development: <a href="https://ko-fi.com/quickmd">Ko-fi</a> &middot; <a href="https://buymeacoffee.com/bsroczynskh">Buy Me a Coffee</a> &middot; <a href="https://paypal.me/b451c">PayPal</a></div>
</main>
</div>
<div class="scroll-top" id="top" title="Back to top">&uarr;</div>
<script>{JS}</script>
</body>
</html>
"""


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--src', default=os.path.join(ROOT, 'docs', 'user-guide.md'))
    ap.add_argument('--out', default=os.path.join(ROOT, 'docs', 'guide.html'))
    ap.add_argument('--version', default=None)
    ap.add_argument('--check', action='store_true')
    a = ap.parse_args()
    if a.check:
        if not os.path.exists(a.out) or os.path.getmtime(a.out) < os.path.getmtime(a.src):
            print('guide.html is older than %s: run tools/gen_guide.py' % os.path.relpath(a.src, ROOT))
            return 1
        print('guide.html is current')
        return 0
    md = open(a.src, encoding='utf-8').read()
    page = build(md, a.version or package_version())
    with open(a.out, 'w', encoding='utf-8') as f:
        f.write(page)
    n_h2 = page.count('<h2 '), page.count('<h3 '), page.count('<figure')
    print('%s: %d KB, %d chapters, %d sections, %d figures' % (os.path.relpath(a.out, ROOT), len(page.encode('utf-8')) // 1024, n_h2[0], n_h2[1], n_h2[2]))
    return 0


if __name__ == '__main__':
    sys.exit(main())
