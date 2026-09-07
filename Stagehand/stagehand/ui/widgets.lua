-- ui/widgets.lua - the controls every Stagehand panel is built from: icon buttons with the four states,
-- toggle buttons, family chips, clipped text with a tooltip, monospace numbers, the search field.
-- All sizes and colours come from ui/theme.lua. Lua 5.4; no globals.

local theme = require('ui.theme')
local icons = require('ui.icons')
local text = require('lib.text')

local M = {}

local ImGui = nil

function M.init(imgui)
  ImGui = imgui
end

function M.tooltip(ctx, s)
  if s and s ~= '' and ImGui.IsItemHovered(ctx, ImGui.HoveredFlags_ForTooltip) then
    ImGui.SetTooltip(ctx, s)
  end
end

-- background + border of a control from its state; returns the foreground colour
local function control_bg(ctx, dl, x0, y0, x1, y1, o, hovered, held)
  local c = theme.c
  local rgb = o.color or c.accent
  local fg
  if o.disabled then
    ImGui.DrawList_AddRectFilled(dl, x0, y0, x1, y1, theme.rgba(c.panel), o.rounding)
    fg = theme.rgba(c.dim)
  elseif o.active then
    ImGui.DrawList_AddRectFilled(dl, x0, y0, x1, y1, theme.rgba(held and theme.mix(rgb, c.bg, 0.2) or rgb), o.rounding)
    fg = theme.rgba(theme.on(rgb))
  else
    local bg = held and c.sel or (hovered and c.hover or (o.flat and c.bg or c.panel2))
    ImGui.DrawList_AddRectFilled(dl, x0, y0, x1, y1, theme.rgba(bg, o.flat and (hovered and 1 or 0) or 1), o.rounding)
    if o.on then
      ImGui.DrawList_AddRect(dl, x0 + 0.5, y0 + 0.5, x1 - 0.5, y1 - 0.5, theme.rgba(rgb), o.rounding, 0, 1.5)
      fg = theme.rgba(rgb)
    else
      fg = theme.rgba(hovered and c.text or (o.muted and c.muted or c.text))
    end
  end
  if o.focused then
    ImGui.DrawList_AddRect(dl, x0 - 1, y0 - 1, x1 + 1, y1 + 1, theme.rgba(c.focus), o.rounding + 1, 0, 1)
  end
  return fg
end

-- icon_button(ctx, id, kind, o): o = { w, h, active, on, color, tooltip, label, disabled, flat, muted, font }
-- kind = an icons.lua kind or nil when o.label carries text. Returns clicked, hovered, right_clicked.
function M.icon_button(ctx, id, kind, o)
  o = o or {}
  local w, h = o.w or theme.control_h_small, o.h or theme.control_h_small
  o.rounding = o.rounding or theme.radius.s
  local x0, y0 = ImGui.GetCursorScreenPos(ctx)
  if o.disabled then ImGui.BeginDisabled(ctx) end
  local clicked = ImGui.InvisibleButton(ctx, id, w, h)
  if o.disabled then ImGui.EndDisabled(ctx) end
  local hovered = ImGui.IsItemHovered(ctx)
  local held = ImGui.IsItemActive(ctx)
  local right = hovered and ImGui.IsMouseClicked(ctx, ImGui.MouseButton_Right)
  local dl = ImGui.GetWindowDrawList(ctx)
  local fg = control_bg(ctx, dl, x0, y0, x0 + w, y0 + h, o, hovered, held)
  if kind then
    icons.draw(ImGui, dl, kind, x0 + w / 2, y0 + h / 2, math.min(w, h) * 0.55, fg)
  elseif o.label then
    if o.font then theme.push_font(ImGui, ctx, o.font) end
    local tw, th = ImGui.CalcTextSize(ctx, o.label)
    ImGui.DrawList_AddText(dl, x0 + (w - tw) / 2, y0 + (h - th) / 2, fg, o.label)
    if o.font then theme.pop_font(ImGui, ctx) end
  end
  if o.tooltip then M.tooltip(ctx, o.tooltip) end
  return clicked and not o.disabled, hovered, right
end

-- text button with the same states (used for footer toggles and group buttons)
function M.button(ctx, id, label, o)
  o = o or {}
  o.label = label
  o.w = o.w or (ImGui.CalcTextSize(ctx, label) + theme.space[4])
  o.h = o.h or theme.control_h
  o.rounding = o.rounding or theme.radius.m
  return M.icon_button(ctx, id, nil, o)
end

-- family chip: filled with its colour when on, outlined when off
function M.chip(ctx, id, label, on, color, o)
  o = o or {}
  local pad = theme.space[2]
  theme.push_font(ImGui, ctx, 'small')
  local tw, th = ImGui.CalcTextSize(ctx, label)
  local w, h = o.w or (tw + pad * 2), o.h or theme.chip_h
  local x0, y0 = ImGui.GetCursorScreenPos(ctx)
  local clicked = ImGui.InvisibleButton(ctx, id, w, h)
  local hovered = ImGui.IsItemHovered(ctx)
  local dl = ImGui.GetWindowDrawList(ctx)
  local c = theme.c
  local fg
  if on then
    ImGui.DrawList_AddRectFilled(dl, x0, y0, x0 + w, y0 + h, theme.rgba(hovered and theme.mix(color, c.text, 0.12) or color), theme.radius.s)
    fg = theme.rgba(theme.on(color))
  else
    ImGui.DrawList_AddRectFilled(dl, x0, y0, x0 + w, y0 + h, theme.rgba(hovered and c.hover or c.panel), theme.radius.s)
    ImGui.DrawList_AddRect(dl, x0 + 0.5, y0 + 0.5, x0 + w - 0.5, y0 + h - 0.5, theme.rgba(color, 0.55), theme.radius.s, 0, 1)
    fg = theme.rgba(c.muted)
  end
  ImGui.DrawList_AddText(dl, x0 + (w - tw) / 2, y0 + (h - th) / 2, fg, label)
  theme.pop_font(ImGui, ctx)
  if o.tooltip then M.tooltip(ctx, o.tooltip) end
  return clicked, hovered
end

-- text clipped to max_w with "..." and a tooltip holding the full text; drawn at the given screen position
function M.text_at(ctx, dl, x, y, s, col, max_w, font)
  if font then theme.push_font(ImGui, ctx, font) end
  local shown, cut = s, false
  if max_w and max_w > 8 then
    shown, cut = text.fit(s, max_w, function(t) return (ImGui.CalcTextSize(ctx, t)) end)
  end
  ImGui.DrawList_AddText(dl, x, y, col, shown)
  if font then theme.pop_font(ImGui, ctx) end
  return cut
end

-- inline text (layout cursor) in a token font/colour
function M.label(ctx, s, color_name, font)
  if font then theme.push_font(ImGui, ctx, font) end
  ImGui.TextColored(ctx, theme.col(color_name or 'text'), s)
  if font then theme.pop_font(ImGui, ctx) end
end

-- the search field: returns changed, value, submitted (Enter), active (typing lands here)
function M.search_field(ctx, id, value, hint, width)
  local c = theme.c
  local x0, y0 = ImGui.GetCursorScreenPos(ctx)
  local h = theme.control_h + 2
  local icon_w = 24
  ImGui.SetNextItemWidth(ctx, (width or ImGui.GetContentRegionAvail(ctx)) - icon_w)
  ImGui.SetCursorScreenPos(ctx, x0 + icon_w, y0)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_FramePadding, theme.space[2], (h - ImGui.GetTextLineHeight(ctx)) / 2)
  local flags = ImGui.InputTextFlags_EnterReturnsTrue
  local submitted, new_value = ImGui.InputTextWithHint(ctx, id, hint, value, flags)
  local active = ImGui.IsItemActive(ctx)
  local changed = new_value ~= value
  ImGui.PopStyleVar(ctx)
  local dl = ImGui.GetWindowDrawList(ctx)
  local x1 = x0 + icon_w
  ImGui.DrawList_AddRectFilled(dl, x0, y0, x1 + theme.radius.m, y0 + h, theme.rgba(active and c.hover or c.panel2), theme.radius.m, ImGui.DrawFlags_RoundCornersLeft)
  icons.draw(ImGui, dl, 'search', x0 + icon_w / 2 + 2, y0 + h / 2, 13, theme.rgba(active and c.accent or c.muted))
  if active then
    local w = ImGui.GetItemRectSize(ctx)
    ImGui.DrawList_AddRect(dl, x0 + 0.5, y0 + 0.5, x0 + icon_w + w - 0.5, y0 + h - 0.5, theme.rgba(c.focus), theme.radius.m, 0, 1)
  end
  return changed, new_value, submitted, active
end

-- segmented control: options = { { value, label, tooltip } ... }; returns the newly chosen value or nil
function M.segmented(ctx, id, options, current, o)
  o = o or {}
  local h = o.h or theme.control_h_small
  local x0, y0 = ImGui.GetCursorScreenPos(ctx)
  local dl = ImGui.GetWindowDrawList(ctx)
  local c = theme.c
  local chosen
  local x = x0
  theme.push_font(ImGui, ctx, 'small')
  local widths = {}
  local total = 0
  for i, opt in ipairs(options) do
    widths[i] = ImGui.CalcTextSize(ctx, opt[2]) + theme.space[3]
    total = total + widths[i]
  end
  if o.w and o.w > total then
    local extra = (o.w - total) / #options
    for i in ipairs(widths) do widths[i] = widths[i] + extra end
    total = o.w
  end
  ImGui.DrawList_AddRectFilled(dl, x0, y0, x0 + total, y0 + h, theme.rgba(c.panel2), theme.radius.s)
  for i, opt in ipairs(options) do
    local w = widths[i]
    ImGui.SetCursorScreenPos(ctx, x, y0)
    local clicked = ImGui.InvisibleButton(ctx, id .. i, w, h)
    local hovered = ImGui.IsItemHovered(ctx)
    local on = opt[1] == current
    local fg
    if on then
      ImGui.DrawList_AddRectFilled(dl, x, y0, x + w, y0 + h, theme.rgba(o.color or c.accent), theme.radius.s)
      fg = theme.rgba(theme.on(o.color or c.accent))
    else
      if hovered then ImGui.DrawList_AddRectFilled(dl, x, y0, x + w, y0 + h, theme.rgba(c.hover), theme.radius.s) end
      fg = theme.rgba(hovered and c.text or c.muted)
    end
    local tw, th = ImGui.CalcTextSize(ctx, opt[2])
    ImGui.DrawList_AddText(dl, x + (w - tw) / 2, y0 + (h - th) / 2, fg, opt[2])
    if opt[3] then M.tooltip(ctx, opt[3]) end
    if clicked and not on then chosen = opt[1] end
    x = x + w
  end
  theme.pop_font(ImGui, ctx)
  ImGui.SetCursorScreenPos(ctx, x0, y0)
  ImGui.Dummy(ctx, total, h)
  return chosen, total
end

-- a thin progress bar drawn at the cursor (w x h), fraction 0..1 (nil = empty)
function M.progress(ctx, w, h, frac, color)
  local x0, y0 = ImGui.GetCursorScreenPos(ctx)
  local dl = ImGui.GetWindowDrawList(ctx)
  ImGui.DrawList_AddRectFilled(dl, x0, y0, x0 + w, y0 + h, theme.col('panel2'), 2)
  if frac and frac > 0 then
    ImGui.DrawList_AddRectFilled(dl, x0, y0, x0 + w * math.min(1, frac), y0 + h, theme.rgba(color or theme.c.accent), 2)
  end
  ImGui.Dummy(ctx, w, h)
end

-- a filled circle inline (marker class / family colour), advancing the cursor by its width
function M.dot_inline(ctx, rgb, d)
  d = d or 8
  local x, y = ImGui.GetCursorScreenPos(ctx)
  local lh = ImGui.GetTextLineHeight(ctx)
  local dl = ImGui.GetWindowDrawList(ctx)
  ImGui.DrawList_AddCircleFilled(dl, x + d / 2, y + lh / 2, d / 2, theme.rgba(rgb), 12)
  ImGui.Dummy(ctx, d, lh)
end

-- transient status line: message while frames remain, else the hint
function M.status(ctx, msg, hint, strong)
  theme.push_font(ImGui, ctx, 'small')
  local s = (msg and msg ~= '') and msg or (hint or '')
  local w = ImGui.GetContentRegionAvail(ctx)
  local shown = text.fit(s, w, function(t) return (ImGui.CalcTextSize(ctx, t)) end)
  ImGui.TextColored(ctx, theme.col(strong and 'text' or 'muted'), shown)
  if shown ~= s then M.tooltip(ctx, s) end
  theme.pop_font(ImGui, ctx)
end

return M
