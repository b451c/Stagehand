-- ui/icons.lua - icons as draw-list primitives (no Unicode glyphs: they are missing from the default fonts on
-- Linux and Windows). draw(ImGui, dl, kind, cx, cy, s, col): kind in play, stop, loop, search, clear, pin, dock,
-- undock, warning, folder, dot, check, chevron_right, chevron_down, refresh. s = the icon's box size in px.
-- Lua 5.4; no globals.

local M = {}

M.KINDS = { 'play', 'stop', 'loop', 'search', 'clear', 'pin', 'dock', 'undock', 'warning', 'folder', 'dot',
  'check', 'chevron_right', 'chevron_down', 'chevron_left', 'first', 'last', 'refresh', 'eye', 'edit' }

function M.draw(ImGui, dl, kind, cx, cy, s, col)
  local h = s / 2
  if kind == 'play' then
    ImGui.DrawList_AddTriangleFilled(dl, cx - h * 0.7, cy - h, cx - h * 0.7, cy + h, cx + h * 0.9, cy, col)
  elseif kind == 'stop' then
    ImGui.DrawList_AddRectFilled(dl, cx - h * 0.8, cy - h * 0.8, cx + h * 0.8, cy + h * 0.8, col, 1)
  elseif kind == 'loop' then
    local r = h * 0.85
    ImGui.DrawList_PathArcTo(dl, cx, cy, r, math.pi * 0.15, math.pi * 1.75, 16)
    ImGui.DrawList_PathStroke(dl, col, 0, math.max(1.5, s * 0.14))
    local ax, ay = cx + r * math.cos(math.pi * 1.75), cy + r * math.sin(math.pi * 1.75)
    ImGui.DrawList_AddTriangleFilled(dl, ax - h * 0.45, ay - h * 0.55, ax + h * 0.45, ay - h * 0.1, ax - h * 0.35, ay + h * 0.45, col)
  elseif kind == 'search' then
    local r = h * 0.55
    ImGui.DrawList_AddCircle(dl, cx - h * 0.2, cy - h * 0.2, r, col, 12, math.max(1.5, s * 0.12))
    ImGui.DrawList_AddLine(dl, cx + h * 0.2, cy + h * 0.2, cx + h * 0.85, cy + h * 0.85, col, math.max(1.5, s * 0.14))
  elseif kind == 'clear' then
    local d = h * 0.6
    local t = math.max(1.5, s * 0.12)
    ImGui.DrawList_AddLine(dl, cx - d, cy - d, cx + d, cy + d, col, t)
    ImGui.DrawList_AddLine(dl, cx - d, cy + d, cx + d, cy - d, col, t)
  elseif kind == 'pin' then
    ImGui.DrawList_AddCircleFilled(dl, cx, cy - h * 0.35, h * 0.45, col, 10)
    ImGui.DrawList_AddLine(dl, cx, cy, cx, cy + h * 0.9, col, math.max(1.5, s * 0.12))
  elseif kind == 'dock' or kind == 'undock' then
    local t = math.max(1, s * 0.1)
    ImGui.DrawList_AddRect(dl, cx - h * 0.85, cy - h * 0.7, cx + h * 0.85, cy + h * 0.7, col, 1, 0, t)
    if kind == 'dock' then
      ImGui.DrawList_AddRectFilled(dl, cx - h * 0.85, cy + h * 0.15, cx + h * 0.85, cy + h * 0.7, col, 0)
    else
      ImGui.DrawList_AddRectFilled(dl, cx - h * 0.4, cy - h * 0.3, cx + h * 0.4, cy + h * 0.3, col, 0)
    end
  elseif kind == 'warning' then
    ImGui.DrawList_AddTriangle(dl, cx, cy - h * 0.9, cx - h * 0.9, cy + h * 0.75, cx + h * 0.9, cy + h * 0.75, col, math.max(1.5, s * 0.12))
    ImGui.DrawList_AddLine(dl, cx, cy - h * 0.3, cx, cy + h * 0.2, col, math.max(1.5, s * 0.14))
    ImGui.DrawList_AddCircleFilled(dl, cx, cy + h * 0.5, math.max(1, s * 0.08), col, 6)
  elseif kind == 'folder' then
    ImGui.DrawList_AddRectFilled(dl, cx - h * 0.9, cy - h * 0.5, cx + h * 0.9, cy + h * 0.7, col, 1)
    ImGui.DrawList_AddRectFilled(dl, cx - h * 0.9, cy - h * 0.8, cx - h * 0.1, cy - h * 0.3, col, 1)
  elseif kind == 'dot' then
    ImGui.DrawList_AddCircleFilled(dl, cx, cy, h * 0.6, col, 12)
  elseif kind == 'check' then
    local t = math.max(1.5, s * 0.14)
    ImGui.DrawList_AddLine(dl, cx - h * 0.7, cy, cx - h * 0.15, cy + h * 0.55, col, t)
    ImGui.DrawList_AddLine(dl, cx - h * 0.15, cy + h * 0.55, cx + h * 0.8, cy - h * 0.6, col, t)
  elseif kind == 'chevron_right' then
    local t = math.max(1.5, s * 0.14)
    ImGui.DrawList_AddLine(dl, cx - h * 0.3, cy - h * 0.6, cx + h * 0.3, cy, col, t)
    ImGui.DrawList_AddLine(dl, cx + h * 0.3, cy, cx - h * 0.3, cy + h * 0.6, col, t)
  elseif kind == 'chevron_down' then
    local t = math.max(1.5, s * 0.14)
    ImGui.DrawList_AddLine(dl, cx - h * 0.6, cy - h * 0.3, cx, cy + h * 0.3, col, t)
    ImGui.DrawList_AddLine(dl, cx, cy + h * 0.3, cx + h * 0.6, cy - h * 0.3, col, t)
  elseif kind == 'chevron_left' then
    local t = math.max(1.5, s * 0.14)
    ImGui.DrawList_AddLine(dl, cx + h * 0.3, cy - h * 0.6, cx - h * 0.3, cy, col, t)
    ImGui.DrawList_AddLine(dl, cx - h * 0.3, cy, cx + h * 0.3, cy + h * 0.6, col, t)
  elseif kind == 'first' then
    local t = math.max(1.5, s * 0.14)
    ImGui.DrawList_AddLine(dl, cx - h * 0.7, cy - h * 0.6, cx - h * 0.7, cy + h * 0.6, col, t)
    ImGui.DrawList_AddLine(dl, cx + h * 0.5, cy - h * 0.6, cx - h * 0.1, cy, col, t)
    ImGui.DrawList_AddLine(dl, cx - h * 0.1, cy, cx + h * 0.5, cy + h * 0.6, col, t)
  elseif kind == 'last' then
    local t = math.max(1.5, s * 0.14)
    ImGui.DrawList_AddLine(dl, cx + h * 0.7, cy - h * 0.6, cx + h * 0.7, cy + h * 0.6, col, t)
    ImGui.DrawList_AddLine(dl, cx - h * 0.5, cy - h * 0.6, cx + h * 0.1, cy, col, t)
    ImGui.DrawList_AddLine(dl, cx + h * 0.1, cy, cx - h * 0.5, cy + h * 0.6, col, t)
  elseif kind == 'eye' then
    local t = math.max(1.5, s * 0.12)
    ImGui.DrawList_PathArcTo(dl, cx, cy + h * 0.55, h * 1.05, math.pi * 1.22, math.pi * 1.78, 12)
    ImGui.DrawList_PathStroke(dl, col, 0, t)
    ImGui.DrawList_PathArcTo(dl, cx, cy - h * 0.55, h * 1.05, math.pi * 0.22, math.pi * 0.78, 12)
    ImGui.DrawList_PathStroke(dl, col, 0, t)
    ImGui.DrawList_AddCircleFilled(dl, cx, cy, h * 0.28, col, 10)
  elseif kind == 'edit' then
    local t = math.max(1.5, s * 0.14)
    ImGui.DrawList_AddLine(dl, cx - h * 0.7, cy + h * 0.7, cx + h * 0.4, cy - h * 0.4, col, t)
    ImGui.DrawList_AddLine(dl, cx + h * 0.4, cy - h * 0.4, cx + h * 0.7, cy - h * 0.7, col, t * 1.6)
    ImGui.DrawList_AddLine(dl, cx - h * 0.8, cy + h * 0.85, cx - h * 0.45, cy + h * 0.85, col, t)
  elseif kind == 'refresh' then
    local r = h * 0.8
    ImGui.DrawList_PathArcTo(dl, cx, cy, r, math.pi * 0.25, math.pi * 1.85, 16)
    ImGui.DrawList_PathStroke(dl, col, 0, math.max(1.5, s * 0.14))
    local ax, ay = cx + r * math.cos(math.pi * 1.85), cy + r * math.sin(math.pi * 1.85)
    ImGui.DrawList_AddTriangleFilled(dl, ax - h * 0.5, ay - h * 0.3, ax + h * 0.35, ay - h * 0.55, ax + h * 0.1, ay + h * 0.4, col)
  end
end

return M
