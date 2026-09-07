-- modules/recorder/layout.lua - the screen layout at the start of a recording (--): pick the monitor, size the main window, send a named window to a
-- docker, show and place the video window. Every change is journaled (owner 'recorder': window_rect, dock_id,
-- toggle) and put back by restore(). A layout diary (ctl.note -> layout.txt and the log) records what was
-- wanted and what REAPER did, the only way to debug a remote layout. Needs js_ReaScriptAPI for the window
-- work; without it apply() notes why and does nothing. Lua 5.4; no globals.

local log = require('lib.log')
local config = require('config')
local journal = require('lib.journal')
local view = require('lib.view')
local ctl = require('lib.ctl')
local js = require('platform.js')

local RL = { active = false, monitor = nil, monitors = nil, pending_video = nil, video_check = nil, last = {}, diary = {} }

local VIDEO_TOGGLE = 50125
local DOCK_POS = { bottom = 0, left = 1, top = 2, right = 3 }
local DOCK_NAMES = { [0] = 'bottom', [1] = 'left', [2] = 'top', [3] = 'right', [4] = 'floating' }

local app

local function cfg(key)
  return config.get('recorder.layout.' .. key)
end

local function note(fmt, ...)
  local s = ctl.note(fmt, ...)
  RL.diary[#RL.diary + 1] = s
  if #RL.diary > 40 then table.remove(RL.diary, 1) end
  return s
end

function RL.init(app_)
  app = app_
end

-- monitors ----------------------------------------------------------------------------------------------------------

function RL.scan_monitors()
  RL.monitors = js.monitors() or {}
  return RL.monitors
end

-- the monitor to lay out on, by recorder.layout.monitor: current | pick (monitor_index) | largest
function RL.pick_monitor()
  local mons = RL.scan_monitors()
  if #mons == 0 then return nil end
  local mode = cfg('monitor') or 'current'
  if mode == 'pick' then
    local i = math.floor(tonumber(cfg('monitor_index')) or 1)
    return mons[math.max(1, math.min(i, #mons))], i
  elseif mode == 'largest' then
    local best, bi = mons[1], 1
    for i, m in ipairs(mons) do
      if m.w * m.h > best.w * best.h then best, bi = m, i end
    end
    return best, bi
  end
  return mons[1], 1
end

function RL.dockers()
  local out = {}
  if not reaper.DockGetPosition then return out end
  for i = 0, 15 do
    local p = reaper.DockGetPosition(i)
    if p >= 0 then out[#out + 1] = { idx = i, pos = p, name = DOCK_NAMES[p] or tostring(p) } end
  end
  return out
end

-- the first docker index whose position matches ('top', 'bottom', 'left', 'right'), or nil
function RL.docker_index(position)
  local want = DOCK_POS[position]
  if want == nil then return nil end
  for _, d in ipairs(RL.dockers()) do
    if d.pos == want then return d.idx end
  end
  return nil
end

-- pieces ------------------------------------------------------------------------------------------------------------

local function rect_of(hwnd)
  local l, t, r, b = js.rect(hwnd)
  if not l then return nil end
  return { l, t, r - l, b - t }
end

local function fmt_rect(rc)
  if not rc then return '?' end
  return string.format('%d,%d %dx%d', rc[1], rc[2], rc[3], rc[4])
end

local function place_main(mon)
  local mode = cfg('main_window') or 'maximize'
  if mode == 'keep' then note('main window kept'); return end
  local main = reaper.GetMainHwnd()
  local was = rect_of(main)
  if not was then note('main window rect unreadable'); return end
  local want
  if mode == 'maximize' then
    want = { mon.l, mon.t, mon.w, mon.h }
  else
    local w = math.min(mon.w, math.floor(tonumber(cfg('main_w')) or 1920))
    local h = math.min(mon.h, math.floor(tonumber(cfg('main_h')) or 1080))
    want = { mon.l + (mon.w - w) // 2, mon.t + (mon.h - h) // 2, w, h }
  end
  journal.add({ kind = 'window_rect', key = 'main', was = was, owner = 'recorder' })
  js.set_rect(main, want[1], want[2], want[3], want[4])
  local now = rect_of(main)
  RL.last.main = { was = was, want = want, now = now }
  note('main window %s: was %s -> wanted %s -> now %s (monitor %d,%d %dx%d)', mode, fmt_rect(was), fmt_rect(want), fmt_rect(now), mon.l, mon.t, mon.w, mon.h)
end

local function send_to_docker()
  local ident = cfg('dock_window.ident')
  if not ident or ident == '' then return end
  if not (reaper.GetConfigWantsDock and reaper.Dock_UpdateDockID) then note('docker API missing: %s not moved', ident); return end
  local pos = cfg('dock_window.position') or 'top'
  local idx = RL.docker_index(pos)
  if not idx then
    note('no %s docker in this REAPER (dockers: %s): %s not moved', pos, RL.dockers_text(), ident)
    return
  end
  local was = reaper.GetConfigWantsDock(ident)
  journal.add({ kind = 'dock_id', key = ident, was = was, owner = 'recorder' })
  if was ~= idx then reaper.Dock_UpdateDockID(ident, idx) end
  note('%s wants docker %d (%s), was %d', ident, idx, pos, was)
  local cmd = cfg('dock_window.command') or ''
  local id
  if cmd:sub(1, 1) == '_' then id = reaper.NamedCommandLookup(cmd) elseif cmd ~= '' then id = math.floor(tonumber(cmd) or 0) end
  if id and id > 0 then
    local st = reaper.GetToggleCommandState(id)
    if st == 0 then
      journal.add({ kind = 'toggle', key = tostring(id), was = 0, owner = 'recorder' })
      reaper.Main_OnCommand(id, 0)
      note('%s opened through %s (%d)', ident, cmd, id)
    elseif st == 1 then
      note('%s already open (%s)', ident, cmd)
    else
      local h = js.find_window(ident)
      note('%s: toggle state unknown for %s; window %s', ident, cmd, h and 'found by title' or 'not found - open it by hand')
    end
  end
end

function RL.dockers_text()
  local parts = {}
  for _, d in ipairs(RL.dockers()) do parts[#parts + 1] = d.idx .. '=' .. d.name end
  return #parts > 0 and table.concat(parts, ' ') or 'none'
end

-- the arrange top in screen px from REAPER's own numbers (cross-checks the js rect on macOS)
local function arrange_top()
  local arr = js.arrange_hwnd()
  if not arr then return nil end
  local _, at = js.child_rect(arr)   -- y down on macOS too
  return at
end

function RL.video_target(mon)
  local V = { place = cfg('video.place') or 'top_right', w = math.floor(tonumber(cfg('video.w')) or 480), h = math.floor(tonumber(cfg('video.h')) or 270),
    dx = math.floor(tonumber(cfg('video.dx')) or 0), dy = math.floor(tonumber(cfg('video.dy')) or 0), title = math.floor(tonumber(cfg('video.title_px')) or 28) }
  local arr = js.arrange_hwnd()
  local al, at, ar = js.child_rect(arr)
  local ml = js.rect(reaper.GetMainHwnd())
  local x, y, w, h = mon.l, mon.t, V.w, V.h
  if V.place == 'top_right' then
    x, y = mon.l + mon.w - w + V.dx, mon.t + V.dy
  elseif V.place == 'top_left' then
    x, y = mon.l + V.dx, mon.t + V.dy
  elseif V.place == 'fit' then
    local top = arrange_top() or (mon.t + 200)
    local ch = math.max(120, top - mon.t - V.title - 2)
    w, h = math.floor(ch * 16 / 9 + 0.5), ch + V.title
    x, y = mon.l + V.dx, mon.t + V.dy
  elseif V.place == 'arrange' and ar and at then
    x, y = ar - w + V.dx, at + V.dy
  elseif V.place == 'tcp' and al and at then
    x, y = (ml or al) + V.dx, at + V.dy
  end
  return { x, y, w, h }, V.place
end

local function show_video()
  if cfg('video.show') ~= true then return end
  local st = view.toggle_state(VIDEO_TOGGLE, 'video')
  if st < 0 then note('video window: toggle state unknown'); return end
  journal.add({ kind = 'toggle', key = tostring(VIDEO_TOGGLE), was = st, name = 'video', owner = 'recorder' })
  if st == 0 then reaper.Main_OnCommand(VIDEO_TOGGLE, 0) end
  RL.pending_video = 12   -- REAPER re-applies its own saved rect when the window first shows: place it a few frames later
  note('video window %s; placing in 12 frames', st == 0 and 'opened' or 'already open')
end

function RL.place_video()
  local hw = js.find_video_window()
  if not hw then note('video window NOT found by title (%s) - place it by hand', table.concat(js.VIDEO_TITLES, ' / ')); RL.last.video = { found = false }; return false end
  local mon = RL.monitor
  if not mon then return false end
  local was = rect_of(hw)
  local want, place = RL.video_target(mon)
  local title = reaper.JS_Window_GetTitle(hw)
  if not journal.has('window_rect', 'video') then
    journal.add({ kind = 'window_rect', key = 'video', name = title, was = was, owner = 'recorder' })
  end
  js.set_rect(hw, want[1], want[2], want[3], want[4])
  local now = rect_of(hw)
  RL.last.video = { found = true, was = was, want = want, now = now, place = place }
  note('video window %s: was %s -> wanted %s -> now %s', place, fmt_rect(was), fmt_rect(want), fmt_rect(now))
  RL.video_check = 45
  return true
end

-- apply / restore -----------------------------------------------------------------------------------------------------

function RL.apply(why)
  if not (js.caps and js.caps.window_rects and js.caps.window_move) then
    note('layout skipped: js_ReaScriptAPI missing (window rects / move)')
    return false, 'no js_ReaScriptAPI'
  end
  if RL.active then RL.restore('reapply') end
  local mon, mi = RL.pick_monitor()
  if not mon then
    note('layout skipped: no monitor from my_getViewport')
    return false, 'no monitor'
  end
  RL.monitor = mon
  RL.active = true
  RL.last = { monitor = mon, monitor_i = mi }
  note('layout start (%s): monitor %d of %d = %d,%d %dx%d (%s); dockers: %s', why or 'ui', mi, #RL.monitors, mon.l, mon.t, mon.w, mon.h, cfg('monitor') or 'current', RL.dockers_text())
  place_main(mon)
  send_to_docker()
  show_video()
  if app then app.emit('recorder_layout', true) end
  return true
end

function RL.restore(why)
  RL.pending_video, RL.video_check = nil, nil
  local stats = journal.restore(journal.owner_pred('recorder'))
  RL.active = false
  note('layout restored (%s): restored=%d kept=%d gone=%d', why or 'ui', stats.restored, stats.kept, stats.gone)
  if app then app.emit('recorder_layout', false) end
  return stats
end

function RL.tick()
  if RL.pending_video then
    RL.pending_video = RL.pending_video - 1
    if RL.pending_video <= 0 then
      RL.pending_video = nil
      RL.place_video()
    end
  end
  if RL.video_check then
    RL.video_check = RL.video_check - 1
    if RL.video_check <= 0 then
      RL.video_check = nil
      local hw = js.find_video_window()
      local now = hw and rect_of(hw)
      if RL.last.video then RL.last.video.later = now end
      note('video window 1.5 s later: %s', fmt_rect(now))
    end
  end
end

-- the RECT diagnostics line: every rect the layout and the post rely on
function RL.rect_line(hud_rect)
  if hud_rect and hud_rect.x then hud_rect = { hud_rect.x, hud_rect.y, hud_rect.w, hud_rect.h } end
  local main = rect_of(reaper.GetMainHwnd())
  local arr = rect_of(js.arrange_hwnd())
  local vid = rect_of(js.find_video_window())
  local mon = main and { js.monitor_of(main[1], main[2], main[1] + main[3], main[2] + main[4], true) } or {}
  return string.format('RECT main %s | arrange %s | video %s | hud %s | monitor %s | dockers %s',
    fmt_rect(main), fmt_rect(arr), fmt_rect(vid), fmt_rect(hud_rect), #mon >= 4 and string.format('%d,%d-%d,%d', mon[1], mon[2], mon[3], mon[4]) or '?', RL.dockers_text())
end

-- the hud file lines: the bar's painted rect, the full monitor (what a screen recorder captures) and the work area
function RL.hud_lines(bar)
  if not bar or not bar.x then return nil end
  local l, t, r, b = math.floor(bar.x), math.floor(bar.y), math.floor(bar.x + bar.w), math.floor(bar.y + bar.h)
  local fl, ft, fr, fb = js.monitor_of(l, t, r, b, false)
  local wl, wt, wr, wb = js.monitor_of(l, t, r, b, true)
  if not fl then
    local m = rect_of(reaper.GetMainHwnd()) or { 0, 0, 1920, 1080 }
    fl, ft, fr, fb = m[1], m[2], m[1] + m[3], m[2] + m[4]
    wl, wt, wr, wb = fl, ft, fr, fb
  end
  return {
    string.format('hud %d %d %d %d', l, t, r, b),
    string.format('monitor %d %d %d %d', fl, ft, fr, fb),
    string.format('work %d %d %d %d', wl, wt, wr, wb),
  }
end

return RL
