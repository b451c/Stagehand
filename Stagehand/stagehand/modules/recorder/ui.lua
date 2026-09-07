-- modules/recorder/ui.lua - the Recorder tab: header with the armed / flash badge, the controls (Arm, Play,
-- Stop, Export), the checklist with fixes, the layout-at-start row, the protocol panel (ctl folder, the
-- companion command, the last tokens) and the layout diary. Drawing only; init.lua and layout.lua act.
-- Lua 5.4; no globals.

local theme = require('ui.theme')
local widgets = require('ui.widgets')
local text = require('lib.text')
local view = require('lib.view')
local config = require('config')
local state = require('state')
local ctl = require('lib.ctl')
local js = require('platform.js')
local i18n = require('i18n')

local t = i18n.t

local U = {}

local ImGui, ctx, app, S, RL, CL, EX, R
local GAP = 4

function U.init(app_, S_, RL_, CL_, EX_, R_)
  app, S, RL, CL, EX, R = app_, S_, RL_, CL_, EX_, R_
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
  R.say(msg)
end

-- the companion command line for this project
function U.companion_command()
  local dir = ctl.dir()
  if not dir then return nil end
  local py = js.is_win and 'python' or 'python3'
  return string.format('%s tools/record_showcase.py --ctl "%s" --mix <mix.wav>', py, dir)
end

local function do_export(kind)
  local path = EX.pick_save_path(kind)
  if not path then say(t('rec.msg.export_cancelled')); return end
  local p, n = EX.export(kind, path)
  if p then say(string.format(t('rec.msg.exported'), n, p)) else say(string.format(t('rec.msg.export_failed'), tostring(n))) end
end

local function do_import(mode)
  local path = EX.pick_open_path()
  if not path then say(t('rec.msg.export_cancelled')); return end
  local n, err = EX.import(path, mode)
  if n then say(string.format(t('rec.msg.imported'), n, path)) else say(string.format(t('rec.msg.import_failed'), tostring(err))) end
end

-- header -------------------------------------------------------------------------------------------------------------------

local function draw_menu()
  local docked = app.is_docked()
  if ImGui.MenuItem(ctx, t('rec.menu.arm'), 'A', false, S.arm == nil) then R.arm('menu') end
  if ImGui.MenuItem(ctx, t('rec.menu.play'), 'F') then R.play() end
  if ImGui.MenuItem(ctx, t('rec.menu.stop'), 'Esc') then R.stop('menu') end
  if ImGui.MenuItem(ctx, t('rec.menu.quit')) then R.quit('menu') end
  ImGui.Separator(ctx)
  if ImGui.MenuItem(ctx, RL.active and t('rec.menu.unlayout') or t('rec.menu.layout'), 'L') then
    if RL.active then RL.restore('menu') else RL.apply('menu') end
  end
  if ImGui.MenuItem(ctx, t('rec.menu.hud_file')) then
    local lines = R.write_hud_file()
    say(lines and t('rec.msg.hud_written') or t('rec.msg.hud_no_bar'))
  end
  ImGui.Separator(ctx)
  if ImGui.MenuItem(ctx, t('rec.menu.export_json'), 'E') then do_export('json') end
  if ImGui.MenuItem(ctx, t('rec.menu.export_csv')) then do_export('csv') end
  if ImGui.MenuItem(ctx, t('rec.menu.import_replace')) then do_import('replace') end
  if ImGui.MenuItem(ctx, t('rec.menu.import_append')) then do_import('append') end
  ImGui.Separator(ctx)
  if ImGui.MenuItem(ctx, t('rec.menu.copy_cmd'), nil, false, ctl.available()) then
    ImGui.SetClipboardText(ctx, U.companion_command() or '')
    say(t('rec.msg.copied'))
  end
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
  local badge, colname
  if S.flash_phase ~= 'idle' and S.flash_phase ~= 'END' and S.flash_phase ~= 'CANCEL' and S.flash_phase ~= 'STOPPED' then
    badge, colname = t('rec.badge_flash'), 'danger'
  elseif S.armed then
    badge, colname = t('rec.badge_armed'), 'accent2'
  end
  if badge then
    theme.push_font(ImGui, ctx, 'small')
    local bw = ImGui.CalcTextSize(ctx, badge) + 12
    theme.pop_font(ImGui, ctx)
    local bx = x0 + w - right_w - bw - 8
    ImGui.DrawList_AddRectFilled(dl, bx, y0 + (h - 18) / 2, bx + bw, y0 + (h + 18) / 2, theme.col(colname), theme.radius.s)
    row_text(dl, bx + 6, y0, badge, colname == 'danger' and 'text' or 'on_accent', nil, 'small', h)
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
  if widgets.icon_button(ctx, '##menu', 'chevron_down', { flat = true, muted = true, tooltip = t('rec.tip.menu') }) then
    ImGui.OpenPopup(ctx, 'recmenu')
  end
  if ImGui.BeginPopup(ctx, 'recmenu') then
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
  if widgets.button(ctx, '##arm', t('rec.btn.arm'), { w = bw, h = h, active = S.armed, color = theme.c.accent2, disabled = S.arm ~= nil, tooltip = t('rec.tip.arm') }) then
    R.arm('button')
  end
  ImGui.SetCursorScreenPos(ctx, x0 + bw + GAP, y0)
  if widgets.button(ctx, '##play', t('rec.btn.play'), { w = bw, h = h, color = theme.c.ok, tooltip = t('rec.tip.play') }) then R.play() end
  ImGui.SetCursorScreenPos(ctx, x0 + 2 * (bw + GAP), y0)
  if widgets.button(ctx, '##stop', t('rec.btn.stop'), { w = bw, h = h, color = theme.c.danger, tooltip = t('rec.tip.stop') }) then R.stop('button') end
  ImGui.SetCursorScreenPos(ctx, x0 + 3 * (bw + GAP), y0)
  if widgets.button(ctx, '##export', t('rec.btn.export'), { w = bw, h = h, tooltip = t('rec.tip.export') }) then ImGui.OpenPopup(ctx, 'exportmenu') end
  if ImGui.BeginPopup(ctx, 'exportmenu') then
    if ImGui.MenuItem(ctx, t('rec.menu.export_json')) then do_export('json') end
    if ImGui.MenuItem(ctx, t('rec.menu.export_csv')) then do_export('csv') end
    ImGui.Separator(ctx)
    if ImGui.MenuItem(ctx, t('rec.menu.import_replace')) then do_import('replace') end
    if ImGui.MenuItem(ctx, t('rec.menu.import_append')) then do_import('append') end
    ImGui.EndPopup(ctx)
  end
  next_line(x0, y0 + h)
end

local function draw_layout_row()
  local x0, y0 = ImGui.GetCursorScreenPos(ctx)
  local w = ImGui.GetContentRegionAvail(ctx)
  local h = theme.control_h_small
  local dl = ImGui.GetWindowDrawList(ctx)
  local bw = 96
  ImGui.SetCursorScreenPos(ctx, x0, y0)
  if widgets.button(ctx, '##layout', RL.active and t('rec.btn.unlayout') or t('rec.btn.layout'), { w = bw, h = h, font = 'small', active = RL.active, color = theme.c.accent,
      disabled = not (js.caps and js.caps.window_move), tooltip = t('rec.tip.layout') }) then
    if RL.active then RL.restore('button') else
      local ok, err = RL.apply('button')
      if not ok then say(tostring(err)) end
    end
  end
  local x = x0 + bw + theme.space[3]
  row_text(dl, x, y0, t('rec.set.monitor'), 'muted', nil, 'small', h)
  local lw = measure(t('rec.set.monitor'), 'small') + 6
  ImGui.SetCursorScreenPos(ctx, x + lw, y0)
  local chosen, used = widgets.segmented(ctx, '##mon', {
    { 'current', t('rec.mon.current'), t('rec.tip.mon_current') }, { 'largest', t('rec.mon.largest'), t('rec.tip.mon_largest') }, { 'pick', t('rec.mon.pick'), t('rec.tip.mon_pick') } },
    config.get('recorder.layout.monitor') or 'current')
  if chosen then config.set('recorder.layout.monitor', chosen, 'project') end
  x = x + lw + used + theme.space[3]
  row_text(dl, x, y0, t('rec.set.window'), 'muted', nil, 'small', h)
  lw = measure(t('rec.set.window'), 'small') + 6
  ImGui.SetCursorScreenPos(ctx, x + lw, y0)
  chosen, used = widgets.segmented(ctx, '##mainw', {
    { 'keep', t('rec.win.keep'), t('rec.tip.win_keep') }, { 'maximize', t('rec.win.maximize'), t('rec.tip.win_maximize') }, { 'custom', t('rec.win.custom'), t('rec.tip.win_custom') } },
    config.get('recorder.layout.main_window') or 'maximize')
  if chosen then config.set('recorder.layout.main_window', chosen, 'project') end
  x = x + lw + used + theme.space[3]
  if x + 90 < x0 + w then
    ImGui.SetCursorScreenPos(ctx, x, y0)
    local on = config.get('recorder.layout.video.show') == true
    if widgets.button(ctx, '##video', t('rec.tog.video'), { w = measure(t('rec.tog.video'), 'small') + theme.space[3], h = h, on = on, color = theme.c.accent, font = 'small', tooltip = t('rec.tip.video') }) then
      config.set('recorder.layout.video.show', not on, 'project')
    end
  end
  next_line(x0, y0 + h + 2)
end

-- checklist ------------------------------------------------------------------------------------------------------------------------

local STATUS_COL = { ok = 'ok', warn = 'warn', off = 'dim', info = 'muted' }

local function draw_checklist()
  if S.rows_frame ~= app.frame - (app.frame % 15) then
    S.rows_frame = app.frame - (app.frame % 15)
    S.rows = CL.rows()
  end
  local rows = S.rows or {}
  local footer_h = theme.space[2] + (S.compact and 0 or (theme.type.small + theme.space[2]))
  local proto_h = S.compact and 0 or 96
  ImGui.PushStyleColor(ctx, ImGui.Col_ChildBg, theme.col('panel'))
  local visible = ImGui.BeginChild(ctx, 'checklist', 0, -(footer_h + proto_h + GAP), ImGui.ChildFlags_Borders, ImGui.WindowFlags_None)
  ImGui.PopStyleColor(ctx)
  if visible then
    local dl = ImGui.GetWindowDrawList(ctx)
    local x0, y0 = ImGui.GetCursorScreenPos(ctx)
    local w = ImGui.GetContentRegionAvail(ctx)
    local rh = theme.row_h_compact
    local y = y0
    local counts = CL.counts(rows)
    row_text(dl, x0 + 6, y, string.format(t('rec.cl.summary'), counts.ok, counts.warn, counts.info), 'muted', w - 12, 'small', rh)
    y = y + rh
    for i, r in ipairs(rows) do
      ImGui.DrawList_AddCircleFilled(dl, x0 + 12, y + rh / 2, 4, theme.col(STATUS_COL[r.status] or 'muted'), 12)
      row_text(dl, x0 + 22, y, r.label, r.status == 'warn' and 'text' or 'muted', 92, 'small', rh)
      local fix_w = r.fix and 44 or 0
      row_text(dl, x0 + 118, y, r.detail, r.status == 'warn' and 'warn' or 'text', w - 124 - fix_w, 'small', rh)
      ImGui.SetCursorScreenPos(ctx, x0, y)
      ImGui.Dummy(ctx, w - fix_w - 4, rh)
      widgets.tooltip(ctx, r.detail)
      if r.fix then
        ImGui.SetCursorScreenPos(ctx, x0 + w - fix_w, y + (rh - 18) / 2)
        if widgets.button(ctx, '##fix' .. i, r.fix_label or t('rec.cl.fix'), { w = fix_w - 4, h = 18, font = 'small', color = theme.c.accent, tooltip = t('rec.cl.fix_tip') }) then
          if r.fix() then S.rows_frame = -1; say(string.format(t('rec.msg.fixed'), r.label)) end
        end
      end
      y = y + rh
    end
    next_line(x0, y)
  end
  ImGui.EndChild(ctx)
end

local function draw_protocol()
  if S.compact then return end
  local footer_h = theme.space[2] + theme.type.small + theme.space[2]
  ImGui.PushStyleColor(ctx, ImGui.Col_ChildBg, theme.col('panel'))
  local visible = ImGui.BeginChild(ctx, 'protocol', 0, -footer_h, ImGui.ChildFlags_Borders, ImGui.WindowFlags_None)
  ImGui.PopStyleColor(ctx)
  if visible then
    local dl = ImGui.GetWindowDrawList(ctx)
    local x0, y0 = ImGui.GetCursorScreenPos(ctx)
    local w = ImGui.GetContentRegionAvail(ctx)
    local rh = theme.row_h_compact
    local cs = ctl.status()
    local dir = ctl.dir()
    local rows = {
      { t('rec.pr.folder'), dir or t('rec.pr.no_project'), dir and 'text' or 'warn' },
      { t('rec.pr.driver'), U.companion_command() or '-', 'muted' },
      { t('rec.pr.last_cmd'), cs.last_cmd and string.format('%s   (%.0f s ago, %d commands)', cs.last_cmd, reaper.time_precise() - (cs.last_cmd_t or 0), cs.n_cmds) or t('rec.pr.none'), 'muted' },
      { t('rec.pr.tokens'), #cs.ring > 0 and cs.ring[#cs.ring] or '-', 'muted' },
    }
    local y = y0
    for _, r in ipairs(rows) do
      row_text(dl, x0 + 6, y, r[1], 'dim', 60, 'small', rh)
      row_text(dl, x0 + 70, y, r[2], r[3], w - 76, 'small', rh)
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
  if S.compact then return end
  local msg = S.msg_frames > 0 and S.msg or nil
  widgets.status(ctx, msg, t('rec.hint'), msg ~= nil)
end

local function handle_keys()
  if not app.focused or ImGui.IsAnyItemActive(ctx) then return end
  local function chord(key) return ImGui.IsKeyChordPressed(ctx, ImGui.Mod_Ctrl | key) end
  if chord(ImGui.Key_D) then app.toggle_dock() end
  if ImGui.IsKeyPressed(ctx, ImGui.Key_A, false) and not S.arm then R.arm('key') end
  if ImGui.IsKeyPressed(ctx, ImGui.Key_F, false) then R.play() end
  if ImGui.IsKeyPressed(ctx, ImGui.Key_E, false) then do_export('json') end
  if ImGui.IsKeyPressed(ctx, ImGui.Key_L, false) then
    if RL.active then RL.restore('key') else RL.apply('key') end
  end
  if ImGui.IsKeyPressed(ctx, ImGui.Key_Escape, false) then R.stop('esc') end
  if ImGui.IsKeyPressed(ctx, ImGui.Key_Space, false) then reaper.Main_OnCommand(40044, 0) end
end

function U.draw(app_)
  app = app_
  ctx = app.ctx
  S.compact = app.win_h < (config.get('ui.compact_below_px') or theme.compact_below)
  draw_header()
  draw_controls()
  if not S.compact then draw_layout_row() end
  draw_checklist()
  draw_protocol()
  draw_footer()
  handle_keys()
end

U.say = say
return U
