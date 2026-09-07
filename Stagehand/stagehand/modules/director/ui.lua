-- modules/director/ui.lua - the Director tab: header with the run badge, rehearsal controls, layout settings
-- (segmented controls that re-apply the current shot), the current-shot strip with progress and caption, the
-- shot list with validation badges and a context menu, the validation panel, the footer and the keys.
-- Drawing only; the engine (engine.lua) changes the project, the model (model.lua) holds the shots.
-- Lua 5.4; no globals.

local theme = require('ui.theme')
local widgets = require('ui.widgets')
local icons = require('ui.icons')
local text = require('lib.text')
local journal = require('lib.journal')
local view = require('lib.view')
local regions = require('lib.regions')
local arrange = require('lib.arrange')
local config = require('config')
local state = require('state')
local i18n = require('i18n')
local V = require('modules.director.validate')
local ED = require('modules.director.editor')

local t = i18n.t

local U = {}

local ImGui, ctx, app, E, MD, S
local BTN = 22
local GAP = 4
local ISSUES_MAX_H = 150

local function cfg(key)
  return config.get('director.' .. key)
end

local function scope()
  return cfg('persist.scope') or 'project'
end

function U.init(app_, E_, MD_, S_)
  app, E, MD, S = app_, E_, MD_, S_
  ImGui = app.ImGui
end

-- helpers ---------------------------------------------------------------------------------------------------------

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

-- validation --------------------------------------------------------------------------------------------------------

function U.validate()
  S.validate_request = false
  E.check_refresh()
  local H = arrange.height(cfg('heights.arrange_fallback_px'))
  S.issues = V.run(MD.shots, {
    tracks = E.tracks, H = H, cfg = config.get('director'), pins = cfg('pins.rows'), parents = cfg('layout.parents'),
  })
  S.issue_counts = V.counts(S.issues)
  S.worst = {}
  for _, i in ipairs(S.issues) do
    if i.k then
      local cur = S.worst[i.k]
      if i.level == 'error' or (i.level == 'warn' and cur ~= 'error') or (i.level == 'info' and not cur) then S.worst[i.k] = i.level end
    end
  end
  return S.issues
end

local function issues_of(k)
  local out = {}
  for _, i in ipairs(S.issues or {}) do
    if i.k == k then out[#out + 1] = i end
  end
  return out
end

local function level_color(level)
  if level == 'error' then return theme.c.danger elseif level == 'warn' then return theme.c.warn end
  return theme.c.accent
end

-- actions from the UI ---------------------------------------------------------------------------------------------

local function toggle_run()
  if E.active then
    local stats = E.stop('ui')
    say(string.format(t('dir.msg.stopped'), stats and stats.restored or 0))
  else
    if #MD.shots == 0 then say(t('dir.msg.no_shots')); return end
    E.start('ui')
    say(t('dir.msg.started'))
  end
end

local function shots_from_scenes()
  local scenes = regions.scan(nil, 5)
  if #scenes == 0 then say(t('dir.msg.no_scenes')); return end
  for _, s in ipairs(MD.from_scenes(scenes)) do MD.shots[#MD.shots + 1] = s end
  MD.sort()
  MD.save()
  S.validate_request = true
  say(string.format(t('dir.msg.from_scenes'), #scenes))
end

local function restore_layout()
  if E.active then
    local stats = E.stop('restore')
    say(string.format(t('dir.msg.restored'), stats and stats.restored or 0))
  else
    local n = journal.count(nil, 'director')
    if n == 0 then say(t('nav.msg.nothing_to_restore')); return end
    local stats = journal.restore(journal.owner_pred('director'))
    say(string.format(t('dir.msg.restored'), stats.restored))
  end
end

local function set_setting(key, value)
  config.set('director.' .. key, value, scope())
  E.reapply()
  S.validate_request = true
end

-- header ------------------------------------------------------------------------------------------------------------

local function draw_menu()
  local docked = app.is_docked()
  if ImGui.MenuItem(ctx, E.active and t('dir.menu.stop') or t('dir.menu.start'), 'Ctrl+Enter', false, E.active or #MD.shots > 0) then toggle_run() end
  if ImGui.MenuItem(ctx, t('dir.menu.auto'), 'A', E.auto) then E.set_auto(not E.auto); S.dirty = true end
  if ImGui.MenuItem(ctx, t('dir.menu.restore'), nil, false, E.active or journal.count(nil, 'director') > 0) then restore_layout() end
  ImGui.Separator(ctx)
  if ImGui.MenuItem(ctx, t('dir.menu.add')) then ED.request_open('shot', nil) end
  if ImGui.MenuItem(ctx, t('dir.menu.from_scenes')) then shots_from_scenes() end
  if ImGui.MenuItem(ctx, t('dir.menu.pins')) then ED.request_open('pins') end
  if ImGui.MenuItem(ctx, t('dir.menu.validate'), 'Ctrl+R') then U.validate(); S.show_issues = true end
  if ImGui.MenuItem(ctx, t('dir.menu.clear'), nil, false, #MD.shots > 0) then
    if E.active then E.stop('clear') end
    MD.clear()
    S.hi = 0
    S.validate_request = true
    say(t('dir.msg.cleared'))
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
  local time_s = text.fmt_time(view.position())
  local tw = measure(time_s, 'mono')
  local right_w = 16 + tw + GAP + btn + GAP + btn
  local name_w = w - right_w - 8
  if E.active then
    theme.push_font(ImGui, ctx, 'small')
    local bw = ImGui.CalcTextSize(ctx, t('dir.badge')) + 12
    theme.pop_font(ImGui, ctx)
    local bx = x0 + w - right_w - bw - 8
    ImGui.DrawList_AddRectFilled(dl, bx, y0 + (h - 18) / 2, bx + bw, y0 + (h + 18) / 2, theme.col('accent2'), theme.radius.s)
    row_text(dl, bx + 6, y0, t('dir.badge'), 'on_accent', nil, 'small', h)
    ImGui.SetCursorScreenPos(ctx, bx, y0 + (h - 18) / 2)
    ImGui.Dummy(ctx, bw, 18)
    widgets.tooltip(ctx, t('dir.badge_tip'))
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
  if widgets.icon_button(ctx, '##menu', 'chevron_down', { flat = true, muted = true, tooltip = t('dir.tip.menu') }) then
    ImGui.OpenPopup(ctx, 'dirmenu')
  end
  if ImGui.BeginPopup(ctx, 'dirmenu') then
    draw_menu()
    ImGui.EndPopup(ctx)
  end
  next_line(x0, y0 + h)
end

-- rehearsal controls ----------------------------------------------------------------------------------------------

local function draw_controls()
  local x0, y0 = ImGui.GetCursorScreenPos(ctx)
  local w = ImGui.GetContentRegionAvail(ctx)
  local h = theme.control_h
  local icon_w = 30
  local n_icons = 4
  local restore_w = 104
  local start_w = w - (n_icons * (icon_w + GAP)) - restore_w - GAP - 70 - GAP
  if start_w < 70 then start_w = 70 end
  local x = x0
  ImGui.SetCursorScreenPos(ctx, x, y0)
  local can = E.active or #MD.shots > 0
  if widgets.button(ctx, '##run', E.active and t('dir.btn.stop') or t('dir.btn.start'), { w = start_w, h = h, active = E.active,
      color = E.active and theme.c.danger or theme.c.ok, disabled = not can, tooltip = E.active and t('dir.tip.stop') or t('dir.tip.start') }) then
    toggle_run()
  end
  x = x + start_w + GAP
  ImGui.SetCursorScreenPos(ctx, x, y0)
  if widgets.button(ctx, '##auto', t('dir.btn.auto'), { w = 70, h = h, active = E.auto, color = theme.c.accent, tooltip = t('dir.tip.auto') }) then
    E.set_auto(not E.auto)
    S.dirty = true
  end
  x = x + 70 + GAP
  local nav = {
    { 'first', 'dir.tip.first', function() E.goto_shot(1) end },
    { 'chevron_left', 'dir.tip.prev', function() E.prev_shot() end },
    { 'chevron_right', 'dir.tip.next', function() E.next_shot() end },
    { 'last', 'dir.tip.last', function() E.goto_shot(#MD.shots) end },
  }
  for i, b in ipairs(nav) do
    ImGui.SetCursorScreenPos(ctx, x, y0)
    if widgets.icon_button(ctx, '##nav' .. i, b[1], { w = icon_w, h = h, disabled = #MD.shots == 0, tooltip = t(b[2]) }) then b[3]() end
    x = x + icon_w + GAP
  end
  ImGui.SetCursorScreenPos(ctx, x0 + w - restore_w, y0)
  local n = journal.count(nil, 'director')
  local label = n > 0 and string.format(t('nav.footer.restore_n'), n) or t('nav.footer.restore')
  if widgets.button(ctx, '##restore', label, { w = restore_w, h = h, disabled = n == 0 and not E.active, on = n > 0, color = theme.c.accent,
      tooltip = t('dir.tip.restore') }) then
    restore_layout()
  end
  next_line(x0, y0 + h)
end

local function draw_settings()
  local x0, y0 = ImGui.GetCursorScreenPos(ctx)
  local w = ImGui.GetContentRegionAvail(ctx)
  local h = theme.control_h_small
  local groups = {
    { key = 'layout.mode', label = t('dir.set.mode'), options = { { 'focus', t('dir.mode.focus'), t('dir.tip.mode_focus') }, { 'all', t('dir.mode.all'), t('dir.tip.mode_all') } } },
    { key = 'layout.parents', label = t('dir.set.parents'), options = { { 'none', t('dir.parents.none'), t('dir.tip.parents_none') }, { 'bus', t('dir.parents.bus'), t('dir.tip.parents_bus') }, { 'all', t('dir.parents.all'), t('dir.tip.parents_all') } } },
    { key = 'view.mode', label = t('dir.set.view'), options = { { 'page', t('dir.view.page'), t('dir.tip.view_page') }, { 'follow', t('dir.view.follow'), t('dir.tip.view_follow') } } },
    { key = 'envelopes.mode', label = t('dir.set.env'), options = { { 'story', t('dir.env.story'), t('dir.tip.env_story') }, { 'keep', t('dir.env.keep'), t('dir.tip.env_keep') } } },
  }
  local x, y = x0, y0
  local dl = ImGui.GetWindowDrawList(ctx)
  for i, g in ipairs(groups) do
    theme.push_font(ImGui, ctx, 'small')
    local lw = ImGui.CalcTextSize(ctx, g.label)
    theme.pop_font(ImGui, ctx)
    local seg_w = 0
    theme.push_font(ImGui, ctx, 'small')
    for _, o in ipairs(g.options) do seg_w = seg_w + ImGui.CalcTextSize(ctx, o[2]) + theme.space[3] end
    theme.pop_font(ImGui, ctx)
    local total = lw + 6 + seg_w
    if x + total > x0 + w and x > x0 then
      x = x0
      y = y + h + GAP
    end
    row_text(dl, x, y, g.label, 'muted', nil, 'small', h)
    ImGui.SetCursorScreenPos(ctx, x + lw + 6, y)
    local chosen, used = widgets.segmented(ctx, '##set' .. i, g.options, cfg(g.key))
    if chosen then set_setting(g.key, chosen) end
    x = x + lw + 6 + used + theme.space[3]
  end
  next_line(x0, y + h + 2)
end

-- current shot strip ------------------------------------------------------------------------------------------------

local function draw_current()
  local x0, y0 = ImGui.GetCursorScreenPos(ctx)
  local w = ImGui.GetContentRegionAvail(ctx)
  local dl = ImGui.GetWindowDrawList(ctx)
  local h = S.compact and 30 or 46
  ImGui.DrawList_AddRectFilled(dl, x0, y0, x0 + w, y0 + h, theme.col('panel'), theme.radius.m)
  local k, s = E.current()
  local pos = view.position()
  if not s then
    local cand = MD.shot_at(pos, tonumber(cfg('timing.lead_s')) or 0.4)
    local msg = #MD.shots == 0 and t('dir.current.none') or string.format(t('dir.current.idle'), cand or 0, cand and MD.shots[cand].name or '')
    row_text(dl, x0 + 8, y0, msg, 'muted', w - 16, 'body', S.compact and h or 26)
  else
    local head = string.format('%d/%d  %s', k, #MD.shots, s.name)
    local range = string.format('%s - %s', text.fmt_time(s.t0), text.fmt_time(s.t1))
    local rw = measure(range, 'mono')
    row_text(dl, x0 + 8, y0, head, 'text', w - rw - 24, 'bold', 24)
    row_text(dl, x0 + w - rw - 8, y0, range, 'muted', nil, 'mono', 24)
    if not S.compact then
      local cap = s.caption ~= '' and s.caption or t('dir.current.no_caption')
      row_text(dl, x0 + 8, y0 + 22, text.first_line(cap), s.caption ~= '' and 'muted' or 'dim', w - 16, 'small', 18)
    end
  end
  ImGui.SetCursorScreenPos(ctx, x0 + 8, y0 + h - 6)
  widgets.progress(ctx, w - 16, 3, E.progress(pos), theme.c.accent2)
  next_line(x0, y0 + h + 2)
end

-- shot list ---------------------------------------------------------------------------------------------------------

local function draw_row(i, s, rh, pos)
  ImGui.PushID(ctx, i)
  local x0, y0 = ImGui.GetCursorScreenPos(ctx)
  local w = ImGui.GetContentRegionAvail(ctx)
  local dl = ImGui.GetWindowDrawList(ctx)
  local current = (E.active and E.k == i) or (not E.active and pos >= s.t0 and pos < s.t1)
  if current then
    ImGui.DrawList_AddRectFilled(dl, x0, y0, x0 + w, y0 + rh, theme.col(E.active and 'accent2' or 'accent', 0.10), 0)
    ImGui.DrawList_AddRectFilled(dl, x0, y0, x0 + 3, y0 + rh, theme.col(E.active and 'accent2' or 'accent'), 0)
  end
  local flags = ImGui.SelectableFlags_AllowOverlap | ImGui.SelectableFlags_AllowDoubleClick
  local clicked = ImGui.Selectable(ctx, '##row', S.hi == i, flags, w, rh)
  local hovered = ImGui.IsItemHovered(ctx)
  if S.scroll_to_hi and S.hi == i then ImGui.SetScrollHereY(ctx, 0.5) end
  if hovered and ImGui.IsMouseClicked(ctx, ImGui.MouseButton_Right) then
    S.hi = i
    S.menu_row, S.menu_request = i, true
  end
  local dbl = clicked and ImGui.IsMouseDoubleClicked(ctx, ImGui.MouseButton_Left)
  row_text_right(dl, x0 + 26, y0, tostring(i), 'muted', 'mono', rh)
  row_text(dl, x0 + 34, y0, text.fmt_time(s.t0), 'muted', nil, 'mono', rh)
  local name_x = x0 + 34 + S.time_w + 10
  local bx = x0 + w - 2 * (BTN + GAP)
  local worst = S.worst and S.worst[i]
  local badge_w = 0
  if worst then
    badge_w = 20
    icons.draw(ImGui, dl, worst == 'info' and 'dot' or 'warning', bx - GAP - 10, y0 + rh / 2, 13, theme.rgba(level_color(worst)))
  end
  local summary = MD.summary(s)
  local sw = 0
  if not S.compact then sw = row_text_right(dl, bx - GAP - badge_w - 4, y0, summary, 'dim', 'small', rh) end
  row_text(dl, name_x, y0, s.name ~= '' and s.name or t('dir.row.unnamed'), 'text', bx - GAP * 2 - badge_w - sw - name_x - 8, 'body', rh)
  local pressed = false
  if row_button(bx, y0, rh, '##preview', 'eye', { active = E.active and E.k == i and not E.auto, color = theme.c.accent2, tooltip = t('dir.tip.preview') }) then
    pressed = true
    E.preview(i)
    say(string.format(t('dir.msg.preview'), i, s.name))
  end
  if row_button(bx + BTN + GAP, y0, rh, '##edit', 'edit', { tooltip = t('dir.tip.edit') }) then
    pressed = true
    ED.request_open('shot', i)
  end
  if clicked and not pressed then
    S.hi = i
    if dbl then ED.request_open('shot', i) else E.goto_shot(i) end
  end
  ImGui.SetCursorScreenPos(ctx, x0, y0 + rh)
  ImGui.Dummy(ctx, 0, 0)
  ImGui.PopID(ctx)
end

local function draw_row_menu()
  local i = S.menu_row
  local s = i and MD.shots[i]
  if not s then return end
  if ImGui.MenuItem(ctx, t('dir.row.goto')) then E.goto_shot(i) end
  if ImGui.MenuItem(ctx, t('dir.row.preview')) then E.preview(i) end
  if ImGui.MenuItem(ctx, t('dir.row.edit')) then ED.request_open('shot', i) end
  ImGui.Separator(ctx)
  if ImGui.MenuItem(ctx, t('dir.row.duplicate')) then
    local k = MD.duplicate(i)
    S.hi = k or 0
    S.validate_request = true
  end
  if ImGui.MenuItem(ctx, t('dir.row.remove')) then
    if E.active then E.stop('shot removed') end
    MD.remove(i)
    S.hi = 0
    S.validate_request = true
  end
  local iss = issues_of(i)
  if #iss > 0 then
    ImGui.Separator(ctx)
    for _, it in ipairs(iss) do
      ImGui.TextColored(ctx, theme.rgba(level_color(it.level)), it.text)
    end
  end
end

local function draw_empty()
  ImGui.Dummy(ctx, 0, theme.space[3])
  ImGui.Indent(ctx, theme.space[3])
  ImGui.PushTextWrapPos(ctx, 0)
  ImGui.TextColored(ctx, theme.col('muted'), t('dir.empty'))
  ImGui.PopTextWrapPos(ctx)
  ImGui.Spacing(ctx)
  if ImGui.Button(ctx, t('dir.btn.add')) then ED.request_open('shot', nil) end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, t('dir.btn.from_scenes')) then shots_from_scenes() end
  ImGui.Unindent(ctx, theme.space[3])
end

local function draw_issues_panel()
  local counts = S.issue_counts or { error = 0, warn = 0, info = 0 }
  local total = counts.error + counts.warn + counts.info
  local label
  if total == 0 then label = t('dir.val.clean')
  else label = string.format(t('dir.val.summary'), counts.error, counts.warn, counts.info) end
  local x0, y0 = ImGui.GetCursorScreenPos(ctx)
  local w = ImGui.GetContentRegionAvail(ctx)
  local h = theme.control_h_small
  ImGui.SetCursorScreenPos(ctx, x0, y0)
  local col = counts.error > 0 and theme.c.danger or (counts.warn > 0 and theme.c.warn or theme.c.ok)
  if widgets.button(ctx, '##issues', label, { w = w, h = h, flat = true, on = S.show_issues, color = col, font = 'small',
      tooltip = t('dir.tip.issues') }) then
    S.show_issues = not S.show_issues
    S.dirty = true
  end
  next_line(x0, y0 + h)
  if S.show_issues and total > 0 then
    ImGui.PushStyleColor(ctx, ImGui.Col_ChildBg, theme.col('panel'))
    ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding, theme.space[2], theme.space[1])
    local irh = theme.row_h_compact
    local ih = math.min(ISSUES_MAX_H, theme.space[1] * 2 + #S.issues * irh + 2)
    if ImGui.BeginChild(ctx, 'issues', 0, ih, ImGui.ChildFlags_Borders | ImGui.ChildFlags_AlwaysUseWindowPadding, ImGui.WindowFlags_None) then
      for n, it in ipairs(S.issues) do
        ImGui.PushID(ctx, n)
        local ix, iy = ImGui.GetCursorScreenPos(ctx)
        local iw = ImGui.GetContentRegionAvail(ctx)
        local dl = ImGui.GetWindowDrawList(ctx)
        local clicked = ImGui.Selectable(ctx, '##issue', false, ImGui.SelectableFlags_None, iw, irh)
        icons.draw(ImGui, dl, it.level == 'info' and 'dot' or 'warning', ix + 10, iy + irh / 2, 12, theme.rgba(level_color(it.level)))
        local tx = ix + 26
        if it.k then
          row_text(dl, tx, iy, '#' .. it.k, 'muted', nil, 'mono', irh)
          tx = tx + measure('#' .. it.k, 'mono') + 8
        end
        row_text(dl, tx, iy, it.text, 'text', ix + iw - tx - 4, 'small', irh)
        widgets.tooltip(ctx, (it.k and ('#' .. it.k .. '  ') or '') .. it.text)
        if clicked and it.k then
          S.hi = it.k
          S.scroll_to_hi = true
        end
        ImGui.PopID(ctx)
      end
    end
    ImGui.EndChild(ctx)
    ImGui.PopStyleVar(ctx)
    ImGui.PopStyleColor(ctx)
  end
end

local function draw_list()
  local rows = MD.shots
  if S.hi > #rows then S.hi = #rows end
  local issues_h = theme.control_h_small + 2
  if S.show_issues and S.issue_counts and (S.issue_counts.error + S.issue_counts.warn + S.issue_counts.info) > 0 then
    issues_h = issues_h + math.min(ISSUES_MAX_H, theme.space[1] * 2 + #S.issues * theme.row_h_compact + 2) + 4
  end
  local footer_h = theme.control_h + theme.space[2] + (S.compact and 0 or (theme.type.small + theme.space[2])) + issues_h
  ImGui.PushStyleColor(ctx, ImGui.Col_ChildBg, theme.col('panel'))
  local visible = ImGui.BeginChild(ctx, 'shots', 0, -footer_h, ImGui.ChildFlags_Borders, ImGui.WindowFlags_None)
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
      local pos = view.position()
      local clipper = S.clipper
      S.time_w = measure(text.fmt_time(rows[#rows].t0 or 0), 'mono')   -- widest time (rows are sorted by start)
      ImGui.ListClipper_Begin(clipper, #rows, rh)
      if S.scroll_to_hi and S.hi > 0 then ImGui.ListClipper_IncludeItemByIndex(clipper, S.hi - 1) end
      while ImGui.ListClipper_Step(clipper) do
        local d0, d1 = ImGui.ListClipper_GetDisplayRange(clipper)
        for i = d0 + 1, d1 do
          if rows[i] then draw_row(i, rows[i], rh, pos) end
        end
      end
      S.scroll_to_hi = false
    end
    ImGui.PopStyleColor(ctx, 3)
    ImGui.PopStyleVar(ctx)
    if S.menu_request then
      ImGui.OpenPopup(ctx, 'shotmenu')
      S.menu_request = nil
    end
    if ImGui.BeginPopup(ctx, 'shotmenu') then
      draw_row_menu()
      ImGui.EndPopup(ctx)
    end
  end
  ImGui.EndChild(ctx)
  draw_issues_panel()
end

-- footer ------------------------------------------------------------------------------------------------------------

local function draw_footer()
  local x0, y0 = ImGui.GetCursorScreenPos(ctx)
  local w = ImGui.GetContentRegionAvail(ctx)
  local bw = (w - 3 * GAP) / 4
  local h = theme.control_h
  ImGui.SetCursorScreenPos(ctx, x0, y0)
  if widgets.button(ctx, '##add', t('dir.btn.add'), { w = bw, h = h, tooltip = t('dir.tip.add') }) then ED.request_open('shot', nil) end
  ImGui.SetCursorScreenPos(ctx, x0 + bw + GAP, y0)
  if widgets.button(ctx, '##scenes', t('dir.btn.from_scenes'), { w = bw, h = h, tooltip = t('dir.tip.from_scenes') }) then shots_from_scenes() end
  ImGui.SetCursorScreenPos(ctx, x0 + 2 * (bw + GAP), y0)
  if widgets.button(ctx, '##pins', t('dir.btn.pins'), { w = bw, h = h, on = #(cfg('pins.rows') or {}) > 0, color = theme.c.accent2, tooltip = t('dir.tip.pins') }) then
    ED.request_open('pins')
  end
  ImGui.SetCursorScreenPos(ctx, x0 + 3 * (bw + GAP), y0)
  if widgets.button(ctx, '##validate', t('dir.btn.validate'), { w = bw, h = h, tooltip = t('dir.tip.validate') }) then
    U.validate()
    S.show_issues = true
    say(string.format(t('dir.val.summary'), S.issue_counts.error, S.issue_counts.warn, S.issue_counts.info))
  end
  next_line(x0, y0 + h)
  if not S.compact then
    local msg = S.msg_frames > 0 and S.msg or (E.msg_frames > 0 and E.msg or nil)
    widgets.status(ctx, msg, t('dir.hint'), msg ~= nil)
  end
end

-- keys ----------------------------------------------------------------------------------------------------------------

local function handle_keys()
  if not app.focused or ED.open then return end
  local function chord(key) return ImGui.IsKeyChordPressed(ctx, ImGui.Mod_Ctrl | key) end
  local function pressed(key, rep) return ImGui.IsKeyPressed(ctx, key, rep == true) end
  if chord(ImGui.Key_Enter) or chord(ImGui.Key_KeypadEnter) then toggle_run() end
  if chord(ImGui.Key_D) then app.toggle_dock() end
  if chord(ImGui.Key_R) then U.validate(); S.show_issues = true end
  if pressed(ImGui.Key_Space) then reaper.Main_OnCommand(40044, 0) end   -- Transport: Play/stop
  if pressed(ImGui.Key_A) then E.set_auto(not E.auto); S.dirty = true end
  if pressed(ImGui.Key_LeftArrow, true) then E.prev_shot() end
  if pressed(ImGui.Key_RightArrow, true) then E.next_shot() end
  if pressed(ImGui.Key_Home) then E.goto_shot(1) end
  if pressed(ImGui.Key_End) then E.goto_shot(#MD.shots) end
  if pressed(ImGui.Key_DownArrow, true) and #MD.shots > 0 then S.hi = math.min(#MD.shots, S.hi + 1); S.scroll_to_hi = true end
  if pressed(ImGui.Key_UpArrow, true) and #MD.shots > 0 then S.hi = math.max(1, S.hi - 1); S.scroll_to_hi = true end
  local ctrl = (ImGui.GetKeyMods(ctx) & ImGui.Mod_Ctrl) ~= 0
  if (pressed(ImGui.Key_Enter) or pressed(ImGui.Key_KeypadEnter)) and S.hi > 0 and not ctrl then E.goto_shot(S.hi) end
  if pressed(ImGui.Key_E) and S.hi > 0 then ED.request_open('shot', S.hi) end
  if pressed(ImGui.Key_Escape) and E.active then toggle_run() end
end

-- entry ---------------------------------------------------------------------------------------------------------------

function U.draw(app_)
  app = app_
  ctx = app.ctx
  S.compact = app.win_h < (config.get('ui.compact_below_px') or theme.compact_below)
  if S.msg_frames > 0 then S.msg_frames = S.msg_frames - 1 end
  ED.handle_requests(ctx)
  if S.validate_request then U.validate() end
  draw_header()
  draw_controls()
  if not S.compact then draw_settings() end
  draw_current()
  draw_list()
  draw_footer()
  ED.draw(ctx)
  handle_keys()
end

U.say = say
U.shots_from_scenes = shots_from_scenes
return U
