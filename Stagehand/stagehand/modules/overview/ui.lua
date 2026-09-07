-- modules/overview/ui.lua - the Overview tab: apply / restore the overview layout, the summary of what the
-- layout did (rows, lanes, view, content height, pages), quick settings (track and lane heights, minimum
-- points, view range, hide rule), the capture section (companion command line, guided mode) and the page
-- counter window shown while a capture runs. Drawing only; layout.lua changes the project. Lua 5.4; no globals.

local theme = require('ui.theme')
local widgets = require('ui.widgets')
local text = require('lib.text')
local config = require('config')
local state = require('state')
local ctl = require('lib.ctl')
local js = require('platform.js')
local i18n = require('i18n')

local t = i18n.t

local U = {}

local ImGui, ctx, app, L, S
local GAP = 4
local rule_input = nil

function U.init(app_, L_, S_)
  app, L, S = app_, L_, S_
  ImGui = app.ImGui
end

local function cfg(key)
  return config.get('overview.' .. key)
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

local function set_setting(key, value)
  config.set('overview.' .. key, value, 'project')
  if L.active and not L.capture then L.apply('settings') end
end

-- the companion command line for this project (shown and copied to the clipboard)
function U.companion_command()
  local dir = ctl.dir()
  if not dir then return nil end
  local py = js.is_win and 'python' or 'python3'
  return string.format('%s tools/overview_capture.py --ctl "%s"', py, dir)
end

-- header -------------------------------------------------------------------------------------------------------------------

local function draw_menu()
  local docked = app.is_docked()
  if ImGui.MenuItem(ctx, L.active and t('ovw.menu.restore') or t('ovw.menu.apply'), 'Ctrl+Enter') then
    if L.active then L.restore('menu') else L.apply('menu') end
  end
  if ImGui.MenuItem(ctx, t('ovw.menu.guided'), 'G', false, not L.capture) then U.start_guided() end
  if ImGui.MenuItem(ctx, t('ovw.menu.copy_cmd'), nil, false, ctl.available()) then
    ImGui.SetClipboardText(ctx, U.companion_command() or '')
    say(t('ovw.msg.copied'))
  end
  ImGui.Separator(ctx)
  if ImGui.MenuItem(ctx, docked and t('nav.menu.undock') or t('nav.menu.dock'), 'Ctrl+D') then app.toggle_dock() end
end

local function draw_header()
  local x0, y0 = ImGui.GetCursorScreenPos(ctx)
  local w = ImGui.GetContentRegionAvail(ctx)
  local dl = ImGui.GetWindowDrawList(ctx)
  local h = S.compact and 22 or 26
  local btn = theme.control_h_small
  local right_w = btn + GAP + btn
  local name_w = w - right_w - 8
  if L.active then
    theme.push_font(ImGui, ctx, 'small')
    local bw = ImGui.CalcTextSize(ctx, t('ovw.badge')) + 12
    theme.pop_font(ImGui, ctx)
    local bx = x0 + w - right_w - bw - 8
    ImGui.DrawList_AddRectFilled(dl, bx, y0 + (h - 18) / 2, bx + bw, y0 + (h + 18) / 2, theme.col('accent2'), theme.radius.s)
    row_text(dl, bx + 6, y0, t('ovw.badge'), 'on_accent', nil, 'small', h)
    ImGui.SetCursorScreenPos(ctx, bx, y0 + (h - 18) / 2)
    ImGui.Dummy(ctx, bw, 18)
    widgets.tooltip(ctx, t('ovw.badge_tip'))
    name_w = bx - x0 - 8
  end
  row_text(dl, x0, y0, state.project_name(), 'text', name_w, 'bold', h)
  local x = x0 + w - right_w
  ImGui.SetCursorScreenPos(ctx, x, y0 + (h - btn) / 2)
  local docked = app.is_docked()
  if widgets.icon_button(ctx, '##dock', docked and 'undock' or 'dock', { flat = true, muted = true,
      tooltip = docked and t('nav.tip.undock') or t('nav.tip.dock') }) then
    app.toggle_dock()
  end
  x = x + btn + GAP
  ImGui.SetCursorScreenPos(ctx, x, y0 + (h - btn) / 2)
  if widgets.icon_button(ctx, '##menu', 'chevron_down', { flat = true, muted = true, tooltip = t('ovw.tip.menu') }) then
    ImGui.OpenPopup(ctx, 'ovwmenu')
  end
  if ImGui.BeginPopup(ctx, 'ovwmenu') then
    draw_menu()
    ImGui.EndPopup(ctx)
  end
  next_line(x0, y0 + h)
end

-- controls -----------------------------------------------------------------------------------------------------------------------

function U.start_guided()
  local c, err = L.start_capture('guided')
  if not c then say(tostring(err)) else say(string.format(t('ovw.msg.guided_started'), #c.pages)) end
end

local function draw_controls()
  local x0, y0 = ImGui.GetCursorScreenPos(ctx)
  local w = ImGui.GetContentRegionAvail(ctx)
  local h = theme.control_h
  local bw = (w - 2 * GAP) / 3
  ImGui.SetCursorScreenPos(ctx, x0, y0)
  if widgets.button(ctx, '##apply', L.active and t('ovw.btn.restore') or t('ovw.btn.apply'), { w = bw, h = h, active = L.active, color = theme.c.accent,
      tooltip = t('ovw.tip.apply') }) then
    if L.active then
      local st = L.restore('button')
      say(string.format(t('ovw.msg.restored'), st.restored))
    else
      local st = L.apply('button')
      say(string.format(t('ovw.msg.applied'), st.shown, st.lanes_open))
    end
  end
  ImGui.SetCursorScreenPos(ctx, x0 + bw + GAP, y0)
  if widgets.button(ctx, '##guided', t('ovw.btn.guided'), { w = bw, h = h, color = theme.c.ok, disabled = L.capture ~= nil or not (js.caps and js.caps.scroll),
      tooltip = t('ovw.tip.guided') }) then
    U.start_guided()
  end
  ImGui.SetCursorScreenPos(ctx, x0 + 2 * (bw + GAP), y0)
  if widgets.button(ctx, '##copy', t('ovw.btn.copy_cmd'), { w = bw, h = h, disabled = not ctl.available(), tooltip = t('ovw.tip.copy_cmd') }) then
    ImGui.SetClipboardText(ctx, U.companion_command() or '')
    say(t('ovw.msg.copied'))
  end
  next_line(x0, y0 + h)
end

local function draw_settings()
  local x0, y0 = ImGui.GetCursorScreenPos(ctx)
  local w = ImGui.GetContentRegionAvail(ctx)
  local h = theme.control_h_small
  local dl = ImGui.GetWindowDrawList(ctx)
  local x, y = x0, y0
  -- three sliders on one row
  local sliders = {
    { 'track_px', t('ovw.set.track_px'), 20, 120, '%d px', t('ovw.tip.track_px') },
    { 'env_lane_px', t('ovw.set.env_px'), 16, 80, '%d px', t('ovw.tip.env_px') },
    { 'env_min_points', t('ovw.set.min_points'), 1, 10, '%d', t('ovw.tip.min_points') },
  }
  local sw = (w - 2 * GAP) / 3
  for i, s in ipairs(sliders) do
    ImGui.SetCursorScreenPos(ctx, x + (i - 1) * (sw + GAP), y)
    row_text(dl, x + (i - 1) * (sw + GAP), y, s[2], 'muted', sw, 'small', h)
    local lw = measure(s[2], 'small') + 6
    ImGui.SetCursorScreenPos(ctx, x + (i - 1) * (sw + GAP) + lw, y)
    ImGui.SetNextItemWidth(ctx, sw - lw)
    theme.push_font(ImGui, ctx, 'small')
    ImGui.PushStyleVar(ctx, ImGui.StyleVar_FramePadding, 4, 1)
    local cur = math.floor(tonumber(cfg(s[1])) or s[3])
    local changed, v = ImGui.SliderInt(ctx, '##sl' .. i, cur, s[3], s[4], s[5])
    ImGui.PopStyleVar(ctx)
    theme.pop_font(ImGui, ctx)
    widgets.tooltip(ctx, s[6])
    if changed then config.preview('overview.' .. s[1], v, 'project') end
    if ImGui.IsItemDeactivatedAfterEdit(ctx) then
      config.commit('project')
      if L.active and not L.capture then L.apply('settings') end
    end
  end
  y = y + h + GAP
  -- range mode + hide rule
  row_text(dl, x0, y, t('ovw.set.range'), 'muted', nil, 'small', h)
  local lw = measure(t('ovw.set.range'), 'small') + 6
  ImGui.SetCursorScreenPos(ctx, x0 + lw, y)
  local chosen, used = widgets.segmented(ctx, '##range', {
    { 'picture', t('ovw.range.picture'), t('ovw.tip.range_picture') }, { 'project', t('ovw.range.project'), t('ovw.tip.range_project') },
    { 'custom', t('ovw.range.custom'), t('ovw.tip.range_custom') } }, cfg('range.mode') or 'picture')
  if chosen then set_setting('range.mode', chosen) end
  local rx = x0 + lw + used + theme.space[3]
  row_text(dl, rx, y, t('ovw.set.hide'), 'muted', nil, 'small', h)
  local hw = measure(t('ovw.set.hide'), 'small') + 6
  if rule_input == nil then rule_input = cfg('hide_rule') or '' end
  ImGui.SetCursorScreenPos(ctx, rx + hw, y)
  ImGui.SetNextItemWidth(ctx, x0 + w - rx - hw)
  theme.push_font(ImGui, ctx, 'small')
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_FramePadding, 6, 2)
  local changed, v = ImGui.InputTextWithHint(ctx, '##hide', t('ovw.hide.hint'), rule_input)
  ImGui.PopStyleVar(ctx)
  theme.pop_font(ImGui, ctx)
  if changed then rule_input = v end
  if ImGui.IsItemDeactivatedAfterEdit(ctx) then set_setting('hide_rule', rule_input) end
  widgets.tooltip(ctx, t('ovw.tip.hide'))
  next_line(x0, y + h + 2)
end

-- summary ------------------------------------------------------------------------------------------------------------------------

local function draw_summary()
  local footer_h = theme.space[2] + (S.compact and 0 or (theme.type.small + theme.space[2]))
  ImGui.PushStyleColor(ctx, ImGui.Col_ChildBg, theme.col('panel'))
  local visible = ImGui.BeginChild(ctx, 'summary', 0, -footer_h, ImGui.ChildFlags_Borders, ImGui.WindowFlags_None)
  ImGui.PopStyleColor(ctx)
  if visible then
    local dl = ImGui.GetWindowDrawList(ctx)
    local x0, y0 = ImGui.GetCursorScreenPos(ctx)
    local w = ImGui.GetContentRegionAvail(ctx)
    local rh = theme.row_h_compact
    local st = L.stats
    local rows = {}
    if st then
      rows[#rows + 1] = { t('ovw.ro.rows'), string.format(t('ovw.ro.rows_v'), st.shown, st.hidden, st.track_px), 'text' }
      rows[#rows + 1] = { t('ovw.ro.lanes'), string.format(t('ovw.ro.lanes_v'), st.lanes_open, st.lanes_closed, st.env_px), 'text' }
      rows[#rows + 1] = { t('ovw.ro.view'), string.format(t('ovw.ro.view_v'), text.fmt_time(st.end_s), t(('ovw.range.%s'):format(st.rule))), 'text' }
    else
      local _, counts = L.plan()
      rows[#rows + 1] = { t('ovw.ro.rows'), string.format(t('ovw.ro.plan_v'), counts.shown, counts.hidden, counts.lanes_open), 'muted' }
      local end_s, rule = L.range_end()
      rows[#rows + 1] = { t('ovw.ro.view'), string.format(t('ovw.ro.view_v'), text.fmt_time(end_s), t(('ovw.range.%s'):format(rule))), 'muted' }
    end
    if S.geometry_frame ~= app.frame - (app.frame % 30) then
      S.geometry_frame = app.frame - (app.frame % 30)
      S.geometry = L.geometry()
    end
    local g = S.geometry
    if g then
      local pages = g.scroll and g.scroll.page > 0 and (1 + math.ceil(math.max(0, g.scroll.max - g.scroll.page) / math.max(1, g.scroll.page - (tonumber(cfg('capture.page_overlap_px')) or 0)))) or 1
      rows[#rows + 1] = { t('ovw.ro.picture'), string.format(t('ovw.ro.picture_v'), g.arrange[3] - g.tcp_left, g.ruler_h + g.content_h, g.ruler_h, pages, g.client_h), 'text' }
    else
      rows[#rows + 1] = { t('ovw.ro.picture'), t('ovw.ro.no_js'), 'warn' }
    end
    local dir = ctl.dir()
    rows[#rows + 1] = { t('ovw.ro.companion'), dir and (U.companion_command() or '') or t('ovw.ro.no_project'), dir and 'muted' or 'warn' }
    local cs = ctl.status()
    if cs.last_cmd then rows[#rows + 1] = { t('ovw.ro.last_cmd'), string.format('%s   (%.0f s ago)', cs.last_cmd, reaper.time_precise() - (cs.last_cmd_t or 0)), 'muted' } end
    if L.capture then
      rows[#rows + 1] = { t('ovw.ro.capture'), string.format(t('ovw.ro.capture_v'), L.capture.mode, L.capture.i, #L.capture.pages, tostring(L.capture.dir)), 'warn' }
    end
    local y = y0
    for _, r in ipairs(rows) do
      row_text(dl, x0 + 6, y, r[1], 'dim', 76, 'small', rh)
      row_text(dl, x0 + 86, y, r[2], r[3], w - 92, 'small', rh)
      ImGui.SetCursorScreenPos(ctx, x0, y)
      ImGui.Dummy(ctx, w, rh)
      widgets.tooltip(ctx, r[2])
      y = y + rh
    end
    ImGui.Spacing(ctx)
    theme.push_font(ImGui, ctx, 'small')
    ImGui.SetCursorScreenPos(ctx, x0 + 6, y + 4)
    ImGui.PushTextWrapPos(ctx, 0)   -- wrap at the child's content edge (a local x, not a screen x)
    ImGui.TextColored(ctx, theme.col('muted'), t('ovw.help'))
    ImGui.PopTextWrapPos(ctx)
    theme.pop_font(ImGui, ctx)
  end
  ImGui.EndChild(ctx)
end

local function draw_footer()
  if S.compact then return end
  local msg = (S.msg_frames > 0 and S.msg ~= '') and S.msg or (L.msg_frames > 0 and L.msg or nil)
  widgets.status(ctx, msg, t('ovw.hint'), msg ~= nil)
end

-- the page counter window (guided capture) -----------------------------------------------------------------------------------

function U.draw_counter(app_)
  local c = L.capture
  if not c or c.mode ~= 'guided' then return end
  ctx = app_.ctx
  local w, h = 300, 96
  if not S.counter_placed then
    S.counter_placed = true
    local g = L.geometry()
    if g then
      -- outside the picture: under the main window when the monitor has room, else over the transport strip
      -- at the bottom right (below the arrange, outside the crop)
      local _, _, _, mb = js.monitor_of(g.main[1], g.main[2], g.main[3], g.main[4], true)
      local x, y = g.main[3] - w - 24, g.main[4] - h - 8
      if mb and mb - g.main[4] >= h + 16 then y = g.main[4] + 8 end
      ImGui.SetNextWindowPos(ctx, x, y, ImGui.Cond_Always)
    end
  end
  ImGui.SetNextWindowSize(ctx, w, h, ImGui.Cond_Always)
  local flags = ImGui.WindowFlags_NoCollapse | ImGui.WindowFlags_NoResize | ImGui.WindowFlags_NoDocking | ImGui.WindowFlags_NoScrollbar
  local visible, open = ImGui.Begin(ctx, t('ovw.counter.title') .. '###ovwcounter', true, flags)
  if visible then
    local ok, err = pcall(function()
      theme.push_font(ImGui, ctx, 'title')
      ImGui.Text(ctx, c.pending and t('ovw.counter.preparing') or string.format(t('ovw.counter.page'), c.i, #c.pages))
      theme.pop_font(ImGui, ctx)
      theme.push_font(ImGui, ctx, 'small')
      if c.next_at then
        ImGui.TextColored(ctx, theme.col('muted'), string.format(t('ovw.counter.auto'), math.max(0, c.next_at - reaper.time_precise())))
      else
        ImGui.TextColored(ctx, theme.col('muted'), t('ovw.counter.hint'))
      end
      theme.pop_font(ImGui, ctx)
      local bw = (w - 16 - 2 * GAP) / 3
      if widgets.button(ctx, '##prev', t('ovw.counter.prev'), { w = bw, h = theme.control_h_small, font = 'small', disabled = c.i <= 1 }) then L.guided_prev() end
      ImGui.SameLine(ctx, 0, GAP)
      if widgets.button(ctx, '##next', c.i >= #c.pages and t('ovw.counter.done') or t('ovw.counter.next'), { w = bw, h = theme.control_h_small, font = 'small', color = theme.c.accent, active = true }) then L.guided_next() end
      ImGui.SameLine(ctx, 0, GAP)
      if widgets.button(ctx, '##stop', t('ovw.counter.stop'), { w = bw, h = theme.control_h_small, font = 'small', color = theme.c.danger }) then L.end_capture('counter') end
      if ImGui.IsWindowFocused(ctx) then
        if ImGui.IsKeyPressed(ctx, ImGui.Key_Space, false) or ImGui.IsKeyPressed(ctx, ImGui.Key_N, false) or ImGui.IsKeyPressed(ctx, ImGui.Key_RightArrow, false) then L.guided_next() end
        if ImGui.IsKeyPressed(ctx, ImGui.Key_P, false) or ImGui.IsKeyPressed(ctx, ImGui.Key_LeftArrow, false) then L.guided_prev() end
        if ImGui.IsKeyPressed(ctx, ImGui.Key_Escape, false) then L.end_capture('esc') end
      end
    end)
    ImGui.End(ctx)
    if not ok then error(err, 0) end
  end
  if not open then L.end_capture('closed') end
end

local function handle_keys()
  if not app.focused or ImGui.IsAnyItemActive(ctx) then return end
  local function chord(key) return ImGui.IsKeyChordPressed(ctx, ImGui.Mod_Ctrl | key) end
  if chord(ImGui.Key_D) then app.toggle_dock() end
  if chord(ImGui.Key_Enter) then
    if L.active then L.restore('key') else L.apply('key') end
  end
  if ImGui.IsKeyPressed(ctx, ImGui.Key_G, false) and not L.capture then U.start_guided() end
end

function U.draw(app_)
  app = app_
  ctx = app.ctx
  S.compact = app.win_h < (config.get('ui.compact_below_px') or theme.compact_below)
  if S.msg_frames > 0 then S.msg_frames = S.msg_frames - 1 end
  draw_header()
  draw_controls()
  if not S.compact then draw_settings() end
  draw_summary()
  draw_footer()
  handle_keys()
end

U.say = say
return U
