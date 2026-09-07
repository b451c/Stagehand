#!/usr/bin/env python3
"""stagehand_ctl.py - the client side of Stagehand's control protocol (docs/user-guide.md, Recorder chapter).

Stagehand (the Recorder module) polls <ctl dir>/cmd every few frames, deletes it and appends replies to
<ctl dir>/state as "<time_precise> TOKEN key=value ...". The ctl dir is <project folder>/Render/stagehand_ctl
unless recorder.ctl.dir is set. This module is imported by overview_capture.py and record_showcase.py and can
be used from any script:

    from stagehand_ctl import Ctl
    c = Ctl.from_project('/path/to/Session.RPP')   # or Ctl('/path/to/Render/stagehand_ctl')
    c.ping()                                       # raises unless Stagehand answers within the timeout
    line = c.ask('overview rect', 'RECT')          # send a command, wait for a token, return the whole line

Only the standard library is used.
"""
import os
import sys
import time


class CtlError(RuntimeError):
    pass


class Ctl:
    def __init__(self, ctl_dir, log=None):
        self.dir = os.path.abspath(ctl_dir)
        self.cmd_path = os.path.join(self.dir, 'cmd')
        self.state_path = os.path.join(self.dir, 'state')
        self.hud_path = os.path.join(self.dir, 'hud')
        self.log = log or (lambda s: None)
        os.makedirs(self.dir, exist_ok=True)

    @classmethod
    def from_project(cls, rpp, log=None):
        return cls(os.path.join(os.path.dirname(os.path.abspath(rpp)), 'Render', 'stagehand_ctl'), log=log)

    # --- state file -----------------------------------------------------------------------------------------------
    def clear_state(self):
        open(self.state_path, 'w').close()

    def state_lines(self):
        try:
            with open(self.state_path, encoding='utf-8', errors='replace') as f:
                return [ln.rstrip('\n') for ln in f if ln.strip()]
        except FileNotFoundError:
            return []

    def state_size(self):
        try:
            return os.path.getsize(self.state_path)
        except OSError:
            return 0

    @staticmethod
    def parse(line):
        """'<t> TOKEN k=v k2=v2 rest' -> (t, TOKEN, {k: v}, rest_text)."""
        parts = line.split()
        if len(parts) < 2:
            return None, None, {}, ''
        try:
            t = float(parts[0])
        except ValueError:
            t = None
        kv, rest = {}, []
        for p in parts[2:]:
            if '=' in p and not rest:
                k, v = p.split('=', 1)
                kv[k] = v
            else:
                rest.append(p)
        return t, parts[1], kv, ' '.join(rest)

    def find(self, token, since_size=0):
        """The last state line carrying the token, written after byte offset since_size (or None)."""
        try:
            with open(self.state_path, encoding='utf-8', errors='replace') as f:
                f.seek(since_size)
                lines = [ln.rstrip('\n') for ln in f if ln.strip()]
        except FileNotFoundError:
            return None
        hit = None
        for ln in lines:
            parts = ln.split()
            if len(parts) >= 2 and parts[1] == token:
                hit = ln
        return hit

    # --- commands -------------------------------------------------------------------------------------------------
    def send(self, line):
        tmp = self.cmd_path + '.tmp'
        with open(tmp, 'w', encoding='utf-8') as f:
            f.write(line + '\n')
        os.replace(tmp, self.cmd_path)   # atomic: Stagehand never reads a half-written file
        self.log('> ' + line)

    def wait(self, token, timeout=10.0, since_size=0, poll=0.05):
        t0 = time.time()
        while True:
            ln = self.find(token, since_size)
            if ln:
                self.log('< ' + ln)
                return ln
            if time.time() - t0 > timeout:
                return None
            time.sleep(poll)

    def ask(self, line, token, timeout=10.0):
        """Send a command and wait for its reply token; only replies written after the send count."""
        mark = self.state_size()
        self.send(line)
        ln = self.wait(token, timeout, since_size=mark)
        if ln is None:
            raise CtlError('no %s from Stagehand within %.0f s after "%s" (ctl dir %s)' % (token, timeout, line, self.dir))
        return ln

    def ping(self, timeout=10.0, retries=6):
        """Ping until Stagehand answers; between retries the cmd file is rewritten (Stagehand may not run yet)."""
        for i in range(retries):
            try:
                return self.ask('ping', 'PONG', timeout)
            except CtlError:
                self.log('no PONG yet (%d/%d) - is Stagehand running with this project open?' % (i + 1, retries))
        raise CtlError('Stagehand does not answer on %s. Open the project in REAPER, run Stagehand (any tab) and try again.' % self.dir)

    # --- files ------------------------------------------------------------------------------------------------------
    def read_hud(self):
        """{'hud': [l,t,r,b], 'monitor': [...], 'work': [...]} from the hud file (written on arm)."""
        out = {}
        try:
            with open(self.hud_path, encoding='utf-8') as f:
                for ln in f:
                    p = ln.split()
                    if len(p) >= 5 and p[0] in ('hud', 'monitor', 'work'):
                        out[p[0]] = [int(v) for v in p[1:5]]
        except FileNotFoundError:
            pass
        return out


def ctl_from_args(args):
    """Common --ctl / --project handling for the drivers."""
    if getattr(args, 'ctl', None):
        return Ctl(args.ctl, log=getattr(args, 'log', None))
    if getattr(args, 'project', None):
        return Ctl.from_project(args.project, log=getattr(args, 'log', None))
    sys.exit('give --ctl <folder> (Stagehand shows it in the Recorder / Overview tab) or --project <file.RPP>')


def parse_rect_line(line):
    """The RECT reply of 'overview rect' -> dict with ints: arrange, ruler_top (None), ruler_h, tcp_left, client_h,
    main, content_h, crop (x, y, w, h) and scroll (pos, page, min, max) or None."""
    import re
    m = re.search(r'RECT (-?\d+) (-?\d+) (-?\d+) (-?\d+) ruler_top (\S+) ruler_h (\d+) tcp_left (-?\d+) arr_client_h (\d+) '
                  r'main (-?\d+),(-?\d+)-(-?\d+),(-?\d+) content_h (\d+) crop (-?\d+),(-?\d+),(\d+),(\d+) scroll (\S+)', line)
    if not m:
        raise CtlError('cannot parse the RECT line: ' + line)
    g = m.groups()
    d = {
        'arrange': [int(g[0]), int(g[1]), int(g[2]), int(g[3])],
        'ruler_top': None if g[4] == 'nil' else int(g[4]), 'ruler_h': int(g[5]), 'tcp_left': int(g[6]), 'client_h': int(g[7]),
        'main': [int(g[8]), int(g[9]), int(g[10]), int(g[11])], 'content_h': int(g[12]),
        'crop': [int(g[13]), int(g[14]), int(g[15]), int(g[16])],
    }
    if g[17] != 'nil':
        d['scroll'] = [int(v) for v in g[17].split('/')]
    else:
        d['scroll'] = None
    return d


def parse_scroll_line(line):
    import re
    m = re.search(r'SCROLL (-?\d+) (-?\d+) (-?\d+) (-?\d+)', line)
    if not m:
        raise CtlError('cannot parse the SCROLL line: ' + line)
    return [int(v) for v in m.groups()]
