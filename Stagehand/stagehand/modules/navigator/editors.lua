-- modules/navigator/editors.lua - the three small editors behind the navigator menu: family chips, marker
-- classes and groups. Each edits a copy of the config list and saves it to the global file or to this project
-- (config.lua). The full Settings window with search and presets arrives in M4. Lua 5.4; no globals.

local theme = require('ui.theme')
local widgets = require('ui.widgets')
local config = require('config')
local match = require('lib.match')
local text = require('lib.text')
local view = require('lib.view')
local i18n = require('i18n')

local t = i18n.t

local E = { request = nil, open = nil, draft = nil, scope = 'global' }

local ImGui, D, S, A

local KINDS = {
  families = { key = 'navigator.families', title = 'ed.families.title' },
  classes = { key = 'navigator.marker_classes', title = 'ed.classes.title' },
  groups = { key = 'navigator.groups', title = 'ed.groups.title' },
}
local ORDER = { 'families', 'classes', 'groups' }
local ON_OPTIONS = { { 'top', 'ed.on.top' }, { 'own', 'ed.on.own' }, { 'any', 'ed.on.any' } }
local KEY_OPTIONS = { '', '1', '2', '3', '4', '5', '6', '7', '8', '9', '0' }

local function deep_copy(v)
  if type(v) ~= 'table' then return v end
  local out = {}
  for k, x in pairs(v) do out[k] = deep_copy(x) end
  return out
end

function E.init(app, D_, S_, A_)
  ImGui = app.ImGui
  D, S, A = D_, S_, A_
end

function E.request_open(kind)
  E.request = kind
end

local function popup_id(kind)
  return t(KINDS[kind].title) .. '###ed_' .. kind
end

function E.handle_requests(ctx)
  if not E.request then return end
  local kind = E.request
  E.request = nil
  local def = KINDS[kind]
  E.open = kind
  E.draft = deep_copy(config.get(def.key) or {})
  E.scope = config.has_override(def.key, 'project') and 'project' or 'global'
  ImGui.OpenPopup(ctx, popup_id(kind))
end

local function color_edit(ctx, id, hex)
  local rgb = theme.parse_hex(hex) or 0x9AA3B5
  local rv, col = ImGui.ColorEdit3(ctx, id, rgb, ImGui.ColorEditFlags_NoInputs | ImGui.ColorEditFlags_NoLabel)
  if rv then return theme.hex(col) end
  return hex
end

local function remove_button(ctx, i)
  local clicked = widgets.icon_button(ctx, '##rm', 'clear', { w = 20, h = 20, flat = true, muted = true, tooltip = t('ed.remove') })
  return clicked and i or nil
end

local function draw_families(ctx)
  local flags = ImGui.TableFlags_SizingStretchProp | ImGui.TableFlags_BordersInnerH | ImGui.TableFlags_RowBg
  local remove
  if ImGui.BeginTable(ctx, 'fams', 5, flags) then
    ImGui.TableSetupColumn(ctx, t('ed.col.name'), ImGui.TableColumnFlags_WidthStretch, 1.1)
    ImGui.TableSetupColumn(ctx, t('ed.col.color'), ImGui.TableColumnFlags_WidthFixed, 44)
    ImGui.TableSetupColumn(ctx, t('ed.col.rule'), ImGui.TableColumnFlags_WidthStretch, 2.2)
    ImGui.TableSetupColumn(ctx, t('ed.col.on'), ImGui.TableColumnFlags_WidthFixed, 160)
    ImGui.TableSetupColumn(ctx, '', ImGui.TableColumnFlags_WidthFixed, 26)
    ImGui.TableHeadersRow(ctx)
    for i, f in ipairs(E.draft) do
      ImGui.PushID(ctx, i)
      ImGui.TableNextRow(ctx)
      ImGui.TableNextColumn(ctx)
      ImGui.SetNextItemWidth(ctx, -1)
      local _, name = ImGui.InputText(ctx, '##name', tostring(f.name or ''))
      f.name = name
      ImGui.TableNextColumn(ctx)
      f.color = color_edit(ctx, '##col', f.color)
      ImGui.TableNextColumn(ctx)
      ImGui.SetNextItemWidth(ctx, -1)
      local _, rule = ImGui.InputText(ctx, '##rule', tostring(f.rule or ''))
      f.rule = rule
      widgets.tooltip(ctx, match.describe(f.rule))
      ImGui.TableNextColumn(ctx)
      ImGui.SetNextItemWidth(ctx, -1)
      local cur = f.on or 'top'
      local cur_label = cur
      for _, o in ipairs(ON_OPTIONS) do if o[1] == cur then cur_label = t(o[2]) end end
      if ImGui.BeginCombo(ctx, '##on', cur_label) then
        for _, o in ipairs(ON_OPTIONS) do
          if ImGui.Selectable(ctx, t(o[2]), o[1] == cur) then f.on = o[1] end
        end
        ImGui.EndCombo(ctx)
      end
      ImGui.TableNextColumn(ctx)
      remove = remove_button(ctx, i) or remove
      ImGui.PopID(ctx)
    end
    ImGui.EndTable(ctx)
  end
  if remove then table.remove(E.draft, remove) end
  if ImGui.Button(ctx, t('ed.add')) then
    local n = #E.draft
    E.draft[n + 1] = { name = t('ed.new_family'), color = theme.hex(theme.family_palette[n % #theme.family_palette + 1]), rule = '', on = 'top' }
  end
  ImGui.PushTextWrapPos(ctx, 0)
  ImGui.TextColored(ctx, theme.col('muted'), t('ed.rule_help'))
  ImGui.TextColored(ctx, theme.col('muted'), t('ed.other'))
  ImGui.PopTextWrapPos(ctx)
end

local function draw_classes(ctx)
  local flags = ImGui.TableFlags_SizingStretchProp | ImGui.TableFlags_BordersInnerH | ImGui.TableFlags_RowBg
  local remove
  if ImGui.BeginTable(ctx, 'classes', 4, flags) then
    ImGui.TableSetupColumn(ctx, t('ed.col.name'), ImGui.TableColumnFlags_WidthStretch, 1)
    ImGui.TableSetupColumn(ctx, t('ed.col.color'), ImGui.TableColumnFlags_WidthFixed, 44)
    ImGui.TableSetupColumn(ctx, t('ed.col.rule'), ImGui.TableColumnFlags_WidthStretch, 2.4)
    ImGui.TableSetupColumn(ctx, '', ImGui.TableColumnFlags_WidthFixed, 26)
    ImGui.TableHeadersRow(ctx)
    for i, c in ipairs(E.draft) do
      ImGui.PushID(ctx, i)
      ImGui.TableNextRow(ctx)
      ImGui.TableNextColumn(ctx)
      ImGui.SetNextItemWidth(ctx, -1)
      local _, name = ImGui.InputText(ctx, '##name', tostring(c.name or ''))
      c.name = name
      ImGui.TableNextColumn(ctx)
      c.color = color_edit(ctx, '##col', c.color)
      ImGui.TableNextColumn(ctx)
      ImGui.SetNextItemWidth(ctx, -1)
      local _, rule = ImGui.InputText(ctx, '##rule', tostring(c.rule or ''))
      c.rule = rule
      widgets.tooltip(ctx, match.describe(c.rule))
      ImGui.TableNextColumn(ctx)
      remove = remove_button(ctx, i) or remove
      ImGui.PopID(ctx)
    end
    ImGui.EndTable(ctx)
  end
  if remove then table.remove(E.draft, remove) end
  if ImGui.Button(ctx, t('ed.add')) then
    local n = #E.draft
    E.draft[n + 1] = { name = t('ed.new_class'), color = theme.hex(theme.family_palette[n % #theme.family_palette + 1]), rule = '' }
  end
  ImGui.PushTextWrapPos(ctx, 0)
  ImGui.TextColored(ctx, theme.col('muted'), t('ed.rule_help'))
  ImGui.TextColored(ctx, theme.col('muted'), t('ed.classes.help'))
  ImGui.PopTextWrapPos(ctx)
end

local function draw_groups(ctx)
  local flags = ImGui.TableFlags_SizingStretchProp | ImGui.TableFlags_BordersInnerH | ImGui.TableFlags_RowBg
  local remove
  if ImGui.BeginTable(ctx, 'groups', 6, flags) then
    ImGui.TableSetupColumn(ctx, t('ed.col.name'), ImGui.TableColumnFlags_WidthStretch, 1.4)
    ImGui.TableSetupColumn(ctx, t('ed.col.key'), ImGui.TableColumnFlags_WidthFixed, 56)
    ImGui.TableSetupColumn(ctx, t('ed.col.start'), ImGui.TableColumnFlags_WidthFixed, 96)
    ImGui.TableSetupColumn(ctx, t('ed.col.end'), ImGui.TableColumnFlags_WidthFixed, 96)
    ImGui.TableSetupColumn(ctx, '', ImGui.TableColumnFlags_WidthFixed, 130)
    ImGui.TableSetupColumn(ctx, '', ImGui.TableColumnFlags_WidthFixed, 26)
    ImGui.TableHeadersRow(ctx)
    for i, g in ipairs(E.draft) do
      ImGui.PushID(ctx, i)
      ImGui.TableNextRow(ctx)
      ImGui.TableNextColumn(ctx)
      ImGui.SetNextItemWidth(ctx, -1)
      local _, name = ImGui.InputText(ctx, '##name', tostring(g.name or ''))
      g.name = name
      ImGui.TableNextColumn(ctx)
      ImGui.SetNextItemWidth(ctx, -1)
      local cur = tostring(g.key or '')
      if ImGui.BeginCombo(ctx, '##key', cur == '' and '-' or cur) then
        for _, k in ipairs(KEY_OPTIONS) do
          if ImGui.Selectable(ctx, k == '' and '-' or k, k == cur) then g.key = k end
        end
        ImGui.EndCombo(ctx)
      end
      ImGui.TableNextColumn(ctx)
      ImGui.SetNextItemWidth(ctx, -1)
      local _, t0 = ImGui.InputDouble(ctx, '##t0', tonumber(g.t0) or 0, 0, 0, '%.3f')
      g.t0 = t0
      ImGui.TableNextColumn(ctx)
      ImGui.SetNextItemWidth(ctx, -1)
      local _, t1 = ImGui.InputDouble(ctx, '##t1', tonumber(g.t1) or 0, 0, 0, '%.3f')
      g.t1 = t1
      ImGui.TableNextColumn(ctx)
      if ImGui.SmallButton(ctx, t('ed.groups.from_sel')) then
        local a, b = view.get_time_selection()
        if b > a then g.t0, g.t1 = a, b end
      end
      ImGui.SameLine(ctx)
      if ImGui.SmallButton(ctx, t('ed.groups.from_scene')) then
        local s = D.active_scene()
        if s then g.t0, g.t1 = s.t0, s.t1; if g.name == '' or g.name == t('ed.new_group') then g.name = s.name end end
      end
      ImGui.TableNextColumn(ctx)
      remove = remove_button(ctx, i) or remove
      ImGui.PopID(ctx)
    end
    ImGui.EndTable(ctx)
  end
  if remove then table.remove(E.draft, remove) end
  if ImGui.Button(ctx, t('ed.add')) then
    local n = #E.draft
    local key = KEY_OPTIONS[math.min(n + 2, #KEY_OPTIONS)]
    local a, b = view.get_time_selection()
    if b <= a then a, b = 0, reaper.GetProjectLength(0) end
    E.draft[n + 1] = { name = t('ed.new_group'), key = key, t0 = a, t1 = b }
  end
  ImGui.PushTextWrapPos(ctx, 0)
  ImGui.TextColored(ctx, theme.col('muted'), t('ed.groups.help'))
  ImGui.PopTextWrapPos(ctx)
end

local function sanitize(kind)
  for i = #E.draft, 1, -1 do
    local e = E.draft[i]
    e.name = text.trim(e.name or '')
    if e.name == '' then table.remove(E.draft, i) end
    if kind == 'groups' then
      e.t0, e.t1 = tonumber(e.t0) or 0, tonumber(e.t1) or 0
      if e.t1 < e.t0 then e.t0, e.t1 = e.t1, e.t0 end
      if e.key == '' then e.key = nil end
    end
  end
end

local function save(ctx, kind)
  local def = KINDS[kind]
  sanitize(kind)
  config.set(def.key, E.draft, E.scope)
  if E.scope == 'global' and config.has_override(def.key, 'project') then config.reset(def.key, 'project') end
  D.refresh()
  D.invalidate_items()
  E.open = nil
  ImGui.CloseCurrentPopup(ctx)
end

local function draw_footer(ctx, kind)
  ImGui.Separator(ctx)
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, t('ed.scope'))
  ImGui.SameLine(ctx)
  ImGui.SetNextItemWidth(ctx, 200)
  local label = E.scope == 'project' and t('ed.scope.project') or t('ed.scope.global')
  if ImGui.BeginCombo(ctx, '##scope', label) then
    if ImGui.Selectable(ctx, t('ed.scope.global'), E.scope == 'global') then E.scope = 'global' end
    if ImGui.Selectable(ctx, t('ed.scope.project'), E.scope == 'project') then E.scope = 'project' end
    ImGui.EndCombo(ctx)
  end
  ImGui.SameLine(ctx, 0, theme.space[4])
  if ImGui.Button(ctx, t('ed.save'), 100, 0) then save(ctx, kind) end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, t('ed.cancel'), 100, 0) then
    E.open = nil
    ImGui.CloseCurrentPopup(ctx)
  end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, t('ed.reset'), 150, 0) then E.draft = config.default(KINDS[kind].key) or {} end
end

function E.draw(ctx)
  for _, kind in ipairs(ORDER) do
    ImGui.SetNextWindowSize(ctx, 680, 0, ImGui.Cond_Appearing)
    local visible, open = ImGui.BeginPopupModal(ctx, popup_id(kind), true, ImGui.WindowFlags_AlwaysAutoResize | ImGui.WindowFlags_NoCollapse)
    if visible then
      if E.draft then
        if kind == 'families' then draw_families(ctx)
        elseif kind == 'classes' then draw_classes(ctx)
        else draw_groups(ctx) end
        draw_footer(ctx, kind)
      end
      ImGui.EndPopup(ctx)
    end
    if open == false then E.open = nil end
  end
end

return E
