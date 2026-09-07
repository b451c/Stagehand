-- modules/settings/ui.lua - the Settings tab: scope switch (this project / global), search, the presets row,
-- the problems panel (invalid values found in the layers, with "use default"), and every schema key drawn as
-- a row inside its module and group: a control by type (toggle, slider, segmented, text, path, colour,
-- comma list, JSON editor, or a jump to the Navigator's list editors), an override dot, a tooltip with the
-- meaning, range, default and key, a reset per key and per group. Sliders preview every frame and the file
-- is written once the mouse is up. Drawing only; the data lives in config.lua / schema.lua. Lua 5.4; no globals.

local theme = require('ui.theme')
local widgets = require('ui.widgets')
local text = require('lib.text')
local json = require('lib.json')
local config = require('config')
local schema = require('schema')
local state = require('state')
local i18n = require('i18n')
local P = require('modules.settings.presets')

local t = i18n.t

local U = {}

local ImGui, ctx, app, S
local GAP = 4
local ROW_H = 24

function U.init(app_, S_)
  app, S = app_, S_
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
  S.msg_frames = 60
end

local function other_scope()
  return S.scope == 'project' and 'global' or 'project'
end

-- the override keys of both layers, rebuilt once per frame (config.overrides walks the layer; rows only look up)
local ov = { project = {}, global = {}, n = { project = 0, global = 0 } }

local function refresh_overrides()
  for _, scope in ipairs({ 'project', 'global' }) do
    local set, n = {}, 0
    for _, o in ipairs(config.overrides(scope)) do
      set[o.key] = true
      n = n + 1
    end
    ov[scope], ov.n[scope] = set, n
  end
end

local function overridden(key, scope)
  return ov[scope][key] == true
end

-- overrides of a scope under a prefix ('' = all)
local function count_overrides(prefix, scope)
  if prefix == '' then return ov.n[scope] end
  local n = 0
  for k in pairs(ov[scope]) do
    if k == prefix or k:sub(1, #prefix + 1) == prefix .. '.' then n = n + 1 end
  end
  return n
end

local function scope_label(scope)
  return scope == 'project' and t('set.scope.project') or t('set.scope.global')
end

-- strings of an entry ------------------------------------------------------------------------------------------------------

local function label_of(entry)
  local key = 'cfg.' .. entry.key
  if i18n.has(key) then return t(key) end
  local last = entry.key:match('([^.]+)$') or entry.key
  return (last:gsub('_', ' '))
end

-- the meaning line alone (nil when the string table has none)
local function meaning_of(entry)
  local key = 'cfg.' .. entry.key .. '.tip'
  if i18n.has(key) then return t(key) end
  return nil
end

local function tip_of(entry)
  local lines = {}
  local meaning = meaning_of(entry)
  if meaning then lines[#lines + 1] = meaning end
  local range = schema.range_text(entry)
  if range then lines[#lines + 1] = t('set.tip.range') .. ' ' .. range end
  lines[#lines + 1] = t('set.tip.default') .. ' ' .. schema.format(entry, config.default(entry.key))
  local here, there = overridden(entry.key, S.scope), overridden(entry.key, other_scope())
  if here then lines[#lines + 1] = string.format(t('set.tip.overridden_here'), scope_label(S.scope)) end
  if there then lines[#lines + 1] = string.format(t('set.tip.overridden_there'), scope_label(other_scope()), schema.format(entry, config.raw(entry.key, other_scope()))) end
  lines[#lines + 1] = t('set.tip.key') .. ' ' .. entry.key
  return table.concat(lines, '\n')
end

local function value_label(v)
  local key = 'cfg.val.' .. tostring(v)
  if i18n.has(key) then return t(key) end
  return tostring(v)
end

local function group_label(g)
  local key = 'cfg.group.' .. g.id
  if i18n.has(key) then return t(key) end
  return (g.id:match('([^.]+)$'):gsub('_', ' '))
end

local function module_label(mod)
  local key = 'cfg.module.' .. mod
  if i18n.has(key) then return t(key) end
  return mod
end

-- search ------------------------------------------------------------------------------------------------------------------------

local function matches(entry, words)
  if #words == 0 then return true end
  local hay = (entry.key .. ' ' .. label_of(entry) .. ' ' .. (meaning_of(entry) or '')):lower()
  for _, w in ipairs(words) do
    if not hay:find(w, 1, true) then return false end
  end
  return true
end

local function search_words()
  local words = {}
  for w in S.search:lower():gmatch('%S+') do words[#words + 1] = w end
  return words
end

-- rows -------------------------------------------------------------------------------------------------------------------------

local function write(entry, value)
  config.set(entry.key, value, S.scope)
end

local function preview(entry, value)
  config.preview(entry.key, value, S.scope)
end

local function slider_fmt(entry)
  local f = entry.type == 'int' and '%d' or (entry.fmt or '%.2f')
  if entry.unit then f = f .. ' ' .. entry.unit end
  return f
end

local function big_range(entry)
  return entry.min ~= nil and (entry.max - entry.min) > 1000
end

local function draw_bool(entry, v, w)
  local rv, nv = ImGui.Checkbox(ctx, '##v', v == true)
  if rv then write(entry, nv) end
  ImGui.SameLine(ctx)
  theme.push_font(ImGui, ctx, 'small')
  ImGui.TextColored(ctx, theme.col('muted'), nv and t('cfg.val.on') or t('cfg.val.off'))
  theme.pop_font(ImGui, ctx)
end

local function draw_number(entry, v, w)
  ImGui.SetNextItemWidth(ctx, w)
  if big_range(entry) then
    local key = entry.key
    local cur = S.edit[key] or schema.format(entry, v)
    local rv, s = ImGui.InputText(ctx, '##v', cur)
    if rv then S.edit[key] = s end
    if ImGui.IsItemDeactivatedAfterEdit(ctx) then
      local nv, err = schema.parse(entry, S.edit[key] or cur)
      if nv ~= nil then
        write(entry, nv)
        S.errors[key] = nil
      else
        S.errors[key] = err
      end
      S.edit[key] = nil
    end
    return
  end
  local flags = ImGui.SliderFlags_AlwaysClamp
  local rv, nv
  if entry.type == 'int' then
    rv, nv = ImGui.SliderInt(ctx, '##v', math.floor(tonumber(v) or entry.min), entry.min, entry.max, slider_fmt(entry), flags)
  else
    rv, nv = ImGui.SliderDouble(ctx, '##v', tonumber(v) or entry.min, entry.min, entry.max, slider_fmt(entry), flags)
  end
  if rv then preview(entry, nv) end
end

local function draw_enum(entry, v, w)
  local options = {}
  for _, val in ipairs(entry.values) do options[#options + 1] = { val, value_label(val) } end
  local total = 0
  theme.push_font(ImGui, ctx, 'small')
  for _, o in ipairs(options) do total = total + ImGui.CalcTextSize(ctx, o[2]) + theme.space[3] end
  theme.pop_font(ImGui, ctx)
  if total <= w then
    local chosen = widgets.segmented(ctx, '##v', options, v, { w = math.min(w, total + 8 * #options) })
    if chosen then write(entry, chosen) end
  else
    ImGui.SetNextItemWidth(ctx, w)
    if ImGui.BeginCombo(ctx, '##v', value_label(v)) then
      for _, o in ipairs(options) do
        if ImGui.Selectable(ctx, o[2], o[1] == v) then write(entry, o[1]) end
      end
      ImGui.EndCombo(ctx)
    end
  end
end

local function draw_text(entry, v, w, hint)
  local key = entry.key
  local cur = S.edit[key] or tostring(v or '')
  ImGui.SetNextItemWidth(ctx, w)
  local rv, s = ImGui.InputTextWithHint(ctx, '##v', hint or '', cur)
  if rv then S.edit[key] = s end
  if ImGui.IsItemDeactivatedAfterEdit(ctx) then
    local typed = S.edit[key] or cur
    S.edit[key] = nil
    return typed
  end
  return nil
end

local function draw_str(entry, v, w)
  local typed = draw_text(entry, v, w)
  if typed ~= nil and typed ~= tostring(v or '') then write(entry, typed) end
end

local function draw_path(entry, v, w)
  local bw = 28
  local typed = draw_text(entry, v, w - bw - GAP, t('set.path.hint'))
  if typed ~= nil and typed ~= tostring(v or '') then write(entry, typed) end
  ImGui.SameLine(ctx, 0, GAP)
  if ImGui.Button(ctx, '...', bw, 0) then
    local ok, chosen = reaper.GetUserFileNameForRead(tostring(v or ''), t('set.path.pick'), '')
    if ok and chosen and chosen ~= '' then write(entry, chosen) end
  end
  widgets.tooltip(ctx, t('set.path.browse'))
end

local function draw_list_text(entry, v, w)
  local key = entry.key
  local typed = draw_text(entry, schema.format(entry, v), w, t('set.list.hint'))
  if typed ~= nil then
    local nv, err = schema.parse(entry, typed)
    if nv ~= nil then
      S.errors[key] = nil
      if schema.format(entry, nv) ~= schema.format(entry, v) then write(entry, nv) end
    else
      S.errors[key] = err
    end
  end
end

local function draw_color(entry, v, w)
  local key = entry.key
  local rgb = theme.parse_hex(v) or 0xFFFFFF
  local flags = ImGui.ColorEditFlags_NoInputs | ImGui.ColorEditFlags_NoLabel
  local rv, col = ImGui.ColorEdit3(ctx, '##v', rgb, flags)
  if rv then preview(entry, theme.hex(col)) end
  ImGui.SameLine(ctx, 0, GAP)
  local cur = S.edit[key] or tostring(v or '')
  ImGui.SetNextItemWidth(ctx, math.min(84, w - 30))
  theme.push_font(ImGui, ctx, 'mono')
  local rv2, s = ImGui.InputText(ctx, '##hex', cur)
  theme.pop_font(ImGui, ctx)
  if rv2 then S.edit[key] = s end
  if ImGui.IsItemDeactivatedAfterEdit(ctx) then
    local nv, err = schema.parse(entry, S.edit[key] or cur)
    S.edit[key] = nil
    if nv then
      S.errors[key] = nil
      if nv ~= v then write(entry, nv) end
    else
      S.errors[key] = err
    end
  end
end

local function draw_list_editor(entry, v, w)
  local n = type(v) == 'table' and #v or 0
  if widgets.button(ctx, '##edit', string.format(t('set.list.edit'), n), { h = theme.control_h_small, font = 'small', tooltip = t('set.list.edit_tip') }) then
    app.set_tab('navigator')
    app.emit('open_editor', entry.editor)
  end
end

local function draw_json_button(entry, v, w)
  local n = type(v) == 'table' and #v or 0
  if widgets.button(ctx, '##json', string.format(t('set.json.edit'), n), { h = theme.control_h_small, font = 'small', tooltip = t('set.json.edit_tip') }) then
    S.json = { key = entry.key, text = json.encode(v or {}, { pretty = true }), err = nil }
    S.json_request = true
  end
end

local DRAW = {
  bool = draw_bool, int = draw_number, num = draw_number, enum = draw_enum, str = draw_str, path = draw_path,
  color = draw_color, int_list = draw_list_text, str_list = draw_list_text, list = draw_list_editor, table = draw_json_button,
}

-- one key row; returns the height used
local function draw_row(entry, x0, y, w)
  local dl = ImGui.GetWindowDrawList(ctx)
  local label_w = math.max(130, math.min(210, w * 0.44))
  local here, there = overridden(entry.key, S.scope), overridden(entry.key, other_scope())
  local err = S.errors[entry.key]
  local rh = ROW_H
  local used = rh + (err and 16 or 0)
  -- rows outside the visible part of the list only take their space (150 rows would cost ~8 ms drawn blind)
  if y > S.clip_y1 or y + used < S.clip_y0 then
    S.visible_rows = S.visible_rows + 1
    return used
  end
  ImGui.PushID(ctx, entry.key)
  -- override dot
  local cx, cy = x0 + 6, y + rh / 2
  if here then
    ImGui.DrawList_AddCircleFilled(dl, cx, cy, 3.5, theme.col('accent'), 10)
  elseif there then
    ImGui.DrawList_AddCircle(dl, cx, cy, 3.5, theme.col('muted'), 10, 1.2)
  end
  row_text(dl, x0 + 16, y, label_of(entry), err and 'danger' or 'text', label_w - 20, 'body', rh)
  ImGui.SetCursorScreenPos(ctx, x0, y)
  ImGui.Dummy(ctx, label_w - 4, rh)
  if ImGui.IsItemHovered(ctx, ImGui.HoveredFlags_ForTooltip) then ImGui.SetTooltip(ctx, tip_of(entry)) end
  -- control
  local reset_w = here and (theme.control_h_small + GAP) or 0
  local cw = w - label_w - reset_w
  ImGui.SetCursorScreenPos(ctx, x0 + label_w, y + (rh - theme.control_h_small) / 2)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_FramePadding, 6, 2)
  local v = config.get(entry.key)
  DRAW[entry.type](entry, v, cw)
  ImGui.PopStyleVar(ctx)
  if ImGui.IsItemHovered(ctx, ImGui.HoveredFlags_ForTooltip) and not ImGui.IsAnyItemActive(ctx) then
    ImGui.SetTooltip(ctx, tip_of(entry))
  end
  if here then
    ImGui.SetCursorScreenPos(ctx, x0 + w - theme.control_h_small, y + (rh - theme.control_h_small) / 2)
    if widgets.icon_button(ctx, '##reset', 'clear', { flat = true, muted = true, tooltip = string.format(t('set.tip.reset_key'), schema.format(entry, config.default(entry.key))) }) then
      config.reset(entry.key, S.scope)
      S.errors[entry.key] = nil
    end
  end
  if err then
    row_text(dl, x0 + label_w, y + rh, err, 'danger', w - label_w, 'small', 16)
  end
  ImGui.PopID(ctx)
  S.visible_rows = S.visible_rows + 1
  return used
end

local function draw_group(g, x0, y, w, words)
  local dl = ImGui.GetWindowDrawList(ctx)
  local rows = {}
  for _, e in ipairs(g.keys) do
    if matches(e, words) then rows[#rows + 1] = e end
  end
  if #rows == 0 then return 0 end
  local gh = 22
  ImGui.DrawList_AddRectFilled(dl, x0, y + 2, x0 + w, y + gh - 2, theme.col('panel'), theme.radius.s)
  row_text(dl, x0 + 8, y, group_label(g):upper(), 'muted', w - 40, 'small', gh)
  local n = 0
  for _, e in ipairs(g.keys) do if overridden(e.key, S.scope) then n = n + 1 end end
  ImGui.SetCursorScreenPos(ctx, x0 + w - theme.control_h_small - 2, y + (gh - theme.control_h_small) / 2)
  ImGui.PushID(ctx, g.id)
  if widgets.icon_button(ctx, '##rg', 'refresh', { flat = true, muted = true, disabled = n == 0,
      tooltip = string.format(t('set.tip.reset_group'), group_label(g), scope_label(S.scope), n) }) then
    if g.id == g.module .. '.general' then
      for _, e in ipairs(g.keys) do config.reset(e.key, S.scope) end
    else
      config.reset_prefix(g.id, S.scope)
    end
    say(string.format(t('set.msg.group_reset'), group_label(g), n))
  end
  ImGui.PopID(ctx)
  local yy = y + gh + 2
  for _, e in ipairs(rows) do
    yy = yy + draw_row(e, x0, yy, w) + 2
  end
  return yy - y + 4
end

local function draw_module(mod, x0, y, w, words)
  local dl = ImGui.GetWindowDrawList(ctx)
  local groups = schema.groups_of(mod)
  local shown = 0
  for _, g in ipairs(groups) do
    for _, e in ipairs(g.keys) do if matches(e, words) then shown = shown + 1 end end
  end
  if shown == 0 then return 0 end
  local open = S.open[mod]
  if #words > 0 then open = true end
  local hh = 26
  ImGui.SetCursorScreenPos(ctx, x0, y)
  local clicked = ImGui.InvisibleButton(ctx, '##mod_' .. mod, w, hh)
  local hovered = ImGui.IsItemHovered(ctx)
  ImGui.DrawList_AddRectFilled(dl, x0, y, x0 + w, y + hh, theme.col(hovered and 'hover' or 'panel2'), theme.radius.m)
  ImGui.DrawList_AddText(dl, x0 + 26, y + (hh - ImGui.GetTextLineHeight(ctx)) / 2 - 1, theme.col('text'), module_label(mod))
  local icons = require('ui.icons')
  icons.draw(ImGui, dl, open and 'chevron_down' or 'chevron_right', x0 + 13, y + hh / 2, 12, theme.col('muted'))
  local n = count_overrides(mod, S.scope)
  if n > 0 then
    theme.push_font(ImGui, ctx, 'small')
    local s = string.format(t('set.module.overrides'), n)
    local tw = ImGui.CalcTextSize(ctx, s)
    ImGui.DrawList_AddText(dl, x0 + w - tw - 10, y + (hh - theme.type.small) / 2 - 1, theme.col('accent'), s)
    theme.pop_font(ImGui, ctx)
  end
  if clicked and #words == 0 then S.open[mod] = not S.open[mod]; S.dirty = true end
  local yy = y + hh + 4
  if open then
    for _, g in ipairs(groups) do
      yy = yy + draw_group(g, x0 + 4, yy, w - 8, words)
    end
  end
  return yy - y + 4
end

-- panels ---------------------------------------------------------------------------------------------------------------------------

local function draw_menu()
  local docked = app.is_docked()
  if ImGui.MenuItem(ctx, t('set.menu.expand')) then for _, m in ipairs(schema.MODULES) do S.open[m] = true end; S.dirty = true end
  if ImGui.MenuItem(ctx, t('set.menu.collapse')) then for _, m in ipairs(schema.MODULES) do S.open[m] = false end; S.dirty = true end
  ImGui.Separator(ctx)
  if ImGui.MenuItem(ctx, string.format(t('set.menu.reset_all'), scope_label(S.scope))) then S.confirm_reset = true end
  if ImGui.MenuItem(ctx, t('set.menu.export_effective')) then
    local path, err = P.export('stagehand-effective', 'effective')
    say(path and string.format(t('set.msg.exported'), path) or string.format(t('set.msg.failed'), tostring(err)))
  end
  if ImGui.MenuItem(ctx, t('set.menu.show_folder')) then
    local dir = P.user_dir()
    if reaper.CF_LocateInExplorer then reaper.CF_LocateInExplorer(config.path()) end
    say(string.format(t('set.msg.folder'), dir))
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
  row_text(dl, x0, y0, state.project_name(), 'text', w - right_w - 8, 'bold', h)
  local x = x0 + w - right_w
  ImGui.SetCursorScreenPos(ctx, x, y0 + (h - btn) / 2)
  local docked = app.is_docked()
  if widgets.icon_button(ctx, '##dock', docked and 'undock' or 'dock', { flat = true, muted = true,
      tooltip = docked and t('nav.tip.undock') or t('nav.tip.dock') }) then
    app.toggle_dock()
  end
  x = x + btn + GAP
  ImGui.SetCursorScreenPos(ctx, x, y0 + (h - btn) / 2)
  if widgets.icon_button(ctx, '##menu', 'chevron_down', { flat = true, muted = true, tooltip = t('set.tip.menu') }) then
    ImGui.OpenPopup(ctx, 'setmenu')
  end
  if ImGui.BeginPopup(ctx, 'setmenu') then
    draw_menu()
    ImGui.EndPopup(ctx)
  end
  next_line(x0, y0 + h)
end

local function draw_scope_and_search()
  local x0, y0 = ImGui.GetCursorScreenPos(ctx)
  local w = ImGui.GetContentRegionAvail(ctx)
  local dl = ImGui.GetWindowDrawList(ctx)
  local h = theme.control_h_small
  row_text(dl, x0, y0, t('set.scope'), 'muted', nil, 'small', h)
  local lw = measure(t('set.scope'), 'small') + 6
  ImGui.SetCursorScreenPos(ctx, x0 + lw, y0)
  local np, ng = ov.n.project, ov.n.global
  local options = {
    { 'project', string.format('%s (%d)', t('set.scope.project'), np), t('set.tip.scope_project') },
    { 'global', string.format('%s (%d)', t('set.scope.global'), ng), t('set.tip.scope_global') },
  }
  local chosen = widgets.segmented(ctx, '##scope', options, S.scope)
  if chosen then S.scope = chosen; S.dirty = true; S.errors = {} end
  next_line(x0, y0 + h + GAP)
  local changed, v, _, active = widgets.search_field(ctx, '##search', S.search, t('set.search.hint'))
  if changed then S.search = v end
  S.search_active = active
  if S.focus_search then
    ImGui.SetKeyboardFocusHere(ctx, -1)
    S.focus_search = false
  end
end

local function draw_presets()
  local x0, y0 = ImGui.GetCursorScreenPos(ctx)
  local w = ImGui.GetContentRegionAvail(ctx)
  local dl = ImGui.GetWindowDrawList(ctx)
  local h = theme.control_h_small
  if not S.presets or app.frame - (S.presets_frame or -1000) > 300 then
    S.presets = P.list()
    S.presets_frame = app.frame
  end
  row_text(dl, x0, y0, t('set.presets'), 'muted', nil, 'small', h)
  local lw = measure(t('set.presets'), 'small') + 6
  local bw = 58
  local buttons = 4
  ImGui.SetCursorScreenPos(ctx, x0 + lw, y0)
  ImGui.SetNextItemWidth(ctx, w - lw - buttons * (bw + GAP))
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_FramePadding, 6, 2)
  theme.push_font(ImGui, ctx, 'small')
  local cur = P.find(S.presets, S.preset_name, S.preset_source)
  local label = cur and (cur.name .. (cur.source == 'builtin' and '' or ('  (' .. t('set.preset.user') .. ')'))) or t('set.preset.none')
  if ImGui.BeginCombo(ctx, '##preset', label) then
    for i, p in ipairs(S.presets) do
      local name = p.name .. (p.source == 'builtin' and '' or ('  (' .. t('set.preset.user') .. ')'))
      if p.broken then name = name .. '  !' elseif #p.issues > 0 then name = name .. '  !' end
      if ImGui.Selectable(ctx, name .. '##p' .. i, cur == p) then S.preset_name, S.preset_source = p.name, p.source end
      if p.description ~= '' or p.broken or #p.issues > 0 then
        local tip = p.description or ''
        if p.broken then tip = tip .. '\n' .. t('set.preset.broken') .. ' ' .. tostring(p.broken) end
        for _, it in ipairs(p.issues or {}) do tip = tip .. '\n' .. it.key .. ': ' .. it.reason end
        widgets.tooltip(ctx, tip)
      end
    end
    ImGui.EndCombo(ctx)
  end
  theme.pop_font(ImGui, ctx)
  ImGui.PopStyleVar(ctx)
  if cur then widgets.tooltip(ctx, cur.description ~= '' and cur.description or cur.name) end
  local x = x0 + w - buttons * (bw + GAP) + GAP
  ImGui.SetCursorScreenPos(ctx, x, y0)
  if widgets.button(ctx, '##apply', t('set.preset.apply'), { w = bw, h = h, font = 'small', color = theme.c.accent, disabled = cur == nil or cur.broken ~= nil or #(cur.issues or {}) > 0,
      tooltip = string.format(t('set.tip.apply'), scope_label(S.scope)) }) then
    local keys, err = P.apply(cur, S.scope)
    say(keys and string.format(t('set.msg.applied'), cur.name, #keys, scope_label(S.scope)) or string.format(t('set.msg.failed'), tostring(err)))
  end
  x = x + bw + GAP
  ImGui.SetCursorScreenPos(ctx, x, y0)
  if widgets.button(ctx, '##save', t('set.preset.save'), { w = bw, h = h, font = 'small', tooltip = string.format(t('set.tip.save'), scope_label(S.scope)) }) then
    local ok, name = reaper.GetUserInputs(t('set.preset.save_title'), 1, t('set.preset.save_prompt') .. ',extrawidth=160', '')
    if ok and name ~= '' then
      local path, err = P.save(name, '', S.scope)
      S.presets = nil
      say(path and string.format(t('set.msg.saved'), path) or string.format(t('set.msg.failed'), tostring(err)))
    end
  end
  x = x + bw + GAP
  ImGui.SetCursorScreenPos(ctx, x, y0)
  if widgets.button(ctx, '##import', t('set.preset.import'), { w = bw, h = h, font = 'small', tooltip = t('set.tip.import') }) then
    local p, info = P.import()
    S.presets = nil
    if p then
      S.preset_name, S.preset_source = p.name, 'user'
      say(string.format(t('set.msg.imported'), p.name, #p.issues))
    elseif info ~= 'cancelled' then
      say(string.format(t('set.msg.failed'), tostring(info)))
    end
  end
  x = x + bw + GAP
  ImGui.SetCursorScreenPos(ctx, x, y0)
  if widgets.button(ctx, '##export', t('set.preset.export'), { w = bw, h = h, font = 'small', tooltip = string.format(t('set.tip.export'), scope_label(S.scope)) }) then
    local path, err = P.export('stagehand-' .. S.scope, S.scope)
    S.presets = nil
    if path then say(string.format(t('set.msg.exported'), path)) elseif err ~= 'cancelled' then say(string.format(t('set.msg.failed'), tostring(err))) end
  end
  next_line(x0, y0 + h + GAP)
end

local function draw_problems(x0, y, w)
  local issues = config.issues()
  local notes = config.notes()
  if #issues == 0 and #notes == 0 then return 0 end
  local dl = ImGui.GetWindowDrawList(ctx)
  local rh = 20
  local n_rows = math.min(#issues, 8) + #notes + 1
  local h = n_rows * rh + 8
  ImGui.DrawList_AddRectFilled(dl, x0, y, x0 + w, y + h, theme.col('panel'), theme.radius.m)
  ImGui.DrawList_AddRect(dl, x0 + 0.5, y + 0.5, x0 + w - 0.5, y + h - 0.5, theme.col(#issues > 0 and 'warn' or 'line', 0.7), theme.radius.m, 0, 1)
  local yy = y + 4
  row_text(dl, x0 + 8, yy, #issues > 0 and string.format(t('set.problems.title'), #issues) or t('set.problems.notes'), #issues > 0 and 'warn' or 'muted', w - 16, 'bold', rh)
  yy = yy + rh
  for _, n in ipairs(notes) do
    row_text(dl, x0 + 8, yy, n, 'muted', w - 16, 'small', rh)
    yy = yy + rh
  end
  for i, it in ipairs(issues) do
    if i > 8 then break end
    ImGui.PushID(ctx, 'issue' .. i)
    local line = string.format('[%s] %s = %s: %s', it.scope, it.key, json.encode(it.value), it.reason)
    local bw = it.kind == 'invalid' and 82 or 0
    row_text(dl, x0 + 8, yy, line, it.kind == 'invalid' and 'text' or 'muted', w - 16 - bw - 60, 'small', rh)
    ImGui.SetCursorScreenPos(ctx, x0 + 8, yy)
    ImGui.Dummy(ctx, w - 16 - bw - 60, rh)
    widgets.tooltip(ctx, line)
    ImGui.SetCursorScreenPos(ctx, x0 + w - 8 - bw - 54, yy + 1)
    if widgets.button(ctx, '##show', t('set.problems.show'), { w = 50, h = rh - 2, font = 'small', tooltip = t('set.problems.show_tip') }) then
      S.search = it.key
    end
    if it.kind == 'invalid' then
      ImGui.SetCursorScreenPos(ctx, x0 + w - 8 - bw, yy + 1)
      if widgets.button(ctx, '##drop', t('set.problems.drop'), { w = bw, h = rh - 2, font = 'small', color = theme.c.warn, tooltip = t('set.problems.drop_tip') }) then
        config.drop_issue(it)
        say(string.format(t('set.msg.dropped'), it.key))
      end
    end
    ImGui.PopID(ctx)
    yy = yy + rh
  end
  return h + GAP
end

local function draw_body()
  local footer_h = S.compact and theme.space[1] or (theme.type.small + theme.space[3])
  local visible = ImGui.BeginChild(ctx, 'settings_body', 0, -footer_h, ImGui.ChildFlags_None, ImGui.WindowFlags_None)
  if visible then
    local x0, y0 = ImGui.GetCursorScreenPos(ctx)
    local w = ImGui.GetContentRegionAvail(ctx)
    local wx, wy = ImGui.GetWindowPos(ctx)
    local _, wh = ImGui.GetWindowSize(ctx)
    S.clip_y0, S.clip_y1 = wy - ROW_H, wy + wh + ROW_H
    local words = search_words()
    S.visible_rows = 0
    local y = y0
    y = y + draw_problems(x0, y, w)
    for _, mod in ipairs(schema.MODULES) do
      y = y + draw_module(mod, x0, y, w, words)
    end
    if S.visible_rows == 0 and #words > 0 then
      row_text(ImGui.GetWindowDrawList(ctx), x0 + 8, y, t('set.search.none'), 'muted', w - 16, 'body', ROW_H)
      y = y + ROW_H
    end
    next_line(x0, y + theme.space[2])
  end
  ImGui.EndChild(ctx)
end

local function draw_footer()
  if S.compact then return end
  local msg = S.msg_frames > 0 and S.msg or nil
  widgets.status(ctx, msg, string.format(t('set.hint'), config.path()), msg ~= nil)
end

-- the JSON editor for list-typed keys (pins.rows, glow.profiles) ------------------------------------------------------------

local function draw_json_popup()
  if S.json_request then
    ImGui.OpenPopup(ctx, 'jsonedit')
    S.json_request = false
  end
  if not S.json then return end
  local entry = schema.entry(S.json.key)
  ImGui.SetNextWindowSize(ctx, 560, 420, ImGui.Cond_Appearing)
  local visible, open = ImGui.BeginPopupModal(ctx, label_of(entry) .. '###jsonedit', true, ImGui.WindowFlags_NoCollapse)
  if visible then
    ImGui.TextColored(ctx, theme.col('muted'), t('set.json.help'))
    local meaning = meaning_of(entry)
    if meaning then
      ImGui.PushTextWrapPos(ctx, 0)
      ImGui.TextColored(ctx, theme.col('muted'), meaning)
      ImGui.PopTextWrapPos(ctx)
    end
    theme.push_font(ImGui, ctx, 'mono')
    local rv, s = ImGui.InputTextMultiline(ctx, '##json', S.json.text, -1, -64)
    theme.pop_font(ImGui, ctx)
    if rv then
      S.json.text = s
      S.json.err = nil
    end
    local parsed, perr = json.decode(S.json.text)
    local ok, why
    if type(parsed) ~= 'table' then
      ok, why = false, t('set.json.not_json') .. ' ' .. tostring(perr)
    else
      ok, why = schema.check(entry, parsed)
    end
    ImGui.TextColored(ctx, theme.col(ok and 'ok' or 'danger'), ok and string.format(t('set.json.valid'), #parsed) or tostring(why))
    if not ok then ImGui.BeginDisabled(ctx) end
    if ImGui.Button(ctx, t('set.json.apply'), 110, 0) then
      write(entry, parsed)
      S.json = nil
      ImGui.CloseCurrentPopup(ctx)
    end
    if not ok then ImGui.EndDisabled(ctx) end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, t('ed.cancel'), 110, 0) then
      S.json = nil
      ImGui.CloseCurrentPopup(ctx)
    end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, t('ed.reset'), 160, 0) then
      S.json.text = json.encode(config.default(entry.key) or {}, { pretty = true })
    end
    ImGui.EndPopup(ctx)
  end
  if open == false then S.json = nil end
end

local function draw_confirm_reset()
  if S.confirm_reset then
    ImGui.OpenPopup(ctx, 'confirmreset')
    S.confirm_reset = false
  end
  local visible = ImGui.BeginPopupModal(ctx, t('set.reset_all.title') .. '###confirmreset', nil, ImGui.WindowFlags_AlwaysAutoResize | ImGui.WindowFlags_NoCollapse)
  if visible then
    local n = #config.overrides(S.scope)
    ImGui.Text(ctx, string.format(t('set.reset_all.body'), n, scope_label(S.scope)))
    if ImGui.Button(ctx, t('set.reset_all.yes'), 120, 0) then
      config.reset_prefix('', S.scope)
      S.errors = {}
      say(string.format(t('set.msg.all_reset'), n, scope_label(S.scope)))
      ImGui.CloseCurrentPopup(ctx)
    end
    ImGui.SameLine(ctx)
    if ImGui.Button(ctx, t('ed.cancel'), 120, 0) then ImGui.CloseCurrentPopup(ctx) end
    ImGui.EndPopup(ctx)
  end
end

local function handle_keys()
  if not app.focused then return end
  local function chord(key) return ImGui.IsKeyChordPressed(ctx, ImGui.Mod_Ctrl | key) end
  if chord(ImGui.Key_D) then app.toggle_dock() end
  if chord(ImGui.Key_F) then S.focus_search = true end
  if ImGui.IsKeyPressed(ctx, ImGui.Key_Escape, false) and S.search ~= '' and not ImGui.IsPopupOpen(ctx, '', ImGui.PopupFlags_AnyPopupId) then S.search = '' end
end

function U.draw(app_)
  app = app_
  ctx = app.ctx
  S.compact = app.win_h < (config.get('ui.compact_below_px') or theme.compact_below)
  if S.msg_frames > 0 then S.msg_frames = S.msg_frames - 1 end
  refresh_overrides()
  -- sliders and colour pickers preview every frame; the file is written once nothing is being dragged
  if not ImGui.IsAnyItemActive(ctx) and not ImGui.IsPopupOpen(ctx, '', ImGui.PopupFlags_AnyPopupId) then
    config.commit('project')
    config.commit('global')
  end
  draw_header()
  draw_scope_and_search()
  if not S.compact then draw_presets() end
  draw_body()
  draw_footer()
  draw_json_popup()
  draw_confirm_reset()
  handle_keys()
end

U.say = say
U.label_of, U.tip_of = label_of, tip_of
return U
