#!/usr/bin/env python3
"""overview_stitch.py <folder> [--out NAME] [--window] [--no-half] [--dpi auto|logical|native]

Stitches the pages of a Stagehand overview capture into one tall picture. The folder holds:
  geometry.txt   written by Stagehand (guided mode) or by overview_capture.py: crop x y w h (screen px, logical, y
                 down: TCP + ruler + arrange), ruler_h, content_h, tcp_w, arrange l t r b, main l t r b, client_h,
                 half_copy 0|1, dpi_mode
  pages.txt      one line per page: "<i> <scroll pos> <page px> <max>"
  page_NN.png    the captures. Region captures (overview_capture.py) are exactly the crop; window captures (the
                 guided mode with any screenshot tool) are the whole REAPER main window - detected from the PNG
                 width, or forced with --window. HiDPI: scale = PNG width / logical width; every offset scales.
Output: Session_Overview.png (+ Session_Overview_half.png). Pillow when installed, else the pure-Python path of
pngio.py (8-bit PNGs, integer scales).
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pngio  # noqa: E402


def read_geometry(folder):
    g = {}
    with open(os.path.join(folder, 'geometry.txt'), encoding='utf-8') as f:
        for ln in f:
            ln = ln.strip()
            if not ln or ln.startswith('#'):
                continue
            key, *vals = ln.split()
            if key in ('crop', 'arrange', 'main'):
                g[key] = [int(v) for v in vals[:4]]
            elif key in ('ruler_h', 'content_h', 'tcp_w', 'client_h', 'half_copy'):
                g[key] = int(vals[0])
            else:
                g[key] = vals[0] if vals else ''
    for k in ('crop', 'ruler_h', 'content_h'):
        if k not in g:
            sys.exit('geometry.txt lacks %s' % k)
    return g


def read_pages(folder):
    rows = []
    with open(os.path.join(folder, 'pages.txt'), encoding='utf-8') as f:
        for ln in f:
            p = ln.split()
            if len(p) >= 4:
                rows.append(tuple(int(v) for v in p[:4]))
    if not rows:
        sys.exit('pages.txt is empty')
    return rows


def page_path(folder, i):
    for name in ('page_%02d.png' % i, 'page_%d.png' % i, 'page_%03d.png' % i):
        p = os.path.join(folder, name)
        if os.path.exists(p):
            return p
    sys.exit('page %d is missing in %s (expected page_%02d.png)' % (i, folder, i))


def stitch(folder, out_name='Session_Overview.png', window=None, half=None, dpi=None, log=print):
    g = read_geometry(folder)
    rows = read_pages(folder)
    cx, cy, cw, ch = g['crop']
    ruler_h, content_h = g['ruler_h'], g['content_h']
    tcp_w = g.get('tcp_w', 0)
    main = g.get('main')
    first = pngio.load(page_path(folder, rows[0][0]))
    pw, ph = pngio.size(first)
    # region or window capture? the PNG width tells: crop width * scale, or main window width * scale
    if window is None:
        if main and abs(pw / (main[2] - main[0]) - round(pw / (main[2] - main[0]))) < 0.02 and pw / (main[2] - main[0]) >= 0.99 and abs(pw / cw - round(pw / cw)) > 0.02:
            window = True
        elif abs(pw / cw - round(pw / cw)) < 0.02:
            window = False
        elif main:
            window = abs(pw / (main[2] - main[0]) - round(pw / (main[2] - main[0]))) < abs(pw / cw - round(pw / cw))
        else:
            window = False
    if window:
        if not main:
            sys.exit('window captures need the main rect in geometry.txt')
        mw, mh = main[2] - main[0], main[3] - main[1]
        scale = pw / mw
        strip = ph - mh * scale                     # a title bar above the client area (macOS screenshots of a window)
        ox, oy = (cx - main[0]) * scale, (cy - main[1]) * scale + max(0.0, strip)
        log('window captures: %dx%d px, main %dx%d logical, scale %.3f, title strip %.0f px' % (pw, ph, mw, mh, scale, strip))
    else:
        scale = pw / cw
        ox, oy = 0.0, 0.0
        log('region captures: %dx%d px for a %dx%d logical crop, scale %.3f' % (pw, ph, cw, ch, scale))
    r = lambda v: int(round(v))  # noqa: E731

    def cropped(im):
        return pngio.crop(im, r(ox), r(oy), r(ox + cw * scale), r(oy + ch * scale))

    first = cropped(first)
    fw, fh = pngio.size(first)
    mx = max(row[3] for row in rows)
    canvas_h = min(r((ruler_h + mx) * scale), r((ruler_h + rows[-1][1]) * scale) + fh)
    if content_h > 0:
        canvas_h = min(canvas_h, r((ruler_h + content_h) * scale))
    canvas_h = max(canvas_h, fh)
    bg = pngio.pixel(first, min(fw - 1, r((tcp_w + 4) * scale)), min(fh - 1, r((ruler_h + 2) * scale)))
    out = pngio.new(fw, canvas_h, bg)
    for i, pos, page, _ in rows:
        im = cropped(pngio.load(page_path(folder, i)))
        band = 0 if i == rows[0][0] else r(ruler_h * scale)
        src = pngio.crop(im, 0, band, fw, pngio.size(im)[1])
        y = r((ruler_h + pos) * scale) if i != rows[0][0] else 0
        pngio.paste(out, src, 0, y)
    if tcp_w > 0 and ruler_h > 0:   # the toolbar corner above the track panel: paint it flat
        corner = pngio.pixel(first, min(fw - 1, r(4 * scale)), min(fh - 1, r((ruler_h + 4) * scale)))
        pngio.fill(out, 0, 0, r(tcp_w * scale), r(ruler_h * scale), corner)
    dpi = dpi or g.get('dpi_mode', 'auto')
    if dpi == 'logical' and scale > 1.01:
        out = pngio.resize(out, r(fw / scale), r(canvas_h / scale))
        log('scaled to logical pixels (%.2fx down)' % scale)
    out_path = os.path.join(folder, out_name)
    pngio.save(out, out_path)
    ow, oh = pngio.size(out)
    log('stitched %d pages -> %s (%dx%d)' % (len(rows), out_path, ow, oh))
    if half is None:
        half = g.get('half_copy', 1) == 1
    half_path = None
    if half:
        h2 = pngio.resize(out, ow // 2, oh // 2)
        half_path = os.path.join(folder, os.path.splitext(out_name)[0] + '_half.png')
        pngio.save(h2, half_path)
        log('half-size copy -> %s (%dx%d)' % (half_path, ow // 2, oh // 2))
    return out_path, half_path, (ow, oh)


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('folder')
    ap.add_argument('--out', default='Session_Overview.png')
    ap.add_argument('--window', action='store_true', help='the pages are captures of the whole REAPER window (guided mode)')
    ap.add_argument('--no-half', action='store_true')
    ap.add_argument('--dpi', choices=['auto', 'logical', 'native'], default=None)
    a = ap.parse_args()
    stitch(a.folder, a.out, window=True if a.window else None, half=False if a.no_half else None, dpi=a.dpi)


if __name__ == '__main__':
    main()
