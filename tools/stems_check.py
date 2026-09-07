#!/usr/bin/env python3
"""stems_check.py - the independent measurement of a Stagehand stems batch (docs/user-guide.md, Stems chapter).

Two ways to use it:

    python3 tools/stems_check.py --ctl "<project>/Render/stagehand_ctl" [--out check.json]
        asks the running Stagehand to render its enabled stems (ctl verb "stems render"), waits for STEMS_DONE,
        reads the stems_results.json the batch wrote next to the stems and measures every WAV independently

    python3 tools/stems_check.py --results "<stems folder>/stems_results.json" [--out check.json]
        measures the files of a batch that already ran

For every rendered WAV: the exact sample peak (dBFS), the length (s) and the integrated loudness (LUFS-I,
ITU-R BS.1770-4: K-weighting, 400 ms blocks, absolute and relative gates) are computed with numpy and compared
with what Stagehand wrote (peak and length always; LUFS-I when REAPER's render statistics were on). When ffmpeg is
on the PATH its ebur128 filter is run too and reported as a third opinion. The verdict (ok / not ok with the
largest differences) goes to the JSON file and to stdout; exit 0 when every file agrees within the tolerances
(peak 0.1 dB, length 1 ms, LUFS-I 1 LU), 1 otherwise. Only numpy is required (scipy speeds the filters up).
"""
import argparse
import json
import math
import os
import shutil
import struct
import subprocess
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from stagehand_ctl import Ctl, CtlError  # noqa: E402

try:
    import numpy as np
except ImportError:  # pragma: no cover
    print('stems_check: numpy is required', file=sys.stderr)
    sys.exit(2)

try:
    from scipy.signal import lfilter as _lfilter
except ImportError:  # pragma: no cover
    _lfilter = None


# --- WAV ------------------------------------------------------------------------------------------------------------

def read_wav(path):
    """-> (samples float32 [frames, channels] in -1..1, sample rate, bits)"""
    with open(path, 'rb') as f:
        data = f.read()
    if data[:4] != b'RIFF' or data[8:12] != b'WAVE':
        raise ValueError('not a RIFF/WAVE file: %s' % path)
    pos = 12
    fmt = None
    pcm = None
    while pos + 8 <= len(data):
        cid = data[pos:pos + 4]
        size = struct.unpack('<I', data[pos + 4:pos + 8])[0]
        body = data[pos + 8:pos + 8 + size]
        if cid == b'fmt ':
            tag, ch, sr = struct.unpack('<HHI', body[:8])
            bits = struct.unpack('<H', body[14:16])[0]
            if tag == 0xFFFE and len(body) >= 26:
                tag = struct.unpack('<H', body[24:26])[0]
            fmt = (tag, ch, sr, bits)
        elif cid == b'data':
            pcm = body
            break
        pos += 8 + size + (size & 1)
    if fmt is None or pcm is None:
        raise ValueError('no fmt or data chunk: %s' % path)
    tag, ch, sr, bits = fmt
    if tag == 3 and bits == 32:
        x = np.frombuffer(pcm, dtype='<f4').astype(np.float64)
    elif bits == 16:
        x = np.frombuffer(pcm, dtype='<i2').astype(np.float64) / 32768.0
    elif bits == 24:
        n = len(pcm) // 3
        b = np.frombuffer(pcm[:n * 3], dtype=np.uint8).reshape(n, 3).astype(np.int32)
        v = b[:, 0] | (b[:, 1] << 8) | (b[:, 2] << 16)
        v = np.where(v >= 1 << 23, v - (1 << 24), v)
        x = v.astype(np.float64) / 8388608.0
    elif bits == 32:
        x = np.frombuffer(pcm, dtype='<i4').astype(np.float64) / 2147483648.0
    else:
        raise ValueError('unsupported bit depth %d: %s' % (bits, path))
    frames = len(x) // ch
    x = x[:frames * ch].reshape(frames, ch)
    return x, sr, bits


# --- BS.1770 ----------------------------------------------------------------------------------------------------------

def biquad_highshelf(fs, f0, gain_db, q):
    a = 10 ** (gain_db / 40.0)
    w0 = 2 * math.pi * f0 / fs
    alpha = math.sin(w0) / (2 * q)
    cw = math.cos(w0)
    b0 = a * ((a + 1) + (a - 1) * cw + 2 * math.sqrt(a) * alpha)
    b1 = -2 * a * ((a - 1) + (a + 1) * cw)
    b2 = a * ((a + 1) + (a - 1) * cw - 2 * math.sqrt(a) * alpha)
    a0 = (a + 1) - (a - 1) * cw + 2 * math.sqrt(a) * alpha
    a1 = 2 * ((a - 1) - (a + 1) * cw)
    a2 = (a + 1) - (a - 1) * cw - 2 * math.sqrt(a) * alpha
    return [b0 / a0, b1 / a0, b2 / a0], [1.0, a1 / a0, a2 / a0]


def biquad_highpass(fs, f0, q):
    w0 = 2 * math.pi * f0 / fs
    alpha = math.sin(w0) / (2 * q)
    cw = math.cos(w0)
    b0 = (1 + cw) / 2
    b1 = -(1 + cw)
    b2 = (1 + cw) / 2
    a0 = 1 + alpha
    a1 = -2 * cw
    a2 = 1 - alpha
    return [b0 / a0, b1 / a0, b2 / a0], [1.0, a1 / a0, a2 / a0]


def lfilter(b, a, x):
    if _lfilter is not None:
        return _lfilter(b, a, x, axis=0)
    # direct form II transposed, per channel (slow, dependency-free)
    y = np.zeros_like(x)
    for c in range(x.shape[1]):
        z1 = z2 = 0.0
        xc = x[:, c]
        yc = y[:, c]
        for n in range(len(xc)):
            xn = xc[n]
            yn = b[0] * xn + z1
            z1 = b[1] * xn - a[1] * yn + z2
            z2 = b[2] * xn - a[2] * yn
            yc[n] = yn
    return y


def lufs_integrated(x, fs):
    """ITU-R BS.1770-4 integrated loudness of x [frames, channels] (channels 1-2 weighted 1.0, 3+ as surround)"""
    if len(x) < int(0.4 * fs):
        return None
    b1, a1 = biquad_highshelf(fs, 1500.0, 4.0, 1 / math.sqrt(2))
    b2, a2 = biquad_highpass(fs, 38.0, 0.5)
    y = lfilter(b2, a2, lfilter(b1, a1, x))
    block = int(round(0.4 * fs))
    hop = int(round(0.1 * fs))
    n_blocks = 1 + (len(y) - block) // hop
    if n_blocks < 1:
        return None
    weights = np.ones(x.shape[1])
    if x.shape[1] >= 5:
        weights[3:5] = 1.41
    sq = y ** 2
    # cumulative sums give every block's mean square in one pass
    csum = np.concatenate([np.zeros((1, sq.shape[1])), np.cumsum(sq, axis=0)])
    starts = np.arange(n_blocks) * hop
    ms = (csum[starts + block] - csum[starts]) / block
    z = ms @ weights
    with np.errstate(divide='ignore'):
        lk = -0.691 + 10 * np.log10(np.maximum(z, 1e-30))
    keep = lk > -70.0
    if not keep.any():
        return None
    rel = -0.691 + 10 * math.log10(z[keep].mean()) - 10.0
    keep2 = keep & (lk > rel)
    if not keep2.any():
        return None
    return -0.691 + 10 * math.log10(z[keep2].mean())


def ffmpeg_lufs(path):
    exe = shutil.which('ffmpeg')
    if not exe:
        return None
    try:
        p = subprocess.run([exe, '-nostats', '-i', path, '-af', 'ebur128', '-f', 'null', '-'], capture_output=True, text=True, timeout=600)
    except Exception:
        return None
    val = None
    for line in p.stderr.splitlines():
        line = line.strip()
        if line.startswith('I:') and 'LUFS' in line:
            try:
                val = float(line.split()[1])
            except (IndexError, ValueError):
                pass
    return val


def measure(path):
    x, fs, bits = read_wav(path)
    peak = float(np.abs(x).max()) if len(x) else 0.0
    peak_db = 20 * math.log10(peak) if peak > 0 else -144.0
    return {
        'file': path, 'srate': fs, 'bits': bits, 'channels': int(x.shape[1]), 'frames': int(len(x)),
        'length_s': len(x) / fs if fs else 0.0, 'peak_db': peak_db, 'lufs_i': lufs_integrated(x, fs), 'ffmpeg_lufs_i': ffmpeg_lufs(path),
    }


# --- the check ---------------------------------------------------------------------------------------------------------------

def check_results(results, log):
    rows = []
    max_peak = max_len = 0.0
    max_lufs = None
    n = 0
    problems = []
    for r in results.get('rows', []):
        if not r.get('ok') or not r.get('file'):
            continue
        path = r['file']
        if not os.path.isfile(path):
            problems.append('missing file %s' % path)
            continue
        m = measure(path)
        n += 1
        row = {'stem': r.get('name'), 'file': path, 'stagehand': {'peak_db': r.get('peak_db'), 'duration_s': r.get('duration_s'), 'lufs_i': r.get('lufs_i'),
               'reaper_peak_db': r.get('reaper_peak_db')}, 'measured': m}
        if r.get('peak_db') is not None:
            d = abs(float(r['peak_db']) - m['peak_db']) if m['peak_db'] > -144 or float(r['peak_db']) > -144 else 0.0
            row['peak_diff_db'] = d
            max_peak = max(max_peak, d)
        if r.get('duration_s') is not None:
            d = abs(float(r['duration_s']) - m['length_s'])
            row['len_diff_s'] = d
            max_len = max(max_len, d)
        if r.get('lufs_i') is not None and m['lufs_i'] is not None:
            d = abs(float(r['lufs_i']) - m['lufs_i'])
            row['lufs_diff'] = d
            max_lufs = d if max_lufs is None else max(max_lufs, d)
        log('%-24s peak %8.2f dBFS (Stagehand %s)  len %.3f s (Stagehand %s)  LUFS-I %s (REAPER %s, ffmpeg %s)' % (
            (r.get('name') or '')[:24], m['peak_db'], r.get('peak_db'), m['length_s'], r.get('duration_s'),
            '%.2f' % m['lufs_i'] if m['lufs_i'] is not None else '-', r.get('lufs_i'), m['ffmpeg_lufs_i']))
        rows.append(row)
    ok = n > 0 and not problems and max_peak <= 0.1 and max_len <= 0.001 and (max_lufs is None or max_lufs <= 1.0)
    summary = '%d files; max peak diff %.3f dB; max length diff %.4f s; max LUFS-I diff %s%s' % (
        n, max_peak, max_len, '%.2f LU' % max_lufs if max_lufs is not None else 'n/a', ('; ' + '; '.join(problems)) if problems else '')
    return {'ok': ok, 'n': n, 'max_peak_diff_db': max_peak, 'max_len_diff_s': max_len, 'max_lufs_diff': max_lufs, 'rows': rows, 'problems': problems,
            'summary': summary, 'ffmpeg': shutil.which('ffmpeg') is not None}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--ctl', help='the ctl folder of a running Stagehand (renders the enabled stems first)')
    ap.add_argument('--results', help='a stems_results.json written by a batch (no rendering)')
    ap.add_argument('--out', help='where the verdict JSON goes (default: stems_check.json next to the results)')
    ap.add_argument('--timeout', type=float, default=900.0, help='seconds to wait for the batch')
    a = ap.parse_args()
    log = lambda s: print(s, flush=True)
    results_path = a.results
    if a.ctl:
        c = Ctl(a.ctl, log=log)
        c.ping()
        log('stems_check: Stagehand answered; asking for a batch')
        mark = c.state_size()
        c.send('stems render')
        t0 = time.time()
        line = None
        while time.time() - t0 < a.timeout:
            line = c.find('STEMS_DONE', mark) or c.find('ERROR', mark)
            if line:
                break
            time.sleep(0.25)
        if not line:
            raise CtlError('no STEMS_DONE within %.0f s' % a.timeout)
        _, token, kv, rest = Ctl.parse(line)
        if token == 'ERROR':
            print('stems_check: Stagehand refused the batch: %s' % rest)
            return 1
        log('stems_check: batch done: %s' % line)
        results_path = kv.get('results') or ''
        if not results_path and rest:
            results_path = rest.split('results=', 1)[-1].strip()
    if not results_path or not os.path.isfile(results_path):
        print('stems_check: no results file (%s)' % results_path, file=sys.stderr)
        return 2
    with open(results_path, encoding='utf-8') as f:
        results = json.load(f)
    verdict = check_results(results, log)
    verdict['results'] = results_path
    out = a.out or os.path.join(os.path.dirname(results_path), 'stems_check.json')
    with open(out, 'w', encoding='utf-8') as f:
        json.dump(verdict, f, indent=2)
    log('stems_check: %s -> %s (%s)' % ('OK' if verdict['ok'] else 'NOT OK', out, verdict['summary']))
    return 0 if verdict['ok'] else 1


if __name__ == '__main__':
    try:
        sys.exit(main())
    except CtlError as e:
        print('stems_check: %s' % e, file=sys.stderr)
        sys.exit(2)
