-- modules/hud/ui.lua - the HUD tab in the main window: show / hide and dock the bar, arm the sync flash,
-- the bar settings (loudness source, caption language, time, progress, name, hints), the curve file and a
-- live readout of what the bar shows. Drawing only; the bar itself is bar.lua. Lua 5.4; no globals.

local theme = require('ui.theme')
local widgets = require('ui.widgets')
local text = require('lib.text')
local view = require('lib.view')
local loudness = require('lib.loudness')
local config = require('config')
local state = require('state')
local i18n = require('i18n')

local t = i18n.t

local U = {}

local ImGui, ctx, app, H, F, B
local GAP = 4
local curve_input = nil

function U.init(app_, H_, F_, B_)
  app, H, F, B = app_, H_, F_, B_
  ImGui = app.ImGui
end

local function scope()
  return (H.cfg.persist and H.cfg.persist.scope) or 'project'
end

local function measure(s, font)
  theme.push_font(ImGui, ctx, font or 'body')
  local w, h = ImGui.CalcTextSize(ctx, s)
  theme.pop_font(ImGui, ctx)
  return w, h
end

local function row_text(dl, x, y0, s, colname, max_w, font, rh)
  theme.push_font(ImGui, ctx, font or 'body')
  local _, th = ImGui.CalcTextSize(ctx, 'Ag')
  local cut = widgets.text_at(ctx, dl, x, y0 + (rh - th) / 2, s, theme.col(colname), max_w)
  theme.pop_font(ImGui, ctx)
  return cut
end

local function next_line(x, y)
  ImGui.SetCursorScreenPos(ctx, x, y)
  ImGui.Dummy(ctx, 0, 0)
end

local function say(msg)
  H.tab_msg = msg
  H.tab_msg_frames = 40
end

local function set_setting(key, value)
  config.set('hud.' .. key, value, scope())
  H.reconfigure()
end

-- header -------------------------------------------------------------------------------------------------------------------

local function draw_menu()
  local docked = app.is_docked()
  if ImGui.MenuItem(ctx, H.visible and t('hud.menu.hide') or t('hud.menu.show'), 'H') then H.show(not H.visible) end
  if ImGui.MenuItem(ctx, H.dock ~= 0 and t('hud.menu.float_bar') or t('hud.menu.dock_bar'), nil, false, H.visible) then H.toggle_dock() end
  if ImGui.MenuItem(ctx, t('hud.menu.arm'), 'F') then H.arm_and_play() end
  if ImGui.MenuItem(ctx, t('hud.menu.cancel'), nil, false, F.active()) then F.cancel('menu'); reaper.OnStopButton() end
  ImGui.Separator(ctx)
  if ImGui.MenuItem(ctx, t('hud.menu.auto_show'), nil, H.cfg.auto_show ~= false) then set_setting('auto_show', not (H.cfg.auto_show ~= false)) end
  if ImGui.MenuItem(ctx, t('hud.menu.load_curve')) then H.load_curve(); say(H.curve_status) end
  ImGui.Separator(ctx)
  if ImGui.MenuItem(ctx, docked and t('nav.menu.undock') or t('nav.menu.dock'), 'Ctrl+D') then app.toggle_dock() end
end

local function draw_header()
  local x0, y0 = ImGui.GetCursorScreenPos(ctx)
  local w = ImGui.GetContentRegionAvail(ctx)
  local dl = ImGui.GetWindowDrawList(ctx)
  local h = H.compact and 22 or 26
  local btn = theme.control_h_small
  local time_s = text.fmt_time(view.position())
  local tw = measure(time_s, 'mono')
  local right_w = 16 + tw + GAP + btn + GAP + btn
  local name_w = w - right_w - 8
  if F.active() then
    theme.push_font(ImGui, ctx, 'small')
    local bw = ImGui.CalcTextSize(ctx, t('hud.badge_flash')) + 12
    theme.pop_font(ImGui, ctx)
    local bx = x0 + w - right_w - bw - 8
    ImGui.DrawList_AddRectFilled(dl, bx, y0 + (h - 18) / 2, bx + bw, y0 + (h + 18) / 2, theme.col('danger'), theme.radius.s)
    row_text(dl, bx + 6, y0, t('hud.badge_flash'), 'text', nil, 'small', h)
    name_w = bx - x0 - 8
  end
  row_text(dl, x0, y0, state.project_name(), 'text', name_w, 'bold', h)
  local x = x0 + w - right_w
  ImGui.DrawList_AddCircleFilled(dl, x + 5, y0 + h / 2, 4, theme.col(view.playing() and 'ok' or 'dim'), 12)
  row_text(dl, x + 16, y0, time_s, 'text', nil, 'mono', h)
  x = x + 16 + tw + GAP
  ImGui.SetCursorScreenPos(ctx, x, y0 + (h - btn) / 2)
  local docked = app.is_docked()
  if widgets.icon_button(ctx, '##dock', docked and 'undock' or 'dock', { flat = true, muted = true,
      tooltip = docked and t('nav.tip.undock') or t('nav.tip.dock') }) then
    app.toggle_dock()
  end
  x = x + btn + GAP
  ImGui.SetCursorScreenPos(ctx, x, y0 + (h - btn) / 2)
  if widgets.icon_button(ctx, '##menu', 'chevron_down', { flat = true, muted = true, tooltip = t('hud.tip.menu') }) then
    ImGui.OpenPopup(ctx, 'hudmenu')
  end
  if ImGui.BeginPopup(ctx, 'hudmenu') then
    draw_menu()
    ImGui.EndPopup(ctx)
  end
  next_line(x0, y0 + h)
end

-- controls -----------------------------------------------------------------------------------------------------------------------

local function draw_controls()
  local x0, y0 = ImGui.GetCursorScreenPos(ctx)
  local w = ImGui.GetContentRegionAvail(ctx)
  local h = theme.control_h
  local bw = (w - 3 * GAP) / 4
  ImGui.SetCursorScreenPos(ctx, x0, y0)
  if widgets.button(ctx, '##show', H.visible and t('hud.btn.hide') or t('hud.btn.show'), { w = bw, h = h, active = H.visible, color = theme.c.accent,
      tooltip = t('hud.tip.show') }) then
    H.show(not H.visible)
  end
  ImGui.SetCursorScreenPos(ctx, x0 + bw + GAP, y0)
  if widgets.button(ctx, '##dockbar', H.dock ~= 0 and t('hud.btn.float_bar') or t('hud.btn.dock_bar'), { w = bw, h = h, disabled = not H.visible,
      tooltip = t('hud.tip.dock_bar') }) then
    H.toggle_dock()
  end
  ImGui.SetCursorScreenPos(ctx, x0 + 2 * (bw + GAP), y0)
  if widgets.button(ctx, '##arm', t('hud.btn.arm'), { w = bw, h = h, color = theme.c.ok, active = F.active(), tooltip = t('hud.tip.arm') }) then
    if F.active() then
      F.cancel('button')
      reaper.OnStopButton()
    else
      H.arm_and_play()
    end
  end
  ImGui.SetCursorScreenPos(ctx, x0 + 3 * (bw + GAP), y0)
  if widgets.button(ctx, '##stop', t('hud.btn.stop'), { w = bw, h = h, color = theme.c.danger, tooltip = t('hud.tip.stop') }) then
    F.cancel('stop')
    reaper.OnStopButton()
  end
  next_line(x0, y0 + h)
end

local function draw_settings()
  local x0, y0 = ImGui.GetCursorScreenPos(ctx)
  local w = ImGui.GetContentRegionAvail(ctx)
  local h = theme.control_h_small
  local dl = ImGui.GetWindowDrawList(ctx)
  local Lc = H.cfg.loudness or {}
  local groups = {
    { key = 'loudness.mode', label = t('hud.set.loudness'), cur = Lc.mode or 'live', options = { { 'live', t('hud.loud.live'), t('hud.tip.loud_live') }, { 'curve', t('hud.loud.curve'), t('hud.tip.loud_curve') }, { 'off', t('hud.loud.off'), t('hud.tip.loud_off') } } },
    { key = 'caption_lang', label = t('hud.set.caption'), cur = H.cfg.caption_lang or 'primary', options = { { 'primary', t('hud.cap.primary'), t('hud.tip.cap_primary') }, { 'secondary', t('hud.cap.secondary'), t('hud.tip.cap_secondary') } } },
    { key = 'time_format', label = t('hud.set.time'), cur = H.cfg.show_time == false and 'off' or (H.cfg.time_format or 'min_sec'),
      options = { { 'min_sec', t('hud.time.min_sec'), t('hud.tip.time') }, { 'timecode', t('hud.time.timecode'), t('hud.tip.time') }, { 'seconds', t('hud.time.seconds'), t('hud.tip.time') }, { 'off', t('hud.time.off'), t('hud.tip.time') } } },
    { key = 'progress.style', label = t('hud.set.progress'), cur = (H.cfg.progress and H.cfg.progress.style) or 'bar', options = { { 'bar', t('hud.prog.bar'), t('hud.tip.progress') }, { 'dots', t('hud.prog.dots'), t('hud.tip.progress') }, { 'off', t('hud.prog.off'), t('hud.tip.progress') } } },
  }
  local x, y = x0, y0
  for i, g in ipairs(groups) do
    theme.push_font(ImGui, ctx, 'small')
    local lw = ImGui.CalcTextSize(ctx, g.label)
    local seg_w = 0
    for _, o in ipairs(g.options) do seg_w = seg_w + ImGui.CalcTextSize(ctx, o[2]) + theme.space[3] end
    theme.pop_font(ImGui, ctx)
    local total = lw + 6 + seg_w
    if x + total > x0 + w and x > x0 then
      x = x0
      y = y + h + GAP
    end
    row_text(dl, x, y, g.label, 'muted', nil, 'small', h)
    ImGui.SetCursorScreenPos(ctx, x + lw + 6, y)
    local chosen, used = widgets.segmented(ctx, '##hset' .. i, g.options, g.cur)
    if chosen then
      if g.key == 'time_format' then
        if chosen == 'off' then set_setting('show_time', false) else set_setting('show_time', true); set_setting('time_format', chosen) end
      else
        set_setting(g.key, chosen)
      end
    end
    x = x + lw + 6 + used + theme.space[3]
  end
  y = y + h + GAP
  x = x0
  local toggles = {
    { 'show_name', t('hud.tog.name'), t('hud.tip.name') },
    { 'show_hints', t('hud.tog.hints'), t('hud.tip.hints') },
    { 'auto_show', t('hud.tog.auto'), t('hud.tip.auto') },
  }
  for i, tg in ipairs(toggles) do
    ImGui.SetCursorScreenPos(ctx, x, y)
    local on = H.cfg[tg[1]] ~= false
    if tg[1] == 'show_hints' then on = H.cfg.show_hints == true end
    local bw = measure(tg[2], 'small') + theme.space[3]
    if widgets.button(ctx, '##tog' .. i, tg[2], { w = bw, h = h, on = on, color = theme.c.accent, font = 'small', tooltip = tg[3] }) then
      set_setting(tg[1], not on)
    end
    x = x + bw + GAP
  end
  next_line(x0, y + h + 2)
end

local function draw_curve()
  local x0, y0 = ImGui.GetCursorScreenPos(ctx)
  local w = ImGui.GetContentRegionAvail(ctx)
  local h = theme.control_h_small
  local dl = ImGui.GetWindowDrawList(ctx)
  local Lc = H.cfg.loudness or {}
  if curve_input == nil then curve_input = Lc.curve_file or '' end
  row_text(dl, x0, y0, t('hud.curve.label'), 'muted', nil, 'small', h)
  local lw = measure(t('hud.curve.label'), 'small') + 6
  local bw = 52
  ImGui.SetCursorScreenPos(ctx, x0 + lw, y0)
  ImGui.SetNextItemWidth(ctx, w - lw - 2 * (bw + GAP))
  theme.push_font(ImGui, ctx, 'small')
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_FramePadding, 6, 2)
  local changed, v = ImGui.InputTextWithHint(ctx, '##curve', t('hud.curve.hint'), curve_input)
  ImGui.PopStyleVar(ctx)
  theme.pop_font(ImGui, ctx)
  if changed then curve_input = v end
  if ImGui.IsItemDeactivatedAfterEdit(ctx) then set_setting('loudness.curve_file', curve_input) end
  widgets.tooltip(ctx, t('hud.tip.curve'))
  ImGui.SetCursorScreenPos(ctx, x0 + w - 2 * bw - GAP, y0)
  if widgets.button(ctx, '##load', t('hud.curve.load'), { w = bw, h = h, font = 'small', tooltip = t('hud.tip.curve_load') }) then
    set_setting('loudness.curve_file', curve_input)
    H.load_curve()
    say(H.curve_status)
  end
  ImGui.SetCursorScreenPos(ctx, x0 + w - bw, y0)
  if widgets.button(ctx, '##loadmode', t('hud.curve.use'), { w = bw, h = h, font = 'small', on = Lc.mode == 'curve', color = theme.c.accent2, tooltip = t('hud.tip.curve_use') }) then
    set_setting('loudness.curve_file', curve_input)
    set_setting('loudness.mode', 'curve')
    H.load_curve()
    say(H.curve_status)
  end
  next_line(x0, y0 + h + 2)
end

-- readout ----------------------------------------------------------------------------------------------------------------------------

local function draw_readout()
  local footer_h = theme.space[2] + (H.compact and 0 or (theme.type.small + theme.space[2]))
  ImGui.PushStyleColor(ctx, ImGui.Col_ChildBg, theme.col('panel'))
  local visible = ImGui.BeginChild(ctx, 'readout', 0, -footer_h, ImGui.ChildFlags_Borders, ImGui.WindowFlags_None)
  ImGui.PopStyleColor(ctx)
  if visible then
    local dl = ImGui.GetWindowDrawList(ctx)
    local x0, y0 = ImGui.GetCursorScreenPos(ctx)
    local w = ImGui.GetContentRegionAvail(ctx)
    local rh = theme.row_h_compact
    local L = H.loud
    local Lc = H.cfg.loudness or {}
    local rows = {
      { t('hud.ro.bar'), H.visible and string.format(t('hud.ro.bar_state'), math.floor(H.bar_w), math.floor(H.bar_h), H.tier, H.dock ~= 0 and t('hud.ro.docked') or t('hud.ro.floating')) or t('hud.ro.hidden'), 'text' },
      { t('hud.ro.shot'), H.shot and (B.title_text() .. '   ' .. text.fmt_time(H.shot.t0) .. ' - ' .. text.fmt_time(H.shot.t1)) or (H.run_active and t('hud.idle.run') or t('hud.idle.no_run')), 'text' },
      { t('hud.ro.caption'), H.shot and (B.caption_text() ~= '' and B.caption_text() or t('dir.current.no_caption')) or '-', 'muted' },
      { t('hud.ro.loudness'), Lc.mode == 'off' and t('hud.loud.off') or string.format('M %s   S %s   I %s   PK %s   (%s)', loudness.fmt(L.m), loudness.fmt(L.s), loudness.fmt(L.i), loudness.fmt(L.pk),
          Lc.mode == 'curve' and (H.loud.curve and t('hud.ro.curve_on') or t('hud.ro.curve_missing')) or t('hud.ro.live_note')), 'muted' },
      { t('hud.ro.flash'), F.active() and string.format(t('hud.ro.flash_state'), F.phase, #F.tokens) or string.format(t('hud.ro.flash_idle'), text.fmt_time(H.end_at())), F.active() and 'warn' or 'muted' },
    }
    if Lc.mode == 'curve' then rows[#rows + 1] = { t('hud.ro.curve'), H.curve_status ~= '' and H.curve_status or t('hud.curve.none'), H.loud.curve and 'muted' or 'warn' } end
    local y = y0
    for _, r in ipairs(rows) do
      row_text(dl, x0 + 6, y, r[1], 'dim', 70, 'small', rh)
      row_text(dl, x0 + 80, y, r[2], r[3], w - 86, 'small', rh)
      ImGui.SetCursorScreenPos(ctx, x0, y)
      ImGui.Dummy(ctx, w, rh)
      widgets.tooltip(ctx, r[2])
      y = y + rh
    end
    next_line(x0, y)
  end
  ImGui.EndChild(ctx)
end

local function draw_footer()
  if H.compact then return end
  local msg = H.tab_msg_frames > 0 and H.tab_msg or nil
  widgets.status(ctx, msg, t('hud.hint'), msg ~= nil)
end

local function handle_keys()
  if not app.focused or ImGui.IsAnyItemActive(ctx) then return end
  local function chord(key) return ImGui.IsKeyChordPressed(ctx, ImGui.Mod_Ctrl | key) end
  if chord(ImGui.Key_D) then app.toggle_dock() end
  if ImGui.IsKeyPressed(ctx, ImGui.Key_H, false) then H.show(not H.visible) end
  if ImGui.IsKeyPressed(ctx, ImGui.Key_F, false) then
    if F.active() then F.cancel('key'); reaper.OnStopButton() else H.arm_and_play() end
  end
  if ImGui.IsKeyPressed(ctx, ImGui.Key_Space, false) then reaper.Main_OnCommand(40044, 0) end
  if ImGui.IsKeyPressed(ctx, ImGui.Key_Escape, false) and F.active() then F.cancel('esc'); reaper.OnStopButton() end
end

function U.draw(app_)
  app = app_
  ctx = app.ctx
  H.compact = app.win_h < (config.get('ui.compact_below_px') or theme.compact_below)
  if H.tab_msg_frames > 0 then H.tab_msg_frames = H.tab_msg_frames - 1 end
  draw_header()
  draw_controls()
  if not H.compact then
    draw_settings()
    draw_curve()
  end
  draw_readout()
  draw_footer()
  handle_keys()
end

U.say = say
return U
