-- modules/recorder/init.lua - the Recorder module (BRIEF section 3.5): the control protocol for the companion
-- drivers in tools/ (record_showcase.py, overview_capture.py), the arm sequence (cursor, Director run, HUD bar,
-- layout at start, the hud file), the sync tokens mirrored from the HUD's flash sequencer into the state file,
-- the recording checklist, the screen layout at start and the shot-list export. Everything goes through
-- events and commands: the Director, HUD and Glow modules are never required. Module contract
-- (docs/architecture.md section 3): init, tick, draw, selftest, restore, shutdown. Lua 5.4; no globals.

local log = require('lib.log')
local config = require('config')
local journal = require('lib.journal')
local state = require('state')
local view = require('lib.view')
local ctl = require('lib.ctl')
local js = require('platform.js')
local i18n = require('i18n')
local RL = require('modules.recorder.layout')
local CL = require('modules.recorder.checklist')
local EX = require('modules.recorder.export')
local U = require('modules.recorder.ui')
local ST = require('modules.recorder.selftest')

local t = i18n.t

local S = {
  msg = '', msg_frames = 0, compact = false, arm = nil, armed = false, director_active = false, n_shots = 0, t_end = nil,
  flash_phase = 'idle', rows = nil, rows_frame = -1, hud_lines = nil, last_token = nil,
}

local M = { name = 'recorder', title = t('rec.title') }

local app

local function hud_bar()
  local hud = app.by_name['hud']
  if not hud then return nil end
  local H = hud.H
  if not H.visible or not H.bar_x then return nil end
  return { x = H.bar_x, y = H.bar_y, w = H.bar_w, h = H.bar_h }
end

-- the hud file: bar rect + monitor + work area (logical px, y down); returns the lines or nil
function M.write_hud_file()
  local lines = RL.hud_lines(hud_bar())
  if not lines then return nil end
  ctl.write_file('hud', lines)
  S.hud_lines = lines
  return lines
end

function M.say(msg)
  S.msg = msg
  S.msg_frames = 40
end

-- arm: cursor, Director run, HUD bar, layout at start, hud file -> ARMED -------------------------------------------------

function M.arm(why)
  if S.arm then return false end
  reaper.OnStopButton()
  local cur = tonumber(config.get('recorder.arm.cursor_s')) or 0
  reaper.SetEditCurPos2(0, cur, true, false)
  if config.get('recorder.layout.apply') == true then RL.apply(why or 'arm') end
  if config.get('recorder.arm.start_director') ~= false then app.emit('command', 'director_start') end
  if config.get('recorder.arm.show_hud') ~= false then app.emit('command', 'hud_show') end
  S.arm = { frames = 10, why = why or 'ui' }
  log.info('recorder arm (%s): cursor %.3f', why or 'ui', cur)
  return true
end

local function arm_step()
  local a = S.arm
  if not a then return end
  a.frames = a.frames - 1
  if a.frames > 0 then return end
  S.arm = nil
  S.armed = true
  local lines = M.write_hud_file()
  ctl.write('ARMED', { shots = S.n_shots, end_s = S.t_end or 0, director = S.director_active and 1 or 0, hud = lines and 1 or 0, cursor = reaper.GetCursorPosition() })
  M.say(t('rec.msg.armed'))
end

function M.play()
  app.emit('command', 'hud_arm_play')
end

function M.stop(why)
  app.emit('command', 'hud_cancel')
  S.arm = nil
  ctl.write('STOPPED', why or 'ctl')
end

function M.quit(why)
  M.stop(why)
  app.emit('command', 'director_stop')
  if RL.active then RL.restore(why or 'quit') end
  S.armed = false
  ctl.write('QUIT', why or 'ctl')
end

-- the ctl verbs ----------------------------------------------------------------------------------------------------------

local function register_verbs()
  ctl.on('ping', function() ctl.write('PONG', { version = app.version, os = reaper.GetOS() }) end)
  ctl.on('arm', function() M.arm('ctl') end)
  ctl.on('play', function() M.play() end)
  ctl.on('stop', function() M.stop('ctl') end)
  ctl.on('quit', function() M.quit('ctl') end)
  ctl.on('rect', function() ctl.write(RL.rect_line(hud_bar())) end)
  ctl.on('hud', function()
    local lines = M.write_hud_file()
    ctl.write('HUD', lines and table.concat(lines, ' ; ') or 'no bar')
  end)
  ctl.on('layout', function()
    local ok, err = RL.apply('ctl')
    ctl.write('LAYOUT', ok and 'applied' or tostring(err))
  end)
  ctl.on('unlayout', function()
    local st = RL.restore('ctl')
    ctl.write('LAYOUT', 'restored ' .. st.restored)
  end)
  ctl.on('vid', function(args)
    local x, y, w, h = args:match('^(%-?%d+)%s+(%-?%d+)%s+(%d+)%s+(%d+)')
    local hw = js.find_video_window()
    if hw and x then
      if not journal.has('window_rect', 'video') then
        local l, tt, r, b = js.rect(hw)
        journal.add({ kind = 'window_rect', key = 'video', was = { l, tt, r - l, b - tt }, owner = 'recorder' })
      end
      js.set_rect(hw, tonumber(x), tonumber(y), tonumber(w), tonumber(h))
      local l, tt, r, b = js.rect(hw)
      ctl.note('VID set %s,%s %sx%s -> now %d,%d %dx%d', x, y, w, h, l, tt, r - l, b - tt)
      ctl.write('VID', { l = l, t = tt, w = r - l, h = b - tt })
    else
      ctl.write('VID', hw and 'bad arguments' or 'window not found')
    end
  end)
  ctl.on('glow', function(args)
    app.emit('command', args == 'on' and 'glow_on' or (args == 'off' and 'glow_off' or 'glow_toggle'))
    ctl.write('GLOW', args)
  end)
  ctl.on('shots', function(args)
    local path, n = EX.export(args == 'csv' and 'csv' or 'json')
    ctl.write('SHOTS', path and { n = n, path = path } or tostring(n))
  end)
  ctl.on('goto', function(args)
    local pos = tonumber(args) or 0
    reaper.SetEditCurPos2(0, pos, true, false)
    ctl.write('GOTO', { pos = pos })
  end)
end

-- module -------------------------------------------------------------------------------------------------------------------

local function bind_project()
  ctl.bind()
  S.arm, S.armed = nil, false
  S.rows_frame = -1
  if RL.active then RL.restore('project switch') end
  log.info('recorder bound to "%s": ctl %s', state.project_name(), tostring(ctl.dir() or '(unsaved project: no ctl folder)'))
end

function M.init(app_)
  app = app_
  RL.init(app)
  CL.init(app)
  EX.init(app)
  U.init(app, S, RL, CL, EX, M)
  ST.init(app, S, RL, CL, EX, M)
  register_verbs()
  bind_project()
  app.on('project_changed', bind_project)
  app.on('hud_flash', function(name, wall, pos)
    S.flash_phase = name
    S.last_token = name
    ctl.write(name, { pos = pos })
  end)
  app.on('shot_changed', function(k, s)
    ctl.write('SHOT', string.format('k=%d t0=%.3f t1=%.3f name=%s', k, s.t0, s.t1, tostring(s.name)))
  end)
  app.on('director_active', function(on)
    S.director_active = on == true
    ctl.write(on and 'DIRECTOR_START' or 'DIRECTOR_STOP')
  end)
  app.on('director_shots', function(n, t_end)
    S.n_shots, S.t_end = tonumber(n) or 0, tonumber(t_end)
  end)
  app.on('command', function(name)
    if name == 'recorder_arm' then M.arm('command')
    elseif name == 'recorder_play' then M.play()
    elseif name == 'recorder_stop' then M.stop('command')
    elseif name == 'recorder_layout' then RL.apply('command')
    elseif name == 'recorder_export' then EX.export('json') end
  end)
end

function M.tick(app_)
  local every = math.max(1, math.floor(tonumber(config.get('recorder.ctl.poll_frames')) or 3))
  if app_.frame % every == 0 then ctl.poll(app_.frame) end
  arm_step()
  RL.tick()
  if S.msg_frames > 0 then S.msg_frames = S.msg_frames - 1 end
  journal.flush()
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

-- a frame error or the exit: windows back where they were, toggles back (also entries a previous session left)
function M.restore()
  S.arm = nil
  if RL.active or journal.count(nil, 'recorder') > 0 then return RL.restore('restore') end
  return nil
end

function M.shutdown()
  journal.flush()
end

M.S, M.RL, M.CL, M.EX = S, RL, CL, EX
return M
