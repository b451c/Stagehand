-- modules/agent/init.lua - agent access (BRIEF 3.11): the control protocol (lib/ctl) grows read verbs with JSON
-- replies (state, census, shotlist, stemset, results, config get / list) and a few action verbs an agent needs
-- (nav jump / solo / mute / clear, director start / stop / goto / next / prev / auto, command <name>, config
-- set / reset), all gated by three switches the user owns (agent.enable, agent.allow_changes, agent.allow_render).
-- The MCP server (agent/stagehand_mcp.py, shipped in the package) and the skill (agent/skills/stagehand/) sit on
-- top of these verbs; the tab shows the installed paths, the connected agent and its last commands. A discovery
-- file (<home>/.stagehand/agent.json, refreshed while the app runs) tells the server where the ctl folder of the
-- open project is, so the MCP needs no arguments. Every change goes through the modules' own journaled paths
-- (the Navigator's actions, the Director's engine, config.set); nothing here saves the project or renders on
-- its own. Module contract (docs/architecture.md section 3): init, tick, draw, selftest, restore, shutdown.
-- Lua 5.4; no globals.

local log = require('lib.log')
local config = require('config')
local ctl = require('lib.ctl')
local state = require('state')
local view = require('lib.view')
local json = require('lib.json')
local i18n = require('i18n')
local API = require('modules.agent.api')
local U = require('modules.agent.ui')
local ST = require('modules.agent.selftest')

local t = i18n.t

local S = {
  msg = '', msg_frames = 0, compact = false,
  agent = nil, agent_t = nil,          -- the agent that said hello (name) and when
  last = {},                            -- ring of the last agent commands { line, t, ok, token }
  n_cmds = 0, n_refused = 0, discovery_path = nil, discovery_frame = -1000, discovery_err = nil,
}

local RING_MAX = 12
local DISCOVERY_FRAMES = 150   -- the discovery file is refreshed every 5 s at 30 fps (the server treats an old stamp as "not running")

local M = { name = 'agent', title = t('agent.title') }

local app

-- the app commands an agent may emit through "command <name>" (the modules' own vocabulary, nothing else)
local COMMANDS = {
  director_start = true, director_stop = true, glow_on = true, glow_off = true, glow_toggle = true,
  hud_show = true, hud_hide = true, hud_toggle = true, hud_arm_play = true, hud_cancel = true,
  overview_apply = true, overview_restore = true, overview_guided = true,
  recorder_arm = true, recorder_play = true, recorder_stop = true, recorder_layout = true, recorder_export = true,
  settings_show = true, stems_show = true, stems_stop = true,
}

-- the verbs of other modules that change the project, gated by agent.allow_changes together with our own; the
-- value is a pattern of the sub-verbs that change something ('' = the whole verb). stop / quit / unlayout /
-- overview restore put things back and stay open: a driver must always be able to stop.
local MUTATING = { arm = '', play = '', layout = '', vid = '', glow = '', ['goto'] = '', overview = '^apply', stems = '^render' }

function M.say(msg)
  S.msg = msg
  S.msg_frames = 40
end

local function remember(line, ok, token)
  S.n_cmds = S.n_cmds + 1
  if not ok then S.n_refused = S.n_refused + 1 end
  S.last[#S.last + 1] = { line = line, t = reaper.time_precise(), ok = ok, token = token }
  if #S.last > RING_MAX then table.remove(S.last, 1) end
end

local function refuse(verb, why)
  ctl.write('ERROR', verb .. ' refused: ' .. why)
  remember(S.cur_line or verb, false, 'ERROR')
  log.info('agent: %s refused (%s)', verb, why)
  return false
end

local function agent_info()
  return { name = S.agent, since_s = S.agent_t and (reaper.time_precise() - S.agent_t) or nil, commands = S.n_cmds, refused = S.n_refused,
    enable = config.get('agent.enable') ~= false, allow_changes = config.get('agent.allow_changes') ~= false, allow_render = config.get('agent.allow_render') ~= false }
end

-- gates ---------------------------------------------------------------------------------------------------------------------------

-- the self-test's negative control (sabotage ignore_gate) makes every gate say yes: the refusal checks must go red
local function enabled()
  return S.ignore_gate == true or config.get('agent.enable') ~= false
end

local function changes_allowed()
  return S.ignore_gate == true or config.get('agent.allow_changes') ~= false
end

local function render_allowed()
  return S.ignore_gate == true or (changes_allowed() and config.get('agent.allow_render') ~= false)
end

-- wrap a verb of another module so the user's switches apply to every driver, not only to ours
local function guard(verb, pattern)
  local prev = ctl.handler(verb)
  if not prev then return end
  ctl.on(verb, function(args, line)
    S.cur_line = line
    local hit = pattern == '' or (args or ''):match(pattern) ~= nil
    if hit and verb == 'stems' and not render_allowed() then return refuse(verb, t('agent.refused.render')) end
    if hit and not changes_allowed() then return refuse(verb, t('agent.refused.changes')) end
    return prev(args, line)
  end)
end

-- verbs ------------------------------------------------------------------------------------------------------------------------------

local function reply(token, tbl, line)
  local path = ctl.reply(token, tbl)
  remember(line, path ~= nil, token)
  return path
end

local function verb_hello(args, line)
  local name = (args or ''):match('^%s*(.-)%s*$')
  if name == '' then name = 'agent' end
  S.agent, S.agent_t = name, reaper.time_precise()
  log.info('agent connected: %s', name)
  M.say(string.format(t('agent.msg.connected'), name))
  reply('HELLO', { agent = agent_info(), stagehand = { version = app.version, reaper = reaper.GetAppVersion(), os = reaper.GetOS() },
    project = API.project(), verbs = ctl.verbs(), commands = (function()
      local out = {}
      for k in pairs(COMMANDS) do out[#out + 1] = k end
      table.sort(out)
      return out
    end)() }, line)
end

local function nav()
  local m = app.by_name['navigator']
  if not m or not m.D then return nil end
  m.D.check_refresh()
  return m
end

local function find_scene(D, what)
  what = (what or ''):match('^%s*(.-)%s*$')
  local k = tonumber(what)
  if k and D.scenes[k] then return D.scenes[k] end
  local lower = what:lower()
  local partial
  for _, s in ipairs(D.scenes) do
    if s.name == what then return s end
    if s.name:lower() == lower then partial = partial or s end
  end
  if partial then return partial end
  for _, s in ipairs(D.scenes) do
    if s.name:lower():find(lower, 1, true) then return s end
  end
  return nil
end

local function find_marker(D, what)
  what = (what or ''):match('^%s*(.-)%s*$')
  local k = tonumber(what)
  if k and D.markers[k] then return D.markers[k] end
  local lower = what:lower()
  for _, m in ipairs(D.markers) do
    if m.name:lower() == lower then return m end
  end
  for _, m in ipairs(D.markers) do
    if m.name:lower():find(lower, 1, true) then return m end
  end
  return nil
end

local function verb_nav(args, line)
  if not changes_allowed() then return refuse('nav', t('agent.refused.changes')) end
  local m = nav()
  if not m then return refuse('nav', 'navigator not loaded') end
  local D, A = m.D, m.A
  local action, rest = (args or ''):match('^(%S+)%s*(.*)$')
  local out = { action = action }
  if action == 'jump' then
    local kind, what = rest:match('^(%S+)%s*(.*)$')
    if kind == 'scene' then
      local s = find_scene(D, what)
      if not s then return refuse('nav', 'no scene "' .. tostring(what) .. '"') end
      A.jump_scene(s)
      out.scene, out.t0, out.t1 = s.name, s.t0, s.t1
    elseif kind == 'marker' then
      local mk = find_marker(D, what)
      if not mk then return refuse('nav', 'no marker "' .. tostring(what) .. '"') end
      A.jump_marker(mk)
      out.marker, out.t0 = mk.name, mk.t0
    elseif kind == 'time' then
      local pos = tonumber(what)
      if not pos then return refuse('nav', 'jump time needs seconds') end
      view.set_cursor(pos, true)
      out.t0 = pos
    else
      return refuse('nav', 'jump scene <name|k> | marker <name|k> | time <s>')
    end
  elseif action == 'solo' or action == 'mute' then
    local s = find_scene(D, rest)
    if not s then return refuse('nav', 'no scene "' .. tostring(rest) .. '"') end
    out.scene = s.name
    out.n = action == 'solo' and A.solo_scene(s) or A.mute_scene(s)
  elseif action == 'clear' then
    A.clear_all()
    out.solo_scene, out.mute_scene = A.solo_scene_name, A.mute_scene_name
  elseif action == 'restore' then
    local stats = A.restore_all()
    out.restored, out.kept, out.gone = stats.restored, stats.kept, stats.gone
  else
    return refuse('nav', 'jump | solo <scene> | mute <scene> | clear | restore')
  end
  out.cursor_s = reaper.GetCursorPosition()
  out.solo_scene, out.mute_scene = A.solo_scene_name, A.mute_scene_name
  reply('NAV', out, line)
  return true
end

local function verb_director(args, line)
  if not changes_allowed() then return refuse('director', t('agent.refused.changes')) end
  local m = app.by_name['director']
  if not m or not m.E then return refuse('director', 'director not loaded') end
  local E, MD = m.E, m.MD
  local action, rest = (args or ''):match('^(%S+)%s*(.*)$')
  if action == 'start' then
    if #MD.shots == 0 then return refuse('director', 'no shots') end
    if not E.active then E.start('agent') end
  elseif action == 'stop' then
    if E.active then E.stop('agent') end
  elseif action == 'goto' then
    local k = tonumber(rest)
    if not k or not MD.shots[k] then return refuse('director', 'goto needs a shot number 1..' .. #MD.shots) end
    E.goto_shot(k)
  elseif action == 'next' then E.next_shot()
  elseif action == 'prev' then E.prev_shot()
  elseif action == 'auto' then E.set_auto(rest == 'on')
  elseif action == 'validate' then
    if m.U and m.U.validate then m.U.validate() end
  else
    return refuse('director', 'start | stop | goto <k> | next | prev | auto on|off | validate')
  end
  local k, s = E.current()
  reply('DIRECTOR', { action = action, active = E.active == true, auto = E.auto == true, current_k = k, current_name = s and s.name or nil,
    shots = #MD.shots, issues = m.S and m.S.issue_counts or nil }, line)
  return true
end

local function verb_command(args, line)
  if not changes_allowed() then return refuse('command', t('agent.refused.changes')) end
  local name = (args or ''):match('^(%S+)')
  if not name or not COMMANDS[name] then return refuse('command', 'unknown command "' .. tostring(name) .. '"') end
  app.emit('command', name)
  reply('COMMAND', { name = name, modules = API.modules() }, line)
  return true
end

local function verb_config(args, line)
  local action, rest = (args or ''):match('^(%S+)%s*(.*)$')
  if action == 'get' then
    local key = rest:match('^(%S+)')
    local d, err = API.config_get(key)
    if not d then return refuse('config', err) end
    reply('CONFIG', { action = 'get', entry = d }, line)
  elseif action == 'list' then
    local prefix = rest:match('^(%S*)') or ''
    local d = API.config_list(prefix)
    d.action = 'list'
    reply('CONFIG', d, line)
  elseif action == 'set' then
    if not changes_allowed() then return refuse('config', t('agent.refused.changes')) end
    -- config set <key> <value...> [project|global]: the scope is the last word when it is one of the two
    local key, value = rest:match('^(%S+)%s+(.*)$')
    if not key or value == '' then return refuse('config', 'set <key> <value> [project|global]') end
    local scope = 'project'
    local head, tail = value:match('^(.*)%s+(%S+)$')
    if tail == 'project' or tail == 'global' then scope, value = tail, head end
    local d, err = API.config_set(key, value, scope)
    if not d then return refuse('config', err) end
    reply('CONFIG', { action = 'set', entry = d }, line)
  elseif action == 'reset' then
    if not changes_allowed() then return refuse('config', t('agent.refused.changes')) end
    local key, scope = rest:match('^(%S+)%s*(%S*)$')
    local d, err = API.config_reset(key, scope ~= '' and scope or nil)
    if not d then return refuse('config', err) end
    reply('CONFIG', { action = 'reset', entry = d }, line)
  else
    return refuse('config', 'get <key> | list [prefix] | set <key> <value> [project|global] | reset <key> [project|global]')
  end
  return true
end

local function register_verbs()
  local function gated(fn)
    return function(args, line)
      S.cur_line = line
      if not enabled() then return refuse((line or ''):match('^(%S+)') or '?', t('agent.refused.disabled')) end
      return fn(args, line)
    end
  end
  ctl.on('hello', gated(verb_hello))
  ctl.on('verbs', gated(function(_, line) reply('VERBS', { verbs = ctl.verbs() }, line) end))
  ctl.on('state', gated(function(_, line) reply('STATE', API.state(agent_info()), line) end))
  ctl.on('census', gated(function(_, line) reply('CENSUS', API.census(), line) end))
  ctl.on('shotlist', gated(function(_, line) reply('SHOTLIST', API.shotlist(), line) end))
  ctl.on('stemset', gated(function(_, line) reply('STEMSET', API.stemset(), line) end))
  ctl.on('results', gated(function(_, line) reply('RESULTS', API.results(), line) end))
  ctl.on('config', gated(verb_config))
  ctl.on('nav', gated(verb_nav))
  ctl.on('director', gated(verb_director))
  ctl.on('command', gated(verb_command))
  for verb, pattern in pairs(MUTATING) do guard(verb, pattern) end
end

-- discovery file ------------------------------------------------------------------------------------------------------------------------

local sep = package.config:sub(1, 1)

function M.discovery_path()
  local home = os.getenv('HOME') or os.getenv('USERPROFILE')
  if not home or home == '' then return nil end
  return home .. sep .. '.stagehand' .. sep .. 'agent.json'
end

local function write_discovery()
  if config.get('agent.discovery') == false then return end
  local path = M.discovery_path()
  if not path then return end
  local dir = path:match('^(.*)[/\\]')
  reaper.RecursiveCreateDirectory(dir, 0)
  local f = io.open(path, 'w')
  if not f then
    S.discovery_err = path
    return
  end
  f:write(json.encode({ ctl = ctl.dir(), project = state.project_name(), saved = ctl.dir() ~= nil, version = app.version,
    stamp = os.time(), os = reaper.GetOS(), running = true, enable = enabled(), allow_changes = changes_allowed(), allow_render = render_allowed() }, { pretty = true }), '\n')
  f:close()
  S.discovery_path, S.discovery_err = path, nil
end

-- module ----------------------------------------------------------------------------------------------------------------------------

local function bind_project()
  S.discovery_frame = -1000
  log.info('agent bound to "%s": ctl %s', state.project_name(), tostring(ctl.dir() or '(unsaved project: no ctl folder)'))
end

function M.init(app_)
  app = app_
  API.init(app)
  U.init(app, S, M)
  ST.init(app, S, M, API)
  register_verbs()
  bind_project()
  app.on('project_changed', bind_project)
  config.on_change(function(keys)
    for _, k in ipairs(keys) do
      if k:sub(1, 5) == 'agent' or k == '' then S.discovery_frame = -1000 end
    end
  end)
end

function M.tick(app_)
  if S.msg_frames > 0 then S.msg_frames = S.msg_frames - 1 end
  if app_.frame - S.discovery_frame >= DISCOVERY_FRAMES then
    S.discovery_frame = app_.frame
    write_discovery()
  end
end

function M.draw(app_)
  U.draw(app_)
end

function M.selftest(T)
  ST.run(T)
end

function M.selftest_post(frames_since_done)
  ST.post(frames_since_done)
end

function M.restore()
  return nil   -- nothing of our own: every change went through another module's journaled path
end

function M.shutdown()
  local path = M.discovery_path()
  if path and config.get('agent.discovery') ~= false then
    -- the file stays (the server reads the ctl dir from it) but the stamp is zeroed: "Stagehand is not running"
    local f = io.open(path, 'w')
    if f then
      f:write(json.encode({ ctl = ctl.dir(), project = state.project_name(), version = app.version, stamp = 0, running = false }, { pretty = true }), '\n')
      f:close()
    end
  end
end

M.S, M.API, M.COMMANDS = S, API, COMMANDS
return M
