-- modules/glow/ui.lua - the Glow tab: on/off, mode and style, the four intensity sliders with live preview,
-- the performance block (draw time, budget, degrade level), the profiles list, the debug toggles. Drawing
-- only; the engine (engine.lua) paints the overlay, the overlay (overlay.lua) owns the bitmap. Lua 5.4; no globals.

local theme = require('ui.theme')
local widgets = require('ui.widgets')
local text = require('lib.text')
local view = require('lib.view')
local config = require('config')
local state = require('state')
local i18n = require('i18n')
local O = require('modules.glow.overlay')

local t = i18n.t

local U = {}

local ImGui, ctx, app, E, S
local GAP = 4

local function cfg(key)
  return config.get('glow.' .. key)
end

local function scope()
  return cfg('persist.scope') or 'project'
end

function U.init(app_, E_, S_)
  app, E, S = app_, E_, S_
  ImGui = app.ImGui
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
  S.msg = msg
  S.msg_frames = 40
end

-- a click: the value is written at once (the config listener recompiles the engine at the next tick)
local function set_setting(key, value)
  if app then app.note('glow.' .. key) end
  config.set('glow.' .. key, value, scope())
end

function U.toggle_enable()
  set_setting('enable', not (cfg('enable') ~= false))
  say(cfg('enable') ~= false and t('glow.msg.on') or t('glow.msg.off'))
end

-- header --------------------------------------------------------------------------------------------------------------

local function draw_menu()
  local docked = app.is_docked()
  local on = cfg('enable') ~= false
  if ImGui.MenuItem(ctx, on and t('glow.menu.disable') or t('glow.menu.enable'), 'G') then U.toggle_enable() end
  if ImGui.MenuItem(ctx, t('glow.menu.reset_perf')) then E.perf_reset(); E.perf.level = 0 end
  ImGui.Separator(ctx)
  if ImGui.MenuItem(ctx, t('glow.menu.fake'), nil, cfg('debug.fake_meter') == true) then set_setting('debug.fake_meter', not (cfg('debug.fake_meter') == true)) end
  if ImGui.MenuItem(ctx, t('glow.menu.log'), nil, cfg('debug.log') == true) then set_setting('debug.log', not (cfg('debug.log') == true)) end
  ImGui.Separator(ctx)
  if ImGui.MenuItem(ctx, docked and t('nav.menu.undock') or t('nav.menu.dock'), 'Ctrl+D') then app.toggle_dock() end
end

local function draw_header()
  local x0, y0 = ImGui.GetCursorScreenPos(ctx)
  local w = ImGui.GetContentRegionAvail(ctx)
  local dl = ImGui.GetWindowDrawList(ctx)
  local h = S.compact and 22 or 26
  local btn = theme.control_h_small
  local time_s = text.fmt_time(view.position())
  local tw = measure(time_s, 'mono')
  local right_w = 16 + tw + GAP + btn + GAP + btn
  local name_w = w - right_w - 8
  if E.active() and E.alive then
    theme.push_font(ImGui, ctx, 'small')
    local bw = ImGui.CalcTextSize(ctx, t('glow.badge')) + 12
    theme.pop_font(ImGui, ctx)
    local bx = x0 + w - right_w - bw - 8
    ImGui.DrawList_AddRectFilled(dl, bx, y0 + (h - 18) / 2, bx + bw, y0 + (h + 18) / 2, theme.col('accent2'), theme.radius.s)
    row_text(dl, bx + 6, y0, t('glow.badge'), 'on_accent', nil, 'small', h)
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
  if widgets.icon_button(ctx, '##menu', 'chevron_down', { flat = true, muted = true, tooltip = t('glow.tip.menu') }) then
    ImGui.OpenPopup(ctx, 'glowmenu')
  end
  if ImGui.BeginPopup(ctx, 'glowmenu') then
    draw_menu()
    ImGui.EndPopup(ctx)
  end
  next_line(x0, y0 + h)
end

-- controls ------------------------------------------------------------------------------------------------------------

local function draw_controls()
  local x0, y0 = ImGui.GetCursorScreenPos(ctx)
  local w = ImGui.GetContentRegionAvail(ctx)
  local h = theme.control_h
  local dl = ImGui.GetWindowDrawList(ctx)
  local on = cfg('enable') ~= false
  local avail = O.available()
  local bw = 84
  ImGui.SetCursorScreenPos(ctx, x0, y0)
  if widgets.button(ctx, '##enable', on and t('glow.btn.on') or t('glow.btn.off'), { w = bw, h = h, active = on and avail, color = theme.c.ok,
      disabled = not avail, tooltip = t('glow.tip.enable') }) then
    U.toggle_enable()
  end
  local x = x0 + bw + theme.space[3]
  local groups = {
    { key = 'mode', label = t('glow.set.mode'), options = { { 'meter', t('glow.mode.meter'), t('glow.tip.mode_meter') }, { 'item', t('glow.mode.item'), t('glow.tip.mode_item') }, { 'off', t('glow.mode.off'), t('glow.tip.mode_off') } } },
    { key = 'style', label = t('glow.set.style'), options = { { 'bar', t('glow.style.bar'), t('glow.tip.style_bar') }, { 'fill', t('glow.style.fill'), t('glow.tip.style_fill') }, { 'edge', t('glow.style.edge'), t('glow.tip.style_edge') } } },
    { key = 'spark.style', label = t('glow.set.spark'), options = { { 'column', t('glow.spark.column'), t('glow.tip.spark_column') }, { 'beam', t('glow.spark.beam'), t('glow.tip.spark_beam') }, { 'trail', t('glow.spark.trail'), t('glow.tip.spark_trail') } } },
  }
  local y = y0
  for i, g in ipairs(groups) do
    theme.push_font(ImGui, ctx, 'small')
    local lw = ImGui.CalcTextSize(ctx, g.label)
    local seg_w = 0
    for _, o in ipairs(g.options) do seg_w = seg_w + ImGui.CalcTextSize(ctx, o[2]) + theme.space[3] end
    theme.pop_font(ImGui, ctx)
    local total = lw + 6 + seg_w
    if x + total > x0 + w and x > x0 + bw + theme.space[3] then
      x = x0
      y = y + h + GAP
    end
    row_text(dl, x, y, g.label, 'muted', nil, 'small', h)
    ImGui.SetCursorScreenPos(ctx, x + lw + 6, y + (h - theme.control_h_small) / 2)
    local chosen, used = widgets.segmented(ctx, '##set' .. i, g.options, cfg(g.key))
    if chosen then set_setting(g.key, chosen) end
    x = x + lw + 6 + used + theme.space[3]
  end
  next_line(x0, y + h + 2)
end

local SLIDERS = {
  { key = 'warm_amount', label = 'glow.sl.warm', min = 0, max = 1, tip = 'glow.tip.warm' },
  { key = 'meter.tint_gain', label = 'glow.sl.tint', min = 0, max = 1, tip = 'glow.tip.tint', style = 'bar' },
  { key = 'meter.fill_gain', label = 'glow.sl.fill', min = 0, max = 1, tip = 'glow.tip.fill', style = 'fill' },
  { key = 'bar.alpha_gain', label = 'glow.sl.bar', min = 0, max = 1, tip = 'glow.tip.bar', style = 'bar' },
  { key = 'spark.alpha', label = 'glow.sl.spark', min = 0, max = 1, tip = 'glow.tip.spark' },
}

local function draw_sliders()
  local x0, y0 = ImGui.GetCursorScreenPos(ctx)
  local w = ImGui.GetContentRegionAvail(ctx)
  local dl = ImGui.GetWindowDrawList(ctx)
  local h = theme.control_h_small
  local label_w = 46
  local style = cfg('style')
  local y = y0
  theme.push_font(ImGui, ctx, 'small')
  for i, sl in ipairs(SLIDERS) do
    if not sl.style or sl.style == style then
      row_text(dl, x0, y, t(sl.label), 'muted', label_w - 4, 'small', h)
      ImGui.SetCursorScreenPos(ctx, x0 + label_w, y)
      ImGui.SetNextItemWidth(ctx, w - label_w)
      local v = tonumber(cfg(sl.key)) or 0
      local changed, nv = ImGui.SliderDouble(ctx, '##sl' .. i, v, sl.min, sl.max, '%.2f')
      if changed then
        -- live preview: the merge (and the engine through its listener) follows every frame, the file waits
        -- for the release - a write per drag frame stalled the window on macOS (failure note B1)
        app.note('glow.' .. sl.key)
        config.preview('glow.' .. sl.key, nv, scope())
      end
      widgets.tooltip(ctx, t(sl.tip))
      y = y + h + 2
    end
  end
  theme.pop_font(ImGui, ctx)
  next_line(x0, y)
end

-- stats and profiles -----------------------------------------------------------------------------------------------------

local function draw_stats()
  local x0, y0 = ImGui.GetCursorScreenPos(ctx)
  local w = ImGui.GetContentRegionAvail(ctx)
  local dl = ImGui.GetWindowDrawList(ctx)
  local rows = S.compact and 2 or 4
  local lh = 17
  local h = rows * lh + 8
  ImGui.DrawList_AddRectFilled(dl, x0, y0, x0 + w, y0 + h, theme.col('panel'), theme.radius.m)
  local ps = E.perf_stats()
  local budget = tonumber(cfg('perf.budget_ms')) or 2
  local steps = cfg('perf.degrade_steps') or {}
  local over = ps.ema > budget
  local lines = {
    { string.format(t('glow.stat.overlay'), O.w, O.h, O.S, O.available() and (O.bmp and t('glow.stat.live') or t('glow.stat.idle')) or t('glow.stat.missing')), 'text' },
    { string.format(t('glow.stat.frame'), ps.ema, ps.max, ps.p95, budget), over and 'warn' or 'muted' },
    { string.format(t('glow.stat.lit'), E.stats.lit, E.stats.items_lit, E.stats.bus_lit, E.stats.sparks, E.stats.cut_flashes), 'muted' },
    { ps.level > 0 and string.format(t('glow.stat.degraded'), ps.level, table.concat(steps, ', ', 1, ps.level)) or t('glow.stat.full'), ps.level > 0 and 'warn' or 'muted' },
  }
  local y = y0 + 4
  for i = 1, rows do
    row_text(dl, x0 + 8, y, lines[i][1], lines[i][2], w - 16, 'small', lh)
    y = y + lh
  end
  if E.fake then
    theme.push_font(ImGui, ctx, 'small')
    local bw = ImGui.CalcTextSize(ctx, t('glow.badge_fake')) + 10
    theme.pop_font(ImGui, ctx)
    ImGui.DrawList_AddRectFilled(dl, x0 + w - bw - 6, y0 + 4, x0 + w - 6, y0 + 20, theme.col('warn'), theme.radius.s)
    row_text(dl, x0 + w - bw - 1, y0 + 4, t('glow.badge_fake'), 'on_accent', nil, 'small', 16)
  end
  ImGui.SetCursorScreenPos(ctx, x0, y0)
  ImGui.Dummy(ctx, w, h)
  widgets.tooltip(ctx, t('glow.tip.stats'))
  next_line(x0, y0 + h + 4)
end

local function overrides_summary(p)
  local parts = {}
  for _, grp in ipairs({ 'meter', 'detector', 'spark' }) do
    for k, v in pairs(p[grp] or {}) do parts[#parts + 1] = string.format('%s %s', k, tostring(v)) end
  end
  table.sort(parts)
  return table.concat(parts, ', ')
end

local function draw_profiles()
  local footer_h = theme.control_h + theme.space[2] + (S.compact and 0 or (theme.type.small + theme.space[2]))
  ImGui.PushStyleColor(ctx, ImGui.Col_ChildBg, theme.col('panel'))
  local visible = ImGui.BeginChild(ctx, 'profiles', 0, -footer_h, ImGui.ChildFlags_Borders, ImGui.WindowFlags_None)
  ImGui.PopStyleColor(ctx)
  if visible then
    local dl = ImGui.GetWindowDrawList(ctx)
    local rh = theme.row_h_compact
    local x0, y0 = ImGui.GetCursorScreenPos(ctx)
    local w = ImGui.GetContentRegionAvail(ctx)
    row_text(dl, x0 + 6, y0, t('glow.profiles.title'), 'muted', w - 12, 'small', rh)
    local y = y0 + rh
    local profiles = cfg('profiles') or {}
    for _, p in ipairs(profiles) do
      local what = p.family and (t('glow.profiles.family') .. ' ' .. tostring(p.family)) or (t('glow.profiles.rule') .. ' ' .. tostring(p.rule or ''))
      row_text(dl, x0 + 6, y, tostring(p.name), 'text', 80, 'body', rh)
      row_text(dl, x0 + 90, y, what, 'muted', 130, 'small', rh)
      row_text(dl, x0 + 226, y, overrides_summary(p), 'dim', w - 232, 'small', rh)
      ImGui.SetCursorScreenPos(ctx, x0, y)
      ImGui.Dummy(ctx, w, rh)
      widgets.tooltip(ctx, what .. '\n' .. overrides_summary(p))
      y = y + rh
    end
    row_text(dl, x0 + 6, y, t('glow.profiles.default'), 'dim', w - 12, 'small', rh)
    y = y + rh
    row_text(dl, x0 + 6, y, t('glow.profiles.hint'), 'dim', w - 12, 'small', rh)
    next_line(x0, y + rh)
  end
  ImGui.EndChild(ctx)
end

local function draw_empty()
  ImGui.Dummy(ctx, 0, theme.space[3])
  ImGui.Indent(ctx, theme.space[3])
  ImGui.PushTextWrapPos(ctx, 0)
  ImGui.TextColored(ctx, theme.col('warn'), t('glow.empty.title'))
  ImGui.TextColored(ctx, theme.col('muted'), t('glow.empty.body'))
  ImGui.PopTextWrapPos(ctx)
  ImGui.Unindent(ctx, theme.space[3])
end

local function draw_footer()
  local x0, y0 = ImGui.GetCursorScreenPos(ctx)
  local w = ImGui.GetContentRegionAvail(ctx)
  local h = theme.control_h
  local bw = (w - 2 * GAP) / 3
  local fake = cfg('debug.fake_meter') == true
  local logging = cfg('debug.log') == true
  ImGui.SetCursorScreenPos(ctx, x0, y0)
  if widgets.button(ctx, '##fake', t('glow.btn.fake'), { w = bw, h = h, on = fake, color = theme.c.warn, tooltip = t('glow.tip.fake') }) then
    set_setting('debug.fake_meter', not fake)
  end
  ImGui.SetCursorScreenPos(ctx, x0 + bw + GAP, y0)
  if widgets.button(ctx, '##log', t('glow.btn.log'), { w = bw, h = h, on = logging, color = theme.c.accent, tooltip = t('glow.tip.log') }) then
    set_setting('debug.log', not logging)
  end
  ImGui.SetCursorScreenPos(ctx, x0 + 2 * (bw + GAP), y0)
  if widgets.button(ctx, '##perf', t('glow.btn.reset_perf'), { w = bw, h = h, tooltip = t('glow.tip.reset_perf') }) then
    E.perf_reset()
    E.perf.level = 0
    say(t('glow.msg.perf_reset'))
  end
  next_line(x0, y0 + h)
  if not S.compact then
    local msg = S.msg_frames > 0 and S.msg or (E.msg_frames > 0 and E.msg or nil)
    widgets.status(ctx, msg, t('glow.hint'), msg ~= nil)
  end
end

local function handle_keys()
  if not app.focused then return end
  local function chord(key) return ImGui.IsKeyChordPressed(ctx, ImGui.Mod_Ctrl | key) end
  if chord(ImGui.Key_D) then app.toggle_dock() end
  if ImGui.IsKeyPressed(ctx, ImGui.Key_G, false) then U.toggle_enable() end
  if ImGui.IsKeyPressed(ctx, ImGui.Key_Space, false) then reaper.Main_OnCommand(40044, 0) end
end

function U.draw(app_)
  app = app_
  ctx = app.ctx
  S.compact = app.win_h < (config.get('ui.compact_below_px') or theme.compact_below)
  if S.msg_frames > 0 then S.msg_frames = S.msg_frames - 1 end
  -- the sliders preview every frame; the file is written once nothing is being dragged
  if not ImGui.IsAnyItemActive(ctx) then
    config.commit('project')
    config.commit('global')
  end
  draw_header()
  if not O.available() then
    draw_empty()
  else
    draw_controls()
    if not S.compact then draw_sliders() end
    draw_stats()
    draw_profiles()
    draw_footer()
  end
  handle_keys()
end

U.say = say
return U
