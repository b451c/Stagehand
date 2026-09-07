-- modules/agent/selftest.lua - the scripted Agent scenario the test harness runs against the demo project.
-- Oracles: the API (track count, GUIDs, marker counts, the cursor, soloed
-- tracks, muted items), the Navigator's caches for the families, the schema for the config keys, the ctl
-- state file for the tokens, the reply files on disk, lib/layout.dump() before and after (restore diff 0).
-- Verbs are driven both through ctl.dispatch (synchronous) and through the cmd file (the Recorder's poll).
-- Variant 'companion': the scenario hands over to agent/stagehand_mcp.py --selftest (started by the harness),
-- which runs the MCP protocol in-process against this REAPER and writes agent_check.json; the scenario checks
-- its verdict. Sabotage 'ignore_gate' makes every gate say yes (the negative control: the refusal checks must
-- go red). Lua 5.4; no globals.

local layout = require('lib.layout')
local config = require('config')
local schema = require('schema')
local json = require('lib.json')
local ctl = require('lib.ctl')

local ST = {}

local app, S, M, API

function ST.init(app_, S_, M_, API_)
  app, S, M, API = app_, S_, M_, API_
end

local sep = package.config:sub(1, 1)

local function file_exists(p)
  local f = io.open(p, 'rb')
  if f then f:close(); return true end
  return false
end

local function read_file(p)
  local f = io.open(p, 'r')
  if not f then return nil end
  local s = f:read('a')
  f:close()
  return s
end

local function state_size()
  local f = io.open(ctl.path('state') or '', 'rb')
  if not f then return 0 end
  local n = f:seek('end')
  f:close()
  return n
end

-- the last line carrying the token after byte offset mark (or nil)
local function find_token(token, mark)
  local f = io.open(ctl.path('state') or '', 'rb')
  if not f then return nil end
  f:seek('set', mark)
  local hit
  for line in f:lines() do
    local tok = line:match('^%S+%s+(%S+)')
    if tok == token then hit = line end
  end
  f:close()
  return hit
end

local function parse_kv(line)
  local kv = {}
  for k, v in line:gmatch('(%w+)=(%S+)') do kv[k] = v end
  return kv
end

-- dispatch a line and read its JSON reply (or the ERROR line): returns tbl | nil, token_line
local function ask(line, token)
  local mark = state_size()
  ctl.dispatch(line, app.frame)
  local hit = find_token(token, mark)
  if not hit then return nil, find_token('ERROR', mark) end
  local kv = parse_kv(hit)
  local text = kv.file and read_file(ctl.dir() .. sep .. kv.file)
  local tbl = text and json.decode(text)
  return tbl, hit
end

-- the same through the cmd file (the Recorder polls it every few frames)
local function ask_file(T, line, token, max_frames)
  local mark = state_size()
  local p = ctl.path('cmd')
  local f = io.open(p .. '.tmp', 'w')
  f:write(line, '\n')
  f:close()
  os.remove(p)
  os.rename(p .. '.tmp', p)
  local hit
  T.wait_until(function()
    hit = find_token(token, mark) or find_token('ERROR', mark)
    return hit ~= nil
  end, max_frames or 90)
  if not hit or not hit:find(' ' .. token, 1, true) then return nil, hit end
  local kv = parse_kv(hit)
  local text = kv.file and read_file(ctl.dir() .. sep .. kv.file)
  return text and json.decode(text), hit
end

local function is_error(line)
  return line ~= nil and line:find(' ERROR ', 1, true) ~= nil
end

-- a refusal by a gate (the ERROR text says "refused"), as opposed to a handler's own error
local function is_refused(line)
  return is_error(line) and line:find('refused:', 1, true) ~= nil
end

local function count_soloed()
  local n = 0
  for k = 0, reaper.CountTracks(0) - 1 do
    if reaper.GetMediaTrackInfo_Value(reaper.GetTrack(0, k), 'I_SOLO') > 0 then n = n + 1 end
  end
  return n
end

local function count_muted_items()
  local n = 0
  for k = 0, reaper.CountMediaItems(0) - 1 do
    if reaper.GetMediaItemInfo_Value(reaper.GetMediaItem(0, k), 'B_MUTE') == 1 then n = n + 1 end
  end
  return n
end

local function schema_keys_with(prefix)
  local n = 0
  for _, e in ipairs(schema.keys) do
    if e.key == prefix or e.key:sub(1, #prefix + 1) == prefix .. '.' then n = n + 1 end
  end
  return n
end

function ST.run(T)
  local companion = T.variant == 'companion'
  T.fact('variant', companion and 'companion' or 'demo')
  T.fact('sabotage', T.sabotage == '' and 'none' or T.sabotage)
  S.ignore_gate = T.sabotage == 'ignore_gate'
  T.wait(2)
  app.set_tab('agent')
  config.set('recorder.ctl.dir', T.out_path('ctl'), 'project')   -- the harness fetches out/ctl with the evidence
  config.set('hud.auto_show', false, 'project')                   -- a run must not dock the bar (the arrange height would change)
  for _, key in ipairs({ 'agent.enable', 'agent.allow_changes', 'agent.allow_render' }) do config.reset(key, 'project') end
  ctl.bind()
  ctl.clear_state()
  T.fact('ctl_dir', tostring(ctl.dir()))

  local nav = app.by_name['navigator']
  local dir = app.by_name['director']
  local stems = app.by_name['stems']
  T.ok('navigator loaded', nav ~= nil and nav.D ~= nil)
  T.ok('director loaded', dir ~= nil and dir.MD ~= nil)
  local D, A, MD, E = nav.D, nav.A, dir.MD, dir.E

  -- 0. a known state, then the baseline dump --------------------------------------------------------------------------------------
  reaper.OnStopButton()
  A.clear_all()
  if E.active then E.stop('selftest') end
  MD.clear()
  T.wait(3)
  local before = layout.dump()
  layout.write(T.out_path('layout_before.json'), before)
  local n_tracks = reaper.CountTracks(0)
  local _, n_markers, n_regions = reaper.CountProjectMarkers(0)
  local solo0, muted0 = count_soloed(), count_muted_items()   -- the demo keeps two items muted on purpose: count deltas
  T.fact('tracks', n_tracks)
  T.fact('regions', n_regions)

  -- 1. hello and the verbs --------------------------------------------------------------------------------------------------------------
  local hello, hline = ask('hello Selftest agent', 'HELLO')
  T.ok('hello answered with a JSON reply', hello ~= nil, tostring(hline))
  T.check('hello names the agent', hello and hello.agent and hello.agent.name, 'Selftest agent')
  T.check('tab shows the connected agent', S.agent, 'Selftest agent')
  T.ok('hello lists the verbs', hello and type(hello.verbs) == 'table' and #hello.verbs >= 20, hello and #hello.verbs)
  T.ok('hello lists the commands', hello and type(hello.commands) == 'table' and #hello.commands >= 15, hello and #hello.commands)
  local verbs = ask('verbs', 'VERBS')
  T.check('verbs reply lists every registered verb', verbs and #verbs.verbs or -1, #ctl.verbs())
  local has = {}
  for _, v in ipairs(verbs and verbs.verbs or {}) do has[v] = true end
  for _, v in ipairs({ 'state', 'census', 'shotlist', 'stemset', 'results', 'config', 'nav', 'director', 'command', 'ping', 'stems', 'overview' }) do
    T.ok('verb registered: ' .. v, has[v] == true)
  end

  -- 2. state ---------------------------------------------------------------------------------------------------------------------------------
  local t0 = reaper.time_precise()
  local st, sline = ask('state', 'STATE')
  local state_ms = (reaper.time_precise() - t0) * 1000
  T.ok('state answered', st ~= nil, tostring(sline))
  T.check('state: track count', st and st.project.tracks, n_tracks)
  T.check('state: region count', st and st.project.regions, n_regions)
  T.check('state: marker count', st and st.project.markers, n_markers)
  T.ok('state: project saved with a ctl dir', st and st.project.saved == true and st.project.ctl_dir == ctl.dir())
  T.check('state: transport stopped', st and st.transport.playing, false)
  T.check('state: cursor', st and st.transport.cursor_s, reaper.GetCursorPosition(), 0.002)
  T.ok('state: every module reports loaded', st and st.modules.navigator.loaded and st.modules.director.loaded and st.modules.hud.loaded
    and st.modules.glow.loaded and st.modules.overview.loaded and st.modules.recorder.loaded and st.modules.stems.loaded)
  T.check('state: director idle', st and st.modules.director.active, false)
  T.check('state: agent name carried', st and st.agent and st.agent.name, 'Selftest agent')
  T.ok('state: journal counts present', st and type(st.journal.entries) == 'number')
  T.fact('state_ms', string.format('%.1f', state_ms))
  T.fact('state_bytes', sline and (parse_kv(sline).bytes or '?') or '?')

  -- 3. census ---------------------------------------------------------------------------------------------------------------------------------
  t0 = reaper.time_precise()
  local cs, cline = ask('census', 'CENSUS')
  local census_ms = (reaper.time_precise() - t0) * 1000
  T.ok('census answered', cs ~= nil, tostring(cline))
  T.check('census: track count', cs and cs.summary.tracks, n_tracks)
  T.check('census: track rows', cs and #cs.tracks, n_tracks)
  T.check('census: scenes', cs and #cs.scenes, n_regions)
  T.check('census: markers', cs and #cs.markers, n_markers)
  T.check('census: items', cs and cs.summary.items, reaper.CountMediaItems(0))
  local guid_ok, fam_sum, fam_ok = true, 0, true
  for k, row in ipairs(cs and cs.tracks or {}) do
    if row.guid ~= reaper.GetTrackGUID(reaper.GetTrack(0, k - 1)) then guid_ok = false end
  end
  T.ok('census: every track GUID matches the API', guid_ok)
  for _, f in ipairs(cs and cs.families or {}) do
    fam_sum = fam_sum + (f.tracks or 0)
    if (D.family_count[f.name] or 0) ~= (f.tracks or 0) then fam_ok = false end
  end
  T.check('census: family histogram sums to the track count', fam_sum, n_tracks)
  T.ok('census: family histogram equals the Navigator\'s', fam_ok)
  local scene_items_ok = true
  for k, s in ipairs(cs and cs.scenes or {}) do
    if not D.scenes[k] or D.scenes[k].name ~= s.name or D.scenes[k].items ~= s.items then scene_items_ok = false end
  end
  T.ok('census: scene names and item counts equal the Navigator\'s', scene_items_ok)
  local folders = 0
  for k = 0, n_tracks - 1 do
    if reaper.GetMediaTrackInfo_Value(reaper.GetTrack(0, k), 'I_FOLDERDEPTH') == 1 then folders = folders + 1 end
  end
  T.check('census: folder count', cs and cs.summary.folders, folders)
  T.fact('census_ms', string.format('%.1f', census_ms))
  T.fact('census_bytes', cline and (parse_kv(cline).bytes or '?') or '?')

  -- 4. shot list -----------------------------------------------------------------------------------------------------------------------------
  local sl = ask('shotlist', 'SHOTLIST')
  T.check('shotlist: empty list', sl and sl.n, 0)
  for _, s in ipairs(MD.from_scenes(D.scenes)) do MD.add(s) end
  T.wait(2)
  sl = ask('shotlist', 'SHOTLIST')
  T.check('shotlist: one shot per scene', sl and sl.n, #D.scenes)
  T.check('shotlist: names from the scenes', sl and sl.shots[3] and sl.shots[3].name, D.scenes[3].name)
  T.ok('shotlist: issues and counts present', sl and type(sl.issues) == 'table' and type(sl.counts) == 'table')
  T.check('shotlist: run idle', sl and sl.run.active, false)

  -- 5. stem set and results --------------------------------------------------------------------------------------------------------------------
  local ss = ask('stemset', 'STEMSET')
  T.ok('stemset answered', ss ~= nil and ss.loaded == true)
  T.check('stemset: count', ss and ss.n, stems and #stems.MD.stems or -1)
  T.ok('stemset: render settings present', ss and ss.render and ss.render.format ~= nil)
  local rs = ask('results', 'RESULTS')
  T.ok('results answered', rs ~= nil and rs.loaded == true)

  -- 6. config --------------------------------------------------------------------------------------------------------------------------------
  local cg = ask('config get director.timing.lead_s', 'CONFIG')
  T.check('config get: type', cg and cg.entry.type, 'num')
  T.check('config get: value', cg and cg.entry.value, config.get('director.timing.lead_s'), 1e-9)
  local before_lead = config.get('director.timing.lead_s')
  local cset = ask('config set director.timing.lead_s 0.7', 'CONFIG')
  T.check('config set: value written', config.get('director.timing.lead_s'), 0.7, 1e-9)
  T.check('config set: reply scope project', cset and cset.entry.scope, 'project')
  T.ok('config set: override visible', cset and cset.entry.override_project == true)
  local _, eline = ask('config set director.timing.lead_s 9', 'CONFIG')
  T.ok('config set: out of range refused', is_error(eline), tostring(eline))
  T.check('config set: value kept after the refusal', config.get('director.timing.lead_s'), 0.7, 1e-9)
  _, eline = ask('config set director.timing.lead_s abc', 'CONFIG')
  T.ok('config set: not a number refused', is_error(eline), tostring(eline))
  ask('config set navigator.jump.time_selection off', 'CONFIG')
  T.check('config set: bool off', config.get('navigator.jump.time_selection'), false)
  ask('config set navigator.jump.time_selection on', 'CONFIG')
  T.check('config set: bool on', config.get('navigator.jump.time_selection'), true)
  ask('config set director.view.mode follow', 'CONFIG')
  T.check('config set: enum', config.get('director.view.mode'), 'follow')
  _, eline = ask('config set director.view.mode sideways', 'CONFIG')
  T.ok('config set: bad enum refused', is_error(eline), tostring(eline))
  _, eline = ask('config set nosuch.key 1', 'CONFIG')
  T.ok('config set: unknown key refused', is_error(eline), tostring(eline))
  ask('config set hud.font.title_px 18 global', 'CONFIG')
  T.ok('config set: global scope', config.has_override('hud.font.title_px', 'global') == true)
  config.reset('hud.font.title_px', 'global')
  local cl = ask('config list director.view', 'CONFIG')
  T.check('config list: keys under a prefix', cl and cl.n, schema_keys_with('director.view'))
  cl = ask('config list', 'CONFIG')
  T.check('config list: every key', cl and cl.n, #schema.keys)
  local cr = ask('config reset director.timing.lead_s', 'CONFIG')
  T.ok('config reset: override removed', cr and cr.entry.removed == true)
  T.check('config reset: value back', config.get('director.timing.lead_s'), before_lead, 1e-9)
  ask('config reset director.view.mode', 'CONFIG')
  ask('config reset navigator.jump.time_selection', 'CONFIG')

  -- 7. navigator actions ---------------------------------------------------------------------------------------------------------------------
  local sc3, sc4 = D.scenes[3], D.scenes[4]
  local nj = ask('nav jump scene ' .. sc3.name, 'NAV')
  T.check('nav jump scene: reply names the scene', nj and nj.scene, sc3.name)
  T.check('nav jump scene: cursor at the start', reaper.GetCursorPosition(), sc3.t0, 0.002)
  nj = ask('nav jump scene 2', 'NAV')
  T.check('nav jump scene by number', reaper.GetCursorPosition(), D.scenes[2].t0, 0.002)
  local mk = D.markers[2]
  nj = ask('nav jump marker ' .. mk.name, 'NAV')
  T.check('nav jump marker: cursor', reaper.GetCursorPosition(), mk.t0, 0.002)
  nj = ask('nav jump time 12.5', 'NAV')
  T.check('nav jump time: cursor', reaper.GetCursorPosition(), 12.5, 0.002)
  _, eline = ask('nav jump scene No such scene anywhere', 'NAV')
  T.ok('nav jump: unknown scene refused', is_error(eline), tostring(eline))
  local ns = ask('nav solo ' .. sc4.name, 'NAV')
  T.ok('nav solo: some tracks soloed', ns and (ns.n or 0) > 0, ns and ns.n)
  T.check('nav solo: reply count equals the soloed tracks', ns and ns.n, count_soloed() - solo0)
  T.check('nav solo: scene reported', ns and ns.solo_scene, sc4.name)
  local nm = ask('nav mute ' .. sc4.name, 'NAV')
  T.ok('nav mute: some items muted', nm and (nm.n or 0) > 0, nm and nm.n)
  T.check('nav mute: reply count equals the newly muted items', nm and nm.n, count_muted_items() - muted0)
  local st2 = ask('state', 'STATE')
  T.check('state: solo scene reported', st2 and st2.modules.navigator.solo_scene, sc4.name)
  T.check('state: mute scene reported', st2 and st2.modules.navigator.mute_scene, sc4.name)
  local nc = ask('nav clear', 'NAV')
  T.check('nav clear: solo count back to the baseline', count_soloed(), solo0)
  T.check('nav clear: muted items back to the baseline (the user\'s own stay)', count_muted_items(), muted0)
  T.ok('nav clear: reply has no solo scene', nc and nc.solo_scene == nil)
  T.fact('solo_tracks', ns and ns.n or -1)
  T.fact('mute_items', nm and nm.n or -1)

  -- 8. director actions ------------------------------------------------------------------------------------------------------------------------
  local dr = ask('director start', 'DIRECTOR')
  T.check('director start: active', dr and dr.active, true)
  T.ok('director start: DIRECTOR_START token in the state', find_token('DIRECTOR_START', 0) ~= nil)
  T.wait(3)
  dr = ask('director goto 3', 'DIRECTOR')
  T.check('director goto: current shot', dr and dr.current_k, 3)
  T.wait(2)
  dr = ask('director next', 'DIRECTOR')
  T.check('director next', dr and dr.current_k, 4)
  T.wait(2)
  dr = ask('director prev', 'DIRECTOR')
  T.check('director prev', dr and dr.current_k, 3)
  dr = ask('director auto off', 'DIRECTOR')
  T.check('director auto off', dr and dr.auto, false)
  dr = ask('director auto on', 'DIRECTOR')
  T.check('director auto on', dr and dr.auto, true)
  _, eline = ask('director goto 99', 'DIRECTOR')
  T.ok('director goto: out of range refused', is_error(eline), tostring(eline))
  T.wait(2)
  dr = ask('director stop', 'DIRECTOR')
  T.check('director stop: idle', dr and dr.active, false)
  T.ok('director stop: DIRECTOR_STOP token in the state', find_token('DIRECTOR_STOP', 0) ~= nil)
  T.wait(20)   -- the view animation and the transport settle

  -- 9. commands ------------------------------------------------------------------------------------------------------------------------------
  local hud = app.by_name['hud']
  local cmd = ask('command hud_show', 'COMMAND')
  T.wait(3)
  T.ok('command hud_show: the bar is visible', hud and hud.H.visible == true)
  T.ok('command reply carries the modules', cmd and cmd.modules and cmd.modules.hud ~= nil)
  ask('command hud_hide', 'COMMAND')
  T.wait(5)
  T.ok('command hud_hide: the bar is hidden', hud and hud.H.visible == false)
  _, eline = ask('command bogus_thing', 'COMMAND')
  T.ok('command: unknown name refused', is_error(eline), tostring(eline))
  ask('command settings_show', 'COMMAND')
  T.wait(3)
  T.check('command settings_show: tab switched', app.tab, 'settings')
  app.set_tab('agent')
  T.wait(2)

  -- 10. the gates ------------------------------------------------------------------------------------------------------------------------------
  if stems then stems.MD.clear() end   -- a gate that leaks (the negative control) must hit the pre-flight, never a render
  config.set('agent.allow_changes', false, 'project')
  local cur = reaper.GetCursorPosition()
  _, eline = ask('nav jump time 3', 'NAV')
  T.ok('changes off: nav refused', is_refused(eline), tostring(eline))
  T.check('changes off: cursor untouched', reaper.GetCursorPosition(), cur, 0.001)
  _, eline = ask('director start', 'DIRECTOR')
  T.ok('changes off: director refused', is_refused(eline), tostring(eline))
  T.check('changes off: no run started', E.active, false)
  _, eline = ask('command hud_show', 'COMMAND')
  T.ok('changes off: command refused', is_refused(eline), tostring(eline))
  _, eline = ask('config set director.timing.lead_s 0.5', 'CONFIG')
  T.ok('changes off: config set refused', is_refused(eline), tostring(eline))
  T.check('changes off: config untouched', config.get('director.timing.lead_s'), before_lead, 1e-9)
  _, eline = ask('goto 5', 'GOTO')
  T.ok('changes off: the recorder\'s goto refused too', is_refused(eline), tostring(eline))
  T.check('changes off: cursor still untouched', reaper.GetCursorPosition(), cur, 0.001)
  _, eline = ask('stems render', 'STEMS_START')
  T.ok('changes off: stems render refused', is_refused(eline), tostring(eline))
  T.check('changes off: no batch started', stems and stems.E.active or false, false)
  local st3 = ask('state', 'STATE')
  T.ok('changes off: reads still answer', st3 ~= nil and st3.agent.allow_changes == false)
  ask('config get agent.allow_changes', 'CONFIG')
  config.reset('agent.allow_changes', 'project')
  config.set('agent.allow_render', false, 'project')
  _, eline = ask('stems render', 'STEMS_START')
  T.ok('render off: stems render refused', is_refused(eline), tostring(eline))
  T.check('render off: no batch started', stems and stems.E.active or false, false)
  nj = ask('nav jump time 4.25', 'NAV')
  T.check('render off: other changes still allowed', reaper.GetCursorPosition(), 4.25, 0.002)
  config.reset('agent.allow_render', 'project')
  config.set('agent.enable', false, 'project')
  _, eline = ask('state', 'STATE')
  T.ok('agent off: state refused', is_refused(eline), tostring(eline))
  _, eline = ask('hello Nobody', 'HELLO')
  T.ok('agent off: hello refused', is_refused(eline), tostring(eline))
  T.check('agent off: the agent name stays', S.agent, 'Selftest agent')
  local mark = state_size()
  ctl.dispatch('ping', app.frame)
  T.ok('agent off: the companions\' ping still answers', find_token('PONG', mark) ~= nil)
  config.reset('agent.enable', 'project')
  st3 = ask('state', 'STATE')
  T.ok('agent on again: state answers', st3 ~= nil)
  T.fact('refused', S.n_refused)

  if E.active then E.stop('selftest') end   -- a leaking gate (the negative control) may have started a run
  T.wait(3)

  -- 11. the file round trip and the reply rotation ------------------------------------------------------------------------------------------------
  local sf, fline = ask_file(T, 'state', 'STATE', 90)
  T.ok('cmd file: state answered through the poll', sf ~= nil, tostring(fline))
  T.check('cmd file: track count', sf and sf.project.tracks, n_tracks)
  local cs2 = ctl.status()
  T.ok('replies rotate: the first reply file is gone', (cs2.n_replies or 0) > 12 and not file_exists(ctl.dir() .. sep .. 'reply_1.json'), cs2.n_replies)
  T.ok('replies rotate: the last reply file exists', file_exists(ctl.dir() .. sep .. 'reply_' .. tostring(cs2.n_replies) .. '.json'))
  T.fact('replies', cs2.n_replies or 0)

  -- 12. the discovery file -----------------------------------------------------------------------------------------------------------------------
  local dp = M.discovery_path()
  T.ok('discovery file written', dp ~= nil and file_exists(dp), tostring(dp))
  local dj = dp and json.decode(read_file(dp) or '')
  T.check('discovery: ctl dir', dj and dj.ctl, ctl.dir())
  T.ok('discovery: fresh stamp', dj and math.abs(os.time() - (dj.stamp or 0)) < 60, dj and dj.stamp)
  T.ok('discovery: running flag', dj and dj.running == true)

  -- 13. the companion (variant) -----------------------------------------------------------------------------------------------------------------
  if companion then
    local go = io.open(T.out_path('companion_go.txt'), 'w')
    if go then go:write(tostring(ctl.dir()), '\n'); go:close() end
    T.log('COMPANION GO ' .. tostring(ctl.dir()))
    local check_path = T.out_path('agent_check.json')
    local arrived = T.wait_until(function() return file_exists(check_path) end, 3000, 'agent_check.json written by the companion')
    if arrived then
      T.wait(5)
      local v = json.decode(read_file(check_path) or '')
      T.ok('companion verdict ok', type(v) == 'table' and v.ok == true, v and tostring(v.summary) or 'no json')
      if type(v) == 'table' then
        T.fact('companion_tools', v.tools or 0)
        T.fact('companion_calls', v.calls or 0)
        T.fact('companion_failures', v.failures and #v.failures or -1)
        T.ok('companion: at least 12 tools', (v.tools or 0) >= 12, v.tools)
        T.ok('companion: initialize handshake', v.initialized == true)
        T.ok('companion: status read', v.status_ok == true)
        T.ok('companion: census read', v.census_ok == true)
        T.ok('companion: jump moved the cursor', v.jump_ok == true)
        T.ok('companion: render refused without confirmation', v.render_refused == true)
        T.ok('companion: config round trip', v.config_ok == true)
        T.ok('companion: raw verb', v.raw_ok == true)
        T.ok('companion: unknown tool is an error', v.unknown_tool_error == true)
        T.check('companion: agent name from hello', S.agent, 'MCP agent')
      end
    end
    reaper.OnStopButton()
    T.wait(5)
    if E.active then E.stop('selftest') end
    A.clear_all()
  end

  -- 14. restore diff ----------------------------------------------------------------------------------------------------------------------------
  MD.clear()
  T.wait(20)
  local after = layout.dump()
  layout.write(T.out_path('layout_after.json'), after)
  local diff = layout.diff(before, after)
  for i, d in ipairs(diff) do
    if i <= 20 then T.log('DIFF ' .. d) end
  end
  T.log('RESTORE_DIFF ' .. #diff)
  T.check('restore diff', #diff, 0)
  for _, key in ipairs({ 'director.timing.lead_s', 'director.view.mode', 'navigator.jump.time_selection', 'hud.auto_show', 'agent.enable', 'agent.allow_changes', 'agent.allow_render' }) do
    config.reset(key, 'project')
  end
  T.fact('agent_commands', S.n_cmds)

  -- 15. the support links of the About tab (BRIEF 3.12): three https links and the opener (SWS or the clipboard)
  local links = app.support_links or {}
  T.check('about: three support links', #links, 3)
  local https = true
  for _, l in ipairs(links) do
    if type(l.url) ~= 'string' or not l.url:match('^https://') or type(l.label) ~= 'string' then https = false end
  end
  T.ok('about: every support link is https with a label', https)
  T.ok('about: open_url exists', type(app.open_url) == 'function')
end

-- after DONE: the tab with the connected agent and its last commands, then the About tab with the support buttons
function ST.post(frames_since_done)
  if frames_since_done == 1 then app.set_tab('agent') end
  if frames_since_done == 120 then app.set_tab('about') end
end

return ST
