-- modules/recorder/checklist.lua - the recording checklist (BRIEF 3.5): what should be true before a
-- recording starts, checked live where REAPER can tell (window size, mixer, video window, HUD bar, Director shots
-- and validation, glow, transport, cursor, loudness curve, the ctl folder) and stated as a reminder where it
-- cannot (screen sleep, notifications, the recorder permission). A row with a fix applies it through the
-- journal (owner 'recorder') so Restore puts it back. Lua 5.4; no globals.

local config = require('config')
local journal = require('lib.journal')
local view = require('lib.view')
local ctl = require('lib.ctl')
local js = require('platform.js')
local i18n = require('i18n')

local t = i18n.t

local CL = {}

local MIXER_TOGGLE = 40078
local VIDEO_TOGGLE = 50125

local app

function CL.init(app_)
  app = app_
end

local function soft(name)
  return app and app.by_name[name] or nil
end

local function fix_toggle(cmd, word, want)
  return function()
    local st = view.toggle_state(cmd, word)
    if st < 0 or st == want then return false end
    journal.add({ kind = 'toggle', key = tostring(cmd), was = st, name = word, owner = 'recorder' })
    reaper.Main_OnCommand(cmd, 0)
    return true
  end
end

-- rows: { id, label, status = 'ok' | 'warn' | 'off' | 'info', detail, fix = fn | nil, fix_label }
function CL.rows()
  local rows = {}
  local function add(id, status, detail, fix, fix_label)
    rows[#rows + 1] = { id = id, label = t(('rec.cl.%s'):format(id)), status = status, detail = detail, fix = fix, fix_label = fix_label }
  end
  -- 1. the ctl folder (a saved project)
  local dir = ctl.dir()
  add('project', dir and 'ok' or 'warn', dir or t('rec.cl.project_unsaved'))
  -- 2. extension
  add('js', (js.caps and js.caps.window_rects) and 'ok' or 'warn', (js.caps and js.caps.window_rects) and t('rec.cl.js_ok') or t('rec.cl.js_missing'))
  -- 3. shots and validation
  local dir_mod = soft('director')
  if dir_mod then
    local n = #dir_mod.MD.shots
    local counts = dir_mod.S.issue_counts
    if n == 0 then
      add('shots', 'warn', t('rec.cl.shots_none'))
    elseif counts and counts.error > 0 then
      add('shots', 'warn', string.format(t('rec.cl.shots_errors'), n, counts.error))
    else
      add('shots', 'ok', string.format(t('rec.cl.shots_ok'), n, dir_mod.MD.length()))
    end
  else
    add('shots', 'info', t('rec.cl.shots_no_module'))
  end
  -- 4. main window size
  local main = js.rect(reaper.GetMainHwnd()) and { js.rect(reaper.GetMainHwnd()) } or nil
  local min_w = math.floor(tonumber(config.get('recorder.checklist.min_w')) or 1280)
  local min_h = math.floor(tonumber(config.get('recorder.checklist.min_h')) or 720)
  if main then
    local w, h = main[3] - main[1], main[4] - main[2]
    add('window', (w >= min_w and h >= min_h) and 'ok' or 'warn', string.format(t('rec.cl.window_v'), w, h, min_w, min_h))
  else
    add('window', 'info', t('rec.cl.window_unknown'))
  end
  -- 5. mixer hidden
  local mx = view.toggle_state(MIXER_TOGGLE, 'mixer')
  add('mixer', mx == 0 and 'ok' or (mx == 1 and 'warn' or 'info'), mx == 0 and t('rec.cl.mixer_hidden') or (mx == 1 and t('rec.cl.mixer_shown') or t('rec.cl.unknown')),
    mx == 1 and fix_toggle(MIXER_TOGGLE, 'mixer', 0) or nil, t('rec.cl.fix_hide'))
  -- 6. video window as configured
  local want_video = config.get('recorder.layout.video.show') == true
  local vs = view.toggle_state(VIDEO_TOGGLE, 'video')
  if vs < 0 then
    add('video', 'info', t('rec.cl.unknown'))
  else
    local ok = (vs == 1) == want_video
    add('video', ok and 'ok' or 'warn', string.format(t('rec.cl.video_v'), vs == 1 and t('rec.cl.shown') or t('rec.cl.hidden'), want_video and t('rec.cl.shown') or t('rec.cl.hidden')),
      (not ok) and fix_toggle(VIDEO_TOGGLE, 'video', want_video and 1 or 0) or nil, want_video and t('rec.cl.fix_show') or t('rec.cl.fix_hide'))
  end
  -- 7. HUD bar
  local hud = soft('hud')
  if hud then
    local H = hud.H
    if H.visible then
      add('hud', 'ok', string.format(t('rec.cl.hud_v'), math.floor(H.bar_w), math.floor(H.bar_h), H.tier, H.dock ~= 0 and t('rec.cl.docked') or t('rec.cl.floating')))
    else
      add('hud', 'warn', t('rec.cl.hud_hidden'), function() H.show(true); return true end, t('rec.cl.fix_show'))
    end
    local Lc = H.cfg.loudness or {}
    if Lc.mode == 'curve' then
      add('curve', H.loud and H.loud.curve and 'ok' or 'warn', H.curve_status ~= '' and H.curve_status or t('rec.cl.curve_missing'))
    end
  else
    add('hud', 'info', t('rec.cl.hud_no_module'))
  end
  -- 8. glow
  local glow_on = config.get('glow.enable') ~= false and config.get('glow.mode') ~= 'off'
  add('glow', (js.caps and js.caps.composite) and (glow_on and 'ok' or 'off') or 'info',
    (js.caps and js.caps.composite) and (glow_on and t('rec.cl.glow_on') or t('rec.cl.glow_off')) or t('rec.cl.glow_no_js'))
  -- 9. transport and cursor
  add('transport', view.playing() and 'warn' or 'ok', view.playing() and t('rec.cl.playing') or t('rec.cl.stopped'), view.playing() and function() reaper.OnStopButton(); return true end or nil, t('rec.cl.fix_stop'))
  local cur = reaper.GetCursorPosition()
  local want_cur = tonumber(config.get('recorder.arm.cursor_s')) or 0
  add('cursor', math.abs(cur - want_cur) < 0.01 and 'ok' or 'info', string.format(t('rec.cl.cursor_v'), cur, want_cur))
  -- 10. reminders no API can check
  add('sleep', 'info', t('rec.cl.sleep_v'))
  add('permission', 'info', js.is_mac and t('rec.cl.permission_mac') or t('rec.cl.permission_other'))
  return rows
end

function CL.counts(rows)
  local c = { ok = 0, warn = 0, off = 0, info = 0 }
  for _, r in ipairs(rows) do c[r.status] = (c[r.status] or 0) + 1 end
  return c
end

return CL
