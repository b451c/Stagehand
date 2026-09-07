#!/usr/bin/env python3
"""make_lufs_curve.py <mix.wav> <out.txt>  -  the loudness curve the HUD shows in "curve" mode.

Runs ffmpeg's ebur128 filter over the delivered mix and writes one row per 100 ms: "t M S I" (momentary,
short-term, integrated LUFS). Stagehand reads it from <project>/Render/stagehand_ctl/lufs_curve.txt (or the path
in hud.loudness.curve_file). Needs ffmpeg on the PATH.
"""
import re
import subprocess
import sys


def make_curve(mix, out):
    r = subprocess.run(['ffmpeg', '-nostats', '-hide_banner', '-i', mix, '-af', 'ebur128=peak=none', '-f', 'null', '-'],
                       capture_output=True, text=True)
    rows = []
    pat = re.compile(r't:\s*([\d.]+)\s+.*?M:\s*(-?[\d.]+|-inf)\s+S:\s*(-?[\d.]+|-inf)\s+I:\s*(-?[\d.]+|-inf)')
    for ln in r.stderr.splitlines():
        m = pat.search(ln)
        if m:
            vals = [float(v) if v != '-inf' else -120.0 for v in m.groups()]
            rows.append(vals)
    if not rows:
        sys.exit('no ebur128 rows from ffmpeg for %s:\n%s' % (mix, r.stderr[-800:]))
    with open(out, 'w', encoding='utf-8') as f:
        f.write('# Stagehand loudness curve from %s: t M S I (LUFS, 100 ms steps)\n' % mix)
        for t, m, s, i in rows:
            f.write('%.1f %.1f %.1f %.1f\n' % (t, m, s, i))
    print('%s: %d rows, integrated %.1f LUFS -> %s' % (mix, len(rows), rows[-1][3], out))
    return len(rows)


if __name__ == '__main__':
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    make_curve(sys.argv[1], sys.argv[2])
