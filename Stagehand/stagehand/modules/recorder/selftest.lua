-- modules/recorder/selftest.lua - the scripted Recorder scenario the test harness runs against the demo project.
-- The ctl protocol end to end through the files (ping, arm with the cursor / Director run / HUD bar / hud file,
-- rect, play with the sync tokens mirrored in order, quit), the screen layout at start (main window resized and
-- put back, the video window shown, placed and hidden again, the docker lookup), the checklist with a fix
-- through the journal, the shot-list export (JSON round trip, CSV rows) and import, restore diff 0. Variant
-- 'companion': the scenario then hands over to tools/record_showcase.py (started by the harness) and checks the
-- report it writes (two flashes found in the captured frames, an anchor). Sabotage 'leave_window' drops the
-- main window entry before the layout restore (the negative control: the rect check must go red).
-- Lua 5.4; no globals.

local layout = require('lib.layout')
local view = require('lib.view')
local config = require('config')
local journal = require('lib.journal')
local regions = require('lib.regions')
local json = require('lib.json')
local ctl = require('lib.ctl')
local js = require('platform.js')

local ST = {}

local app, S, RL, CL, EX, R

function ST.init(app_, S_, RL_, CL_, EX_, R_)
  app, S, RL, CL, EX, R = app_, S_, RL_, CL_, EX_, R_
end

local sep = package.config:sub(1, 1)

local function write_cmd(line)
  local p = ctl.path('cmd')
  local f = io.open(p, 'w')
  if not f then return false end
  f:write(line, '\n')
  f:close()
  return true
end

local function read_file(p)
  local f = io.open(p, 'r')
  if not f then return nil end
  local s = f:read('a')
  f:close()
  return s
end

local function state_has(token)
  local s = read_file(ctl.path('state')) or ''
  return s:find(' ' .. token, 1, true) ~= nil
end

local function state_tokens()
  local out = {}
  for line in (read_file(ctl.path('state')) or ''):gmatch('[^\n]+') do
    local tok = line:match('^%S+%s+(%S+)')
    if tok then out[#out + 1] = tok end
  end
  return out
end

local function index_of(list, want)
  for i, n in ipairs(list) do
    if n == want then return i end
  end
  return 0
end

local function count_lines(s, pattern)
  local n = 0
  for line in (s or ''):gmatch('[^\n]+') do
    if line:find(pattern) then n = n + 1 end
  end
  return n
end

-- send a command and wait for a reply token; returns true when it arrived within max_frames
local function ask(T, line, token, max_frames, name)
  T.ok(name .. ' (cmd written)', write_cmd(line), line)
  return T.wait_until(function() return state_has(token) end, max_frames or 60, name)
end

function ST.run(T)
  local companion = T.variant == 'companion'
  T.fact('variant', companion and 'companion' or 'demo')
  T.fact('sabotage', T.sabotage == '' and 'none' or T.sabotage)
  T.wait(2)
  reaper.OnStopButton()
  -- a known start: the mixer hidden (a run's post phase may have left it shown in the harness clone)
  local mixer_at_start = view.toggle_state(40078, 'mixer')
  if mixer_at_start == 1 then reaper.Main_OnCommand(40078, 0) end
  T.wait(3)
  local before = layout.dump()
  layout.write(T.out_path('layout_before.json'), before)
  local caps = app.caps
  T.fact('js', tostring(caps.js) .. ' move=' .. tostring(caps.window_move) .. ' viewport=' .. tostring(caps.viewport) .. ' dock_api=' .. tostring(caps.dock_api))

  -- 1. the ctl folder in the run's out dir --------------------------------------------------------------------------------
  config.set('recorder.ctl.dir', T.out_path('ctl'), 'project')
  config.set('recorder.ctl.poll_frames', 2, 'project')
  config.set('recorder.layout.apply', false, 'project')
  config.set('hud.dock', 'bottom', 'project'); config.set('hud.auto_show', true, 'project')
  config.set('hud.flash.frames', 3, 'project'); config.set('hud.flash.gap_frames', 6, 'project')
  config.set('hud.flash.end_mode', 'custom', 'project'); config.set('hud.flash.end_custom_s', 2.2, 'project')
  ctl.bind()
  ctl.clear_state()
  T.check('ctl folder available', ctl.available(), true)
  T.fact('ctl_dir', tostring(ctl.dir()))
  T.ok('ping answered with PONG', ask(T, 'ping', 'PONG', 30, 'ping'))
  T.ok('unknown verb reported', ask(T, 'frobnicate', 'UNKNOWN', 30, 'unknown'))

  -- 2. shots for the run (from the demo scenes) ------------------------------------------------------------------------------
  local dir = app.by_name['director']
  T.ok('director module present', dir ~= nil)
  local scenes = regions.scan(nil, 5)
  local n_shots = 0
  if dir then
    dir.MD.shots = {}
    for _, s in ipairs(dir.MD.from_scenes(scenes)) do dir.MD.shots[#dir.MD.shots + 1] = s end
    dir.MD.sort()
    dir.MD.save()
    n_shots = #dir.MD.shots
  end
  T.ok('shots from scenes', n_shots >= 3, tostring(n_shots))
  T.wait(2)
  T.check('director_shots event received', S.n_shots, n_shots)

  -- 3. arm: cursor, run, bar, hud file, ARMED ------------------------------------------------------------------------------------
  reaper.SetEditCurPos2(0, 12.5, false, false)
  T.ok('arm answered with ARMED', ask(T, 'arm', 'ARMED', 90, 'arm'))
  T.wait(2)
  T.check('arm put the cursor at 0', reaper.GetCursorPosition(), 0, 0.001)
  T.check('arm started the Director run', dir and dir.E.active or false, true)
  T.check('director_active seen', S.director_active, true)
  local hud = app.by_name['hud']
  T.check('arm showed the HUD bar', hud and hud.H.visible or false, true)
  local hud_text = read_file(ctl.path('hud')) or ''
  T.check('hud file has three lines', count_lines(hud_text, '^%a+ %-?%d+ %-?%d+ %-?%d+ %-?%d+$'), 3)
  local hl, ht, hr, hb = hud_text:match('hud (%-?%d+) (%-?%d+) (%-?%d+) (%-?%d+)')
  local ml, mt, mr, mb = hud_text:match('monitor (%-?%d+) (%-?%d+) (%-?%d+) (%-?%d+)')
  T.fact('hud_file', (hud_text:gsub('\n', ' ; ')))
  if hl and ml then
    hl, ht, hr, hb, ml, mt, mr, mb = tonumber(hl), tonumber(ht), tonumber(hr), tonumber(hb), tonumber(ml), tonumber(mt), tonumber(mr), tonumber(mb)
    T.ok('hud rect inside the monitor', hl >= ml - 2 and hr <= mr + 2 and ht >= mt - 2 and hb <= mb + 2, string.format('hud %d,%d-%d,%d monitor %d,%d-%d,%d', hl, ht, hr, hb, ml, mt, mr, mb))
    T.ok('hud rect has a size', hr - hl > 100 and hb - ht > 20, string.format('%dx%d', hr - hl, hb - ht))
  end
  T.ok('rect answered', ask(T, 'rect', 'RECT', 30, 'rect'))
  local st_text = read_file(ctl.path('state')) or ''
  T.ok('RECT line names main, arrange and hud', st_text:find('RECT main') and st_text:find('arrange') and st_text:find('hud'), (st_text:match('[^\n]*RECT[^\n]*') or ''))
  T.ok('SHOT token written for the first shot', state_has('SHOT k=1'))

  -- 4. play: the flash tokens through the state file ------------------------------------------------------------------------------
  T.ok('play ended with END', ask(T, 'play', 'END', 400, 'play'))
  T.wait(3)
  local toks = state_tokens()
  T.fact('tokens', table.concat(toks, ' '))
  T.ok('token order in the state file',
    index_of(toks, 'PLAY_REQUEST') > 0 and index_of(toks, 'FLASH_START') > index_of(toks, 'PLAY_REQUEST') and index_of(toks, 'PLAY_CMD') > index_of(toks, 'FLASH_START')
    and index_of(toks, 'PLAY_POS') > index_of(toks, 'PLAY_CMD') and index_of(toks, 'PLAY_MOVING') > index_of(toks, 'PLAY_POS')
    and index_of(toks, 'FLASH_END') > index_of(toks, 'PLAY_MOVING') and index_of(toks, 'END') > index_of(toks, 'FLASH_END'), table.concat(toks, ' '))
  st_text = read_file(ctl.path('state')) or ''
  local p_end = tonumber(st_text:match('FLASH_END pos=([%d.]+)'))
  T.ok('FLASH_END carries the play position', p_end ~= nil and p_end >= 2.2 and p_end < 2.5, tostring(p_end))
  T.check('transport stopped after END', view.playing(), false)

  -- 5. layout at start: main window, video window, docker lookup ---------------------------------------------------------------
  if caps.window_rects and caps.window_move and caps.viewport then
    local main = reaper.GetMainHwnd()
    local l0, t0, r0, b0 = js.rect(main)
    config.set('recorder.layout.monitor', 'current', 'project')
    config.set('recorder.layout.main_window', 'custom', 'project')
    config.set('recorder.layout.main_w', 900, 'project'); config.set('recorder.layout.main_h', 620, 'project')
    config.set('recorder.layout.video.show', true, 'project'); config.set('recorder.layout.video.place', 'top_right', 'project')
    config.set('recorder.layout.video.w', 320, 'project'); config.set('recorder.layout.video.h', 200, 'project')
    local mons = RL.scan_monitors()
    T.ok('monitors found', #mons >= 1, tostring(#mons))
    T.fact('monitors', (function() local p = {} for i, m in ipairs(mons) do p[#p + 1] = string.format('%d:%d,%d %dx%d', i, m.l, m.t, m.w, m.h) end return table.concat(p, ' ') end)())
    T.fact('dockers', RL.dockers_text())
    local bottom = RL.docker_index('bottom')
    local check_bottom = nil
    for i = 0, 15 do if reaper.DockGetPosition(i) == 0 then check_bottom = i; break end end
    T.check('docker lookup (bottom)', bottom, check_bottom)
    local ok, err = RL.apply('selftest')
    T.ok('layout applied', ok, tostring(err))
    T.wait(3)
    local l1, t1, r1, b1 = js.rect(main)
    T.ok('main window resized to 900x620 (+-40)', l1 and math.abs((r1 - l1) - 900) <= 40 and math.abs((b1 - t1) - 620) <= 40, string.format('%dx%d (was %dx%d)', (r1 or 0) - (l1 or 0), (b1 or 0) - (t1 or 0), r0 - l0, b0 - t0))
    T.check('video window toggle on', math.max(0, view.toggle_state(50125, 'video')), 1)
    T.wait_until(function() return RL.last.video ~= nil end, 40)
    T.wait(2)
    local v = RL.last.video
    if v and v.found then
      T.ok('video window placed top right (+-40)', v.now and math.abs(v.now[1] - v.want[1]) <= 40 and math.abs(v.now[2] - v.want[2]) <= 40, string.format('now %s wanted %s', v.now and table.concat(v.now, ',') or '?', table.concat(v.want, ',')))
      T.fact('video_rect', string.format('was=%s want=%s now=%s', v.was and table.concat(v.was, ',') or '?', table.concat(v.want, ','), v.now and table.concat(v.now, ',') or '?'))
    else
      T.fact('video_window', 'not found by title on this machine')
    end
    T.ok('window rect journaled', journal.has('window_rect', 'main'))
    if T.sabotage == 'leave_window' then
      journal.discard(function(e) return e.owner == 'recorder' and e.kind == 'window_rect' and e.key == 'main' end)
    end
    RL.restore('selftest')
    T.wait(3)
    local l2, t2, r2, b2 = js.rect(main)
    T.ok('main window rect restored', l2 == l0 and t2 == t0 and r2 == r0 and b2 == b0, string.format('now %d,%d-%d,%d was %d,%d-%d,%d', l2 or 0, t2 or 0, r2 or 0, b2 or 0, l0, t0, r0, b0))
    T.check('video window toggle back', math.max(0, view.toggle_state(50125, 'video')), 0)
    T.check('layout entries gone from the journal', journal.count(nil, 'recorder'), 0)
    T.fact('diary_lines', #RL.diary)
    for _, key in ipairs({ 'monitor', 'main_window', 'main_w', 'main_h', 'video.show', 'video.place', 'video.w', 'video.h' }) do config.reset('recorder.layout.' .. key, 'project') end
  else
    T.ok('layout at start needs js_ReaScriptAPI', false, 'missing on this machine')
  end

  -- 6. checklist with a fix through the journal ------------------------------------------------------------------------------------
  local mixer_before = view.toggle_state(40078, 'mixer')
  if mixer_before == 0 then reaper.Main_OnCommand(40078, 0) end
  T.wait(2)
  local rows = CL.rows()
  T.ok('checklist rows', #rows >= 10, tostring(#rows))
  local mixer_row
  for _, r in ipairs(rows) do if r.id == 'mixer' then mixer_row = r end end
  T.check('mixer row warns while the mixer shows', mixer_row and mixer_row.status, 'warn')
  T.ok('mixer row offers a fix', mixer_row and mixer_row.fix ~= nil)
  if mixer_row and mixer_row.fix then mixer_row.fix() end
  T.wait(2)
  T.check('fix hid the mixer', view.toggle_state(40078, 'mixer'), 0)
  T.check('fix journaled', journal.count('toggle', 'recorder'), 1)
  rows = CL.rows()
  for _, r in ipairs(rows) do if r.id == 'mixer' then mixer_row = r end end
  T.check('mixer row ok after the fix', mixer_row and mixer_row.status, 'ok')
  local ids = {}
  for _, r in ipairs(rows) do ids[#ids + 1] = r.id .. '=' .. r.status end
  T.fact('checklist', table.concat(ids, ' '))
  journal.restore(journal.owner_pred('recorder'))
  T.wait(2)
  T.check('mixer back after restore', view.toggle_state(40078, 'mixer'), 1)
  if mixer_before == 0 then reaper.Main_OnCommand(40078, 0) end

  -- 7. shot-list export and import ---------------------------------------------------------------------------------------------------
  local jpath = T.out_path('shots_export.json')
  local cpath = T.out_path('shots_export.csv')
  local p1, n1 = EX.export('json', jpath)
  T.check('JSON export written', p1, jpath)
  T.check('JSON export count', n1, n_shots)
  local back = json.decode(read_file(jpath) or '')
  T.check('JSON export parses', type(back) == 'table' and type(back.shots) == 'table', true)
  T.check('JSON export shots', back and back.shots and #back.shots or 0, n_shots)
  T.ok('JSON export carries timecodes', back and back.shots and back.shots[1] and type(back.shots[1].t0_tc) == 'string', back and back.shots and back.shots[1] and back.shots[1].t0_tc or '?')
  local p2 = EX.export('csv', cpath)
  T.check('CSV export written', p2, cpath)
  local csv = read_file(cpath) or ''
  T.check('CSV rows = shots + header', count_lines(csv, '.'), n_shots + 1)
  T.ok('CSV header', csv:match('^index,name,start,end,duration,start_tc') ~= nil)
  if dir then
    local first_name = dir.MD.shots[1].name
    local n_imp, ierr = EX.import(jpath, 'replace')
    T.check('JSON import count', n_imp, n_shots)
    T.check('JSON import keeps the shots', #dir.MD.shots, n_shots)
    T.check('JSON import keeps the names', dir.MD.shots[1].name, first_name)
    local n_app = EX.import(jpath, 'append')
    T.check('JSON import append', #dir.MD.shots, n_shots * 2)
    EX.import(jpath, 'replace')
    T.ok('shots list back', #dir.MD.shots == n_shots and n_app == n_shots)
  end

  -- 8. quit: run stopped, bar hidden, QUIT ---------------------------------------------------------------------------------------------
  T.ok('quit answered with QUIT', ask(T, 'quit', 'QUIT', 60, 'quit'))
  T.wait(3)
  T.check('quit stopped the Director run', dir and dir.E.active or false, false)
  T.check('quit hid the HUD bar (auto-show)', hud and hud.H.visible or false, false)

  -- 9. the companion driver (variant) --------------------------------------------------------------------------------------------------
  if companion then
    local report = T.out_path('rec') .. sep .. 'report.json'
    ctl.clear_state()
    local go = io.open(T.out_path('companion_go.txt'), 'w')
    if go then go:write('go\n'); go:close() end
    T.log('COMPANION waiting for tools/record_showcase.py on ctl ' .. tostring(ctl.dir()))
    local cs = ctl.status()
    local armed = T.wait_until(function() return state_has('ARMED') end, 2700, 'companion armed')
    local ended = armed and T.wait_until(function() return state_has('END') end, 1500, 'companion recorded to END')
    local quit = ended and T.wait_until(function() return cs.last_cmd == 'quit' end, 900, 'companion quit')
    local have = T.wait_until(function() local f = io.open(report, 'r'); if f then f:close(); return true end return false end, 1800, 'companion report written')
    if have then
      T.wait(5)
      local rep = json.decode(read_file(report) or '') or {}
      T.fact('report', string.format('fps=%s frames=%s start_flash=%s end_flash=%s t0=%s anchor=%s drift_ms=%s', tostring(rep.fps), tostring(rep.frames), rep.start_flash and json.encode(rep.start_flash) or 'nil', rep.end_flash and json.encode(rep.end_flash) or 'nil', tostring(rep.t0), tostring(rep.anchor), tostring(rep.drift_ms)))
      T.ok('report has both flashes', type(rep.start_flash) == 'table' and type(rep.end_flash) == 'table')
      T.ok('report anchors mix time 0', type(rep.t0) == 'number' and rep.t0 > 0, tostring(rep.t0))
      T.ok('end flash after the start flash', rep.start_flash and rep.end_flash and rep.end_flash[1] > rep.start_flash[2], '')
      if rep.drift_ms then T.ok('engine start latency within 300 ms', math.abs(rep.drift_ms) < 300, tostring(rep.drift_ms)) end
    end
    T.ok('companion round trip', armed and ended and quit and have, string.format('armed=%s ended=%s quit=%s report=%s', tostring(armed), tostring(ended), tostring(quit), tostring(have)))
  end

  -- 10. restore diff ---------------------------------------------------------------------------------------------------------------------
  if dir then dir.MD.clear() end
  T.wait(2)
  local after = layout.dump()
  layout.write(T.out_path('layout_after.json'), after)
  local diff = layout.diff(before, after)
  for i, d in ipairs(diff) do
    if i <= 20 then T.log('DIFF ' .. d) end
  end
  T.log('RESTORE_DIFF ' .. #diff)
  T.check('restore diff', #diff, 0)
  for _, key in ipairs({ 'ctl.dir', 'ctl.poll_frames', 'layout.apply' }) do config.reset('recorder.' .. key, 'project') end
  for _, key in ipairs({ 'dock', 'auto_show', 'flash.frames', 'flash.gap_frames', 'flash.end_mode', 'flash.end_custom_s' }) do config.reset('hud.' .. key, 'project') end
  T.fact('frame', T.frame())
end

-- after DONE: the tab with the checklist (shots from scenes and the mixer shown so a warning row appears), then armed
function ST.post(frames_since_done)
  if frames_since_done == 5 then
    app.set_tab('recorder')
    local dir = app.by_name['director']
    if dir and #dir.MD.shots == 0 then
      for _, s in ipairs(dir.MD.from_scenes(regions.scan(nil, 5))) do dir.MD.shots[#dir.MD.shots + 1] = s end
      dir.MD.sort()
      dir.MD.save()
    end
    if view.toggle_state(40078, 'mixer') == 0 then reaper.Main_OnCommand(40078, 0) end
  elseif frames_since_done == 100 then
    -- the mixer goes back early: the harness may kill REAPER before the last step and REAPER saves the
    -- toggle in the clone's ini, which would shrink the arrange of the next scenario (director regression, R2)
    if view.toggle_state(40078, 'mixer') == 1 then reaper.Main_OnCommand(40078, 0) end
  elseif frames_since_done == 110 then
    R.arm('post')
  elseif frames_since_done == 240 then
    R.quit('post')
    local dir = app.by_name['director']
    if dir then dir.MD.clear() end
  end
end

return ST
