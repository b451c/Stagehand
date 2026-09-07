#!/usr/bin/env python3
"""record_showcase.py --ctl <folder> | --project <file.RPP> [--mix mix.wav] [--out DIR] [--backend auto|screencapture|ffmpeg|frames]
                      [--lead 2.5] [--len N] [--display N] [--fps 30] [--dry N] [--no-post] [--no-encode] [--keep-run]

Records a Stagehand showcase from outside REAPER. Stagehand must be running with the project open, the shot list
ready (Director tab) and the Recorder checklist green. The driver talks through the ctl folder (the Recorder tab
shows the exact command):
  ping -> PONG; the loudness curve of the mix is written for the HUD (ffmpeg); arm -> ARMED (cursor 0, Director
  run, HUD bar, layout at start when enabled, the hud file with the bar rect); the screen capture starts; after
  --lead seconds play -> PLAY_REQUEST, FLASH_START ... FLASH_END, END; the capture stops; quit (unless --keep-run:
  the Director run and the screen layout are restored); showcase_post.py lays the mix under the picture using the
  flashes and writes report.json / report.md.
Backends: macOS screencapture -v (video only, fixed length, needs Screen Recording permission for the terminal),
ffmpeg x11grab (Linux) / gdigrab (Windows), or "frames": a Python loop grabbing the monitor with Pillow into
JPEG frames + frames.txt (no ffmpeg needed; good for the flash analysis and a sync check, not for a delivery).
Exit codes: 0 ok, 2 arguments, 3 Stagehand does not answer, 4 no ARMED / no flashes, 5 capture failed.
"""
import argparse
import os
import platform
import shutil
import subprocess
import sys
import threading
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from stagehand_ctl import Ctl, CtlError  # noqa: E402

OS = platform.system()


def log_to(path):
    def log(s):
        line = time.strftime('%H:%M:%S ') + s
        print(line, flush=True)
        with open(path, 'a', encoding='utf-8') as f:
            f.write(line + '\n')
    return log


# --- capture backends -------------------------------------------------------------------------------------------------

class Capture:
    """start(mon, length) / stop() / path"""

    def __init__(self, kind, out, fps, log, display=None):
        self.kind, self.out, self.fps, self.log, self.display = kind, out, fps, log, display
        self.proc = None
        self.path = None
        self.thread = None
        self.stop_flag = False
        self.frames = []

    def start(self, mon, length):
        l, t, r, b = mon
        w, h = r - l, b - t
        if self.kind == 'screencapture':
            self.path = os.path.join(self.out, 'screen_raw.mov')
            d = self.display or find_display(mon, self.out, self.log)
            self.proc = subprocess.Popen(['screencapture', '-v', '-x', '-V', str(int(length)), '-D', str(d), self.path])
            self.log('screencapture -v on display %d for %d s (pid %d)' % (d, int(length), self.proc.pid))
        elif self.kind == 'ffmpeg':
            self.path = os.path.join(self.out, 'screen_raw.mkv')
            if OS == 'Windows':
                cmd = ['ffmpeg', '-y', '-hide_banner', '-loglevel', 'error', '-f', 'gdigrab', '-framerate', str(self.fps), '-offset_x', str(l), '-offset_y', str(t),
                       '-video_size', '%dx%d' % (w, h), '-i', 'desktop']
            elif OS == 'Darwin':
                cmd = ['ffmpeg', '-y', '-hide_banner', '-loglevel', 'error', '-f', 'avfoundation', '-framerate', str(self.fps), '-capture_cursor', '1', '-i', '%s:none' % (self.display or 1)]
            else:
                disp = os.environ.get('DISPLAY', ':0')
                cmd = ['ffmpeg', '-y', '-hide_banner', '-loglevel', 'error', '-f', 'x11grab', '-framerate', str(self.fps), '-video_size', '%dx%d' % (w, h),
                       '-i', '%s+%d,%d' % (disp, l, t)]
            cmd += ['-t', str(int(length)), '-c:v', 'libx264', '-preset', 'ultrafast', '-qp', '18', '-pix_fmt', 'yuv420p', self.path]
            self.proc = subprocess.Popen(cmd, stdin=subprocess.PIPE)
            self.log('ffmpeg capture %dx%d at %d fps for %d s (pid %d)' % (w, h, self.fps, int(length), self.proc.pid))
        elif self.kind == 'frames':
            self.path = os.path.join(self.out, 'frames')
            os.makedirs(self.path, exist_ok=True)
            self.thread = threading.Thread(target=self._frames_loop, args=(l, t, w, h, length), daemon=True)
            self.thread.start()
            self.log('frames capture %dx%d (Pillow) for up to %d s' % (w, h, int(length)))
        else:
            raise RuntimeError('unknown backend ' + self.kind)

    def _frames_loop(self, l, t, w, h, length):
        from PIL import ImageGrab
        kw = {}
        if OS == 'Linux' and os.environ.get('DISPLAY'):
            kw['xdisplay'] = os.environ['DISPLAY']
        t0 = time.time()
        i = 0
        lines = []
        period = 1.0 / self.fps
        try:
            while not self.stop_flag and time.time() - t0 < length:
                tick = time.time()
                im = ImageGrab.grab(bbox=(l, t, l + w, t + h), **kw)
                if im.mode != 'RGB':
                    im = im.convert('RGB')   # macOS grabs RGBA, which JPEG cannot hold
                name = 'f%05d.jpg' % i
                im.save(os.path.join(self.path, name), quality=85)
                lines.append('%d %.4f %s' % (i, tick - t0, name))
                i += 1
                rest = period - (time.time() - tick)
                if rest > 0:
                    time.sleep(rest)
        except Exception as e:  # noqa: BLE001 - the loop must still write frames.txt so the post can say what happened
            self.log('frames loop stopped: %s: %s' % (type(e).__name__, e))
        with open(os.path.join(self.path, 'frames.txt'), 'w', encoding='utf-8') as f:
            f.write('\n'.join(lines) + '\n')
        self.frames = lines

    def stop(self, wait=60):
        if self.kind == 'frames':
            self.stop_flag = True
            if self.thread:
                self.thread.join(wait)
            self.log('frames captured: %d' % len(self.frames))
        elif self.kind == 'ffmpeg' and self.proc:
            try:
                self.proc.stdin.write(b'q')
                self.proc.stdin.flush()
            except Exception:  # noqa: BLE001
                pass
            try:
                self.proc.wait(wait)
            except subprocess.TimeoutExpired:
                self.proc.terminate()
        elif self.kind == 'screencapture' and self.proc:
            # screencapture -v ignores SIGINT from a script: it ends on its own at the fixed length
            for _ in range(int(wait * 5)):
                if self.proc.poll() is not None:
                    break
                time.sleep(0.2)
            if self.proc.poll() is None:
                self.log('screencapture still running after the fixed length: terminating')
                self.proc.terminate()
                time.sleep(3)


def find_display(mon, out, log):
    """Which screencapture -D index records the monitor: a 1 s probe per display, the frame size must be a whole
    multiple of the monitor's logical size (Retina scale)."""
    mw, mh = mon[2] - mon[0], mon[3] - mon[1]
    for d in (1, 2, 3):
        probe = os.path.join(out, 'probe_%d.mov' % d)
        subprocess.run(['screencapture', '-v', '-x', '-V', '1', '-D', str(d), probe], capture_output=True)
        if os.path.exists(probe):
            try:
                wh = subprocess.run(['ffprobe', '-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream=width,height', '-of', 'csv=p=0', probe],
                                    capture_output=True, text=True).stdout.strip()
                w, h = (int(v) for v in wh.split(',')[:2])
                log('display %d -> %dx%d' % (d, w, h))
                if w % mw == 0 and (w // mw) >= 1 and h // mh == w // mw:
                    os.remove(probe)
                    return d
            except Exception:  # noqa: BLE001
                pass
            os.remove(probe)
    raise RuntimeError('no display of %dx%d logical among screencapture outputs: give --display N' % (mw, mh))


def pick_backend(name, log):
    if name != 'auto':
        return name
    if OS == 'Darwin' and shutil.which('screencapture'):
        return 'screencapture'
    if shutil.which('ffmpeg'):
        return 'ffmpeg'
    try:
        from PIL import ImageGrab  # noqa: F401
        log('ffmpeg not found: using the frames backend (Pillow); install ffmpeg for a real recording')
        return 'frames'
    except ImportError:
        sys.exit('no capture backend: install ffmpeg (or Pillow for the frames backend)')


# --- the run ----------------------------------------------------------------------------------------------------------

def run(a):
    ctl = Ctl(a.ctl) if a.ctl else Ctl.from_project(a.project)
    out = a.out or os.path.join(os.path.dirname(ctl.dir), 'showcase_' + time.strftime('%Y%m%d_%H%M%S'))
    os.makedirs(out, exist_ok=True)
    log = log_to(os.path.join(out, 'record_log.txt'))
    ctl.log = log
    log('ctl %s -> out %s' % (ctl.dir, out))
    try:
        ctl.ping(timeout=a.timeout)
    except CtlError as e:
        log(str(e))
        return 3
    backend = pick_backend(a.backend, log)
    if a.mix and shutil.which('ffmpeg'):
        import make_lufs_curve
        make_lufs_curve.make_curve(a.mix, os.path.join(ctl.dir, 'lufs_curve.txt'))
    elif a.mix:
        log('ffmpeg not found: no loudness curve for the HUD (live meter stays)')
    ctl.clear_state()
    try:
        armed = ctl.ask('arm', 'ARMED', timeout=a.timeout + 20)
    except CtlError as e:
        log(str(e))
        return 4
    _, _, kv, _ = Ctl.parse(armed)
    end_s = float(kv.get('end_s', 0) or 0)
    hud = ctl.read_hud()
    if 'monitor' not in hud:
        log('no hud file after ARMED (is the HUD bar shown and js_ReaScriptAPI installed?)')
        return 4
    mon = hud['monitor']
    log('armed: shots end at %.1f s; hud %s; monitor %s' % (end_s, hud.get('hud'), mon))
    length = a.len if a.len else (a.lead + end_s + 8.0)
    if a.dry:
        cap = Capture(backend, out, a.fps, log, a.display)
        cap.start(mon, a.dry)
        time.sleep(a.dry + 0.5)
        cap.stop()
        log('dry run done: %s' % cap.path)
        if not a.keep_run:
            ctl.ask('quit', 'QUIT', timeout=a.timeout)
        return 0
    cap = Capture(backend, out, a.fps, log, a.display)
    try:
        cap.start(mon, length)
    except Exception as e:  # noqa: BLE001
        log('capture failed to start: %s' % e)
        return 5
    time.sleep(a.lead)
    rc = 0
    try:
        ctl.ask('play', 'FLASH_START', timeout=15)
        log('playing')
        if ctl.wait('END', timeout=end_s + 30) is None:
            log('no END after %.0f s (stopping by hand)' % (end_s + 30))
            ctl.send('stop')
            rc = 4
        else:
            log('END')
        time.sleep(1.0)
    finally:
        cap.stop(wait=max(30, length))
    shutil.copy(ctl.state_path, os.path.join(out, 'state.txt'))
    shutil.copy(ctl.hud_path, os.path.join(out, 'hud.txt'))
    if not a.keep_run:
        try:
            ctl.ask('quit', 'QUIT', timeout=a.timeout)
        except CtlError as e:
            log(str(e))
    if rc == 0 and not a.no_post:
        import showcase_post
        argv = [cap.path, '--state', os.path.join(out, 'state.txt'), '--hud', os.path.join(out, 'hud.txt'), '--out', out, '--crop-top', a.crop_top, '--anchor', a.anchor]
        if a.mix:
            argv += ['--mix', a.mix]
        if a.no_encode or backend == 'frames':
            argv.append('--no-encode')
        argv += a.post_args
        try:
            showcase_post.main(argv)
        except SystemExit as e:
            if e.code not in (0, None):
                log('post failed: %s' % e)
                rc = 4
        if backend == 'frames' and not a.keep_frames:
            shutil.rmtree(cap.path, ignore_errors=True)
            log('frames removed (--keep-frames keeps them)')
    log('done: %s' % out)
    return rc


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--ctl')
    ap.add_argument('--project')
    ap.add_argument('--out')
    ap.add_argument('--mix', help='the delivered mix (wav): loudness curve for the HUD and the audio of the output')
    ap.add_argument('--backend', default='auto', choices=['auto', 'screencapture', 'ffmpeg', 'frames'])
    ap.add_argument('--lead', type=float, default=2.5, help='seconds of recording before the flash')
    ap.add_argument('--len', type=float, default=None, help='fixed capture length in s (default: lead + shots end + 8)')
    ap.add_argument('--display', type=int, default=None, help='screencapture -D index (macOS; default: probe)')
    ap.add_argument('--fps', type=int, default=30)
    ap.add_argument('--dry', type=float, default=None, help='record N seconds without playback (permission / display check)')
    ap.add_argument('--timeout', type=float, default=20.0)
    ap.add_argument('--anchor', choices=['end', 'moving', 'start'], default='end')
    ap.add_argument('--crop-top', default='auto2')
    ap.add_argument('--no-post', action='store_true')
    ap.add_argument('--no-encode', action='store_true')
    ap.add_argument('--keep-run', action='store_true', help='do not send quit: the Director run and the layout stay')
    ap.add_argument('--keep-frames', action='store_true')
    ap.add_argument('post_args', nargs='*', help='extra arguments for showcase_post.py after --')
    a = ap.parse_args()
    if not a.ctl and not a.project:
        ap.error('give --ctl <folder> or --project <file.RPP>')
    sys.exit(run(a))


if __name__ == '__main__':
    main()
