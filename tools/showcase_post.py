#!/usr/bin/env python3
"""showcase_post.py <recording> --state state.txt --hud hud.txt --out DIR [--mix mix.wav] [options]

Lays the delivered mix under a screen recording of a Stagehand showcase, using the two HUD flashes as the sync
marks, and writes report.json / report.md with every anchor. <recording> is a video file (any ffmpeg input) or a
folder written by record_showcase.py's "frames" backend (frames.txt + JPEG frames).

state.txt (Stagehand's ctl state file): "<wall t> TOKEN pos=<play position>" lines. Used: FLASH_START (the first
dark frame after the start flash, wall T1), PLAY_POS (first playing frame, wall T3, position p3), PLAY_MOVING
(first frame where the position really advanced), FLASH_END (first white frame of the end flash, position p_end).
hud.txt: "hud l t r b" (the bar's painted rect), "monitor l t r b" (the recorded screen), "work l t r b".
Flash detection: mean brightness of the bar's crop per frame (ffprobe signalstats YAVG for a video; Pillow for a
frame folder); a white run = brightness above the dark median + 100. Anchors for mix time 0 in recording time:
  start   t_dark + (T3 - p3 - T1)      naive: REAPER reports position 0.000 before the engine moves
  moving  t_dark + (T4 - p4 - T1)      the PLAY_MOVING frame: engine start latency included
  end     first white frame of the end flash - end_offset frames - p_end   (default; verified against the picture)
--t0 overrides after a picture check. Encoding (needs ffmpeg and --mix): the video is trimmed in the filter graph,
the mix delayed by the pre-roll, two outputs (native + 1920 wide) with the platform encoders (videotoolbox / aac_at
on macOS, libx264 / aac elsewhere). --no-encode writes the report only.
"""
import argparse
import json
import os
import platform
import shutil
import statistics
import subprocess
import sys

OS = platform.system()


def run(cmd, **kw):
    r = subprocess.run(cmd, capture_output=True, text=True, **kw)
    if r.returncode != 0:
        sys.stderr.write(' '.join(cmd) + '\n' + r.stderr[-2000:] + '\n')
        sys.exit(1)
    return r.stdout


def read_state(path):
    state = {}
    for ln in open(path, encoding='utf-8', errors='replace'):
        p = ln.split()
        if len(p) >= 2:
            pos = None
            for q in p[2:]:
                if q.startswith('pos='):
                    try:
                        pos = float(q[4:])
                    except ValueError:
                        pass
            try:
                state.setdefault(p[1], []).append((float(p[0]), pos))
            except ValueError:
                pass
    return state


def read_hud(path):
    hud = mon = work = None
    for ln in open(path, encoding='utf-8'):
        p = ln.split()
        if len(p) >= 5 and p[0] == 'hud':
            hud = [int(v) for v in p[1:5]]
        if len(p) >= 5 and p[0] == 'monitor':
            mon = [int(v) for v in p[1:5]]
        if len(p) >= 5 and p[0] == 'work':
            work = [int(v) for v in p[1:5]]
    if not hud or not mon:
        sys.exit('hud.txt incomplete (needs hud and monitor lines)')
    return hud, mon, work or mon


def hud_crop(hud, mon, work, W, H):
    mw, mh = mon[2] - mon[0], mon[3] - mon[1]
    scale = W / mw
    cw, ch = int((hud[2] - hud[0]) * scale), int((hud[3] - hud[1]) * scale)
    cx = int((hud[0] - mon[0]) * scale)
    if abs(hud[3] - work[3]) <= 3:   # a bar docked at the bottom of the work area = the bottom of the frame
        cy = H - ch
    else:
        cy = int((hud[1] - mon[1]) * scale)
    cx, cy = max(0, cx), max(0, cy)
    cw, ch = min(cw, W - cx), min(ch, H - cy)
    return cx, cy, cw, ch, scale


# --- per-frame brightness ---------------------------------------------------------------------------------------------

def frames_from_video(path, crop):
    cx, cy, cw, ch = crop
    info = json.loads(run(['ffprobe', '-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream=width,height:format=duration', '-of', 'json', path]))
    csv = run(['ffprobe', '-v', 'error', '-f', 'lavfi', '-i', 'movie=%s,crop=%d:%d:%d:%d,signalstats' % (path.replace('\\', '/').replace(':', '\\:'), cw, ch, cx, cy),
               '-show_entries', 'frame=pts_time:frame_tags=lavfi.signalstats.YAVG', '-of', 'csv=p=0'])
    frames = []
    for ln in csv.splitlines():
        p = ln.split(',')
        if len(p) >= 2 and p[0] and p[1]:
            try:
                frames.append((float(p[0]), float(p[1])))
            except ValueError:
                pass
    return frames, float(info['format']['duration'])


def video_size(path):
    info = json.loads(run(['ffprobe', '-v', 'error', '-select_streams', 'v:0', '-show_entries', 'stream=width,height', '-of', 'json', path]))
    return info['streams'][0]['width'], info['streams'][0]['height']


def frames_from_folder(folder, hud, mon, work):
    """frames.txt: "<index> <t seconds since capture start> <file>"; brightness of the hud crop per frame."""
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import pngio
    rows = []
    if not os.path.isfile(os.path.join(folder, 'frames.txt')):
        sys.exit('no frames.txt in %s: the frames backend captured nothing (see the recorder log)' % folder)
    for ln in open(os.path.join(folder, 'frames.txt'), encoding='utf-8'):
        p = ln.split()
        if len(p) >= 3:
            rows.append((float(p[1]), p[2]))
    if not rows:
        sys.exit('frames.txt is empty')
    first = pngio.load(os.path.join(folder, rows[0][1]))
    W, H = pngio.size(first)
    cx, cy, cw, ch, scale = hud_crop(hud, mon, work, W, H)
    frames = []
    for t, name in rows:
        im = pngio.load(os.path.join(folder, name))
        frames.append((t, pngio.mean_luma(pngio.crop(im, cx, cy, cx + cw, cy + ch))))
    return frames, rows[-1][0], (W, H), (cx, cy, cw, ch, scale)


def white_runs(frames, thr):
    runs, cur = [], None
    for t, v in frames:
        white = v > thr
        if white and cur is None:
            cur = [t, t]
        elif white:
            cur[1] = t
        elif cur is not None:
            runs.append(cur)
            cur = None
    if cur:
        runs.append(cur)
    return runs


# --- main -------------------------------------------------------------------------------------------------------------

def analyse(a, log=print):
    state = read_state(a.state)
    for tok in ('FLASH_START', 'PLAY_POS', 'FLASH_END'):
        if tok not in state:
            sys.exit('state.txt: %s missing (the flash sequence did not complete)' % tok)
    T1 = state['FLASH_START'][-1][0]
    T3, p3 = state['PLAY_POS'][-1]
    p_end = state['FLASH_END'][-1][1]
    gap = T3 - p3 - T1
    gap_moving = None
    if 'PLAY_MOVING' in state:
        T4, p4 = state['PLAY_MOVING'][-1]
        gap_moving = T4 - p4 - T1
    hud, mon, work = read_hud(a.hud)
    is_folder = os.path.isdir(a.recording)
    if is_folder:
        frames, dur, (W, H), (cx, cy, cw, ch, scale) = frames_from_folder(a.recording, hud, mon, work)
    else:
        if not shutil.which('ffprobe'):
            sys.exit('ffprobe is needed to analyse a video recording (install ffmpeg)')
        W, H = video_size(a.recording)
        cx, cy, cw, ch, scale = hud_crop(hud, mon, work, W, H)
        frames, dur = frames_from_video(a.recording, (cx, cy, cw, ch))
    if len(frames) < 10:
        sys.exit('too few frames analysed (%d)' % len(frames))
    log('recording %dx%d, %.2f s, %d frames; monitor %dx%d logical -> scale %.2f; HUD crop %dx%d+%d+%d' % (W, H, dur, len(frames), mon[2] - mon[0], mon[3] - mon[1], scale, cw, ch, cx, cy))
    med = statistics.median(v for _, v in frames)
    thr = a.flash_thr if a.flash_thr is not None else (med + 100 if med < 120 else 235)
    runs = white_runs(frames, thr)
    log('HUD median brightness %.0f, threshold %.0f, white runs: %s' % (med, thr, [(round(x, 3), round(y, 3)) for x, y in runs]))
    if len(runs) < 2:
        sys.exit('need two flashes (start + end) in the recording; found %d' % len(runs))
    fps = (len(frames) - 1) / max(0.01, frames[-1][0] - frames[0][0])
    frame_dt = 1.0 / fps
    first, last = runs[0], runs[-1]
    t_dark = first[1] + frame_dt
    t0_start = t_dark + gap
    t0_moving = (t_dark + gap_moving) if gap_moving is not None else None
    t0_end = last[0] - a.end_offset_frames * frame_dt - p_end
    t0 = {'end': t0_end, 'moving': t0_moving if t0_moving is not None else t0_start, 'start': t0_start}[a.anchor]
    anchor = a.anchor
    if a.t0 is not None:
        t0, anchor = a.t0, 'manual t0=%.3f' % a.t0
    drift = last[0] - (t0_start + p_end)
    log('fps ~%.1f; start flash %.3f-%.3f -> first dark %.3f; anchors: start %.3f%s, end %.3f -> using %s: t0 = %.3f' % (
        fps, first[0], first[1], t_dark, t0_start, (', moving %.3f' % t0_moving) if t0_moving is not None else '', t0_end, anchor, t0))
    log('end flash at %.3f; start-anchor expected %.3f -> engine start latency ~%+.0f ms' % (last[0], t0_start + p_end, drift * 1000))
    if t0_moving is not None and abs(t0_moving - t0_end) > 0.06:
        log('WARNING: moving and end anchors differ by %+.0f ms - check the capture frame rate' % ((t0_end - t0_moving) * 1000))
    picture_end = a.picture_end if a.picture_end is not None else p_end
    rep = {
        'recording': a.recording, 'size': [W, H], 'fps': round(fps, 2), 'frames': len(frames), 'duration': dur, 'hud_crop': [cx, cy, cw, ch],
        'threshold': thr, 'median': med, 'start_flash': first, 'end_flash': last, 't_dark': t_dark,
        't0': t0, 'anchor': anchor, 't0_start': t0_start, 't0_moving': t0_moving, 't0_end': t0_end, 'p_start': p3, 'p_end': p_end,
        'drift_ms': round(drift * 1000, 1), 'engine_start_ms': round((gap_moving - gap) * 1000, 1) if gap_moving is not None else None,
        'pre': a.pre, 'post': a.post, 'picture_end': picture_end, 'mix': a.mix,
    }
    return rep


def encode(a, rep, log=print):
    if not a.mix:
        log('no --mix: report only')
        return []
    if not shutil.which('ffmpeg'):
        log('ffmpeg not found: report only')
        return []
    if os.path.isdir(a.recording):
        log('a frame folder cannot be encoded: report only')
        return []
    W, H = rep['size']
    start = rep['t0'] - a.pre
    length = a.pre + rep['picture_end'] + a.post
    if start < 0:
        log('WARNING: pre-roll %.2f s not available (t0=%.2f); trimming' % (a.pre, rep['t0']))
        length += start
        start = 0.0
    if start + length > rep['duration']:
        length = rep['duration'] - start
    delay_ms = int(round(a.pre * 1000))
    crop_top = detect_crop_top(a, start, length, W, H, log) if a.crop_top in ('auto', 'auto2') else int(a.crop_top)
    crop_top = max(0, min(crop_top, H // 4)) // 2 * 2
    rep.update({'cut_start': start, 'cut_length': length, 'crop_top': crop_top})
    adelay = 'adelay=%d|%d,' % (delay_ms, delay_ms) if delay_ms > 0 else ''

    def graph(scale):
        v = '[0:v]trim=start=%.4f:duration=%.4f,setpts=PTS-STARTPTS,fps=%d' % (start, length, a.fps_out)
        if crop_top > 0:
            v += ',crop=iw:ih-%d:0:%d' % (crop_top, crop_top)
        if scale:
            v += ',scale=%d:-2:flags=lanczos' % scale
        v += '[v]'
        return v + ';[1:a]%sapad,atrim=duration=%.4f,asetpts=PTS-STARTPTS[a]' % (adelay, length)
    vcodec = ['-c:v', 'h264_videotoolbox'] if OS == 'Darwin' else ['-c:v', 'libx264', '-preset', 'medium']
    acodec = ['-c:a', 'aac_at'] if OS == 'Darwin' else ['-c:a', 'aac']
    outs = []
    for name, scale, kbps in (('Showcase_native.mp4', None, a.bitrate), ('Showcase_%d.mp4' % a.width, a.width, a.bitrate_scaled)):
        o = os.path.join(a.out, name)
        run(['ffmpeg', '-y', '-hide_banner', '-loglevel', 'error', '-i', a.recording, '-i', a.mix, '-filter_complex', graph(scale),
             '-map', '[v]', '-map', '[a]'] + vcodec + ['-b:v', kbps, '-pix_fmt', 'yuv420p'] + acodec + ['-b:a', '320k', '-movflags', '+faststart', o])
        outs.append(o)
        log('%s -> %s' % (o, run(['ffprobe', '-v', 'error', '-show_entries', 'format=duration:stream=codec_name,width,height', '-of', 'csv=p=0', o]).replace('\n', ' | ')))
    rep['outputs'] = outs
    return outs


def detect_crop_top(a, start, length, W, H, log):
    probe_t = start + min(10.0, length / 2)
    rows = min(240, H // 2)
    raw = subprocess.run(['ffmpeg', '-v', 'error', '-ss', '%.3f' % probe_t, '-i', a.recording, '-frames:v', '1', '-vf', 'crop=iw:%d:0:0' % rows,
                          '-f', 'rawvideo', '-pix_fmt', 'gray', '-'], capture_output=True).stdout
    if len(raw) < rows * W:
        log('crop-top: probe failed, 0')
        return 0
    means = [sum(raw[y * W:(y + 1) * W]) / W for y in range(rows)]
    b1 = None
    for y in range(1, rows):
        if abs(means[y] - means[y - 1]) > 30:
            b1 = y
            break
    if b1 is None or b1 > rows - 20:
        log('crop-top: no strip found in the top %d rows, 0' % rows)
        return 0
    if a.crop_top == 'auto':
        log('crop-top auto: desktop strip %d px' % b1)
        return b1
    b2 = None
    for y in range(b1 + 8, rows):
        if means[y] < 40:
            b2 = y
            break
    if b2 is None:
        log('crop-top auto2: strip %d px (no title bar end found)' % b1)
        return b1
    log('crop-top auto2: strip %d px + title bar -> %d px' % (b1, b2))
    return b2


def write_report(a, rep, log=print):
    os.makedirs(a.out, exist_ok=True)
    with open(os.path.join(a.out, 'report.json'), 'w', encoding='utf-8') as f:
        json.dump(rep, f, indent=2)
    lines = ['# Stagehand showcase post (%s)' % os.path.basename(a.recording.rstrip('/\\')), '',
             '- recording %dx%d @ ~%.1f fps, %.2f s, %d frames; HUD crop %s' % (rep['size'][0], rep['size'][1], rep['fps'], rep['duration'], rep['frames'], rep['hud_crop']),
             '- start flash %.3f-%.3f s (first dark %.3f); end flash %.3f s at play position %.3f' % (rep['start_flash'][0], rep['start_flash'][1], rep['t_dark'], rep['end_flash'][0], rep['p_end']),
             '- mix time 0 at %.3f s (%s anchor; start-anchored %.3f, end-anchored %.3f%s; engine start latency ~%+.0f ms)' % (
                 rep['t0'], rep['anchor'], rep['t0_start'], rep['t0_end'], (', moving %.3f' % rep['t0_moving']) if rep['t0_moving'] is not None else '', rep['drift_ms'])]
    if rep.get('outputs'):
        lines.append('- cut %.3f s + %.3f s, top crop %d px, mix delayed %d ms; outputs: %s' % (rep['cut_start'], rep['cut_length'], rep['crop_top'], int(rep['pre'] * 1000), ', '.join(os.path.basename(o) for o in rep['outputs'])))
    with open(os.path.join(a.out, 'report.md'), 'w', encoding='utf-8') as f:
        f.write('\n'.join(lines) + '\n')
    log('\n'.join(lines))


def build_parser():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('recording', help='video file or a frames folder (frames.txt)')
    ap.add_argument('--state', required=True)
    ap.add_argument('--hud', required=True)
    ap.add_argument('--out', required=True)
    ap.add_argument('--mix', default=None, help='the delivered mix laid under the picture (no encode without it)')
    ap.add_argument('--pre', type=float, default=0.0, help='seconds of picture before mix time 0')
    ap.add_argument('--post', type=float, default=0.10, help='seconds after the picture end')
    ap.add_argument('--picture-end', type=float, default=None, help='length of the mix in seconds (default: the end flash position)')
    ap.add_argument('--anchor', choices=['end', 'moving', 'start'], default='end')
    ap.add_argument('--t0', type=float, default=None, help='override mix time 0 in recording seconds')
    ap.add_argument('--end-offset-frames', type=float, default=1.5, help='paint + capture latency of the end flash in recording frames')
    ap.add_argument('--flash-thr', type=float, default=None, help='white threshold (default: dark median + 100)')
    ap.add_argument('--crop-top', default='auto2', help='N px, auto (desktop strip) or auto2 (strip + title bar)')
    ap.add_argument('--width', type=int, default=1920)
    ap.add_argument('--bitrate', default='40M')
    ap.add_argument('--bitrate-scaled', default='12M')
    ap.add_argument('--fps-out', type=int, default=60)
    ap.add_argument('--no-encode', action='store_true')
    return ap


def main(argv=None):
    a = build_parser().parse_args(argv)
    os.makedirs(a.out, exist_ok=True)
    rep = analyse(a)
    if not a.no_encode:
        encode(a, rep)
    write_report(a, rep)
    return 0


if __name__ == '__main__':
    sys.exit(main())
