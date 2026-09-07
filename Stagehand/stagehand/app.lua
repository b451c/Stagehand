-- app.lua - the application shell: one defer loop, module registry with an event bus, the window (docking,
-- size and dock remembered), the tab bar, the about panel, the error panel, the self-test runner.
--
-- run(opts): loads ReaImGui (ui/imgui.lua), config, the theme, probes capabilities (platform/js.lua), creates
-- the context and runs the frame loop under xpcall. A frame error never freezes REAPER: the traceback goes to
-- the log and to a copyable error panel, every module restores what it changed, and the loop keeps running so
-- the user can read it. Modules register through M.register (contract: docs/architecture.md section 3).
-- Launchers ("Stagehand - Navigator.lua") set ExtState launch_tab; when the app already runs (heartbeat) the
-- launcher only switches the tab. Lua 5.4; no globals.

local log = require('lib.log')
local imgui = require('ui.imgui')
local js = require('platform.js')
local theme = require('ui.theme')
local widgets = require('ui.widgets')
local config = require('config')
local state = require('state')
local i18n = require('i18n')
local selftest = require('selftest')

local t = i18n.t

local M = {}

local NAME = 'Stagehand'
local VERSION = '0.1.0-dev'
local HEARTBEAT_FRAMES = 15
local SLOW_FRAME_MS = 50   -- a frame over this is logged with the last user action (docs/research/failures.md B1)
local START_COMMANDS = { hud_show = true, settings_show = true, stems_show = true }   -- commands a launcher may carry into a fresh start (a toggle would flip a default)
local DEFAULT_W, DEFAULT_H = 460, 700
-- the support links (BRIEF 3.12): the About tab's buttons, the README, the ReaPack @about and the guide name the same three
local SUPPORT_LINKS = {
  { id = 'kofi', label = 'Ko-fi', url = 'https://ko-fi.com/quickmd' },
  { id = 'bmc', label = 'Buy Me a Coffee', url = 'https://buymeacoffee.com/bsroczynskh' },
  { id = 'paypal', label = 'PayPal', url = 'https://paypal.me/b451c' },
}

local app = {
  name = NAME, version = VERSION,
  ImGui = nil, ctx = nil, caps = nil, imgui_info = nil,
  modules = {}, by_name = {}, listeners = {},
  frame = 0, error_text = nil, quit = false,
  tick_ms_max = 0, tick_ms_last = 0, mod_tick_ms_last = 0,
  slow_frames = 0, slow_ring = {}, slow_logged_at = 0, last_action = '-',
  win_w = 0, win_h = 0, dpi = 1, dock = 0, focused = false,
  tab = 'navigator', tab_request = nil,
  window = { w = DEFAULT_W, h = DEFAULT_H, dock = 0, last_dock = nil },
  pending_dock = nil, window_dirty_frame = nil,
  init_ms = {}, first_frames_ms = {},
  script_dir = '.', about_msg = nil, about_msg_frames = 0,
}

-- module registry and events ----------------------------------------------------------------------------------

function M.register(module)
  app.modules[#app.modules + 1] = module
  app.by_name[module.name] = module
  if module.init then
    local t0 = reaper.time_precise()
    module.init(app)
    app.init_ms[module.name] = (reaper.time_precise() - t0) * 1000
  end
end

function app.on(event, fn)
  app.listeners[event] = app.listeners[event] or {}
  table.insert(app.listeners[event], fn)
end

function app.emit(event, ...)
  for _, fn in ipairs(app.listeners[event] or {}) do
    local ok, err = pcall(fn, ...)
    if not ok then log.error('listener for %s failed: %s', event, tostring(err)) end
  end
end

function app.set_tab(name)
  app.tab_request = name
end

-- the last user action, kept for the slow-frame guard ("what was the user doing when the frame stalled")
function app.note(action)
  app.last_action = tostring(action)
end

function app.say(msg)
  app.emit('message', msg)
end

-- hide the main window while a capture runs (the overview module); the frame loop keeps running
function app.suspend_window(on)
  app.suspended = on == true
end

-- place the floating main window (ImGui screen coordinates, logical px) on the next frame: scripted scenarios and
-- layouts go through ImGui, never through the OS window (a window moved behind ImGui's back keeps its old position
-- for popups and input, verified on the macOS leg)
function app.place_window(x, y, w, h)
  app.window_request = { x = x, y = y, w = w, h = h }
end

local function restore_all()
  for _, m in ipairs(app.modules) do
    if m.restore then
      local ok, err = pcall(m.restore)
      if not ok then log.error('restore failed in %s: %s', tostring(m.name), tostring(err)) end
    end
  end
end

local function shutdown_all()
  for _, m in ipairs(app.modules) do
    if m.shutdown then pcall(m.shutdown) end
  end
end

-- window persistence ------------------------------------------------------------------------------------------

local function load_window()
  local w = state.get_scoped('window', config.get('navigator.persist.scope'))
  if type(w) == 'table' then
    app.window.w = tonumber(w.w) or DEFAULT_W
    app.window.h = tonumber(w.h) or DEFAULT_H
    app.window.dock = math.floor(tonumber(w.dock) or 0)
    app.window.last_dock = tonumber(w.last_dock)
  end
end

local function save_window()
  state.set_scoped('window', { w = math.floor(app.window.w), h = math.floor(app.window.h), dock = app.window.dock,
    last_dock = app.window.last_dock }, config.get('navigator.persist.scope'))
end

-- REAPER docker index -> ReaImGui dock id; prefers a bottom docker, else docker 0
local function default_docker()
  if reaper.DockGetPosition then
    for i = 0, 15 do
      if reaper.DockGetPosition(i) == 0 then return ~i end
    end
  end
  return ~0
end

function app.is_docked()
  return app.window.dock ~= 0
end

function app.toggle_dock()
  if app.window.dock ~= 0 then
    app.pending_dock = 0
  else
    local target = app.window.last_dock
    if not target or target == 0 then target = default_docker() end
    app.pending_dock = target
  end
end

-- panels ------------------------------------------------------------------------------------------------------

local function facts()
  local rows = {
    { 'Stagehand', VERSION },
    { 'REAPER', reaper.GetAppVersion() },
    { 'OS', reaper.GetOS() },
    { 'ReaImGui', app.imgui_info.reaimgui_version .. ' (' .. app.imgui_info.style .. ' API style)' },
    { 'Dear ImGui', app.imgui_info.imgui_version },
    { 'fonts', 'mono: ' .. tostring(theme.fonts_info.mono) .. ', bold: ' .. tostring(theme.fonts_info.bold) },
    { 'theme', (theme.is_dark and 'dark' or 'light') .. ' (' .. theme.mode .. ')' },
    { 'resource path', reaper.GetResourcePath() },
    { 'config', config.path() },
  }
  for _, r in ipairs(js.describe(app.caps)) do rows[#rows + 1] = r end
  return rows
end

function app.selftest_facts(T)
  for _, r in ipairs(facts()) do
    T.fact(r[1]:gsub('%s+', '_'):lower(), r[2])
  end
  local frame_sum, tick_sum, n = 0, 0, 0
  T.wait(45)   -- let the transport and the glow's tails settle (1.5 s) so the idle numbers are idle
  for _ = 1, 30 do
    T.wait(1)
    frame_sum = frame_sum + app.tick_ms_last
    tick_sum = tick_sum + app.mod_tick_ms_last
    n = n + 1
  end
  T.fact('window', string.format('%dx%d', math.floor(app.win_w + 0.5), math.floor(app.win_h + 0.5)))
  T.fact('dpi', string.format('%.3f', app.dpi))
  T.fact('dock', app.window.dock)
  T.fact('frames', app.frame)
  local inits = {}
  for name, ms in pairs(app.init_ms) do inits[#inits + 1] = string.format('%s=%.1f', name, ms) end
  table.sort(inits)
  T.fact('init_ms', table.concat(inits, ' '))
  local firsts = {}
  for i, ms in ipairs(app.first_frames_ms) do firsts[i] = string.format('%.1f', ms) end
  T.fact('first_frames_ms', table.concat(firsts, ' '))
  T.fact('frame_ms_max', string.format('%.2f', app.tick_ms_max))
  local slow = {}
  for _, s in ipairs(app.slow_ring) do slow[#slow + 1] = string.format('%d:%.0fms:%s', s.frame, s.ms, s.action) end
  T.fact('slow_frames', string.format('%d%s', app.slow_frames, #slow > 0 and (' ' .. table.concat(slow, ' ')) or ''))
  T.fact('frame_ms_idle_avg', string.format('%.2f', frame_sum / n))
  T.fact('tick_ms_idle_avg', string.format('%.3f', tick_sum / n))
end

-- open a URL through SWS when it is there, else put it on the clipboard and say so
function app.open_url(url)
  if app.caps and app.caps.sws and reaper.CF_ShellExecute then
    reaper.CF_ShellExecute(url)
    app.about_msg, app.about_msg_frames = string.format(t('about.opened'), url), 90
    return true
  end
  app.ImGui.SetClipboardText(app.ctx, url)
  app.about_msg, app.about_msg_frames = string.format(t('about.copied'), url), 90
  return false
end

app.support_links = SUPPORT_LINKS

local function draw_support()
  local ImGui, ctx = app.ImGui, app.ctx
  ImGui.Spacing(ctx)
  ImGui.TextWrapped(ctx, t('about.support'))
  for i, link in ipairs(SUPPORT_LINKS) do
    if i > 1 then ImGui.SameLine(ctx, 0, theme.space[2]) end
    if widgets.button(ctx, 'support_' .. link.id, link.label) then
      app.note('support ' .. link.id)
      app.open_url(link.url)
    end
    widgets.tooltip(ctx, link.url)
  end
  if app.about_msg_frames > 0 then
    app.about_msg_frames = app.about_msg_frames - 1
    theme.push_font(ImGui, ctx, 'small')
    ImGui.TextColored(ctx, theme.col('muted'), app.about_msg)
    theme.pop_font(ImGui, ctx)
  end
end

local function draw_about()
  local ImGui, ctx = app.ImGui, app.ctx
  theme.push_font(ImGui, ctx, 'title')
  ImGui.Text(ctx, NAME .. ' ' .. VERSION)
  theme.pop_font(ImGui, ctx)
  ImGui.TextColored(ctx, theme.col('muted'), t('about.tagline'))
  ImGui.Spacing(ctx)
  local flags = ImGui.TableFlags_RowBg | ImGui.TableFlags_SizingStretchProp
  if ImGui.BeginTable(ctx, 'facts', 2, flags) then
    for _, r in ipairs(facts()) do
      ImGui.TableNextRow(ctx)
      ImGui.TableNextColumn(ctx); ImGui.TextColored(ctx, theme.col('muted'), r[1])
      ImGui.TableNextColumn(ctx); ImGui.TextWrapped(ctx, tostring(r[2]))
    end
    ImGui.EndTable(ctx)
  end
  ImGui.Spacing(ctx)
  theme.push_font(ImGui, ctx, 'small')
  ImGui.TextColored(ctx, theme.col('muted'), string.format(t('about.frame_stats'), app.frame, app.tick_ms_last, app.tick_ms_max))
  ImGui.TextColored(ctx, theme.col('muted'), t('about.log') .. ' ' .. log.path())
  for _, e in ipairs(config.errors()) do
    ImGui.TextColored(ctx, theme.col('warn'), e)
  end
  theme.pop_font(ImGui, ctx)
  ImGui.Spacing(ctx)
  ImGui.TextWrapped(ctx, t('about.credits'))
  draw_support()
end

local function draw_error_panel()
  local ImGui, ctx = app.ImGui, app.ctx
  ImGui.TextColored(ctx, theme.col('danger'), t('error.title'))
  ImGui.TextWrapped(ctx, t('error.body'))
  local flags = ImGui.InputTextFlags_ReadOnly
  ImGui.InputTextMultiline(ctx, '##error', app.error_text, -1, 220, flags)
  if ImGui.Button(ctx, t('error.copy')) then ImGui.SetClipboardText(ctx, app.error_text) end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, t('error.dismiss')) then app.error_text = nil end
end

local function draw_tabs()
  local ImGui, ctx = app.ImGui, app.ctx
  -- nine tabs no longer fit 460 px with the resize-down policy ("S..." for Settings and Stems): the bar scrolls
  -- and a list button on the left names every tab
  if not ImGui.BeginTabBar(ctx, 'apptabs', ImGui.TabBarFlags_NoTooltip | ImGui.TabBarFlags_FittingPolicyScroll | ImGui.TabBarFlags_TabListPopupButton) then return end
  local names = {}
  for _, m in ipairs(app.modules) do
    if m.draw then names[#names + 1] = { name = m.name, title = m.title or m.name, module = m } end
  end
  names[#names + 1] = { name = 'about', title = t('tab.about') }
  for _, tabdef in ipairs(names) do
    local flags = 0
    if app.tab_request == tabdef.name then flags = ImGui.TabItemFlags_SetSelected end
    local visible = ImGui.BeginTabItem(ctx, tabdef.title .. '###tab_' .. tabdef.name, nil, flags)
    if visible then
      app.tab = tabdef.name
      ImGui.EndTabItem(ctx)
    end
  end
  app.tab_request = nil
  ImGui.EndTabBar(ctx)
  local m = app.by_name[app.tab]
  if m and m.draw then
    m.draw(app)
  else
    draw_about()
  end
end

local function draw_body()
  local ImGui, ctx = app.ImGui, app.ctx
  app.dpi = ImGui.GetWindowDpiScale(ctx)
  app.win_w, app.win_h = ImGui.GetWindowSize(ctx)   -- inside Begin/End: outside, the size is the debug window's
  local dock = ImGui.GetWindowDockID(ctx)
  if dock ~= app.window.dock then
    app.window.dock = dock
    if dock ~= 0 then app.window.last_dock = dock end
    app.window_dirty_frame = app.frame
  end
  if dock == 0 and (math.abs(app.win_w - app.window.w) > 1 or math.abs(app.win_h - app.window.h) > 1) then
    app.window.w, app.window.h = app.win_w, app.win_h
    app.window_dirty_frame = app.frame
  end
  app.focused = ImGui.IsWindowFocused(ctx, ImGui.FocusedFlags_RootAndChildWindows)
  if app.focused then ImGui.SetNextFrameWantCaptureKeyboard(ctx, true) end
  if app.error_text then
    draw_error_panel()
  else
    draw_tabs()
  end
end

-- frame loop --------------------------------------------------------------------------------------------------

-- launchers talk to the running instance through two ExtStates: launch_tab (switch the tab) and command
-- (a verb such as glow_toggle or hud_show, delivered as the "command" event)
local function poll_launch_tab()
  if app.frame % HEARTBEAT_FRAMES ~= 0 then return end
  reaper.SetExtState('Stagehand', 'heartbeat', tostring(reaper.time_precise()), false)
  local tab = reaper.GetExtState('Stagehand', 'launch_tab')
  if tab ~= '' then
    reaper.DeleteExtState('Stagehand', 'launch_tab', false)
    if app.by_name[tab] then app.set_tab(tab) end
  end
  local cmd = reaper.GetExtState('Stagehand', 'command')
  if cmd ~= '' then
    reaper.DeleteExtState('Stagehand', 'command', false)
    app.emit('command', cmd)
  end
end

-- windows a module draws besides the main one (the HUD bar); each pairs its own Begin/End under pcall
local function draw_extra_windows()
  for _, m in ipairs(app.modules) do
    if m.draw_extra then m.draw_extra(app) end
  end
end

local function frame()
  local ImGui, ctx = app.ImGui, app.ctx
  local t0 = reaper.time_precise()
  app.frame = app.frame + 1
  if state.bind() then
    config.reload_project()
    theme.detect(config.get('ui.theme'))
    app.emit('project_changed')
  end
  poll_launch_tab()
  for _, m in ipairs(app.modules) do
    if m.tick then m.tick(app) end
  end
  app.mod_tick_ms_last = (reaper.time_precise() - t0) * 1000
  ImGui.SetNextWindowSize(ctx, app.window.w, app.window.h, ImGui.Cond_Once)   -- our persisted size wins over ReaImGui's ini
  if app.window_request then
    local r = app.window_request
    app.window_request = nil
    if app.window.dock == 0 then
      ImGui.SetNextWindowPos(ctx, r.x, r.y, ImGui.Cond_Always)
      if r.w and r.h then ImGui.SetNextWindowSize(ctx, r.w, r.h, ImGui.Cond_Always) end
    end
  end
  if app.frame == 1 and app.window.dock ~= 0 then app.pending_dock = app.window.dock end
  if app.pending_dock ~= nil then
    ImGui.SetNextWindowDockID(ctx, app.pending_dock)
    app.pending_dock = nil
  end
  theme.push(ImGui, ctx)
  local flags = ImGui.WindowFlags_NoCollapse | ImGui.WindowFlags_NoScrollbar | ImGui.WindowFlags_NoScrollWithMouse
  local visible, open = true, true
  if app.suspended then
    -- a capture is running (overview companion / guided pages): the main window stays away from the arrange;
    -- the extra windows (HUD bar, page counter) still draw
    visible = false
  else
    visible, open = ImGui.Begin(ctx, NAME, true, flags)
  end
  if visible then
    -- the body runs under its own pcall so End() is always paired with Begin(): a frame error between the two
    -- leaves the ReaImGui context invalid ("Missing End()" dialog, verified on the legs)
    local ok, err = pcall(draw_body)
    ImGui.End(ctx)
    if not ok then
      theme.pop(ImGui, ctx)
      error(err, 0)
    end
  end
  draw_extra_windows()
  theme.pop(ImGui, ctx)
  selftest.tick(app)
  selftest.post(app)
  if app.window_dirty_frame and app.frame - app.window_dirty_frame > 20 then
    app.window_dirty_frame = nil
    save_window()
  end
  app.tick_ms_last = (reaper.time_precise() - t0) * 1000
  if app.tick_ms_last > app.tick_ms_max then app.tick_ms_max = app.tick_ms_last end
  if app.frame <= 5 then app.first_frames_ms[app.frame] = app.tick_ms_last end
  if app.frame > 5 and app.tick_ms_last > SLOW_FRAME_MS then
    -- the guard: the frame, its cost, the modules' share and the last action, a ring of 20 and a log line per second
    app.slow_frames = app.slow_frames + 1
    local ring = app.slow_ring
    ring[#ring + 1] = { frame = app.frame, ms = app.tick_ms_last, mod_ms = app.mod_tick_ms_last, action = app.last_action }
    if #ring > 20 then table.remove(ring, 1) end
    local now = reaper.time_precise()
    if now - app.slow_logged_at > 1 then
      app.slow_logged_at = now
      log.warn('slow frame %d: %.1f ms (modules %.1f ms) after %s', app.frame, app.tick_ms_last, app.mod_tick_ms_last, app.last_action)
    end
  end
  return open and not app.quit
end

local function loop()
  local ok, result = xpcall(frame, debug.traceback)
  if not ok then
    local text = tostring(result)
    log.error('frame error: %s', text)
    if log.selftest_armed() then
      log.selftest('ERROR: ' .. text)
      log.selftest('SELFTEST ABORTED')
    end
    restore_all()
    app.error_text = text
    reaper.defer(loop)   -- keep the window alive so the error panel can be read
    return
  end
  if result then
    reaper.defer(loop)
  else
    shutdown_all()
  end
end

local function app_already_running()
  local hb = tonumber(reaper.GetExtState('Stagehand', 'heartbeat'))
  return hb ~= nil and (reaper.time_precise() - hb) < 1.0
end

function M.run(opts)
  opts = opts or {}
  local launch_tab = reaper.GetExtState('Stagehand', 'launch_tab')
  if opts.from_launcher and app_already_running() then
    log.info('launcher: app already running, switching to tab %s', launch_tab)
    return   -- the running instance polls launch_tab and switches
  end
  local ImGui, info = imgui.load()
  if not ImGui then
    log.error('startup: %s', tostring(info))
    if log.selftest_armed() then
      log.selftest('ERROR: ' .. tostring(info))
      log.selftest('SELFTEST ABORTED')
    end
    reaper.MB(info, NAME, 0)
    return
  end
  app.ImGui, app.imgui_info = ImGui, info
  app.caps = js.probe()
  app.script_dir = opts.script_dir or '.'
  state.bind()
  config.load()
  theme.detect(config.get('ui.theme'))
  config.on_change(function(keys)
    for _, k in ipairs(keys) do
      if k == 'ui.theme' or k == 'ui' or k == '' then theme.detect(config.get('ui.theme')) end
    end
  end)
  load_window()
  app.ctx = ImGui.CreateContext(NAME, ImGui.ConfigFlags_DockingEnable)
  theme.fonts(ImGui, app.ctx)
  widgets.init(ImGui)
  selftest.init(app)
  log.info('%s %s started; REAPER %s on %s; ReaImGui %s (%s); js %s; sws %s; theme %s', NAME, VERSION,
    reaper.GetAppVersion(), reaper.GetOS(), info.reaimgui_version, info.style,
    tostring(app.caps.js_version or 'no'), tostring(app.caps.sws_version or 'no'), theme.is_dark and 'dark' or 'light')
  if info.shim_error then log.warn('ReaImGui shim failed to load, classic API in use: %s', info.shim_error) end
  if app.caps.action_options then reaper.set_action_options(1) end   -- relaunch terminates the running instance
  for _, name in ipairs(opts.modules or {}) do
    local ok, mod = pcall(require, name)
    if ok then M.register(mod) else log.error('module %s failed to load: %s', name, tostring(mod)) end
  end
  if launch_tab ~= '' and app.by_name[launch_tab] then app.set_tab(launch_tab) end
  reaper.DeleteExtState('Stagehand', 'launch_tab', false)
  local start_cmd = reaper.GetExtState('Stagehand', 'command')
  reaper.DeleteExtState('Stagehand', 'command', false)
  if START_COMMANDS[start_cmd] then app.emit('command', start_cmd) end
  reaper.atexit(function()
    restore_all()
    save_window()
    reaper.DeleteExtState('Stagehand', 'heartbeat', false)
    log.info('%s exit', NAME)
  end)
  reaper.defer(loop)
end

M.app = app
return M
