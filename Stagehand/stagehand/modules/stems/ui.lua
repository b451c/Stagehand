-- modules/stems/ui.lua - the Stems tab: header with the batch badge, render controls, quick render settings
-- (format, range, existing files, pattern, folder), the progress strip of a running batch, the stem list
-- (enable, name, source, summary, last result) with a context menu, the Add menu (bulk builders, presets), the
-- matrix editor (tracks x stems, cells off / S / I / M), the pre-flight panel with fixes and the results panel.
-- Drawing only; the model holds the stems, the engine changes the project. Lua 5.4; no globals.

local theme = require('ui.theme')
local widgets = require('ui.widgets')
local icons = require('ui.icons')
local text = require('lib.text')
local config = require('config')
local state = require('state')
local families = require('lib.families')
local i18n = require('i18n')
local RS = require('modules.stems.results')

local t = i18n.t

local U = {}

local ImGui, ctx, app, S, MD, R, E
local GAP = 4
local BTN = 22
local PANEL_MAX_H = 170
local MATRIX_ID = '###stems_matrix'

local MX = { open = false, draft = nil, filter = '', request = false, scroll_to = nil }
local rename = { k = nil, text = '' }
local pattern_input, dir_input = nil, nil
local preset_name = ''

function U.init(app_, S_, MD_, R_, E_)
  app, S, MD, R, E = app_, S_, MD_, R_, E_
  ImGui = app.ImGui
end

local function cfg(key)
  return config.get('stems.' .. key)
end

local function set_cfg(key, v)
  config.set('stems.' .. key, v, 'project')
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

local function row_text_right(dl, x_right, y0, s, colname, font, rh)
  local tw = measure(s, font)
  row_text(dl, x_right - tw, y0, s, colname, nil, font, rh)
  return tw
end

local function row_button(x, y0, rh, id, kind, o)
  ImGui.SetCursorScreenPos(ctx, x, y0 + (rh - BTN) / 2)
  o = o or {}
  o.w, o.h = BTN, BTN
  return widgets.icon_button(ctx, id, kind, o)
end

local function next_line(x, y)
  ImGui.SetCursorScreenPos(ctx, x, y)
  ImGui.Dummy(ctx, 0, 0)
end

local function say(msg)
  S.msg = msg
  S.msg_frames = 40
end
U.say = say

local function level_color(level)
  if level == 'error' then return theme.c.danger elseif level == 'warn' then return theme.c.warn elseif level == 'ok' then return theme.c.ok end
  return theme.c.accent
end

local function status_color(st)
  if st == 'ok' then return theme.c.ok elseif st == 'silent' then return theme.c.warn elseif st == 'error' then return theme.c.danger end
  return theme.c.dim
end

-- the last result row of a stem (by name), if any
local function result_of(s)
  local r = E.results
  if not r or not r.rows then return nil end
  for _, row in ipairs(r.rows) do
    if row.name == s.name then return row end
  end
  return nil
end

-- actions --------------------------------------------------------------------------------------------------------------------------

local function add_many(list, what)
  local n = 0
  for _, s in ipairs(list) do
    MD.stems[#MD.stems + 1] = s
    s.name = MD.unique_name(s.name)
    n = n + 1
  end
  -- unique_name above compared against the list as it grew; fix names that were unique before their own insert
  MD.save()
  say(string.format(t('stems.msg.added'), n, what))
  S.hi = #MD.stems
  return n
end

local function add_from_families()
  local list = MD.from_families()
  if #list == 0 then say(t('stems.msg.nothing')) return end
  add_many(list, t('stems.src.family'))
end

local function add_from_folders()
  local list = MD.from_folders()
  if #list == 0 then say(t('stems.msg.no_folders')) return end
  add_many(list, t('stems.src.folder'))
end

local function add_from_selection()
  local s, n = MD.from_selection()
  if not s then say(t('stems.msg.no_selection')) return end
  MD.add(s)
  S.hi = #MD.stems
  say(string.format(t('stems.msg.added_one'), s.name, n))
end

local function add_from_scenes()
  local list = MD.from_scenes()
  if #list == 0 then say(t('stems.msg.no_scenes')) return end
  add_many(list, t('stems.src.scene'))
end

local function add_capture()
  local s, n = MD.capture()
  if n == 0 then say(t('stems.msg.nothing_soloed')) return end
  MD.add(s)
  S.hi = #MD.stems
  say(string.format(t('stems.msg.added_one'), s.name, n))
end

local function add_empty()
  local s = MD.sanitize({ name = t('stems.name.mix'), source = { kind = 'manual', name = '' } })
  MD.add(s)
  S.hi = #MD.stems
end

local function render(subset, why)
  local ok = E.start(subset, why)
  if not ok then S.show_preflight = true end
  return ok
end

local function render_selected()
  if S.hi < 1 or not MD.stems[S.hi] then say(t('stems.msg.pick_one')) return end
  render({ [S.hi] = true }, 'ui')
end

function U.preflight()
  E.preflight_rows, E.preflight_counts = E.preflight()
  S.show_preflight = true
  local c = E.preflight_counts
  say(string.format(t('stems.msg.preflight'), c.error, c.warn, c.info))
end

local function open_folder()
  local dir = E.results and E.results.dir or R.out_dir()
  if not dir then say(t('stems.msg.no_dir')) return end
  if reaper.CF_ShellExecute then
    reaper.CF_ShellExecute(dir)
  else
    ImGui.SetClipboardText(ctx, dir)
    say(t('stems.msg.dir_copied'))
  end
end

-- matrix editor ---------------------------------------------------------------------------------------------------------------------

function U.open_matrix(k)
  MX.request = true
  MX.scroll_to = k
end

-- closes the matrix on the next frame (scripted scenarios; the buttons close it themselves)
function U.close_matrix()
  MX.close_request = true
end

local MX_NAME_INDENT, MX_NAME_MIN, MX_NAME_MAX_FRAC = 14, 120, 0.6

-- the track column is measured from the widest name (small font, its folder indent, the family dot) instead
-- of a pixel constant: real sessions have 40-character names that a 220 px column cut short
function U.matrix_name_width(modal_w)
  ctx = ctx or app.ctx   -- the self-test measures before the tab was ever drawn
  local widest = 0
  theme.push_font(ImGui, ctx, 'small')
  for _, e in ipairs(MD.D.tracks) do
    local tw = ImGui.CalcTextSize(ctx, e.name) + MX_NAME_INDENT + e.depth * 10 + 12
    if tw > widest then widest = tw end
  end
  theme.pop_font(ImGui, ctx)
  local max_w = math.floor((modal_w or 720) * MX_NAME_MAX_FRAC)
  return math.floor(math.max(MX_NAME_MIN, math.min(widest, max_w)) + 0.5), widest
end

local function matrix_handle_request()
  if not MX.request then return end
  MX.request = false
  MX.draft = {}
  for _, s in ipairs(MD.stems) do MX.draft[#MX.draft + 1] = MD.copy(s) end
  MX.open = true
  MD.check_refresh()
  MX.name_w, MX.name_widest = U.matrix_name_width(720)
  ImGui.OpenPopup(ctx, t('stems.mx.title') .. MATRIX_ID)
end

local function matrix_save()
  for k, d in ipairs(MX.draft) do
    local s = MD.stems[k]
    if s and s.id == d.id then
      s.cells, s.names = d.cells, d.names
    end
  end
  MD.save()
  say(t('stems.msg.matrix_saved'))
end

local CELL_LABEL = { S = 'S', I = 'I', M = 'M' }

local function draw_matrix()
  local d = MX.draft
  local fams = MD.D.fams
  theme.push_font(ImGui, ctx, 'small')
  ImGui.TextColored(ctx, theme.col('muted'), t('stems.mx.help'))
  theme.pop_font(ImGui, ctx)
  local changed, v = widgets.search_field(ctx, '##mxfilter', MX.filter, t('stems.mx.filter_hint'), 260)
  if changed then MX.filter = v end
  ImGui.SameLine(ctx, 0, theme.space[3])
  local show_hidden = cfg('matrix.show_hidden') == true
  if widgets.button(ctx, '##mxhidden', t('stems.mx.show_hidden'), { h = theme.control_h_small, font = 'small', on = show_hidden, tooltip = t('cfg.stems.matrix.show_hidden.tip') }) then
    set_cfg('matrix.show_hidden', not show_hidden)
  end
  local rows = {}
  local filt = MX.filter:lower()
  for _, e in ipairs(MD.D.tracks) do
    local visible = show_hidden or reaper.GetMediaTrackInfo_Value(e.tr, 'B_SHOWINTCP') == 1
    if visible and (filt == '' or e.name:lower():find(filt, 1, true) or (e.fam or ''):lower():find(filt, 1, true)) then rows[#rows + 1] = e end
  end
  local n_cols = #d
  local flags = ImGui.TableFlags_ScrollX | ImGui.TableFlags_ScrollY | ImGui.TableFlags_BordersInnerV | ImGui.TableFlags_RowBg
    | ImGui.TableFlags_SizingFixedFit | ImGui.TableFlags_Resizable
  local avail_h = math.max(200, ImGui.GetContentRegionAvail(ctx) - theme.control_h - theme.type.small - theme.space[4] * 2)
  -- the table id carries the measured width: a new measurement (another project, renamed tracks) starts from it,
  -- a width the user dragged stays while the measurement holds
  local name_w = MX.name_w or 220
  if ImGui.BeginTable(ctx, 'matrix' .. name_w, n_cols + 1, flags, 0, avail_h) then
    ImGui.TableSetupScrollFreeze(ctx, 1, 1)
    ImGui.TableSetupColumn(ctx, t('stems.mx.track'), ImGui.TableColumnFlags_WidthFixed, name_w)
    for k = 1, n_cols do ImGui.TableSetupColumn(ctx, tostring(k), ImGui.TableColumnFlags_WidthFixed, 28) end
    ImGui.TableNextRow(ctx, ImGui.TableRowFlags_Headers)
    ImGui.TableNextColumn(ctx)
    theme.push_font(ImGui, ctx, 'small')
    ImGui.TextColored(ctx, theme.col('muted'), t('stems.mx.track'))
    for k = 1, n_cols do
      ImGui.TableNextColumn(ctx)
      local on = d[k].enabled
      ImGui.TextColored(ctx, theme.col(on and 'text' or 'dim'), string.format('%2d', k))
      if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, string.format('%d. %s\n%s', k, d[k].name, MD.summary(d[k]))) end
    end
    theme.pop_font(ImGui, ctx)
    local dl = ImGui.GetWindowDrawList(ctx)
    for _, e in ipairs(rows) do
      ImGui.TableNextRow(ctx)
      ImGui.TableNextColumn(ctx)
      ImGui.PushID(ctx, e.guid)
      local x, y = ImGui.GetCursorScreenPos(ctx)
      local col = families.color(fams, e.fam)
      ImGui.DrawList_AddCircleFilled(dl, x + 6 + e.depth * 10, y + 9, 3.5, theme.rgba(col), 10)
      ImGui.SetCursorScreenPos(ctx, x + 14 + e.depth * 10, y)
      theme.push_font(ImGui, ctx, 'small')
      ImGui.TextColored(ctx, theme.col(e.folder and 'text' or 'muted'), e.name)
      theme.pop_font(ImGui, ctx)
      if ImGui.IsItemHovered(ctx) then ImGui.SetTooltip(ctx, string.format('%d. %s  (%s)', e.n, e.name, e.fam or '')) end
      for k = 1, n_cols do
        ImGui.TableNextColumn(ctx)
        local s = d[k]
        local cell = s.cells[e.guid]
        local cx, cy = ImGui.GetCursorScreenPos(ctx)
        local clicked = ImGui.InvisibleButton(ctx, '##c' .. k, 24, 18)
        local hovered = ImGui.IsItemHovered(ctx)
        local c = theme.c
        local bg = cell == 'S' and c.accent or (cell == 'I' and c.accent2 or (cell == 'M' and c.danger or nil))
        if bg then
          ImGui.DrawList_AddRectFilled(dl, cx + 2, cy + 1, cx + 22, cy + 17, theme.rgba(bg, hovered and 0.85 or 1), 3)
          theme.push_font(ImGui, ctx, 'small')
          local tw, th = ImGui.CalcTextSize(ctx, CELL_LABEL[cell])
          ImGui.DrawList_AddText(dl, cx + 12 - tw / 2, cy + 9 - th / 2, theme.rgba(theme.on(bg)), CELL_LABEL[cell])
          theme.pop_font(ImGui, ctx)
        elseif hovered then
          ImGui.DrawList_AddRect(dl, cx + 2, cy + 1, cx + 22, cy + 17, theme.rgba(c.line), 3)
        end
        if hovered then
          ImGui.SetTooltip(ctx, string.format(t('stems.mx.cell_tip'), s.name, e.name, t(('stems.cell.%s'):format(cell or 'off'))))
          if ImGui.IsMouseClicked(ctx, ImGui.MouseButton_Right) then MD.set_cell(s, e.guid, nil) end
        end
        if clicked then MD.set_cell(s, e.guid, MD.next_cell(cell), e.name) end
      end
      ImGui.PopID(ctx)
    end
    ImGui.EndTable(ctx)
  end
  theme.push_font(ImGui, ctx, 'small')
  ImGui.TextColored(ctx, theme.col('muted'), string.format(t('stems.mx.legend'), #rows, n_cols))
  theme.pop_font(ImGui, ctx)
  if widgets.button(ctx, '##mxsave', t('stems.mx.save'), { color = theme.c.accent, active = true }) then
    matrix_save()
    ImGui.CloseCurrentPopup(ctx)
    MX.open = false
  end
  ImGui.SameLine(ctx, 0, GAP)
  if widgets.button(ctx, '##mxcancel', t('stems.mx.cancel')) then
    ImGui.CloseCurrentPopup(ctx)
    MX.open = false
  end
end

local function draw_matrix_modal()
  matrix_handle_request()
  if not MX.open then return end
  ImGui.SetNextWindowSize(ctx, 720, 640, ImGui.Cond_Appearing)
  if S.win_x then
    -- centred on the main window but kept inside the monitor's work area (a 460 px window at a screen edge would
    -- otherwise push a third of the matrix off screen; seen in the demo tour)
    local cx, cy = S.win_x + S.win_w / 2, S.win_y + S.win_h / 2
    local x, y = cx - 360, cy - 320
    if reaper.my_getViewport then
      local l, t, r, b = reaper.my_getViewport(0, 0, 0, 0, math.floor(cx), math.floor(cy), math.floor(cx) + 1, math.floor(cy) + 1, true)
      if l and r and r - l > 720 then x = math.max(l + 8, math.min(x, r - 728)) end
      if t and b and b - t > 640 then y = math.max(t + 8, math.min(y, b - 648)) end
    end
    ImGui.SetNextWindowPos(ctx, x, y, ImGui.Cond_Appearing)
  end
  local visible, open = ImGui.BeginPopupModal(ctx, t('stems.mx.title') .. MATRIX_ID, true, ImGui.WindowFlags_NoCollapse)
  if visible then
    local ok, err = pcall(draw_matrix)
    if MX.close_request then
      MX.close_request = nil
      ImGui.CloseCurrentPopup(ctx)
      open = false
    end
    ImGui.EndPopup(ctx)
    if not ok then error(err, 0) end
  end
  if not open then MX.open = false end
end

-- header --------------------------------------------------------------------------------------------------------------------------------

local function draw_presets_menu()
  if ImGui.BeginMenu(ctx, t('stems.menu.presets')) then
    ImGui.SetNextItemWidth(ctx, 180)
    local changed, v = ImGui.InputTextWithHint(ctx, '##pname', t('stems.menu.preset_name_hint'), preset_name)
    if changed then preset_name = v end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, t('stems.menu.preset_save')) and text.trim(preset_name) ~= '' then
      local path, err = MD.save_preset(preset_name)
      say(path and string.format(t('stems.msg.preset_saved'), preset_name) or tostring(err))
    end
    ImGui.Separator(ctx)
    local list = MD.list_presets()
    if #list == 0 then ImGui.MenuItem(ctx, t('stems.menu.preset_none'), nil, false, false) end
    for _, p in ipairs(list) do
      if ImGui.BeginMenu(ctx, p.name) then
        if ImGui.MenuItem(ctx, t('stems.menu.preset_replace')) then
          local n, found, lost = MD.load_preset(p.path, 'replace')
          say(n and string.format(t('stems.msg.preset_loaded'), n, found or 0, lost or 0) or tostring(found))
        end
        if ImGui.MenuItem(ctx, t('stems.menu.preset_append')) then
          local n, found, lost = MD.load_preset(p.path, 'append')
          say(n and string.format(t('stems.msg.preset_loaded'), n, found or 0, lost or 0) or tostring(found))
        end
        ImGui.EndMenu(ctx)
      end
    end
    ImGui.Separator(ctx)
    ImGui.MenuItem(ctx, MD.preset_dir(), nil, false, false)
    ImGui.EndMenu(ctx)
  end
end

local function draw_add_menu()
  if ImGui.MenuItem(ctx, t('stems.menu.from_families')) then add_from_families() end
  if ImGui.MenuItem(ctx, t('stems.menu.from_folders')) then add_from_folders() end
  if ImGui.MenuItem(ctx, t('stems.menu.from_selection')) then add_from_selection() end
  if ImGui.MenuItem(ctx, t('stems.menu.from_scenes')) then add_from_scenes() end
  if ImGui.MenuItem(ctx, t('stems.menu.capture')) then add_capture() end
  if ImGui.MenuItem(ctx, t('stems.menu.empty')) then add_empty() end
  ImGui.Separator(ctx)
  if ImGui.MenuItem(ctx, t('stems.menu.adopt')) then
    local n, unknown = MD.adopt()
    say(string.format(t('stems.msg.adopted'), n, #unknown > 0 and table.concat(unknown, ', ') or '-'))
  end
  draw_presets_menu()
  ImGui.Separator(ctx)
  if ImGui.MenuItem(ctx, t('stems.menu.clear'), nil, false, #MD.stems > 0 and not E.active) then
    MD.clear()
    S.hi = 0
    say(t('stems.msg.cleared'))
  end
end

local function draw_menu()
  local docked = app.is_docked()
  if ImGui.MenuItem(ctx, t('stems.menu.render_all'), 'Ctrl+Enter', false, not E.active) then render(nil, 'menu') end
  if ImGui.MenuItem(ctx, t('stems.menu.render_selected'), nil, false, not E.active and S.hi > 0) then render_selected() end
  if ImGui.MenuItem(ctx, t('stems.menu.stop'), 'Esc', false, E.active) then E.stop('menu') end
  ImGui.Separator(ctx)
  if ImGui.MenuItem(ctx, t('stems.menu.matrix'), 'M', false, #MD.stems > 0) then U.open_matrix() end
  if ImGui.MenuItem(ctx, t('stems.menu.preflight'), 'P') then U.preflight() end
  if ImGui.MenuItem(ctx, t('stems.menu.results'), 'R', S.show_results, E.results ~= nil) then S.show_results = not S.show_results end
  if ImGui.MenuItem(ctx, t('stems.menu.open_folder')) then open_folder() end
  ImGui.Separator(ctx)
  if ImGui.MenuItem(ctx, t('stems.menu.restore')) then
    local st = E.abort('menu')
    say(string.format(t('stems.msg.restored'), st.restored))
  end
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
  if E.active then
    theme.push_font(ImGui, ctx, 'small')
    local bw = ImGui.CalcTextSize(ctx, t('stems.badge')) + 12
    theme.pop_font(ImGui, ctx)
    local bx = x0 + w - right_w - bw - 8
    ImGui.DrawList_AddRectFilled(dl, bx, y0 + (h - 18) / 2, bx + bw, y0 + (h + 18) / 2, theme.col('accent2'), theme.radius.s)
    row_text(dl, bx + 6, y0, t('stems.badge'), 'on_accent', nil, 'small', h)
    ImGui.SetCursorScreenPos(ctx, bx, y0 + (h - 18) / 2)
    ImGui.Dummy(ctx, bw, 18)
    widgets.tooltip(ctx, t('stems.badge_tip'))
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
  if widgets.icon_button(ctx, '##menu', 'chevron_down', { flat = true, muted = true, tooltip = t('stems.tip.menu') }) then
    ImGui.OpenPopup(ctx, 'stemsmenu')
  end
  if ImGui.BeginPopup(ctx, 'stemsmenu') then
    draw_menu()
    ImGui.EndPopup(ctx)
  end
  next_line(x0, y0 + h)
end

-- controls ------------------------------------------------------------------------------------------------------------------------------

local function draw_controls()
  local x0, y0 = ImGui.GetCursorScreenPos(ctx)
  local w = ImGui.GetContentRegionAvail(ctx)
  local h = theme.control_h
  local bw = (w - 3 * GAP) / 4
  ImGui.SetCursorScreenPos(ctx, x0, y0)
  if E.active then
    if widgets.button(ctx, '##stop', t('stems.btn.stop'), { w = bw, h = h, color = theme.c.danger, active = true, tooltip = t('stems.tip.stop') }) then E.stop('button') end
  else
    if widgets.button(ctx, '##render', t('stems.btn.render'), { w = bw, h = h, color = theme.c.accent, active = MD.enabled_count() > 0,
        disabled = MD.enabled_count() == 0, tooltip = t('stems.tip.render') }) then
      render(nil, 'button')
    end
  end
  ImGui.SetCursorScreenPos(ctx, x0 + bw + GAP, y0)
  if widgets.button(ctx, '##render_sel', t('stems.btn.render_selected'), { w = bw, h = h, disabled = E.active or S.hi < 1, tooltip = t('stems.tip.render_selected') }) then
    render_selected()
  end
  ImGui.SetCursorScreenPos(ctx, x0 + 2 * (bw + GAP), y0)
  if widgets.button(ctx, '##preflight', t('stems.btn.preflight'), { w = bw, h = h, on = S.show_preflight, tooltip = t('stems.tip.preflight') }) then
    if S.show_preflight then S.show_preflight = false else U.preflight() end
  end
  ImGui.SetCursorScreenPos(ctx, x0 + 3 * (bw + GAP), y0)
  if widgets.button(ctx, '##results', t('stems.btn.results'), { w = bw, h = h, on = S.show_results, disabled = E.results == nil, tooltip = t('stems.tip.results') }) then
    S.show_results = not S.show_results
  end
  next_line(x0, y0 + h)
end

local FORMATS = { 'wav16', 'wav24', 'wav32f', 'flac', 'mp3', 'project' }

local function draw_settings()
  local x0, y0 = ImGui.GetCursorScreenPos(ctx)
  local w = ImGui.GetContentRegionAvail(ctx)
  local h = theme.control_h_small
  local dl = ImGui.GetWindowDrawList(ctx)
  local y = y0
  -- row 1: format combo, range, existing files
  row_text(dl, x0, y, t('stems.set.format'), 'muted', nil, 'small', h)
  local lw = measure(t('stems.set.format'), 'small') + 6
  ImGui.SetCursorScreenPos(ctx, x0 + lw, y)
  ImGui.SetNextItemWidth(ctx, 118)
  theme.push_font(ImGui, ctx, 'small')
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_FramePadding, 6, 2)
  local cur = cfg('render.format') or 'wav24'
  if ImGui.BeginCombo(ctx, '##fmt', t(('cfg.val.%s'):format(cur))) then
    for _, f in ipairs(FORMATS) do
      if ImGui.Selectable(ctx, t(('cfg.val.%s'):format(f)), f == cur) then set_cfg('render.format', f) end
    end
    ImGui.EndCombo(ctx)
  end
  ImGui.PopStyleVar(ctx)
  theme.pop_font(ImGui, ctx)
  widgets.tooltip(ctx, t('cfg.stems.render.format.tip'))
  local x = x0 + lw + 118 + theme.space[3]
  row_text(dl, x, y, t('stems.set.range'), 'muted', nil, 'small', h)
  local rw = measure(t('stems.set.range'), 'small') + 6
  ImGui.SetCursorScreenPos(ctx, x + rw, y)
  local chosen, used = widgets.segmented(ctx, '##range', {
    { 'stem', t('stems.range.stem'), t('stems.tip.range_stem') }, { 'project', t('stems.range.project'), t('stems.tip.range_project') },
    { 'time_selection', t('stems.range.timesel'), t('stems.tip.range_timesel') }, { 'custom', t('stems.range.custom'), t('stems.tip.range_custom') } },
    cfg('render.bounds') or 'stem')
  if chosen then set_cfg('render.bounds', chosen) end
  x = x + rw + used + theme.space[3]
  if x + 150 < x0 + w then
    row_text(dl, x, y, t('stems.set.existing'), 'muted', nil, 'small', h)
    local ew = measure(t('stems.set.existing'), 'small') + 6
    ImGui.SetCursorScreenPos(ctx, x + ew, y)
    local ch2 = widgets.segmented(ctx, '##ovw', {
      { 'replace', t('stems.ovw.replace'), t('stems.tip.ovw_replace') }, { 'increment', t('stems.ovw.increment'), t('stems.tip.ovw_increment') },
      { 'skip', t('stems.ovw.skip'), t('stems.tip.ovw_skip') } }, cfg('render.overwrite') or 'replace')
    if ch2 then set_cfg('render.overwrite', ch2) end
  end
  y = y + h + GAP
  -- row 2: pattern + folder
  row_text(dl, x0, y, t('stems.set.pattern'), 'muted', nil, 'small', h)
  local pw = measure(t('stems.set.pattern'), 'small') + 6
  if pattern_input == nil then pattern_input = cfg('render.pattern') or '' end
  if dir_input == nil then dir_input = cfg('render.dir') or '' end
  local half = (w - pw) / 2
  ImGui.SetCursorScreenPos(ctx, x0 + pw, y)
  ImGui.SetNextItemWidth(ctx, half - theme.space[3])
  theme.push_font(ImGui, ctx, 'small')
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_FramePadding, 6, 2)
  local pc, pv = ImGui.InputText(ctx, '##pattern', pattern_input)
  if pc then pattern_input = pv end
  if ImGui.IsItemDeactivatedAfterEdit(ctx) then set_cfg('render.pattern', pattern_input) end
  ImGui.PopStyleVar(ctx)
  theme.pop_font(ImGui, ctx)
  widgets.tooltip(ctx, t('cfg.stems.render.pattern.tip'))
  local fx = x0 + pw + half
  row_text(dl, fx, y, t('stems.set.folder'), 'muted', nil, 'small', h)
  local fw = measure(t('stems.set.folder'), 'small') + 6
  ImGui.SetCursorScreenPos(ctx, fx + fw, y)
  ImGui.SetNextItemWidth(ctx, x0 + w - fx - fw)
  theme.push_font(ImGui, ctx, 'small')
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_FramePadding, 6, 2)
  local dc, dv = ImGui.InputText(ctx, '##dir', dir_input)
  if dc then dir_input = dv end
  if ImGui.IsItemDeactivatedAfterEdit(ctx) then set_cfg('render.dir', dir_input) end
  ImGui.PopStyleVar(ctx)
  theme.pop_font(ImGui, ctx)
  widgets.tooltip(ctx, t('cfg.stems.render.dir.tip'))
  next_line(x0, y + h + 2)
end

-- the running batch -------------------------------------------------------------------------------------------------------------------

local function draw_progress()
  local r = E.run
  if not r then return end
  local x0, y0 = ImGui.GetCursorScreenPos(ctx)
  local w = ImGui.GetContentRegionAvail(ctx)
  local dl = ImGui.GetWindowDrawList(ctx)
  local h = S.compact and 30 or 40
  ImGui.DrawList_AddRectFilled(dl, x0, y0, x0 + w, y0 + h, theme.col('panel2'), theme.radius.m)
  local label = string.format(t('stems.run.line'), r.i, r.n, r.name ~= '' and r.name or '-', t(('stems.phase.%s'):format(r.phase or 'start')))
  row_text(dl, x0 + 8, y0, label, 'text', w - 16, 'body', h - (S.compact and 8 or 12))
  ImGui.SetCursorScreenPos(ctx, x0 + 8, y0 + h - 8)
  widgets.progress(ctx, w - 16, 3, E.progress(), theme.c.accent2)
  next_line(x0, y0 + h + 2)
end

-- the list ----------------------------------------------------------------------------------------------------------------------------

local function draw_row(i, s, rh)
  ImGui.PushID(ctx, i)
  local x0, y0 = ImGui.GetCursorScreenPos(ctx)
  local w = ImGui.GetContentRegionAvail(ctx)
  local dl = ImGui.GetWindowDrawList(ctx)
  local running = E.active and E.run and E.run.list and E.run.list[E.run.i] == i
  if running then
    ImGui.DrawList_AddRectFilled(dl, x0, y0, x0 + w, y0 + rh, theme.col('accent2', 0.10), 0)
    ImGui.DrawList_AddRectFilled(dl, x0, y0, x0 + 3, y0 + rh, theme.col('accent2'), 0)
  end
  local flags = ImGui.SelectableFlags_AllowOverlap | ImGui.SelectableFlags_AllowDoubleClick
  local clicked = ImGui.Selectable(ctx, '##row', S.hi == i, flags, w, rh)
  local hovered = ImGui.IsItemHovered(ctx)
  if hovered and ImGui.IsMouseClicked(ctx, ImGui.MouseButton_Right) then
    S.hi = i
    S.menu_row, S.menu_request = i, true
  end
  local dbl = clicked and ImGui.IsMouseDoubleClicked(ctx, ImGui.MouseButton_Left)
  -- enable toggle
  local pressed = false
  if row_button(x0 + 4, y0, rh, '##en', 'check', { active = s.enabled, on = s.enabled, color = theme.c.ok, flat = not s.enabled, muted = not s.enabled,
      tooltip = s.enabled and t('stems.tip.disable') or t('stems.tip.enable') }) then
    pressed = true
    s.enabled = not s.enabled
    MD.save()
  end
  row_text_right(dl, x0 + 4 + BTN + 22, y0, tostring(i), 'muted', 'mono', rh)
  local name_x = x0 + 4 + BTN + 30
  local bx = x0 + w - 2 * (BTN + GAP)
  -- result dot
  local res = result_of(s)
  local dot_w = 0
  if res then
    local st = RS.status_of(res)
    dot_w = 16
    ImGui.DrawList_AddCircleFilled(dl, bx - GAP - 8, y0 + rh / 2, 4, theme.rgba(status_color(st)), 12)
    ImGui.SetCursorScreenPos(ctx, bx - GAP - 16, y0)
    ImGui.Dummy(ctx, 16, rh)
    widgets.tooltip(ctx, string.format(t('stems.tip.result'), st, res.peak_db and string.format('%.1f', res.peak_db) or '-', res.lufs_i and string.format('%.1f', res.lufs_i) or '-', res.file or ''))
  end
  local summary = MD.summary(s)
  local sw = 0
  if not S.compact then sw = row_text_right(dl, bx - GAP - dot_w - 6, y0, summary, 'dim', 'small', rh) end
  -- source badge
  local src = s.source and s.source.kind or 'manual'
  theme.push_font(ImGui, ctx, 'small')
  local badge = t(('stems.src.%s'):format(src))
  local bw2 = ImGui.CalcTextSize(ctx, badge) + 8
  theme.pop_font(ImGui, ctx)
  local badge_x = bx - GAP - dot_w - 6 - sw - GAP - bw2
  if not S.compact then
    ImGui.DrawList_AddRectFilled(dl, badge_x, y0 + (rh - 16) / 2, badge_x + bw2, y0 + (rh + 16) / 2, theme.col('panel2'), theme.radius.s)
    row_text(dl, badge_x + 4, y0, badge, 'muted', nil, 'small', rh)
  else
    badge_x = bx - GAP - dot_w
  end
  if rename.k == i then
    ImGui.SetCursorScreenPos(ctx, name_x, y0 + (rh - theme.control_h_small) / 2)
    ImGui.SetNextItemWidth(ctx, badge_x - name_x - 8)
    ImGui.SetKeyboardFocusHere(ctx)
    local ch, v = ImGui.InputText(ctx, '##rename', rename.text, ImGui.InputTextFlags_EnterReturnsTrue | ImGui.InputTextFlags_AutoSelectAll)
    if ch then
      MD.rename(i, v)
      rename.k = nil
    elseif ImGui.IsItemDeactivated(ctx) then
      rename.k = nil
    end
    pressed = true
  else
    row_text(dl, name_x, y0, s.name, s.enabled and 'text' or 'dim', badge_x - name_x - 8, 'body', rh)
  end
  if row_button(bx, y0, rh, '##matrix', 'edit', { tooltip = t('stems.tip.matrix_row') }) then
    pressed = true
    U.open_matrix(i)
  end
  if row_button(bx + BTN + GAP, y0, rh, '##rm', 'clear', { flat = true, muted = true, tooltip = t('stems.tip.remove'), disabled = E.active }) then
    pressed = true
    MD.remove(i)
    if S.hi > #MD.stems then S.hi = #MD.stems end
  end
  if clicked and not pressed then
    S.hi = i
    if dbl then
      rename.k, rename.text = i, s.name
    end
  end
  ImGui.SetCursorScreenPos(ctx, x0, y0 + rh)
  ImGui.Dummy(ctx, 0, 0)
  ImGui.PopID(ctx)
end

local function draw_row_menu()
  local i = S.menu_row
  local s = i and MD.stems[i]
  if not s then return end
  if ImGui.MenuItem(ctx, t('stems.row.render'), nil, false, not E.active) then render({ [i] = true }, 'row') end
  if ImGui.MenuItem(ctx, t('stems.row.matrix')) then U.open_matrix(i) end
  if ImGui.MenuItem(ctx, t('stems.row.rename')) then rename.k, rename.text = i, s.name end
  if ImGui.MenuItem(ctx, s.enabled and t('stems.row.disable') or t('stems.row.enable')) then
    s.enabled = not s.enabled
    MD.save()
  end
  if ImGui.BeginMenu(ctx, t('stems.row.variant')) then
    if ImGui.MenuItem(ctx, t('stems.variant.default'), nil, s.variant == nil) then s.variant = nil; MD.save() end
    for _, v in ipairs(MD.VARIANTS) do
      if ImGui.MenuItem(ctx, t(('cfg.val.%s'):format(v)), nil, s.variant == v) then s.variant = v; MD.save() end
    end
    ImGui.EndMenu(ctx)
  end
  if ImGui.BeginMenu(ctx, t('stems.row.range')) then
    if ImGui.MenuItem(ctx, t('stems.row.range_none'), nil, s.range == nil) then s.range = nil; MD.save() end
    if ImGui.MenuItem(ctx, t('stems.row.range_timesel')) then
      local a, b = reaper.GetSet_LoopTimeRange2(0, false, false, 0, 0, false)
      if b > a then s.range = { name = '', t0 = a, t1 = b }; MD.save() else say(t('stems.msg.no_timesel')) end
    end
    if #MD.D.scenes > 0 then
      ImGui.Separator(ctx)
      for _, sc in ipairs(MD.D.scenes) do
        if ImGui.MenuItem(ctx, string.format('%s  %s-%s', sc.name, text.fmt_time(sc.t0), text.fmt_time(sc.t1)), nil, s.range ~= nil and s.range.name == sc.name) then
          s.range = { name = sc.name, t0 = sc.t0, t1 = sc.t1 }
          MD.save()
        end
      end
    end
    ImGui.EndMenu(ctx)
  end
  ImGui.Separator(ctx)
  if ImGui.MenuItem(ctx, t('stems.row.up'), nil, false, i > 1) then S.hi = MD.move(i, -1) end
  if ImGui.MenuItem(ctx, t('stems.row.down'), nil, false, i < #MD.stems) then S.hi = MD.move(i, 1) end
  if ImGui.MenuItem(ctx, t('stems.row.duplicate')) then S.hi = MD.duplicate(i) or S.hi end
  if ImGui.MenuItem(ctx, t('stems.row.remove'), nil, false, not E.active) then
    MD.remove(i)
    if S.hi > #MD.stems then S.hi = #MD.stems end
  end
  local res = result_of(s)
  if res then
    ImGui.Separator(ctx)
    ImGui.TextColored(ctx, theme.rgba(status_color(RS.status_of(res))), string.format('%s  %s', RS.status_of(res), res.file and (res.file:match('[^/\\]+$') or '') or ''))
  end
end

local function draw_empty()
  ImGui.Dummy(ctx, 0, theme.space[3])
  ImGui.Indent(ctx, theme.space[3])
  ImGui.PushTextWrapPos(ctx, 0)
  ImGui.TextColored(ctx, theme.col('muted'), t('stems.empty'))
  ImGui.PopTextWrapPos(ctx)
  ImGui.Dummy(ctx, 0, theme.space[2])
  if widgets.button(ctx, '##efam', t('stems.menu.from_families'), { color = theme.c.accent, active = true }) then add_from_families() end
  ImGui.SameLine(ctx, 0, GAP)
  if widgets.button(ctx, '##efold', t('stems.menu.from_folders')) then add_from_folders() end
  ImGui.SameLine(ctx, 0, GAP)
  if widgets.button(ctx, '##escn', t('stems.menu.from_scenes')) then add_from_scenes() end
  ImGui.Unindent(ctx, theme.space[3])
end

-- panels: pre-flight and results ------------------------------------------------------------------------------------------------------

local function panel_height(n_rows)
  return math.min(PANEL_MAX_H, theme.space[1] * 2 + n_rows * theme.row_h_compact + 2)
end

local function draw_preflight_panel()
  local rows = E.preflight_rows or {}
  local h = panel_height(math.max(1, #rows))
  ImGui.PushStyleColor(ctx, ImGui.Col_ChildBg, theme.col('panel'))
  local visible = ImGui.BeginChild(ctx, 'preflight', 0, h, ImGui.ChildFlags_Borders, ImGui.WindowFlags_None)
  ImGui.PopStyleColor(ctx)
  if visible then
    local dl = ImGui.GetWindowDrawList(ctx)
    local rh = theme.row_h_compact
    local iw = ImGui.GetContentRegionAvail(ctx)
    for i, r in ipairs(rows) do
      ImGui.PushID(ctx, i)
      local ix, iy = ImGui.GetCursorScreenPos(ctx)
      icons.draw(ImGui, dl, r.level == 'ok' and 'check' or (r.level == 'info' and 'dot' or 'warning'), ix + 10, iy + rh / 2, 12, theme.rgba(level_color(r.level)))
      local fix_w = 0
      if r.fix then
        fix_w = 60
        ImGui.SetCursorScreenPos(ctx, ix + iw - fix_w, iy + (rh - 18) / 2)
        if widgets.button(ctx, '##fix', r.fix_label or t('stems.pf.fix'), { w = fix_w - 4, h = 18, font = 'small', color = theme.c.accent }) then
          if r.fix() then U.preflight() end
        end
      end
      row_text(dl, ix + 22, iy, r.text, r.level == 'error' and 'text' or 'muted', iw - 26 - fix_w, 'small', rh)
      ImGui.SetCursorScreenPos(ctx, ix, iy)
      ImGui.Dummy(ctx, iw - fix_w, rh)
      widgets.tooltip(ctx, r.text)
      ImGui.PopID(ctx)
    end
    if #rows == 0 then
      theme.push_font(ImGui, ctx, 'small')
      ImGui.TextColored(ctx, theme.col('muted'), t('stems.pf.none'))
      theme.pop_font(ImGui, ctx)
    end
  end
  ImGui.EndChild(ctx)
end

local function draw_results_panel()
  local r = E.results
  if not r then return end
  local rows = r.rows or {}
  local h = panel_height(#rows + 1)
  ImGui.PushStyleColor(ctx, ImGui.Col_ChildBg, theme.col('panel'))
  local visible = ImGui.BeginChild(ctx, 'results', 0, h, ImGui.ChildFlags_Borders, ImGui.WindowFlags_None)
  ImGui.PopStyleColor(ctx)
  if visible then
    local dl = ImGui.GetWindowDrawList(ctx)
    local rh = theme.row_h_compact
    local iw = ImGui.GetContentRegionAvail(ctx)
    local ix, iy = ImGui.GetCursorScreenPos(ctx)
    local head = string.format(t('stems.res.head'), r.ok or 0, #rows, r.failed or 0, r.skipped or 0, r.silent or 0, r.seconds or 0, r.stopped and t('stems.res.stopped') or '')
    row_text(dl, ix + 4, iy, head, 'text', iw - 120, 'small', rh)
    ImGui.SetCursorScreenPos(ctx, ix + iw - 116, iy + (rh - 18) / 2)
    if widgets.button(ctx, '##open', t('stems.res.open'), { w = 56, h = 18, font = 'small' }) then open_folder() end
    ImGui.SameLine(ctx, 0, GAP)
    if widgets.button(ctx, '##copy', t('stems.res.copy'), { w = 56, h = 18, font = 'small', tooltip = t('stems.res.copy_tip') }) then
      ImGui.SetClipboardText(ctx, RS.to_md(r))
      say(t('stems.msg.copied'))
    end
    local y = iy + rh
    -- columns from measured text (the widest value each column can show), never pixel constants
    local col_len = measure('000.00s', 'mono') + 10
    local col_lufs = measure('-00.0 LUFS', 'mono') + 10
    local col_peak = measure('-00.0 dB', 'mono') + 10
    for _, row in ipairs(rows) do
      local st = RS.status_of(row)
      ImGui.DrawList_AddCircleFilled(dl, ix + 10, y + rh / 2, 4, theme.rgba(status_color(st)), 12)
      local right = ix + iw - 6
      row_text_right(dl, right, y, row.duration_s and string.format('%.2fs', row.duration_s) or '-', 'muted', 'mono', rh)
      right = right - col_len
      row_text_right(dl, right, y, row.lufs_i and string.format('%.1f LUFS', row.lufs_i) or '', 'muted', 'mono', rh)
      right = right - col_lufs
      local pk = row.peak_db or row.reaper_peak_db
      row_text_right(dl, right, y, pk and (pk <= -144 and '-inf' or string.format('%.1f dB', pk)) or '', pk and pk > -0.1 and 'danger' or 'muted', 'mono', rh)
      right = right - col_peak
      local label = string.format('%d. %s', row.i, row.name)
      if row.action and row.action ~= 'new' then label = label .. '  (' .. row.action .. ')' end
      if row.error then label = label .. '  ' .. row.error end
      row_text(dl, ix + 22, y, label, st == 'error' and 'danger' or 'text', right - ix - 26, 'small', rh)
      ImGui.SetCursorScreenPos(ctx, ix, y)
      ImGui.Dummy(ctx, iw, rh)
      widgets.tooltip(ctx, string.format('%s\n%s', row.file or '', row.error or ''))
      y = y + rh
    end
  end
  ImGui.EndChild(ctx)
end

local function draw_list()
  local rows = MD.stems
  if S.hi > #rows then S.hi = #rows end
  local extra = 0
  if S.show_preflight then extra = extra + panel_height(math.max(1, #(E.preflight_rows or {}))) + 4 end
  if S.show_results and E.results then extra = extra + panel_height(#(E.results.rows or {}) + 1) + 4 end
  local footer_h = theme.control_h + theme.space[2] + (S.compact and 0 or (theme.type.small + theme.space[2])) + extra
  ImGui.PushStyleColor(ctx, ImGui.Col_ChildBg, theme.col('panel'))
  local visible = ImGui.BeginChild(ctx, 'stems', 0, -footer_h, ImGui.ChildFlags_Borders, ImGui.WindowFlags_None)
  ImGui.PopStyleColor(ctx)
  if visible then
    local rh = S.compact and theme.row_h_compact or theme.row_h
    ImGui.PushStyleVar(ctx, ImGui.StyleVar_ItemSpacing, 0, 0)
    ImGui.PushStyleColor(ctx, ImGui.Col_Header, theme.col('sel'))
    ImGui.PushStyleColor(ctx, ImGui.Col_HeaderHovered, theme.col('hover'))
    ImGui.PushStyleColor(ctx, ImGui.Col_HeaderActive, theme.col('sel'))
    if #rows == 0 then
      draw_empty()
    else
      for i, s in ipairs(rows) do draw_row(i, s, rh) end
    end
    ImGui.PopStyleColor(ctx, 3)
    ImGui.PopStyleVar(ctx)
    if S.menu_request then
      ImGui.OpenPopup(ctx, 'stemrow')
      S.menu_request = nil
    end
    if ImGui.BeginPopup(ctx, 'stemrow') then
      draw_row_menu()
      ImGui.EndPopup(ctx)
    end
  end
  ImGui.EndChild(ctx)
  if S.show_preflight then draw_preflight_panel() end
  if S.show_results and E.results then draw_results_panel() end
end

-- footer ------------------------------------------------------------------------------------------------------------------------------

local function draw_footer()
  local x0, y0 = ImGui.GetCursorScreenPos(ctx)
  local w = ImGui.GetContentRegionAvail(ctx)
  local bw = (w - 2 * GAP) / 3
  local h = theme.control_h
  ImGui.SetCursorScreenPos(ctx, x0, y0)
  if widgets.button(ctx, '##add', t('stems.btn.add'), { w = bw, h = h, color = theme.c.accent, tooltip = t('stems.tip.add') }) then ImGui.OpenPopup(ctx, 'stemsadd') end
  if ImGui.BeginPopup(ctx, 'stemsadd') then
    draw_add_menu()
    ImGui.EndPopup(ctx)
  end
  ImGui.SetCursorScreenPos(ctx, x0 + bw + GAP, y0)
  if widgets.button(ctx, '##matrix', t('stems.btn.matrix'), { w = bw, h = h, disabled = #MD.stems == 0, tooltip = t('stems.tip.matrix') }) then U.open_matrix() end
  ImGui.SetCursorScreenPos(ctx, x0 + 2 * (bw + GAP), y0)
  local vd = cfg('variant.default') or 'master'
  local chosen = widgets.segmented(ctx, '##variant', {
    { 'master', t('stems.variant.master'), t('stems.tip.variant_master') }, { 'nofx', t('stems.variant.nofx'), t('stems.tip.variant_nofx') },
    { 'dry', t('stems.variant.dry'), t('stems.tip.variant_dry') } }, vd, { w = bw, h = h })
  if chosen then set_cfg('variant.default', chosen) end
  next_line(x0, y0 + h)
  if not S.compact then
    local msg = S.msg_frames > 0 and S.msg or (E.msg_frames > 0 and E.msg or nil)
    widgets.status(ctx, msg, t('stems.hint'), msg ~= nil)
  end
end

-- keys ----------------------------------------------------------------------------------------------------------------------------------

local function handle_keys()
  if not app.focused or MX.open or ImGui.IsAnyItemActive(ctx) then return end
  local function chord(key) return ImGui.IsKeyChordPressed(ctx, ImGui.Mod_Ctrl | key) end
  if chord(ImGui.Key_D) then app.toggle_dock() end
  if chord(ImGui.Key_Enter) then
    if E.active then E.stop('key') else render(nil, 'key') end
  end
  if ImGui.IsKeyPressed(ctx, ImGui.Key_Escape, false) and E.active then E.stop('key') end
  if ImGui.IsKeyPressed(ctx, ImGui.Key_M, false) and #MD.stems > 0 then U.open_matrix() end
  if ImGui.IsKeyPressed(ctx, ImGui.Key_P, false) then U.preflight() end
  if ImGui.IsKeyPressed(ctx, ImGui.Key_R, false) and E.results then S.show_results = not S.show_results end
  if ImGui.IsKeyPressed(ctx, ImGui.Key_UpArrow, false) and S.hi > 1 then S.hi = S.hi - 1 end
  if ImGui.IsKeyPressed(ctx, ImGui.Key_DownArrow, false) and S.hi < #MD.stems then S.hi = S.hi + 1 end
  if ImGui.IsKeyPressed(ctx, ImGui.Key_Delete, false) and S.hi > 0 and not E.active then
    MD.remove(S.hi)
    if S.hi > #MD.stems then S.hi = #MD.stems end
  end
  if ImGui.IsKeyPressed(ctx, ImGui.Key_Space, false) and S.hi > 0 and MD.stems[S.hi] then
    MD.stems[S.hi].enabled = not MD.stems[S.hi].enabled
    MD.save()
  end
end

function U.draw(app_)
  app = app_
  ctx = app.ctx
  S.compact = app.win_h < (config.get('ui.compact_below_px') or theme.compact_below)
  S.win_x, S.win_y = ImGui.GetWindowPos(ctx)
  S.win_w, S.win_h = ImGui.GetWindowSize(ctx)
  if S.msg_frames > 0 then S.msg_frames = S.msg_frames - 1 end
  MD.check_refresh()
  if S.cfg_sig ~= tostring(cfg('render.pattern')) .. '|' .. tostring(cfg('render.dir')) then
    S.cfg_sig = tostring(cfg('render.pattern')) .. '|' .. tostring(cfg('render.dir'))
    if not ImGui.IsAnyItemActive(ctx) then pattern_input, dir_input = cfg('render.pattern') or '', cfg('render.dir') or '' end
  end
  draw_header()
  draw_controls()
  if not S.compact then draw_settings() end
  draw_progress()
  draw_list()
  draw_footer()
  draw_matrix_modal()
  handle_keys()
end

U.MX = MX
return U
