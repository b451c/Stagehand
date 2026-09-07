-- modules/navigator/ui.lua - the navigator window body: header, groups, search, tabs, transport strip, family
-- chips, the list (clipped rows with in-row buttons and a context menu), footer, status line and the keys.
-- Drawing only; every project change goes through actions.lua. Lua 5.4; no globals.

local theme = require('ui.theme')
local widgets = require('ui.widgets')
local text = require('lib.text')
local search = require('lib.search')
local match = require('lib.match')
local journal = require('lib.journal')
local view = require('lib.view')
local config = require('config')
local state = require('state')
local i18n = require('i18n')
local E = require('modules.navigator.editors')

local t = i18n.t

local U = {}

local ImGui, ctx, app, D, A, S
local BTN = 22
local COL_GAP = 10   -- gap between the time column and the next column
local GAP = 4
local DIGITS = nil

local function cfg(key)
  return config.get('navigator.' .. key)
end

function U.init(app_, D_, A_, S_)
  app, D, A, S = app_, D_, A_, S_
  ImGui = app.ImGui
  DIGITS = {
    { ImGui.Key_1, '1' }, { ImGui.Key_2, '2' }, { ImGui.Key_3, '3' }, { ImGui.Key_4, '4' }, { ImGui.Key_5, '5' },
    { ImGui.Key_6, '6' }, { ImGui.Key_7, '7' }, { ImGui.Key_8, '8' }, { ImGui.Key_9, '9' }, { ImGui.Key_0, '0' },
  }
end

-- helpers -------------------------------------------------------------------------------------------------------

local function row_h()
  return S.compact and theme.row_h_compact or theme.row_h
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

-- end a hand-laid-out section: move the cursor and submit an empty item so ImGui extends the window bounds
local function next_line(x, y)
  ImGui.SetCursorScreenPos(ctx, x, y)
  ImGui.Dummy(ctx, 0, 0)
end

local function scene_rgb(s)
  if s.color and s.color ~= 0 then return theme.native_to_rgb(s.color) end
  return theme.c.dim
end

local function rows_for_tab()
  local q = search.prepare(S.search, cfg('search.fuzzy') ~= false)
  if S.tab == 1 then
    return search.filter(q, D.scenes, function(s) return s.name end)
  elseif S.tab == 2 then
    return search.filter(q, D.markers, function(m) return m.name end)
  elseif S.tab == 3 then
    return search.filter(q, D.tracks, function(e) return e.name end)
  end
  local list = D.build_items(D.active_scene(), S.fam)
  return search.filter(q, list, function(r) return (r.name or '') .. ' ' .. r.track.name end)
end

local function activate(row)
  if S.tab == 1 then A.jump_scene(row)
  elseif S.tab == 2 then A.jump_marker(row)
  elseif S.tab == 3 then A.jump_track(row)
  else A.jump_item(row) end
end

local function audition_row(row)
  if S.tab == 1 then A.audition_scene(row)
  elseif S.tab == 2 then A.audition_marker(row)
  elseif S.tab == 3 then A.audition_track(row)
  else A.audition_item(row) end
end

local function is_current(row, pos)
  if S.tab == 1 then return pos >= row.t0 and pos < row.t1
  elseif S.tab == 2 then return math.abs(pos - row.t0) < 0.25
  elseif S.tab == 3 then return reaper.IsTrackSelected(row.tr)
  end
  return pos >= row.t0 and pos < row.t1
end

local function toggle_focus()
  if S.director_active then
    A.say(t('nav.msg.director_owns_layout'))
    return
  end
  S.focus = not S.focus
  S.dirty = true
  if not S.focus then
    A.restore_visibility()
    A.say(t('nav.msg.focus_off'))
  end
end

-- header --------------------------------------------------------------------------------------------------------

local function draw_menu()
  local docked = app.is_docked()
  if ImGui.MenuItem(ctx, docked and t('nav.menu.undock') or t('nav.menu.dock'), 'Ctrl+D') then app.toggle_dock() end
  if ImGui.MenuItem(ctx, t('nav.menu.refresh'), 'Ctrl+R') then D.refresh(); A.say(t('nav.msg.refreshed')) end
  ImGui.Separator(ctx)
  if ImGui.MenuItem(ctx, t('nav.menu.loop'), 'Ctrl+L', S.loop) then S.loop = not S.loop; S.dirty = true end
  if ImGui.MenuItem(ctx, t('nav.footer.focus'), 'Ctrl+H', S.focus) then toggle_focus() end
  if ImGui.MenuItem(ctx, t('nav.footer.timesel'), 'Ctrl+T', S.timesel) then S.timesel = not S.timesel; S.dirty = true end
  ImGui.Separator(ctx)
  if ImGui.MenuItem(ctx, t('nav.menu.show_all'), 'Ctrl+A') then A.show_all() end
  if ImGui.MenuItem(ctx, t('nav.menu.clear'), 'Ctrl+0') then A.clear_all() end
  if ImGui.MenuItem(ctx, t('nav.menu.restore'), nil, false, #journal.entries() > 0) then A.restore_all() end
  ImGui.Separator(ctx)
  if ImGui.MenuItem(ctx, t('nav.menu.families')) then E.request_open('families') end
  if ImGui.MenuItem(ctx, t('nav.menu.markers')) then E.request_open('classes') end
  if ImGui.MenuItem(ctx, t('nav.menu.groups')) then E.request_open('groups') end
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
  row_text(dl, x0, y0, state.project_name(), 'text', w - right_w - 8, 'bold', h)
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
  if widgets.icon_button(ctx, '##menu', 'chevron_down', { flat = true, muted = true, tooltip = t('nav.tip.menu') }) then
    ImGui.OpenPopup(ctx, 'navmenu')
  end
  if ImGui.BeginPopup(ctx, 'navmenu') then
    draw_menu()
    ImGui.EndPopup(ctx)
  end
  next_line(x0, y0 + h)
end

-- groups ---------------------------------------------------------------------------------------------------------

local function draw_groups()
  local groups = cfg('groups') or {}
  if #groups == 0 then return end
  local pos = view.position()
  local x0, y0 = ImGui.GetCursorScreenPos(ctx)
  local w = ImGui.GetContentRegionAvail(ctx)
  local n = #groups
  local bw = math.max(40, (w - (n - 1) * GAP) / n)
  for i, g in ipairs(groups) do
    ImGui.SetCursorScreenPos(ctx, x0 + (i - 1) * (bw + GAP), y0)
    local t0, t1 = tonumber(g.t0) or 0, tonumber(g.t1) or 0
    local active = pos >= t0 and pos < t1
    local tip = string.format(t('nav.tip.group'), tostring(g.key or '-'), text.fmt_time(t0), text.fmt_time(t1))
    if widgets.button(ctx, '##group' .. i, tostring(g.name or i), { w = bw, h = theme.control_h, active = active,
        color = theme.c.accent2, tooltip = tip }) then
      A.jump_group({ name = g.name, t0 = t0, t1 = t1 })
    end
  end
  next_line(x0, y0 + theme.control_h)
end

-- search ---------------------------------------------------------------------------------------------------------

local function draw_search()
  if S.focus_search then
    ImGui.SetKeyboardFocusHere(ctx)
    S.focus_search = false
  end
  local avail = ImGui.GetContentRegionAvail(ctx)
  local clear_w = S.search ~= '' and (BTN + GAP) or 0
  local changed, value, submitted, active = widgets.search_field(ctx, '##search', S.search, t('nav.search.hint'), avail - clear_w)
  S.search_active = active
  if changed then
    S.search = value
    S.hi = 0
  end
  if submitted then
    local rows = S.rows or {}
    local r = rows[S.hi > 0 and S.hi or 1]
    if r then activate(r) end
  end
  if S.search ~= '' then
    ImGui.SameLine(ctx, 0, GAP)
    if widgets.icon_button(ctx, '##clear', 'clear', { w = BTN, h = theme.control_h + 2, flat = true, muted = true,
        tooltip = t('nav.tip.clear_search') }) then
      S.search = ''
      S.hi = 0
    end
  end
end

-- tabs ------------------------------------------------------------------------------------------------------------

local function draw_tabs()
  local labels = { t('nav.tab.scenes'), t('nav.tab.markers'), t('nav.tab.tracks'), t('nav.tab.items') }
  local scene = D.active_scene()
  local item_count = scene and #D.build_items(scene, S.fam) or 0
  local counts = { #D.scenes, #D.markers, #D.tracks, item_count }
  if ImGui.BeginTabBar(ctx, 'navtabs', ImGui.TabBarFlags_NoTooltip | ImGui.TabBarFlags_FittingPolicyResizeDown) then
    for i = 1, 4 do
      local flags = (S.tab_request == i) and ImGui.TabItemFlags_SetSelected or ImGui.TabItemFlags_None
      local label = string.format('%s %d###navtab%d', labels[i], counts[i], i)
      local visible = ImGui.BeginTabItem(ctx, label, nil, flags)
      if visible then
        if S.tab ~= i then
          S.tab = i
          S.hi = 0
          S.dirty = true
        end
        ImGui.EndTabItem(ctx)
      end
    end
    S.tab_request = nil
    ImGui.EndTabBar(ctx)
  end
end

-- transport strip ----------------------------------------------------------------------------------------------

local function draw_transport()
  local x0, y0 = ImGui.GetCursorScreenPos(ctx)
  local w = ImGui.GetContentRegionAvail(ctx)
  local dl = ImGui.GetWindowDrawList(ctx)
  local h = BTN + 8
  ImGui.DrawList_AddRectFilled(dl, x0, y0, x0 + w, y0 + h, theme.col('panel'), theme.radius.m)
  local scene = D.active_scene()
  local playing = view.playing()
  local x, y = x0 + 4, y0 + 4
  local pw = BTN + 4
  ImGui.SetCursorScreenPos(ctx, x, y)
  if widgets.icon_button(ctx, '##play', 'play', { w = pw, h = BTN, active = A.aud ~= nil and playing, color = theme.c.ok,
      tooltip = t('nav.tip.play_scene'), disabled = scene == nil }) then
    A.audition_scene(scene)
  end
  x = x + pw + GAP
  ImGui.SetCursorScreenPos(ctx, x, y)
  if widgets.icon_button(ctx, '##stop', 'stop', { w = pw, h = BTN, color = theme.c.danger, tooltip = t('nav.tip.stop') }) then
    A.stop()
  end
  x = x + pw + GAP
  ImGui.SetCursorScreenPos(ctx, x, y)
  if widgets.icon_button(ctx, '##loop', 'loop', { w = pw, h = BTN, active = S.loop, color = theme.c.warn, tooltip = t('nav.tip.loop') }) then
    S.loop = not S.loop
    S.dirty = true
  end
  x = x + pw + GAP * 2
  local rx = x0 + w - 4 - 3 * (BTN + GAP) + GAP
  local solo_on = scene ~= nil and A.solo_scene_name == scene.name
  local mute_on = scene ~= nil and A.mute_scene_name == scene.name
  row_text(dl, x, y0, scene and scene.name or t('nav.transport.no_scene'), scene and 'text' or 'muted', rx - x - GAP, 'body', h)
  ImGui.SetCursorScreenPos(ctx, rx, y)
  if widgets.icon_button(ctx, '##solo', nil, { w = BTN, h = BTN, label = 'S', font = 'bold', active = solo_on,
      on = A.solo_scene_name ~= nil, color = theme.c.warn, tooltip = t('nav.tip.solo_scene'), disabled = scene == nil }) then
    A.toggle_solo_scene(scene)
  end
  rx = rx + BTN + GAP
  ImGui.SetCursorScreenPos(ctx, rx, y)
  if widgets.icon_button(ctx, '##mute', nil, { w = BTN, h = BTN, label = 'M', font = 'bold', active = mute_on,
      on = A.mute_scene_name ~= nil, color = theme.c.danger, tooltip = t('nav.tip.mute_scene'), disabled = scene == nil }) then
    A.toggle_mute_scene(scene)
  end
  rx = rx + BTN + GAP
  ImGui.SetCursorScreenPos(ctx, rx, y)
  local pending = journal.count('solo', 'scene_solo') + journal.count('item_mute', 'scene_mute')
  if widgets.icon_button(ctx, '##clearall', 'clear', { w = BTN, h = BTN, on = pending > 0, color = theme.c.muted,
      tooltip = t('nav.tip.clear') }) then
    A.clear_all()
  end
  next_line(x0, y0 + h)
end

-- family chips ----------------------------------------------------------------------------------------------------

local function draw_chips()
  local x0, y0 = ImGui.GetCursorScreenPos(ctx)
  local w = ImGui.GetContentRegionAvail(ctx)
  local x, y = x0, y0
  for i, f in ipairs(D.all_families) do
    local count = D.family_count[f.name] or 0
    local label = string.format('%s %d', f.name, count)
    local tw = measure(label, 'small')
    local cw = tw + theme.space[2] * 2
    if x + cw > x0 + w and x > x0 then
      x = x0
      y = y + theme.chip_h + GAP
    end
    ImGui.SetCursorScreenPos(ctx, x, y)
    local on = D.fam_on(S.fam, f.name)
    local tip
    if f.other then tip = t('nav.family.other_tip')
    else tip = string.format(t('nav.family.tip'), f.name, match.describe(f.rule), count) end
    if widgets.chip(ctx, '##fam' .. i, label, on, f.color, { w = cw, tooltip = tip }) then
      S.fam[f.name] = not on
      S.dirty = true
      D.invalidate_items()
    end
    x = x + cw + GAP
  end
  next_line(x0, y + theme.chip_h)
end

-- rows ------------------------------------------------------------------------------------------------------------

local function draw_row_scene(s, x0, y0, w, dl, rh, playing)
  local pressed = false
  ImGui.DrawList_AddRectFilled(dl, x0 + 8, y0 + 7, x0 + 14, y0 + rh - 7, theme.rgba(scene_rgb(s)), 2)
  row_text(dl, x0 + 22, y0, text.fmt_time(s.t0), 'muted', nil, 'mono', rh)
  local bx = x0 + w - 3 * (BTN + GAP)
  local name_x = x0 + 22 + S.time_w + COL_GAP
  local count_w = row_text_right(dl, bx - GAP, y0, tostring(s.items), 'muted', 'mono', rh)
  row_text(dl, name_x, y0, s.name, 'text', bx - GAP * 2 - count_w - name_x, 'body', rh)
  if row_button(bx, y0, rh, '##play', 'play', { active = A.is_auditioning(s.t0) and playing, color = theme.c.ok,
      tooltip = t('nav.tip.play_scene') }) then
    pressed = true
    A.audition_scene(s)
  end
  if row_button(bx + BTN + GAP, y0, rh, '##solo', nil, { label = 'S', font = 'bold', active = A.solo_scene_name == s.name,
      color = theme.c.warn, tooltip = t('nav.tip.solo_scene') }) then
    pressed = true
    A.set_active_scene(s)
    A.toggle_solo_scene(s)
  end
  if row_button(bx + 2 * (BTN + GAP), y0, rh, '##mute', nil, { label = 'M', font = 'bold', active = A.mute_scene_name == s.name,
      color = theme.c.danger, tooltip = t('nav.tip.mute_scene') }) then
    pressed = true
    A.set_active_scene(s)
    A.toggle_mute_scene(s)
  end
  return pressed
end

local function draw_row_marker(m, x0, y0, w, dl, rh, playing)
  local pressed = false
  local rgb = m.class and m.class.rgb or theme.c.dim
  ImGui.DrawList_AddCircleFilled(dl, x0 + 11, y0 + rh / 2, 4, theme.rgba(rgb), 12)
  row_text(dl, x0 + 22, y0, text.fmt_time(m.t0), 'muted', nil, 'mono', rh)
  local bx = x0 + w - (BTN + GAP)
  local name_x = x0 + 22 + S.time_w + COL_GAP
  row_text(dl, name_x, y0, m.name, 'text', bx - GAP - name_x, 'body', rh)
  if row_button(bx, y0, rh, '##play', 'play', { active = A.is_auditioning(m.t0) and playing, color = theme.c.ok,
      tooltip = t('nav.tip.play_marker') }) then
    pressed = true
    A.audition_marker(m)
  end
  return pressed
end

local function draw_row_track(e, x0, y0, w, dl, rh)
  local pressed = false
  row_text_right(dl, x0 + 34, y0, tostring(e.n), 'muted', 'mono', rh)
  local ind = e.depth * 14
  local nx = x0 + 44 + ind
  if e.folder then
    local ic = theme.rgba(D.family_color(e.fam))
    require('ui.icons').draw(ImGui, dl, 'folder', nx + 6, y0 + rh / 2, 11, ic)
  else
    ImGui.DrawList_AddCircleFilled(dl, nx + 6, y0 + rh / 2, 3, theme.rgba(D.family_color(e.fam)), 10)
  end
  nx = nx + 18
  local bx = x0 + w - 2 * (BTN + GAP)
  local count_w = 0
  if e.items > 0 then count_w = row_text_right(dl, bx - GAP, y0, tostring(e.items), 'muted', 'mono', rh) end
  row_text(dl, nx, y0, e.name, e.folder and 'text' or 'text', bx - GAP * 2 - count_w - nx, e.folder and 'bold' or 'body', rh)
  local solo = reaper.GetMediaTrackInfo_Value(e.tr, 'I_SOLO') > 0
  local mute = reaper.GetMediaTrackInfo_Value(e.tr, 'B_MUTE') == 1
  if row_button(bx, y0, rh, '##solo', nil, { label = 'S', font = 'bold', active = solo, color = theme.c.warn, tooltip = t('nav.tip.track_solo') }) then
    pressed = true
    A.track_solo_toggle(e)
  end
  if row_button(bx + BTN + GAP, y0, rh, '##mute', nil, { label = 'M', font = 'bold', active = mute, color = theme.c.danger, tooltip = t('nav.tip.track_mute') }) then
    pressed = true
    A.track_mute_toggle(e)
  end
  return pressed
end

local function draw_row_item(r, x0, y0, w, dl, rh, playing)
  local pressed = false
  local valid = reaper.ValidatePtr2(0, r.it, 'MediaItem*')
  local mute = valid and reaper.GetMediaItemInfo_Value(r.it, 'B_MUTE') == 1
  row_text(dl, x0 + 8, y0, text.fmt_time(r.t0), 'muted', nil, 'mono', rh)
  local tn = r.track.name
  local tn_x = x0 + 8 + S.time_w + COL_GAP
  local tn_w = math.min(120, math.max(60, math.floor(w * 0.22)))
  row_text(dl, tn_x, y0, tn, 'muted', tn_w, 'small', rh)
  local bx = x0 + w - 2 * (BTN + GAP)
  local name_x = tn_x + tn_w + COL_GAP
  row_text(dl, name_x, y0, r.name or t('nav.item.unnamed'), mute and 'muted' or 'text', bx - GAP - name_x, 'body', rh)
  if row_button(bx, y0, rh, '##play', 'play', { active = A.is_auditioning(r.t0, r.track.guid) and playing, color = theme.c.ok,
      tooltip = t('nav.tip.play_item') }) then
    pressed = true
    A.audition_item(r)
  end
  if row_button(bx + BTN + GAP, y0, rh, '##mute', nil, { label = 'M', font = 'bold', active = mute, color = theme.c.danger,
      tooltip = t('nav.tip.item_mute'), disabled = not valid }) then
    pressed = true
    A.item_mute_toggle(r)
  end
  return pressed
end

local function draw_row(i, row, rh, pos, playing)
  ImGui.PushID(ctx, i)
  local x0, y0 = ImGui.GetCursorScreenPos(ctx)
  local w = ImGui.GetContentRegionAvail(ctx)
  local dl = ImGui.GetWindowDrawList(ctx)
  if is_current(row, pos) then
    ImGui.DrawList_AddRectFilled(dl, x0, y0, x0 + w, y0 + rh, theme.col('accent', 0.10), 0)
    ImGui.DrawList_AddRectFilled(dl, x0, y0, x0 + 3, y0 + rh, theme.col('accent'), 0)
  end
  local flags = ImGui.SelectableFlags_AllowOverlap | ImGui.SelectableFlags_AllowDoubleClick
  local clicked = ImGui.Selectable(ctx, '##row', S.hi == i, flags, w, rh)
  local hovered = ImGui.IsItemHovered(ctx)
  if S.scroll_to_hi and S.hi == i then ImGui.SetScrollHereY(ctx, 0.5) end
  if hovered and ImGui.IsMouseClicked(ctx, ImGui.MouseButton_Right) then
    S.hi = i
    S.menu_row, S.menu_tab, S.menu_request = row, S.tab, true
  end
  local dbl = clicked and ImGui.IsMouseDoubleClicked(ctx, ImGui.MouseButton_Left)
  local pressed
  if S.tab == 1 then pressed = draw_row_scene(row, x0, y0, w, dl, rh, playing)
  elseif S.tab == 2 then pressed = draw_row_marker(row, x0, y0, w, dl, rh, playing)
  elseif S.tab == 3 then pressed = draw_row_track(row, x0, y0, w, dl, rh)
  else pressed = draw_row_item(row, x0, y0, w, dl, rh, playing) end
  if clicked and not pressed then
    S.hi = i
    if dbl then audition_row(row) else activate(row) end
  end
  ImGui.SetCursorScreenPos(ctx, x0, y0 + rh)
  ImGui.Dummy(ctx, 0, 0)
  ImGui.PopID(ctx)
end

local function draw_empty()
  local msg
  if S.search ~= '' then msg = string.format(t('nav.empty.search'), S.search)
  elseif S.tab == 1 then msg = t('nav.empty.scenes')
  elseif S.tab == 2 then msg = t('nav.empty.markers')
  elseif S.tab == 3 then msg = t('nav.empty.tracks')
  elseif not D.active_scene() then msg = t('nav.empty.items_no_scene')
  else msg = t('nav.empty.items') end
  ImGui.Dummy(ctx, 0, theme.space[3])
  ImGui.Indent(ctx, theme.space[3])
  ImGui.PushTextWrapPos(ctx, 0)
  ImGui.TextColored(ctx, theme.col('muted'), msg)
  ImGui.PopTextWrapPos(ctx)
  ImGui.Unindent(ctx, theme.space[3])
end

local function draw_row_menu()
  local row, tab = S.menu_row, S.menu_tab
  if not row then return end
  if tab == 1 then
    if ImGui.MenuItem(ctx, t('nav.row.jump')) then A.jump_scene(row) end
    if ImGui.MenuItem(ctx, t('nav.row.audition')) then A.audition_scene(row) end
    if ImGui.MenuItem(ctx, t('nav.row.solo_scene'), nil, A.solo_scene_name == row.name) then A.set_active_scene(row); A.toggle_solo_scene(row) end
    if ImGui.MenuItem(ctx, t('nav.row.mute_scene'), nil, A.mute_scene_name == row.name) then A.set_active_scene(row); A.toggle_mute_scene(row) end
    if ImGui.MenuItem(ctx, t('nav.row.focus_scene')) then
      A.set_active_scene(row)
      S.focus = true
      S.dirty = true
      local shown = A.focus_range(row.t0, row.t1)
      A.say(string.format(t('nav.msg.jump_tracks'), row.name, text.fmt_time(row.t0), text.fmt_time(row.t1), shown))
    end
    if ImGui.MenuItem(ctx, t('nav.row.activate')) then A.set_active_scene(row) end
  elseif tab == 2 then
    if ImGui.MenuItem(ctx, t('nav.row.jump')) then A.jump_marker(row) end
    if ImGui.MenuItem(ctx, t('nav.row.audition_marker')) then A.audition_marker(row) end
  elseif tab == 3 then
    if ImGui.MenuItem(ctx, t('nav.row.jump')) then A.jump_track(row) end
    if ImGui.MenuItem(ctx, t('nav.row.audition_track')) then A.audition_track(row) end
    local solo = reaper.GetMediaTrackInfo_Value(row.tr, 'I_SOLO') > 0
    local mute = reaper.GetMediaTrackInfo_Value(row.tr, 'B_MUTE') == 1
    if ImGui.MenuItem(ctx, solo and t('nav.row.unsolo_track') or t('nav.row.solo_track')) then A.track_solo_toggle(row) end
    if ImGui.MenuItem(ctx, mute and t('nav.row.unmute_track') or t('nav.row.mute_track')) then A.track_mute_toggle(row) end
  else
    if ImGui.MenuItem(ctx, t('nav.row.jump')) then A.jump_item(row) end
    if ImGui.MenuItem(ctx, t('nav.row.audition')) then A.audition_item(row) end
    local mute = reaper.ValidatePtr2(0, row.it, 'MediaItem*') and reaper.GetMediaItemInfo_Value(row.it, 'B_MUTE') == 1
    if ImGui.MenuItem(ctx, mute and t('nav.row.unmute_item') or t('nav.row.mute_item')) then A.item_mute_toggle(row) end
  end
  ImGui.Separator(ctx)
  if ImGui.MenuItem(ctx, t('nav.row.copy_name')) then ImGui.SetClipboardText(ctx, row.name or '') end
end

local function draw_list()
  local rows = rows_for_tab()
  S.rows = rows
  if S.hi > #rows then S.hi = #rows end
  local footer_h = theme.control_h + theme.space[2] + (S.compact and 0 or (theme.type.small + theme.space[2]))
  ImGui.PushStyleColor(ctx, ImGui.Col_ChildBg, theme.col('panel'))
  local visible = ImGui.BeginChild(ctx, 'list', 0, -footer_h, ImGui.ChildFlags_Borders, ImGui.WindowFlags_None)
  ImGui.PopStyleColor(ctx)
  if visible then
    local rh = row_h()
    ImGui.PushStyleVar(ctx, ImGui.StyleVar_ItemSpacing, 0, 0)
    ImGui.PushStyleColor(ctx, ImGui.Col_Header, theme.col('sel'))
    ImGui.PushStyleColor(ctx, ImGui.Col_HeaderHovered, theme.col('hover'))
    ImGui.PushStyleColor(ctx, ImGui.Col_HeaderActive, theme.col('sel'))
    if #rows == 0 then
      draw_empty()
    else
      local pos = view.position()
      local playing = view.playing()
      local clipper = S.clipper
      -- the time column takes the width of the widest time in the list (rows are sorted by time): the monospace
      -- face differs per platform, so a fixed column would run into the names (seen on macOS with 15:21.55)
      local last = rows[#rows]
      S.time_w = measure(text.fmt_time((last and last.t0) or 0), 'mono')
      ImGui.ListClipper_Begin(clipper, #rows, rh)
      if S.scroll_to_hi and S.hi > 0 then ImGui.ListClipper_IncludeItemByIndex(clipper, S.hi - 1) end
      while ImGui.ListClipper_Step(clipper) do
        local d0, d1 = ImGui.ListClipper_GetDisplayRange(clipper)
        for i = d0 + 1, d1 do
          if rows[i] then draw_row(i, rows[i], rh, pos, playing) end
        end
      end
      S.scroll_to_hi = false
    end
    ImGui.PopStyleColor(ctx, 3)
    ImGui.PopStyleVar(ctx)
    if S.menu_request then
      ImGui.OpenPopup(ctx, 'rowmenu')
      S.menu_request = nil
    end
    if ImGui.BeginPopup(ctx, 'rowmenu') then
      draw_row_menu()
      ImGui.EndPopup(ctx)
    end
  end
  ImGui.EndChild(ctx)
end

-- footer ----------------------------------------------------------------------------------------------------------

local function draw_footer()
  local x0, y0 = ImGui.GetCursorScreenPos(ctx)
  local w = ImGui.GetContentRegionAvail(ctx)
  local bw = (w - 3 * GAP) / 4
  local h = theme.control_h
  ImGui.SetCursorScreenPos(ctx, x0, y0)
  local owned = S.director_active
  if widgets.button(ctx, '##focus', t('nav.footer.focus'), { w = bw, h = h, active = S.focus and not owned, color = theme.c.ok,
      disabled = owned, tooltip = owned and t('nav.tip.director_owns') or t('nav.tip.focus') }) then
    toggle_focus()
  end
  ImGui.SetCursorScreenPos(ctx, x0 + bw + GAP, y0)
  if widgets.button(ctx, '##showall', t('nav.footer.show_all'), { w = bw, h = h, disabled = owned,
      tooltip = owned and t('nav.tip.director_owns') or t('nav.tip.show_all') }) then
    A.show_all()
  end
  ImGui.SetCursorScreenPos(ctx, x0 + 2 * (bw + GAP), y0)
  if widgets.button(ctx, '##timesel', t('nav.footer.timesel'), { w = bw, h = h, active = S.timesel, color = theme.c.warn, tooltip = t('nav.tip.timesel') }) then
    S.timesel = not S.timesel
    S.dirty = true
  end
  ImGui.SetCursorScreenPos(ctx, x0 + 3 * (bw + GAP), y0)
  local n = #journal.entries()
  local label = n > 0 and string.format(t('nav.footer.restore_n'), n) or t('nav.footer.restore')
  if widgets.button(ctx, '##restore', label, { w = bw, h = h, disabled = n == 0, on = n > 0, color = theme.c.accent, tooltip = t('nav.tip.restore') }) then
    A.restore_all()
  end
  next_line(x0, y0 + h)
  if not S.compact then
    widgets.status(ctx, S.msg_frames > 0 and S.msg or nil, t('nav.hint'), S.msg_frames > 0)
  end
end

-- recovery prompt (a journal left by a run that did not exit cleanly) ---------------------------------------------

local function draw_recover()
  if S.recover_request then
    ImGui.OpenPopup(ctx, t('nav.recover.title') .. '###recover')
    S.recover_request = nil
  end
  local visible = ImGui.BeginPopupModal(ctx, t('nav.recover.title') .. '###recover', nil, ImGui.WindowFlags_AlwaysAutoResize)
  if visible then
    ImGui.PushTextWrapPos(ctx, 380)
    ImGui.Text(ctx, string.format(t('nav.recover.body'), S.recover or 0))
    ImGui.PopTextWrapPos(ctx)
    ImGui.Spacing(ctx)
    if ImGui.Button(ctx, t('nav.recover.restore'), 120, 0) then
      A.restore_all()
      S.recover = nil
      ImGui.CloseCurrentPopup(ctx)
    end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, t('nav.recover.discard'), 120, 0) then
      journal.discard()
      S.recover = nil
      ImGui.CloseCurrentPopup(ctx)
    end
    ImGui.EndPopup(ctx)
  end
end

-- keyboard ------------------------------------------------------------------------------------------------------

local function handle_keys()
  if not app.focused then return end
  local typing = S.search_active
  local rows = S.rows or {}
  local mods = ImGui.GetKeyMods(ctx)
  local ctrl = (mods & ImGui.Mod_Ctrl) ~= 0
  local shift = (mods & ImGui.Mod_Shift) ~= 0
  local function chord(key) return ImGui.IsKeyChordPressed(ctx, ImGui.Mod_Ctrl | key) end
  local function pressed(key, rep) return ImGui.IsKeyPressed(ctx, key, rep == true) end
  if chord(ImGui.Key_F) then S.focus_search = true end
  if chord(ImGui.Key_H) then toggle_focus() end
  if chord(ImGui.Key_T) then S.timesel = not S.timesel; S.dirty = true end
  if chord(ImGui.Key_L) then S.loop = not S.loop; S.dirty = true end
  if chord(ImGui.Key_D) then app.toggle_dock() end
  if chord(ImGui.Key_R) then D.refresh(); A.say(t('nav.msg.refreshed')) end
  if chord(ImGui.Key_0) then A.clear_all() end
  if not typing and chord(ImGui.Key_A) then A.show_all() end
  if pressed(ImGui.Key_DownArrow, true) and #rows > 0 then
    S.hi = math.min(#rows, S.hi + 1)
    S.scroll_to_hi = true
  end
  if pressed(ImGui.Key_UpArrow, true) and #rows > 0 then
    S.hi = math.max(1, S.hi - 1)
    S.scroll_to_hi = true
  end
  if (pressed(ImGui.Key_Enter) or pressed(ImGui.Key_KeypadEnter)) and not typing then
    local r = rows[S.hi]
    if r then
      if ctrl then audition_row(r) else activate(r) end
    end
  elseif typing and ctrl and (pressed(ImGui.Key_Enter) or pressed(ImGui.Key_KeypadEnter)) then
    local r = rows[S.hi > 0 and S.hi or 1]
    if r then audition_row(r) end
  end
  if pressed(ImGui.Key_Escape) and S.search ~= '' then
    S.search = ''
    S.hi = 0
  end
  if not typing then
    if pressed(ImGui.Key_Space) then
      if A.aud then A.stop() else reaper.Main_OnCommand(40044, 0) end   -- Transport: Play/stop
    end
    if pressed(ImGui.Key_Tab) then
      if shift then S.tab_request = (S.tab - 2) % 4 + 1 else S.tab_request = S.tab % 4 + 1 end
    end
    if not ctrl then
      local groups = cfg('groups') or {}
      for _, d in ipairs(DIGITS) do
        if pressed(d[1]) then
          for _, g in ipairs(groups) do
            if tostring(g.key) == d[2] then A.jump_group({ name = g.name, t0 = tonumber(g.t0) or 0, t1 = tonumber(g.t1) or 0 }) end
          end
        end
      end
    end
  end
end

-- entry -----------------------------------------------------------------------------------------------------------

function U.draw(app_)
  app = app_
  ctx = app.ctx
  D.check_refresh()
  S.compact = app.win_h < (config.get('ui.compact_below_px') or theme.compact_below)
  if S.msg_frames > 0 then S.msg_frames = S.msg_frames - 1 end
  E.handle_requests(ctx)
  draw_recover()
  draw_header()
  draw_groups()
  draw_search()
  draw_tabs()
  draw_transport()
  if not S.compact then draw_chips() end
  draw_list()
  draw_footer()
  E.draw(ctx)
  handle_keys()
end

return U
