#!/usr/bin/env python3
"""overview_capture.py --ctl <folder> | --project <file.RPP> [--out DIR] [--backend auto|screencapture|pil|scrot|import|powershell]
                       [--settle 0.7] [--no-apply] [--no-restore] [--no-stitch]

One tall picture of the whole session, driven from outside REAPER. Stagehand must be running with the project
open (any tab); the Overview tab shows the exact command for the project. The driver talks through the ctl folder:
  ping -> PONG; "overview apply" -> APPLIED (Stagehand lays the session out: mixer / master / video hidden, uniform
  rows, used lanes open, whole picture in view; its own window hides); "overview rect" -> RECT (the crop in screen
  px); "overview scroll <px>" -> SCROLL pos page min max (after the redraw); per page one screen-region capture;
  "overview restore" -> RESTORED. Then overview_stitch.py pastes the pages at their real scroll offsets.
Capture backends (auto = the first that works on this OS): macOS screencapture -R (Retina aware: the PNG comes in
native pixels, the stitcher measures the scale), Pillow ImageGrab, Linux scrot / ImageMagick import, Windows
PowerShell (CopyFromScreen). Nothing but the standard library is required; Pillow makes the stitch faster.
Exit codes: 0 ok, 2 arguments, 3 Stagehand does not answer, 4 capture failed.
"""
import argparse
import os
import platform
import shutil
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from stagehand_ctl import Ctl, CtlError, parse_rect_line, parse_scroll_line  # noqa: E402
import overview_stitch  # noqa: E402

OS = platform.system()


def log_to(path):
    def log(s):
        line = time.strftime('%H:%M:%S ') + s
        print(line, flush=True)
        with open(path, 'a', encoding='utf-8') as f:
            f.write(line + '\n')
    return log


# --- capture backends: grab a screen region (logical px) into a PNG ---------------------------------------------------

def grab_screencapture(x, y, w, h, path):
    subprocess.run(['screencapture', '-x', '-R', '%d,%d,%d,%d' % (x, y, w, h), path], check=True)


def grab_pil(x, y, w, h, path):
    from PIL import ImageGrab
    kw = {}
    if OS == 'Linux' and os.environ.get('DISPLAY'):
        kw['xdisplay'] = os.environ['DISPLAY']
    im = ImageGrab.grab(bbox=(x, y, x + w, y + h), **kw)
    im.save(path)


def grab_scrot(x, y, w, h, path):
    subprocess.run(['scrot', '-a', '%d,%d,%d,%d' % (x, y, w, h), '-o', path], check=True)


def grab_import(x, y, w, h, path):
    subprocess.run(['import', '-window', 'root', '-crop', '%dx%d+%d+%d' % (w, h, x, y), '+repage', path], check=True)


def grab_powershell(x, y, w, h, path):
    ps = ('Add-Type -AssemblyName System.Windows.Forms,System.Drawing; '
          '$b = New-Object System.Drawing.Bitmap %d,%d; $g = [System.Drawing.Graphics]::FromImage($b); '
          '$g.CopyFromScreen((New-Object System.Drawing.Point %d,%d), [System.Drawing.Point]::Empty, (New-Object System.Drawing.Size %d,%d)); '
          '$b.Save("%s", [System.Drawing.Imaging.ImageFormat]::Png); $g.Dispose(); $b.Dispose()') % (w, h, x, y, w, h, path.replace('"', ''))
    subprocess.run(['powershell', '-NoProfile', '-Command', ps], check=True)


BACKENDS = {
    'screencapture': (grab_screencapture, lambda: OS == 'Darwin' and shutil.which('screencapture')),
    'pil': (grab_pil, lambda: _has_pil()),
    'scrot': (grab_scrot, lambda: shutil.which('scrot')),
    'import': (grab_import, lambda: shutil.which('import')),
    'powershell': (grab_powershell, lambda: OS == 'Windows' and shutil.which('powershell')),
}
ORDER = {'Darwin': ['screencapture', 'pil'], 'Windows': ['pil', 'powershell'], 'Linux': ['pil', 'scrot', 'import']}


def _has_pil():
    try:
        from PIL import ImageGrab  # noqa: F401
        return True
    except ImportError:
        return False


def pick_backend(name, log):
    names = [name] if name != 'auto' else ORDER.get(OS, ['pil'])
    for n in names:
        fn, ok = BACKENDS[n]
        if ok():
            # a probe capture proves the backend really works here (permissions, display)
            probe = os.path.join(tempfile.gettempdir(), 'stagehand_probe.png')
            try:
                fn(0, 0, 64, 64, probe)
                if os.path.getsize(probe) > 0:
                    log('capture backend: %s' % n)
                    return n, fn
            except Exception as e:  # noqa: BLE001
                log('backend %s failed the probe: %s' % (n, e))
    sys.exit('no capture backend works here (tried %s); install Pillow (pip install pillow) or scrot / ImageMagick' % ', '.join(names))


# --- the run ----------------------------------------------------------------------------------------------------------

def run(a):
    log = print
    ctl = Ctl(a.ctl) if a.ctl else Ctl.from_project(a.project)
    out = a.out or os.path.join(os.path.dirname(ctl.dir), 'overview_' + time.strftime('%Y%m%d_%H%M%S'))
    os.makedirs(out, exist_ok=True)
    log = log_to(os.path.join(out, 'capture_log.txt'))
    ctl.log = log
    log('ctl %s -> out %s' % (ctl.dir, out))
    try:
        ctl.ping(timeout=a.timeout)
    except CtlError as e:
        log(str(e))
        return 3
    _, grab = pick_backend(a.backend, log)
    if not a.no_apply:
        ctl.ask('overview apply', 'APPLIED', timeout=a.timeout)
        time.sleep(a.settle)
    rect = parse_rect_line(ctl.ask('overview rect', 'RECT', timeout=a.timeout))
    cx, cy, cw, ch = rect['crop']
    log('crop %d,%d %dx%d ruler_h %d content_h %d client_h %d scroll %s' % (cx, cy, cw, ch, rect['ruler_h'], rect['content_h'], rect['client_h'], rect['scroll']))
    if not rect['scroll']:
        log('Stagehand reports no scroll info (js_ReaScriptAPI missing?): capturing one page only')
    with open(os.path.join(out, 'geometry.txt'), 'w', encoding='utf-8') as f:
        f.write('# Stagehand overview geometry (from the RECT reply): screen px, logical, y down\n')
        f.write('crop %d %d %d %d\nruler_h %d\ncontent_h %d\ntcp_w %d\narrange %d %d %d %d\nmain %d %d %d %d\nclient_h %d\nhalf_copy %d\ndpi_mode %s\n' % (
            cx, cy, cw, ch, rect['ruler_h'], rect['content_h'], rect['arrange'][0] - rect['tcp_left'], *rect['arrange'], *rect['main'], rect['client_h'], 0 if a.no_half else 1, a.dpi))
    pages = []
    pos, i = 0, 0
    rc = 0
    try:
        while True:
            if rect['scroll']:
                s = parse_scroll_line(ctl.ask('overview scroll %d' % pos, 'SCROLL', timeout=a.timeout))
                p, page, _, mx = s
            else:
                p, page, mx = 0, ch, 0
            time.sleep(a.settle)
            path = os.path.join(out, 'page_%02d.png' % i)
            try:
                grab(cx, cy, cw, ch, path)
            except Exception as e:  # noqa: BLE001
                log('capture of page %d failed: %s' % (i, e))
                rc = 4
                break
            pages.append((i, p, page, mx))
            log('page %d: scroll %d (page %d, max %d) -> %s' % (i, p, page, mx, os.path.basename(path)))
            if not rect['scroll'] or p + page >= mx:
                break
            nxt = p + max(1, page - a.overlap)
            if nxt <= p or i > 200:
                break
            pos, i = nxt, i + 1
    finally:
        with open(os.path.join(out, 'pages.txt'), 'w', encoding='utf-8') as f:
            for row in pages:
                f.write('%d %d %d %d\n' % row)
        if not a.no_restore:
            try:
                ctl.ask('overview restore', 'RESTORED', timeout=a.timeout)
                log('session layout restored')
            except CtlError as e:
                log(str(e))
    if rc == 0 and pages and not a.no_stitch:
        overview_stitch.stitch(out, half=not a.no_half if a.no_half else None, dpi=a.dpi if a.dpi != 'auto' else None, log=log)
    log('done: %s' % out)
    return rc


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--ctl', help='the ctl folder (Overview tab shows it)')
    ap.add_argument('--project', help='the .RPP (ctl = <its folder>/Render/stagehand_ctl)')
    ap.add_argument('--out', help='output folder (default: next to the ctl folder, overview_<stamp>)')
    ap.add_argument('--backend', default='auto', choices=['auto'] + list(BACKENDS))
    ap.add_argument('--settle', type=float, default=0.7, help='seconds after each scroll before the capture')
    ap.add_argument('--overlap', type=int, default=0, help='page overlap in px')
    ap.add_argument('--timeout', type=float, default=20.0)
    ap.add_argument('--dpi', default='auto', choices=['auto', 'logical', 'native'])
    ap.add_argument('--no-apply', action='store_true', help='the layout is already applied (Overview tab)')
    ap.add_argument('--no-restore', action='store_true')
    ap.add_argument('--no-stitch', action='store_true')
    ap.add_argument('--no-half', action='store_true')
    a = ap.parse_args()
    if not a.ctl and not a.project:
        ap.error('give --ctl <folder> or --project <file.RPP>')
    sys.exit(run(a))


if __name__ == '__main__':
    main()
