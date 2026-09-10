#!/usr/bin/env python3
"""stagehand_mcp.py - an MCP server (stdio, standard library only) that lets an AI agent read and drive a running
Stagehand through its control protocol (docs/user-guide.md, Agent access chapter).

Stagehand polls <ctl dir>/cmd and appends replies to <ctl dir>/state; the agent verbs answer with JSON files
(reply_N.json) named in the token line. This server turns those verbs into MCP tools with schemas. It finds the
ctl folder of the open project through the discovery file Stagehand refreshes while it runs
(<home>/.stagehand/agent.json), or takes --ctl <folder> / --project <file.RPP> / the STAGEHAND_CTL variable.

Install (the Agent tab copies these):
    claude mcp add stagehand -- python3 /path/to/Stagehand/agent/stagehand_mcp.py
    {"mcpServers": {"stagehand": {"command": "python3", "args": ["/path/to/Stagehand/agent/stagehand_mcp.py"]}}}

Rules the tools enforce or state: nothing here saves the project; stems_render needs confirm=true (the agent asks
the user in the conversation first); the user's switches in the Agent tab can refuse any change; every change
goes through Stagehand's journal and is restored like the user's own.

--selftest --ctl <folder> --out <json> runs the protocol in-process against a live Stagehand and writes a verdict
(the test harness runs it as the companion of its agent scenario).
"""
import argparse
import json
import os
import sys
import time

PROTOCOL_VERSIONS = ('2025-06-18', '2025-03-26', '2024-11-05')
SERVER_NAME = 'stagehand'
SERVER_VERSION = '1.0.0'
DEFAULT_TIMEOUT = 15.0
HELLO_NAME = 'MCP agent'


# --- the protocol client ----------------------------------------------------------------------------------------------

class CtlError(RuntimeError):
    pass


def discovery_path():
    home = os.environ.get('HOME') or os.environ.get('USERPROFILE') or ''
    if not home:
        return None
    return os.path.join(home, '.stagehand', 'agent.json')


def read_discovery():
    p = discovery_path()
    if not p or not os.path.isfile(p):
        return None
    try:
        with open(p, encoding='utf-8') as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


class Ctl:
    """One ctl folder: send a line, wait for its token, read the JSON reply file."""

    def __init__(self, ctl_dir):
        self.dir = os.path.abspath(ctl_dir)
        self.cmd_path = os.path.join(self.dir, 'cmd')
        self.state_path = os.path.join(self.dir, 'state')

    def state_size(self):
        try:
            return os.path.getsize(self.state_path)
        except OSError:
            return 0

    def send(self, line):
        os.makedirs(self.dir, exist_ok=True)
        tmp = self.cmd_path + '.tmp'
        with open(tmp, 'w', encoding='utf-8') as f:
            f.write(line + '\n')
        os.replace(tmp, self.cmd_path)

    @staticmethod
    def parse(line):
        parts = line.split()
        if len(parts) < 2:
            return None, {}, ''
        kv, rest = {}, []
        for p in parts[2:]:
            if '=' in p and not rest:
                k, v = p.split('=', 1)
                kv[k] = v
            else:
                rest.append(p)
        return parts[1], kv, ' '.join(rest)

    def lines_after(self, mark):
        try:
            with open(self.state_path, encoding='utf-8', errors='replace') as f:
                f.seek(mark)
                return [ln.rstrip('\n') for ln in f if ln.strip()]
        except FileNotFoundError:
            return []

    def ask(self, line, token, timeout=DEFAULT_TIMEOUT, poll=0.05):
        """Send a line; return (token, kv, rest, json_or_None). An ERROR written after the send raises CtlError."""
        mark = self.state_size()
        self.send(line)
        t0 = time.time()
        while True:
            for ln in self.lines_after(mark):
                tok, kv, rest = self.parse(ln)
                if tok == token:
                    data = None
                    if 'file' in kv:
                        data = self.read_reply(kv['file'])
                    return tok, kv, rest, data
                if tok == 'ERROR':
                    raise CtlError(ln.split(' ', 2)[2] if ln.count(' ') >= 2 else ln)
                if tok == 'UNKNOWN':
                    raise CtlError('Stagehand does not know the verb: ' + rest)
            if time.time() - t0 > timeout:
                raise CtlError('no %s from Stagehand within %.0f s after "%s" (is Stagehand running with the project open? ctl dir %s)'
                               % (token, timeout, line, self.dir))
            time.sleep(poll)

    def read_reply(self, name):
        p = os.path.join(self.dir, name)
        for _ in range(40):
            try:
                with open(p, encoding='utf-8') as f:
                    return json.load(f)
            except (OSError, ValueError):
                time.sleep(0.05)
        raise CtlError('reply file %s could not be read' % p)

    def json(self, line, token, timeout=DEFAULT_TIMEOUT):
        _, kv, rest, data = self.ask(line, token, timeout)
        if data is None:
            return {'token': token, 'kv': kv, 'text': rest}
        return data


# --- the connection (discovery or explicit) ------------------------------------------------------------------------------

class Connection:
    def __init__(self, ctl_dir=None, project=None):
        self.pinned = None
        if ctl_dir:
            self.pinned = ctl_dir
        elif project:
            self.pinned = os.path.join(os.path.dirname(os.path.abspath(project)), 'Render', 'stagehand_ctl')
        elif os.environ.get('STAGEHAND_CTL'):
            self.pinned = os.environ['STAGEHAND_CTL']
        self.said_hello = False
        self.last_dir = None

    def resolve(self):
        if self.pinned:
            return Ctl(self.pinned), None
        d = read_discovery()
        if not d:
            raise CtlError('no Stagehand found: start Stagehand in REAPER with a saved project (the Agent tab shows the ctl folder), '
                           'or start this server with --ctl <folder> / --project <file.RPP>')
        if not d.get('running') or (time.time() - float(d.get('stamp') or 0)) > 30:
            raise CtlError('Stagehand is not running (discovery file %s is stale); start Stagehand in REAPER' % discovery_path())
        if not d.get('ctl'):
            raise CtlError('the open project is not saved: Stagehand has no ctl folder for it. Save the project in REAPER first')
        return Ctl(d['ctl']), d

    def ctl(self):
        c, _ = self.resolve()
        if c.dir != self.last_dir:
            self.said_hello = False
            self.last_dir = c.dir
        if not self.said_hello:
            c.ask('hello ' + HELLO_NAME, 'HELLO')
            self.said_hello = True
        return c


# --- the tools --------------------------------------------------------------------------------------------------------------

def _obj(props, required=None):
    s = {'type': 'object', 'properties': props, 'additionalProperties': False}
    if required:
        s['required'] = required
    return s


TOOLS = [
    {
        'name': 'stagehand_status',
        'description': 'Read the live state of the open REAPER session through Stagehand: project (name, path, saved, counts), '
                       'transport (playing, cursor, time selection, view), every module (Navigator active scene and solo / mute '
                       'scenes, Director run and current shot, HUD, Glow, Overview, Recorder, Stems batch and last results), '
                       'the restore journal counts and the agent switches the user set. Read this first.',
        'inputSchema': _obj({}),
    },
    {
        'name': 'stagehand_census',
        'description': 'The project census: every track (number, GUID, name, folder depth and parent, item / FX / envelope counts, '
                       'family, colour, solo / mute / visible), the scenes (regions with times and item counts), the markers with '
                       'their classes, the families with their rules and histogram, and the groups. Large on big sessions '
                       '(one row per track); ask for it once and reason over the result.',
        'inputSchema': _obj({}),
    },
    {
        'name': 'stagehand_shots',
        'description': "The Director's shot list with the validator's issues (errors, warnings, info per shot) and the run "
                       'state (active, auto-follow, current shot).',
        'inputSchema': _obj({}),
    },
    {
        'name': 'stagehand_stems',
        'description': 'The stem set (every stem with its cells S / I / M, variant, range, source), the render settings '
                       'Stagehand owns and a summary of the last batch.',
        'inputSchema': _obj({}),
    },
    {
        'name': 'stagehand_results',
        'description': 'The full results of the last stems batch: one row per stem with file, action, range, render time, '
                       'duration, sample peak, loudness (LUFS-I, momentary and short-term max, LRA when REAPER measured them), '
                       'silent flag, ok / error.',
        'inputSchema': _obj({}),
    },
    {
        'name': 'stagehand_config',
        'description': 'Read or change Stagehand settings (the same keys as the Settings tab and docs/config-reference.md). '
                       'action "get" reads one key with its type, range, default and overrides; "list" reads every key under a '
                       'prefix (empty = all); "set" writes a value (text: numbers, on/off, an enum word, a path, JSON for lists) '
                       'into the project layer (default) or the global file; "reset" removes an override. Values outside the '
                       "schema's range are refused with the reason. Confirm a set or reset with the user first.",
        'inputSchema': _obj({
            'action': {'type': 'string', 'enum': ['get', 'list', 'set', 'reset']},
            'key': {'type': 'string', 'description': 'dotted key, e.g. director.timing.lead_s (for list: a prefix or empty)'},
            'value': {'type': 'string', 'description': 'for set: the new value as text'},
            'scope': {'type': 'string', 'enum': ['project', 'global'], 'description': 'for set / reset; default project'},
        }, ['action']),
    },
    {
        'name': 'stagehand_jump',
        'description': 'Move the edit cursor (and the view) with the Navigator: to a scene (name, part of a name, or its number '
                       'in the census), to a marker (name or number), or to a time in seconds. A scene jump also sets the time '
                       'selection when the user has that option on.',
        'inputSchema': _obj({
            'scene': {'type': 'string'}, 'marker': {'type': 'string'}, 'time_s': {'type': 'number'},
        }),
    },
    {
        'name': 'stagehand_scene',
        'description': 'Scene solo / mute with exact restore (the Navigator\'s journal): "solo" solos in place every track with '
                       'items in the scene, "mute" mutes every item in it, "clear" puts both back, "restore" replays the whole '
                       'journal (everything Stagehand changed). Tell the user what you will solo or mute before doing it.',
        'inputSchema': _obj({
            'action': {'type': 'string', 'enum': ['solo', 'mute', 'clear', 'restore']},
            'scene': {'type': 'string', 'description': 'scene name / part / number (solo and mute)'},
        }, ['action']),
    },
    {
        'name': 'stagehand_director',
        'description': 'Drive the Director: "start" a follow-play run over the shot list (the arrange shows each shot\'s lanes '
                       'while playing), "stop" it and restore the layout, "goto" a shot number (starts a run when none is '
                       'active), "next" / "prev", "auto" on or off (follow the play position), "validate" the shot list. Ask '
                       'the user before starting a run: it changes the arrange until stopped.',
        'inputSchema': _obj({
            'action': {'type': 'string', 'enum': ['start', 'stop', 'goto', 'next', 'prev', 'auto', 'validate']},
            'shot': {'type': 'integer', 'description': 'for goto: 1-based shot number'},
            'on': {'type': 'boolean', 'description': 'for auto'},
        }, ['action']),
    },
    {
        'name': 'stagehand_shots_set',
        'description': 'Edit the Director\'s shot list, the script of a showcase: "set" replaces the whole list with `shots`, '
                       '"add" appends `shot`, "update" merges the fields of `shot` into shot number `k`, "remove" deletes shot `k`, '
                       '"clear" empties the list, "from_scenes" appends one shot per region (name and caption from the region). '
                       'A shot: {name, t0, t1 (seconds), caption, caption2, lanes: [{kind: "items"} | {kind: "items", family} | '
                       '{kind: "family", name} | {kind: "rule", rule} | {kind: "track", name}], envelopes: [{track, env}] (name '
                       'rules), view: "page" | "follow", parents: "none" | "bus" | "all", pad_before, pad_after}. Lanes default '
                       'to the tracks with items in the range. The list lives in the project and is saved only when the user '
                       'saves. Ask before replacing a list the user built by hand; read stagehand_shots first.',
        'inputSchema': _obj({
            'action': {'type': 'string', 'enum': ['set', 'add', 'update', 'remove', 'clear', 'from_scenes']},
            'shots': {'type': 'array', 'items': {'type': 'object'}, 'description': 'for set: the new list'},
            'shot': {'type': 'object', 'description': 'for add: the shot; for update: the fields to change'},
            'k': {'type': 'integer', 'description': 'for update / remove: 1-based shot number'},
        }, ['action']),
    },
    {
        'name': 'stagehand_command',
        'description': 'Emit one of Stagehand\'s named commands: director_start / director_stop, glow_on / glow_off / glow_toggle, '
                       'hud_show / hud_hide / hud_toggle, hud_arm_play / hud_cancel, overview_apply / overview_restore / '
                       'overview_guided, recorder_arm / recorder_play / recorder_stop / recorder_layout / recorder_export, '
                       'settings_show, stems_show, stems_stop. Anything that changes the arrange or starts playback: confirm with the user first.',
        'inputSchema': _obj({'name': {'type': 'string'}}, ['name']),
    },
    {
        'name': 'stagehand_stems_render',
        'description': 'Start the stems batch (every enabled stem rendered one after another with Stagehand\'s render settings; '
                       'files land in the stems folder). This writes files and takes time: ALWAYS ask the user in the '
                       'conversation and pass confirm=true only after they said yes. Returns when the batch has started; poll '
                       'stagehand_status (modules.stems.batch_active) and read stagehand_results when it is done. "stop" '
                       'cancels a running batch after the current stem.',
        'inputSchema': _obj({
            'confirm': {'type': 'boolean', 'description': 'true only after the user confirmed in the conversation'},
            'stop': {'type': 'boolean', 'description': 'true to stop a running batch instead of starting one'},
        }),
    },
    {
        'name': 'stagehand_verbs',
        'description': 'List every verb the running Stagehand answers on its control protocol (the companions\' verbs included) '
                       'and the commands stagehand_command accepts.',
        'inputSchema': _obj({}),
    },
    {
        'name': 'stagehand_raw',
        'description': 'Send one raw control-protocol line and wait for a token (escape hatch for verbs without a tool, e.g. '
                       '"overview rect" -> RECT, "rect" -> RECT, "goto 12.5" -> GOTO, "shots json" -> SHOTS). Returns the token '
                       'line and the JSON reply when the verb wrote one. Use the typed tools when one exists.',
        'inputSchema': _obj({
            'line': {'type': 'string'}, 'token': {'type': 'string', 'description': 'the reply token to wait for'},
            'timeout_s': {'type': 'number'},
        }, ['line', 'token']),
    },
    {
        'name': 'stagehand_connect',
        'description': 'Connect to a specific Stagehand instead of the discovered one: pass the ctl folder (the Agent tab shows '
                       'it) or the project file path. Without arguments: report where the server currently connects and what '
                       'the discovery file says.',
        'inputSchema': _obj({'ctl_dir': {'type': 'string'}, 'project': {'type': 'string'}}),
    },
]


def find_key(args, *names):
    for n in names:
        if n in args and args[n] not in (None, ''):
            return args[n]
    return None


class Server:
    def __init__(self, conn):
        self.conn = conn

    # tool implementations return a JSON-serialisable value (dict / list / str)
    def call(self, name, args):
        args = args or {}
        c = self.conn
        if name == 'stagehand_connect':
            if args.get('ctl_dir') or args.get('project'):
                self.conn = Connection(ctl_dir=args.get('ctl_dir'), project=args.get('project'))
                ctl = self.conn.ctl()
                return {'connected': ctl.dir, 'hello': ctl.json('state', 'STATE').get('project')}
            d = read_discovery()
            out = {'discovery_file': discovery_path(), 'discovery': d, 'pinned': self.conn.pinned}
            try:
                ctl, _ = self.conn.resolve()
                out['resolved_ctl_dir'] = ctl.dir
            except CtlError as e:
                out['error'] = str(e)
            return out
        ctl = c.ctl()
        if name == 'stagehand_status':
            return ctl.json('state', 'STATE')
        if name == 'stagehand_census':
            return ctl.json('census', 'CENSUS', timeout=60)
        if name == 'stagehand_shots':
            return ctl.json('shotlist', 'SHOTLIST')
        if name == 'stagehand_stems':
            return ctl.json('stemset', 'STEMSET')
        if name == 'stagehand_results':
            return ctl.json('results', 'RESULTS')
        if name == 'stagehand_verbs':
            v = ctl.json('verbs', 'VERBS')
            h = ctl.json('hello ' + HELLO_NAME, 'HELLO')
            return {'verbs': v.get('verbs'), 'commands': h.get('commands')}
        if name == 'stagehand_config':
            action = args.get('action')
            key = (args.get('key') or '').strip()
            scope = args.get('scope') or 'project'
            if action == 'get':
                if not key:
                    raise CtlError('config get needs a key')
                return ctl.json('config get %s' % key, 'CONFIG')
            if action == 'list':
                return ctl.json(('config list %s' % key).rstrip(), 'CONFIG', timeout=30)
            if action == 'set':
                value = args.get('value')
                if not key or value is None or str(value) == '':
                    raise CtlError('config set needs key and value')
                return ctl.json('config set %s %s %s' % (key, value, scope), 'CONFIG')
            if action == 'reset':
                if not key:
                    raise CtlError('config reset needs a key')
                return ctl.json('config reset %s %s' % (key, scope), 'CONFIG')
            raise CtlError('config action must be get, list, set or reset')
        if name == 'stagehand_jump':
            if args.get('scene') not in (None, ''):
                return ctl.json('nav jump scene %s' % args['scene'], 'NAV')
            if args.get('marker') not in (None, ''):
                return ctl.json('nav jump marker %s' % args['marker'], 'NAV')
            if args.get('time_s') is not None:
                return ctl.json('nav jump time %s' % float(args['time_s']), 'NAV')
            raise CtlError('jump needs scene, marker or time_s')
        if name == 'stagehand_scene':
            action = args.get('action')
            if action in ('solo', 'mute'):
                if not args.get('scene'):
                    raise CtlError('%s needs a scene' % action)
                return ctl.json('nav %s %s' % (action, args['scene']), 'NAV')
            if action in ('clear', 'restore'):
                return ctl.json('nav %s' % action, 'NAV')
            raise CtlError('scene action must be solo, mute, clear or restore')
        if name == 'stagehand_director':
            action = args.get('action')
            if action == 'goto':
                if not args.get('shot'):
                    raise CtlError('goto needs a shot number')
                return ctl.json('director goto %d' % int(args['shot']), 'DIRECTOR')
            if action == 'auto':
                return ctl.json('director auto %s' % ('on' if args.get('on', True) else 'off'), 'DIRECTOR')
            if action in ('start', 'stop', 'next', 'prev', 'validate'):
                return ctl.json('director %s' % action, 'DIRECTOR')
            raise CtlError('director action must be start, stop, goto, next, prev, auto or validate')
        if name == 'stagehand_shots_set':
            action = args.get('action')
            if action == 'set':
                shots = args.get('shots')
                if not isinstance(shots, list):
                    raise CtlError('set needs a list of shots')
                return ctl.json('director shots set %s' % json.dumps(shots, separators=(',', ':')), 'DIRECTOR')
            if action == 'add':
                if not isinstance(args.get('shot'), dict):
                    raise CtlError('add needs a shot')
                return ctl.json('director shots add %s' % json.dumps(args['shot'], separators=(',', ':')), 'DIRECTOR')
            if action == 'update':
                if not args.get('k') or not isinstance(args.get('shot'), dict):
                    raise CtlError('update needs k and the fields to change')
                return ctl.json('director shots update %d %s' % (int(args['k']), json.dumps(args['shot'], separators=(',', ':'))), 'DIRECTOR')
            if action == 'remove':
                if not args.get('k'):
                    raise CtlError('remove needs k')
                return ctl.json('director shots remove %d' % int(args['k']), 'DIRECTOR')
            if action in ('clear', 'from_scenes'):
                return ctl.json('director shots %s' % action, 'DIRECTOR')
            raise CtlError('shots_set action must be set, add, update, remove, clear or from_scenes')
        if name == 'stagehand_command':
            cmd = (args.get('name') or '').strip()
            if not cmd:
                raise CtlError('command needs a name')
            return ctl.json('command %s' % cmd, 'COMMAND')
        if name == 'stagehand_stems_render':
            if args.get('stop'):
                tok, kv, rest, _ = ctl.ask('stems stop', 'STEMS_STOP')
                return {'token': tok, 'result': rest or kv}
            if args.get('confirm') is not True:
                raise CtlError('stems_render refused: the batch writes files and takes time. Ask the user in the conversation '
                               '(which stems, where they land, the format) and call again with confirm=true after a clear yes.')
            tok, kv, rest, _ = ctl.ask('stems render', 'STEMS_START', timeout=30)
            return {'token': tok, 'started': kv, 'hint': 'poll stagehand_status modules.stems.batch_active, then stagehand_results'}
        if name == 'stagehand_raw':
            line = (args.get('line') or '').strip()
            token = (args.get('token') or '').strip()
            if not line or not token:
                raise CtlError('raw needs line and token')
            tok, kv, rest, data = ctl.ask(line, token, timeout=float(args.get('timeout_s') or DEFAULT_TIMEOUT))
            return {'token': tok, 'kv': kv, 'text': rest, 'reply': data}
        raise CtlError('unknown tool ' + name)

    # --- JSON-RPC ------------------------------------------------------------------------------------------------------------
    def handle(self, msg):
        """One request -> one response dict (or None for a notification)."""
        method = msg.get('method')
        rid = msg.get('id')
        params = msg.get('params') or {}
        if method == 'initialize':
            want = params.get('protocolVersion')
            version = want if want in PROTOCOL_VERSIONS else PROTOCOL_VERSIONS[0]
            return self.result(rid, {
                'protocolVersion': version,
                'capabilities': {'tools': {'listChanged': False}},
                'serverInfo': {'name': SERVER_NAME, 'version': SERVER_VERSION},
                'instructions': 'Stagehand for REAPER. Read stagehand_status first. Never save the project. Confirm with the user '
                                'before anything that changes the session (jumps are fine; solo / mute, runs, config set, renders '
                                'are not) and pass confirm=true to stagehand_stems_render only after a clear yes. Every change '
                                'is journaled by Stagehand and restored like the user\'s own (stagehand_scene restore).',
            })
        if method == 'notifications/initialized' or (method or '').startswith('notifications/'):
            return None
        if method == 'ping':
            return self.result(rid, {})
        if method == 'tools/list':
            return self.result(rid, {'tools': TOOLS})
        if method == 'tools/call':
            name = params.get('name')
            args = params.get('arguments') or {}
            known = any(t['name'] == name for t in TOOLS)
            if not known:
                return self.error(rid, -32602, 'unknown tool: %s' % name)
            try:
                value = self.call(name, args)
                text = value if isinstance(value, str) else json.dumps(value, indent=1, ensure_ascii=False)
                return self.result(rid, {'content': [{'type': 'text', 'text': text}], 'isError': False})
            except CtlError as e:
                return self.result(rid, {'content': [{'type': 'text', 'text': 'Stagehand: %s' % e}], 'isError': True})
            except Exception as e:   # noqa: BLE001 - the agent must see the failure, the server must live on
                return self.result(rid, {'content': [{'type': 'text', 'text': 'stagehand_mcp: %s: %s' % (type(e).__name__, e)}], 'isError': True})
        if rid is None:
            return None
        return self.error(rid, -32601, 'method not found: %s' % method)

    @staticmethod
    def result(rid, value):
        return {'jsonrpc': '2.0', 'id': rid, 'result': value}

    @staticmethod
    def error(rid, code, message):
        return {'jsonrpc': '2.0', 'id': rid, 'error': {'code': code, 'message': message}}


def serve(conn):
    """The stdio transport: one JSON message per line in, one per line out."""
    server = Server(conn)
    out = sys.stdout
    for raw in sys.stdin:
        raw = raw.strip()
        if not raw:
            continue
        try:
            msg = json.loads(raw)
        except ValueError:
            out.write(json.dumps(Server.error(None, -32700, 'parse error')) + '\n')
            out.flush()
            continue
        msgs = msg if isinstance(msg, list) else [msg]
        for m in msgs:
            resp = server.handle(m)
            if resp is not None:
                out.write(json.dumps(resp, ensure_ascii=False) + '\n')
                out.flush()


# --- the self-test (the test companion) ------------------------------------------------------------------------------------------

def selftest(conn, out_path, log):
    server = Server(conn)
    v = {'ok': False, 'tools': len(TOOLS), 'calls': 0, 'failures': [], 'initialized': False}
    rid = [0]

    def rpc(method, params=None):
        rid[0] += 1
        return server.handle({'jsonrpc': '2.0', 'id': rid[0], 'method': method, 'params': params or {}})

    def tool(name, args=None):
        v['calls'] += 1
        r = rpc('tools/call', {'name': name, 'arguments': args or {}})
        res = r.get('result') or {}
        text = res.get('content', [{}])[0].get('text', '')
        log('%s %s -> %s%s' % (name, json.dumps(args or {}), 'ERROR ' if res.get('isError') else '', text[:160].replace('\n', ' ')))
        if res.get('isError'):
            return None, text
        try:
            return json.loads(text), text
        except ValueError:
            return text, text

    def expect(name, cond, detail=''):
        if cond:
            log('PASS ' + name)
        else:
            v['failures'].append(name + (' (' + str(detail) + ')' if detail else ''))
            log('FAIL ' + name + ' ' + str(detail))
        return cond

    r = rpc('initialize', {'protocolVersion': PROTOCOL_VERSIONS[0], 'capabilities': {}, 'clientInfo': {'name': 'selftest', 'version': '0'}})
    v['initialized'] = expect('initialize', r.get('result', {}).get('serverInfo', {}).get('name') == SERVER_NAME, r)
    rpc('notifications/initialized')
    r = rpc('tools/list')
    expect('tools/list', len(r.get('result', {}).get('tools', [])) == len(TOOLS))
    st, _ = tool('stagehand_status')
    v['status_ok'] = expect('status', isinstance(st, dict) and st.get('project', {}).get('tracks', 0) > 0)
    expect('hello named the agent', isinstance(st, dict) and st.get('agent', {}).get('name') == HELLO_NAME, st and st.get('agent'))
    cs, _ = tool('stagehand_census')
    v['census_ok'] = expect('census', isinstance(cs, dict) and len(cs.get('tracks', [])) == st['project']['tracks']
                            and len(cs.get('scenes', [])) == st['project']['regions'])
    sh, _ = tool('stagehand_shots')
    expect('shots', isinstance(sh, dict) and 'shots' in sh)
    ss, _ = tool('stagehand_stems')
    expect('stems', isinstance(ss, dict) and 'stems' in ss)
    rs, _ = tool('stagehand_results')
    expect('results', isinstance(rs, dict) and rs.get('loaded') is True)
    vb, _ = tool('stagehand_verbs')
    expect('verbs', isinstance(vb, dict) and 'state' in (vb.get('verbs') or []) and 'hud_show' in (vb.get('commands') or []))
    j, _ = tool('stagehand_jump', {'time_s': 7.25})
    st2, _ = tool('stagehand_status')
    v['jump_ok'] = expect('jump moved the cursor', isinstance(st2, dict) and abs(st2['transport']['cursor_s'] - 7.25) < 0.01,
                          st2 and st2.get('transport'))
    if cs and cs.get('scenes'):
        name = cs['scenes'][0]['name']
        j, _ = tool('stagehand_jump', {'scene': name})
        expect('jump to a scene by name', isinstance(j, dict) and j.get('scene') == name, j)
    _, text = tool('stagehand_stems_render', {})
    v['render_refused'] = expect('render refused without confirm', 'refused' in (text or ''), text)
    _, text = tool('stagehand_jump', {})
    expect('jump without arguments is an error', 'needs' in (text or ''), text)
    _, text = tool('stagehand_shots_set', {'action': 'remove', 'k': 9999})
    expect('shots_set: out-of-range remove is refused by Stagehand', 'needs' in (text or '') or 'refused' in (text or ''), text)
    _, text = tool('stagehand_shots_set', {'action': 'update'})
    expect('shots_set: update without k is an error', 'needs' in (text or ''), text)
    cg, _ = tool('stagehand_config', {'action': 'get', 'key': 'director.timing.lead_s'})
    before = cg and cg.get('entry', {}).get('value')
    cset, _ = tool('stagehand_config', {'action': 'set', 'key': 'director.timing.lead_s', 'value': '0.65'})
    cg2, _ = tool('stagehand_config', {'action': 'get', 'key': 'director.timing.lead_s'})
    _, bad = tool('stagehand_config', {'action': 'set', 'key': 'director.timing.lead_s', 'value': '42'})
    cr, _ = tool('stagehand_config', {'action': 'reset', 'key': 'director.timing.lead_s'})
    cg3, _ = tool('stagehand_config', {'action': 'get', 'key': 'director.timing.lead_s'})
    v['config_ok'] = expect('config round trip', isinstance(cg2, dict) and abs(float(cg2['entry']['value']) - 0.65) < 1e-9
                            and 'refused' in (bad or '') and isinstance(cg3, dict) and cg3['entry']['value'] == before
                            and cg3['entry'].get('override_project') is False, (cg2, bad, cg3))
    cl, _ = tool('stagehand_config', {'action': 'list', 'key': 'agent'})
    expect('config list agent', isinstance(cl, dict) and cl.get('n') == 4, cl and cl.get('n'))
    raw, _ = tool('stagehand_raw', {'line': 'ping', 'token': 'PONG'})
    v['raw_ok'] = expect('raw ping', isinstance(raw, dict) and raw.get('token') == 'PONG' and 'version' in raw.get('kv', {}), raw)
    r = rpc('tools/call', {'name': 'stagehand_nonsense', 'arguments': {}})
    v['unknown_tool_error'] = expect('unknown tool is a JSON-RPC error', 'error' in r, r)
    r = rpc('no/such/method')
    expect('unknown method is a JSON-RPC error', 'error' in r, r)
    if sh and sh.get('n', 0) > 0:
        d, _ = tool('stagehand_director', {'action': 'start'})
        expect('director start', isinstance(d, dict) and d.get('active') is True, d)
        time.sleep(0.5)
        d, _ = tool('stagehand_director', {'action': 'goto', 'shot': 2})
        expect('director goto 2', isinstance(d, dict) and d.get('current_k') == 2, d)
        time.sleep(0.3)
        d, _ = tool('stagehand_director', {'action': 'stop'})
        expect('director stop', isinstance(d, dict) and d.get('active') is False, d)
    else:
        log('no shots: the Director tools are not exercised')
    sc, _ = tool('stagehand_scene', {'action': 'clear'})
    expect('scene clear', isinstance(sc, dict) and sc.get('action') == 'clear', sc)
    v['ok'] = len(v['failures']) == 0
    v['summary'] = '%d tools, %d calls, %d failures%s' % (v['tools'], v['calls'], len(v['failures']),
                                                          (': ' + '; '.join(v['failures'])) if v['failures'] else '')
    tmp = out_path + '.tmp'
    with open(tmp, 'w', encoding='utf-8') as f:
        json.dump(v, f, indent=1)
    os.replace(tmp, out_path)
    log('verdict: ' + v['summary'])
    return 0 if v['ok'] else 1


def main():
    ap = argparse.ArgumentParser(description='Stagehand MCP server (stdio)')
    ap.add_argument('--ctl', help='the ctl folder (the Agent tab shows it); default: the discovery file')
    ap.add_argument('--project', help='the project file (.RPP); its Render/stagehand_ctl folder is used')
    ap.add_argument('--selftest', action='store_true', help='run the protocol in-process against a live Stagehand and write a verdict')
    ap.add_argument('--out', help='--selftest: the verdict JSON path')
    args = ap.parse_args()
    conn = Connection(ctl_dir=args.ctl, project=args.project)
    if args.selftest:
        out = args.out or 'agent_check.json'

        def log(s):
            sys.stderr.write(s + '\n')
            sys.stderr.flush()
        try:
            sys.exit(selftest(conn, out, log))
        except CtlError as e:
            log('selftest aborted: %s' % e)
            with open(out, 'w', encoding='utf-8') as f:
                json.dump({'ok': False, 'summary': str(e), 'failures': [str(e)], 'tools': len(TOOLS), 'calls': 0}, f, indent=1)
            sys.exit(2)
    serve(conn)


if __name__ == '__main__':
    main()
