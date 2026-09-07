-- modules/director/editor.lua - the shot editor and the pinned-rows editor (modal popups over the Director tab).
--
-- The shot editor edits a copy (draft) of one shot: name, range (typed, from the cursor, the time selection or
-- the scene under the cursor), captions, lane rules with live "resolves to N tracks" counts, envelope rules,
-- per-shot overrides. Save writes the sanitized shot into the model (project state); Cancel drops the draft.
-- The pins editor edits director.pins.rows (rule + height) for this project or globally. Lua 5.4; no globals.

local theme = require('ui.theme')
local widgets = require('ui.widgets')
local config = require('config')
local json = require('lib.json')
local match = require('lib.match')
local text = require('lib.text')
local view = require('lib.view')
local regions = require('lib.regions')
local tracks = require('lib.tracks')
local i18n = require('i18n')

local t = i18n.t

local ED = { request = nil, open = nil, draft = nil, k = nil, counts = nil, sig = nil, env_counts = nil,
  pins = nil, pins_scope = 'project', pins_counts = nil, pins_sig = nil }

local ImGui, app, E, MD, R, S

local KIND_LABELS = { items = 'ed.lane.items', family = 'ed.lane.family', rule = 'ed.lane.rule', track = 'ed.lane.track' }
local VIEW_OPTIONS = { { nil, 'ed.override.default' }, { 'page', 'dir.view.page' }, { 'follow', 'dir.view.follow' } }
local PARENT_OPTIONS = { { nil, 'ed.override.default' }, { 'none', 'dir.parents.none' }, { 'bus', 'dir.parents.bus' }, { 'all', 'dir.parents.all' } }

function ED.init(app_, E_, MD_, R_, S_)
  app, E, MD, R, S = app_, E_, MD_, R_, S_
  ImGui = app.ImGui
end

-- kind = 'shot' (k = index, nil = new shot; template = fields for a new one) | 'pins'
function ED.request_open(kind, k, template)
  ED.request = { kind = kind, k = k, template = template }
end

local SHOT_ID = '###shot_editor'
local PINS_ID = '###pins_editor'

local function scope_key()
  return config.get('director.persist.scope') or 'project'
end

function ED.handle_requests(ctx)
  if not ED.request then return end
  local req = ED.request
  ED.request = nil
  if req.kind == 'shot' then
    ED.k = req.k
    if req.k and MD.shots[req.k] then
      ED.draft = MD.copy(MD.shots[req.k])
    else
      local tpl = req.template or {}
      if not tpl.t0 then
        local a, b = view.get_time_selection()
        if b > a then tpl.t0, tpl.t1 = a, b
        else
          local c = view.cursor()
          tpl.t0, tpl.t1 = c, c + 10
        end
      end
      ED.draft = MD.new_shot(tpl)
    end
    ED.sig = nil
    ED.open = 'shot'
    ImGui.OpenPopup(ctx, t('ed.shot.title') .. SHOT_ID)
  elseif req.kind == 'pins' then
    ED.pins = MD.copy(config.get('director.pins.rows') or {})
    ED.pins_scope = config.has_override('director.pins.rows', 'project') and 'project' or 'global'
    ED.pins_sig = nil
    ED.open = 'pins'
    ImGui.OpenPopup(ctx, t('ed.pins.title') .. PINS_ID)
  end
end

local function remove_button(ctx)
  return widgets.icon_button(ctx, '##rm', 'clear', { w = 20, h = 20, flat = true, muted = true, tooltip = t('ed.remove') })
end

local function refresh_counts()
  local d = ED.draft
  local sig = json.encode(d.lanes) .. json.encode(d.envelopes) .. tostring(d.t0) .. tostring(d.t1) .. tostring(E.state_count)
  if sig == ED.sig then return end
  ED.sig = sig
  local _, counts = R.lanes(d, E.tracks)
  ED.counts = counts
  local _, _, env_counts = R.envelopes(d, E.tracks)
  ED.env_counts = env_counts
end

local function family_combo(ctx, id, current, allow_any)
  local label = current or (allow_any and t('ed.lane.any_family') or '-')
  local chosen
  if ImGui.BeginCombo(ctx, id, label) then
    if allow_any and ImGui.Selectable(ctx, t('ed.lane.any_family'), current == nil) then chosen = false end
    for _, f in ipairs(E.fams and E.fams.all or {}) do
      if ImGui.Selectable(ctx, f.name, f.name == current) then chosen = f.name end
    end
    ImGui.EndCombo(ctx)
  end
  return chosen
end

local function track_combo(ctx, id, lane)
  local label = lane.name ~= '' and lane.name or t('ed.lane.pick_track')
  local chosen
  if ImGui.BeginCombo(ctx, id, label) then
    for _, e in ipairs(E.tracks) do
      local pad = string.rep('  ', e.depth)
      if ImGui.Selectable(ctx, pad .. e.name .. '##' .. e.guid, e.guid == lane.guid) then chosen = e end
    end
    ImGui.EndCombo(ctx)
  end
  return chosen
end

local function draw_lanes(ctx)
  local d = ED.draft
  widgets.label(ctx, t('ed.shot.lanes'), 'muted', 'small')
  local flags = ImGui.TableFlags_SizingStretchProp | ImGui.TableFlags_BordersInnerH | ImGui.TableFlags_RowBg
  local remove
  if ImGui.BeginTable(ctx, 'lanes', 4, flags) then
    ImGui.TableSetupColumn(ctx, t('ed.col.kind'), ImGui.TableColumnFlags_WidthFixed, 150)
    ImGui.TableSetupColumn(ctx, t('ed.col.what'), ImGui.TableColumnFlags_WidthStretch, 1)
    ImGui.TableSetupColumn(ctx, t('ed.col.tracks'), ImGui.TableColumnFlags_WidthFixed, 64)
    ImGui.TableSetupColumn(ctx, '', ImGui.TableColumnFlags_WidthFixed, 26)
    ImGui.TableHeadersRow(ctx)
    for i, l in ipairs(d.lanes) do
      ImGui.PushID(ctx, i)
      ImGui.TableNextRow(ctx)
      ImGui.TableNextColumn(ctx)
      ImGui.SetNextItemWidth(ctx, -1)
      if ImGui.BeginCombo(ctx, '##kind', t(KIND_LABELS[l.kind] or 'ed.lane.rule')) then
        for _, kind in ipairs(MD.KINDS) do
          if ImGui.Selectable(ctx, t(KIND_LABELS[kind]), kind == l.kind) and kind ~= l.kind then
            for key in pairs(l) do l[key] = nil end
            l.kind = kind
            if kind == 'rule' then l.rule = '' elseif kind == 'track' then l.name = '' end
          end
        end
        ImGui.EndCombo(ctx)
      end
      ImGui.TableNextColumn(ctx)
      ImGui.SetNextItemWidth(ctx, -1)
      if l.kind == 'items' then
        local c = family_combo(ctx, '##fam', l.family, true)
        if c == false then l.family = nil elseif c then l.family = c end
      elseif l.kind == 'family' then
        local c = family_combo(ctx, '##fam', l.name, false)
        if c then l.name = c end
      elseif l.kind == 'rule' then
        local _, rule = ImGui.InputText(ctx, '##rule', tostring(l.rule or ''))
        l.rule = rule
        widgets.tooltip(ctx, match.describe(l.rule))
      else
        local e = track_combo(ctx, '##track', l)
        if e then l.guid, l.name = e.guid, e.name end
      end
      ImGui.TableNextColumn(ctx)
      local n = ED.counts and ED.counts[i] or 0
      widgets.label(ctx, tostring(n), n > 0 and 'text' or 'danger', 'mono')
      ImGui.TableNextColumn(ctx)
      if remove_button(ctx) then remove = i end
      ImGui.PopID(ctx)
    end
    ImGui.EndTable(ctx)
  end
  if remove then table.remove(d.lanes, remove) end
  if ImGui.Button(ctx, t('ed.add_lane')) then d.lanes[#d.lanes + 1] = { kind = 'rule', rule = '' } end
  ImGui.SameLine(ctx)
  widgets.label(ctx, t('ed.lane.help'), 'muted', 'small')
end

local function draw_envelopes(ctx)
  local d = ED.draft
  widgets.label(ctx, t('ed.shot.envelopes'), 'muted', 'small')
  local flags = ImGui.TableFlags_SizingStretchProp | ImGui.TableFlags_BordersInnerH | ImGui.TableFlags_RowBg
  local remove
  if #d.envelopes > 0 and ImGui.BeginTable(ctx, 'envs', 4, flags) then
    ImGui.TableSetupColumn(ctx, t('ed.col.track_rule'), ImGui.TableColumnFlags_WidthStretch, 1)
    ImGui.TableSetupColumn(ctx, t('ed.col.env_rule'), ImGui.TableColumnFlags_WidthStretch, 1)
    ImGui.TableSetupColumn(ctx, t('ed.col.matches'), ImGui.TableColumnFlags_WidthFixed, 64)
    ImGui.TableSetupColumn(ctx, '', ImGui.TableColumnFlags_WidthFixed, 26)
    ImGui.TableHeadersRow(ctx)
    for i, r in ipairs(d.envelopes) do
      ImGui.PushID(ctx, 100 + i)
      ImGui.TableNextRow(ctx)
      ImGui.TableNextColumn(ctx)
      ImGui.SetNextItemWidth(ctx, -1)
      local _, tr = ImGui.InputText(ctx, '##tr', tostring(r.track or ''))
      r.track = tr
      widgets.tooltip(ctx, match.describe(r.track))
      ImGui.TableNextColumn(ctx)
      ImGui.SetNextItemWidth(ctx, -1)
      local _, en = ImGui.InputText(ctx, '##en', tostring(r.env or ''))
      r.env = en
      widgets.tooltip(ctx, match.describe(r.env))
      ImGui.TableNextColumn(ctx)
      local n = ED.env_counts and ED.env_counts[i] or 0
      widgets.label(ctx, tostring(n), n > 0 and 'text' or 'warn', 'mono')
      ImGui.TableNextColumn(ctx)
      if remove_button(ctx) then remove = i end
      ImGui.PopID(ctx)
    end
    ImGui.EndTable(ctx)
  end
  if remove then table.remove(d.envelopes, remove) end
  if ImGui.Button(ctx, t('ed.add_env')) then d.envelopes[#d.envelopes + 1] = { track = '', env = 'Volume' } end
  ImGui.SameLine(ctx)
  widgets.label(ctx, t('ed.env.help'), 'muted', 'small')
end

local function draw_range(ctx)
  local d = ED.draft
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, t('ed.col.start'))
  ImGui.SameLine(ctx)
  ImGui.SetNextItemWidth(ctx, 110)
  local _, t0 = ImGui.InputDouble(ctx, '##t0', d.t0, 0, 0, '%.3f')
  d.t0 = t0
  ImGui.SameLine(ctx)
  if ImGui.SmallButton(ctx, t('ed.from_cursor') .. '##c0') then d.t0 = view.cursor() end
  ImGui.SameLine(ctx, 0, theme.space[4])
  ImGui.Text(ctx, t('ed.col.end'))
  ImGui.SameLine(ctx)
  ImGui.SetNextItemWidth(ctx, 110)
  local _, t1 = ImGui.InputDouble(ctx, '##t1', d.t1, 0, 0, '%.3f')
  d.t1 = t1
  ImGui.SameLine(ctx)
  if ImGui.SmallButton(ctx, t('ed.from_cursor') .. '##c1') then d.t1 = view.cursor() end
  ImGui.SameLine(ctx, 0, theme.space[4])
  if ImGui.SmallButton(ctx, t('ed.groups.from_sel')) then
    local a, b = view.get_time_selection()
    if b > a then d.t0, d.t1 = a, b end
  end
  ImGui.SameLine(ctx)
  if ImGui.SmallButton(ctx, t('ed.from_scene')) then
    local scenes = regions.scan(nil, 5)
    local sc = regions.scene_at(scenes, view.cursor())
    if sc then
      d.t0, d.t1 = sc.t0, sc.t1
      if d.name == '' then d.name = sc.name end
      if d.caption == '' then d.caption = sc.name end
    end
  end
  ImGui.SameLine(ctx)
  widgets.label(ctx, string.format('%s - %s  (%.2f s)', text.fmt_time(d.t0), text.fmt_time(d.t1), d.t1 - d.t0), 'muted', 'mono')
end

local function draw_overrides(ctx)
  local d = ED.draft
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, t('ed.override.view'))
  ImGui.SameLine(ctx)
  ImGui.SetNextItemWidth(ctx, 130)
  local cur = d.view
  local label = t('ed.override.default')
  for _, o in ipairs(VIEW_OPTIONS) do if o[1] == cur and o[1] then label = t(o[2]) end end
  if ImGui.BeginCombo(ctx, '##view', label) then
    for _, o in ipairs(VIEW_OPTIONS) do
      if ImGui.Selectable(ctx, t(o[2]), o[1] == cur) then d.view = o[1] end
    end
    ImGui.EndCombo(ctx)
  end
  ImGui.SameLine(ctx, 0, theme.space[4])
  ImGui.Text(ctx, t('ed.override.parents'))
  ImGui.SameLine(ctx)
  ImGui.SetNextItemWidth(ctx, 130)
  local pcur = d.parents
  local plabel = t('ed.override.default')
  for _, o in ipairs(PARENT_OPTIONS) do if o[1] == pcur and o[1] then plabel = t(o[2]) end end
  if ImGui.BeginCombo(ctx, '##parents', plabel) then
    for _, o in ipairs(PARENT_OPTIONS) do
      if ImGui.Selectable(ctx, t(o[2]), o[1] == pcur) then d.parents = o[1] end
    end
    ImGui.EndCombo(ctx)
  end
  widgets.tooltip(ctx, t('ed.override.help'))
end

local function save_shot(ctx)
  local s = MD.sanitize(ED.draft)
  local k
  if ED.k and MD.shots[ED.k] then k = MD.replace(ED.k, s) else k = MD.add(s) end
  S.hi = k or 0
  S.validate_request = true
  if E.active and E.k == ED.k then E.reapply() end
  ED.open, ED.draft = nil, nil
  ImGui.CloseCurrentPopup(ctx)
end

local function draw_shot_editor(ctx)
  local d = ED.draft
  refresh_counts()
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, t('ed.col.name'))
  ImGui.SameLine(ctx)
  ImGui.SetNextItemWidth(ctx, -1)
  local _, name = ImGui.InputText(ctx, '##name', d.name)
  d.name = name
  draw_range(ctx)
  ImGui.Spacing(ctx)
  local max_chars = tonumber(config.get('director.validate.caption_max_chars')) or 135
  widgets.label(ctx, string.format('%s  (%d / %d)', t('ed.shot.caption'), #d.caption, max_chars), #d.caption > max_chars and 'warn' or 'muted', 'small')
  local _, cap = ImGui.InputTextMultiline(ctx, '##caption', d.caption, -1, 44)
  d.caption = cap
  widgets.label(ctx, string.format('%s  (%d / %d)', t('ed.shot.caption2'), #d.caption2, max_chars), #d.caption2 > max_chars and 'warn' or 'muted', 'small')
  local _, cap2 = ImGui.InputTextMultiline(ctx, '##caption2', d.caption2, -1, 32)
  d.caption2 = cap2
  ImGui.Spacing(ctx)
  draw_lanes(ctx)
  ImGui.Spacing(ctx)
  draw_envelopes(ctx)
  ImGui.Spacing(ctx)
  draw_overrides(ctx)
  ImGui.Separator(ctx)
  if ImGui.Button(ctx, t('ed.save'), 110, 0) then save_shot(ctx) end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, t('ed.cancel'), 110, 0) then
    ED.open, ED.draft = nil, nil
    ImGui.CloseCurrentPopup(ctx)
  end
  if ED.k and MD.shots[ED.k] then
    ImGui.SameLine(ctx, 0, theme.space[5])
    if ImGui.Button(ctx, t('ed.delete_shot'), 130, 0) then
      MD.remove(ED.k)
      S.validate_request = true
      if E.active then E.stop('shot removed') end
      ED.open, ED.draft = nil, nil
      ImGui.CloseCurrentPopup(ctx)
    end
  end
end

-- pinned rows ----------------------------------------------------------------------------------------------------

local function refresh_pin_counts()
  local sig = json.encode(ED.pins) .. tostring(E.state_count)
  if sig == ED.pins_sig then return end
  ED.pins_sig = sig
  ED.pins_counts = {}
  for i, p in ipairs(ED.pins) do
    local test = match.compile(p.rule)
    local n = 0
    for _, e in ipairs(E.tracks) do if test(e.name) then n = n + 1 end end
    ED.pins_counts[i] = n
  end
end

local function draw_pins_editor(ctx)
  refresh_pin_counts()
  local flags = ImGui.TableFlags_SizingStretchProp | ImGui.TableFlags_BordersInnerH | ImGui.TableFlags_RowBg
  local remove
  if ImGui.BeginTable(ctx, 'pins', 4, flags) then
    ImGui.TableSetupColumn(ctx, t('ed.col.rule'), ImGui.TableColumnFlags_WidthStretch, 1)
    ImGui.TableSetupColumn(ctx, t('ed.col.height'), ImGui.TableColumnFlags_WidthFixed, 90)
    ImGui.TableSetupColumn(ctx, t('ed.col.tracks'), ImGui.TableColumnFlags_WidthFixed, 64)
    ImGui.TableSetupColumn(ctx, '', ImGui.TableColumnFlags_WidthFixed, 26)
    ImGui.TableHeadersRow(ctx)
    for i, p in ipairs(ED.pins) do
      ImGui.PushID(ctx, i)
      ImGui.TableNextRow(ctx)
      ImGui.TableNextColumn(ctx)
      ImGui.SetNextItemWidth(ctx, -1)
      local _, rule = ImGui.InputText(ctx, '##rule', tostring(p.rule or ''))
      p.rule = rule
      widgets.tooltip(ctx, match.describe(p.rule))
      ImGui.TableNextColumn(ctx)
      ImGui.SetNextItemWidth(ctx, -1)
      local _, h = ImGui.InputInt(ctx, '##h', math.floor(tonumber(p.height_px) or 50), 0, 0)
      p.height_px = math.max(8, math.min(600, h))
      ImGui.TableNextColumn(ctx)
      local n = ED.pins_counts and ED.pins_counts[i] or 0
      widgets.label(ctx, tostring(n), n > 0 and 'text' or 'danger', 'mono')
      ImGui.TableNextColumn(ctx)
      if remove_button(ctx) then remove = i end
      ImGui.PopID(ctx)
    end
    ImGui.EndTable(ctx)
  end
  if remove then table.remove(ED.pins, remove) end
  if ImGui.Button(ctx, t('ed.add')) then ED.pins[#ED.pins + 1] = { rule = '', height_px = 50 } end
  ImGui.PushTextWrapPos(ctx, 0)
  ImGui.TextColored(ctx, theme.col('muted'), t('ed.pins.help'))
  ImGui.PopTextWrapPos(ctx)
  ImGui.Separator(ctx)
  ImGui.AlignTextToFramePadding(ctx)
  ImGui.Text(ctx, t('ed.scope'))
  ImGui.SameLine(ctx)
  ImGui.SetNextItemWidth(ctx, 200)
  local label = ED.pins_scope == 'project' and t('ed.scope.project') or t('ed.scope.global')
  if ImGui.BeginCombo(ctx, '##scope', label) then
    if ImGui.Selectable(ctx, t('ed.scope.global'), ED.pins_scope == 'global') then ED.pins_scope = 'global' end
    if ImGui.Selectable(ctx, t('ed.scope.project'), ED.pins_scope == 'project') then ED.pins_scope = 'project' end
    ImGui.EndCombo(ctx)
  end
  ImGui.SameLine(ctx, 0, theme.space[4])
  if ImGui.Button(ctx, t('ed.save'), 100, 0) then
    for i = #ED.pins, 1, -1 do
      ED.pins[i].rule = text.trim(ED.pins[i].rule)
      if ED.pins[i].rule == '' then table.remove(ED.pins, i) end
    end
    config.set('director.pins.rows', ED.pins, ED.pins_scope)
    if ED.pins_scope == 'global' and config.has_override('director.pins.rows', 'project') then config.reset('director.pins.rows', 'project') end
    S.validate_request = true
    E.reapply()
    ED.open, ED.pins = nil, nil
    ImGui.CloseCurrentPopup(ctx)
  end
  ImGui.SameLine(ctx)
  if ImGui.Button(ctx, t('ed.cancel'), 100, 0) then
    ED.open, ED.pins = nil, nil
    ImGui.CloseCurrentPopup(ctx)
  end
end

function ED.draw(ctx)
  ImGui.SetNextWindowSize(ctx, 760, 0, ImGui.Cond_Appearing)
  local visible, open = ImGui.BeginPopupModal(ctx, t('ed.shot.title') .. SHOT_ID, true, ImGui.WindowFlags_AlwaysAutoResize | ImGui.WindowFlags_NoCollapse)
  if visible then
    if ED.draft then draw_shot_editor(ctx) end
    ImGui.EndPopup(ctx)
  end
  if open == false then ED.open, ED.draft = nil, nil end
  ImGui.SetNextWindowSize(ctx, 560, 0, ImGui.Cond_Appearing)
  local pvisible, popen = ImGui.BeginPopupModal(ctx, t('ed.pins.title') .. PINS_ID, true, ImGui.WindowFlags_AlwaysAutoResize | ImGui.WindowFlags_NoCollapse)
  if pvisible then
    if ED.pins then draw_pins_editor(ctx) end
    ImGui.EndPopup(ctx)
  end
  if popen == false then ED.open, ED.pins = nil, nil end
end

ED.scope_key = scope_key
ED.tracks_lib = tracks
return ED
