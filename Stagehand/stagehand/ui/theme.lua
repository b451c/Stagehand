-- ui/theme.lua - the design tokens (docs/architecture.md section 5) and the ImGui style they produce.
--
-- The only file with raw numbers for spacing, type and colour. Colours are 0xRRGGBB; rgba(c, a) turns them
-- into the 0xRRGGBBAA ints ReaImGui wants. detect(mode) picks the dark or light palette from the REAPER theme's
-- main background (GetThemeColor) unless the user forces one. push()/pop() wrap every frame with the style.
-- Fonts: the ReaImGui default face at token sizes (PushFont(ctx, nil, size)) plus a monospace face for numbers.
-- Lua 5.4; no globals.

local M = {}

M.space = { 4, 8, 12, 16, 24, 32 }
M.row_h = 26
M.row_h_compact = 22
M.control_h = 24
M.control_h_small = 20
M.chip_h = 20
M.radius = { s = 4, m = 6, l = 10 }
M.border = 1
M.compact_below = 430

M.type = { title = 18, body = 14, mono = 13, small = 12 }

M.motion = { fast = 0.12, normal = 0.20, message_frames = 40 }

M.dark = {
  bg = 0x171A21, panel = 0x20242E, panel2 = 0x2A2F3B, line = 0x39404F, hover = 0x323949, sel = 0x3A4256,
  text = 0xE9EDF3, muted = 0x8D95A7, dim = 0x4A5163, accent = 0x3AD1FF, accent2 = 0xFFB347,
  ok = 0x6FE39A, warn = 0xF5E663, danger = 0xFF5A5A, focus = 0x63C8FF, on_accent = 0x10131A,
}

M.light = {
  bg = 0xF3F5F8, panel = 0xE7EAF0, panel2 = 0xD8DDE6, line = 0xBFC6D2, hover = 0xD0D6E0, sel = 0xC3CBDA,
  text = 0x1B1F27, muted = 0x5C6474, dim = 0xA5ACB9, accent = 0x0A7FBF, accent2 = 0xB85E12,
  ok = 0x1E8E4E, warn = 0x8A6D00, danger = 0xC8202D, focus = 0x0A7FBF, on_accent = 0xFFFFFF,
}

-- colour-blind safe starter set for families (no red/green pair)
M.family_palette = { 0x4E9AF1, 0xF1A24E, 0x3FBFAE, 0xD96AC8, 0xA6B84E, 0x9AA3B5, 0x8F7BEF }

M.c = M.dark
M.is_dark = true
M.mode = 'auto'

function M.rgba(rgb, a)
  a = a == nil and 1 or a
  if a < 0 then a = 0 elseif a > 1 then a = 1 end
  return ((rgb & 0xFFFFFF) << 8) | math.floor(a * 255 + 0.5)
end

function M.col(name, a)
  return M.rgba(M.c[name] or 0xFF00FF, a)
end

function M.parse_hex(s)
  if type(s) == 'number' then return s & 0xFFFFFF end
  local hex = tostring(s or ''):match('^#?(%x%x%x%x%x%x)$')
  if not hex then return nil end
  return tonumber(hex, 16)
end

function M.hex(rgb)
  return string.format('#%06X', rgb & 0xFFFFFF)
end

function M.native_to_rgb(native)
  local r, g, b = reaper.ColorFromNative(native & 0xFFFFFF)
  return (r << 16) | (g << 8) | b
end

function M.luminance(rgb)
  local r, g, b = (rgb >> 16) & 255, (rgb >> 8) & 255, rgb & 255
  return (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255
end

function M.mix(c1, c2, t)
  local function ch(shift)
    local a, b = (c1 >> shift) & 255, (c2 >> shift) & 255
    return math.floor(a + (b - a) * t + 0.5) & 255
  end
  return (ch(16) << 16) | (ch(8) << 8) | ch(0)
end

-- text colour that reads on a given background (for chips filled with a family colour)
function M.on(rgb)
  return M.luminance(rgb) > 0.55 and 0x10131A or 0xF5F7FA
end

function M.detect(mode)
  M.mode = mode or 'auto'
  if M.mode == 'dark' then M.is_dark = true
  elseif M.mode == 'light' then M.is_dark = false
  else
    local native = reaper.GetThemeColor('col_main_bg2', 0)
    if native and native >= 0 then
      M.is_dark = M.luminance(M.native_to_rgb(native)) < 0.5
    else
      M.is_dark = true
    end
  end
  M.c = M.is_dark and M.dark or M.light
  return M.is_dark
end

local pushed = { colors = 0, vars = 0 }

function M.push(ImGui, ctx)
  local c = M.c
  local colors = {
    { ImGui.Col_WindowBg, M.rgba(c.bg) }, { ImGui.Col_ChildBg, M.rgba(c.bg) }, { ImGui.Col_PopupBg, M.rgba(c.panel) },
    { ImGui.Col_Border, M.rgba(c.line) }, { ImGui.Col_BorderShadow, M.rgba(c.bg, 0) },
    { ImGui.Col_FrameBg, M.rgba(c.panel2) }, { ImGui.Col_FrameBgHovered, M.rgba(c.hover) }, { ImGui.Col_FrameBgActive, M.rgba(c.sel) },
    { ImGui.Col_TitleBg, M.rgba(c.panel) }, { ImGui.Col_TitleBgActive, M.rgba(c.panel2) }, { ImGui.Col_TitleBgCollapsed, M.rgba(c.panel) },
    { ImGui.Col_MenuBarBg, M.rgba(c.panel) },
    { ImGui.Col_ScrollbarBg, M.rgba(c.bg) }, { ImGui.Col_ScrollbarGrab, M.rgba(c.line) },
    { ImGui.Col_ScrollbarGrabHovered, M.rgba(c.hover) }, { ImGui.Col_ScrollbarGrabActive, M.rgba(c.sel) },
    { ImGui.Col_CheckMark, M.rgba(c.accent) }, { ImGui.Col_SliderGrab, M.rgba(c.accent) }, { ImGui.Col_SliderGrabActive, M.rgba(c.focus) },
    { ImGui.Col_Button, M.rgba(c.panel2) }, { ImGui.Col_ButtonHovered, M.rgba(c.hover) }, { ImGui.Col_ButtonActive, M.rgba(c.sel) },
    { ImGui.Col_Header, M.rgba(c.sel) }, { ImGui.Col_HeaderHovered, M.rgba(c.hover) }, { ImGui.Col_HeaderActive, M.rgba(c.sel) },
    { ImGui.Col_Separator, M.rgba(c.line) }, { ImGui.Col_SeparatorHovered, M.rgba(c.accent) }, { ImGui.Col_SeparatorActive, M.rgba(c.accent) },
    { ImGui.Col_ResizeGrip, M.rgba(c.line, 0.5) }, { ImGui.Col_ResizeGripHovered, M.rgba(c.accent, 0.7) }, { ImGui.Col_ResizeGripActive, M.rgba(c.accent) },
    { ImGui.Col_Tab, M.rgba(c.panel) }, { ImGui.Col_TabHovered, M.rgba(c.hover) }, { ImGui.Col_TabSelected, M.rgba(c.panel2) },
    { ImGui.Col_TabSelectedOverline, M.rgba(c.accent) }, { ImGui.Col_TabDimmed, M.rgba(c.panel) },
    { ImGui.Col_TabDimmedSelected, M.rgba(c.panel2) }, { ImGui.Col_TabDimmedSelectedOverline, M.rgba(c.accent, 0.5) },
    { ImGui.Col_DockingPreview, M.rgba(c.accent, 0.6) }, { ImGui.Col_DockingEmptyBg, M.rgba(c.bg) },
    { ImGui.Col_Text, M.rgba(c.text) }, { ImGui.Col_TextDisabled, M.rgba(c.muted) }, { ImGui.Col_TextSelectedBg, M.rgba(c.accent, 0.35) },
    { ImGui.Col_TableHeaderBg, M.rgba(c.panel2) }, { ImGui.Col_TableBorderStrong, M.rgba(c.line) },
    { ImGui.Col_TableBorderLight, M.rgba(c.line, 0.6) }, { ImGui.Col_TableRowBg, M.rgba(c.bg, 0) }, { ImGui.Col_TableRowBgAlt, M.rgba(c.panel, 0.5) },
    { ImGui.Col_NavCursor, M.rgba(c.focus) }, { ImGui.Col_PlotHistogram, M.rgba(c.accent) }, { ImGui.Col_ModalWindowDimBg, M.rgba(c.bg, 0.6) },
  }
  for _, e in ipairs(colors) do ImGui.PushStyleColor(ctx, e[1], e[2]) end
  pushed.colors = #colors
  local vars = {
    { ImGui.StyleVar_WindowRounding, 0 }, { ImGui.StyleVar_FrameRounding, M.radius.m }, { ImGui.StyleVar_ChildRounding, M.radius.m },
    { ImGui.StyleVar_PopupRounding, M.radius.m }, { ImGui.StyleVar_TabRounding, M.radius.s }, { ImGui.StyleVar_ScrollbarRounding, M.radius.s },
    { ImGui.StyleVar_GrabRounding, M.radius.s }, { ImGui.StyleVar_ScrollbarSize, 10 },
    { ImGui.StyleVar_FrameBorderSize, 0 }, { ImGui.StyleVar_WindowBorderSize, 1 }, { ImGui.StyleVar_ChildBorderSize, 1 },
    { ImGui.StyleVar_WindowPadding, M.space[3], M.space[2] }, { ImGui.StyleVar_FramePadding, M.space[2], 4 },
    { ImGui.StyleVar_ItemSpacing, M.space[2] - 2, M.space[1] }, { ImGui.StyleVar_ItemInnerSpacing, M.space[2] - 2, M.space[1] },
    { ImGui.StyleVar_TabBarBorderSize, 1 },
  }
  for _, e in ipairs(vars) do
    if e[3] ~= nil then ImGui.PushStyleVar(ctx, e[1], e[2], e[3]) else ImGui.PushStyleVar(ctx, e[1], e[2]) end
  end
  pushed.vars = #vars
end

function M.pop(ImGui, ctx)
  if pushed.colors > 0 then ImGui.PopStyleColor(ctx, pushed.colors) end
  if pushed.vars > 0 then ImGui.PopStyleVar(ctx, pushed.vars) end
  pushed.colors, pushed.vars = 0, 0
end

M.fonts_info = {}

-- create the faces once per context (attached so they live as long as the context)
function M.fonts(ImGui, ctx)
  M.font_mono, M.font_bold = nil, nil
  local ok, f = pcall(ImGui.CreateFont, 'monospace')
  if ok and f then
    local ok2 = pcall(ImGui.Attach, ctx, f)
    if ok2 then M.font_mono = f end
  end
  M.fonts_info.mono = M.font_mono and 'monospace' or ('default (' .. tostring(f) .. ')')
  local okb, fb = pcall(ImGui.CreateFont, 'sans-serif', ImGui.FontFlags_Bold)
  if okb and fb then
    local ok2 = pcall(ImGui.Attach, ctx, fb)
    if ok2 then M.font_bold = fb end
  end
  M.fonts_info.bold = M.font_bold and 'sans-serif bold' or ('default (' .. tostring(fb) .. ')')
end

-- kind: 'body' | 'title' | 'small' | 'mono' | 'bold'
function M.push_font(ImGui, ctx, kind)
  if kind == 'mono' then ImGui.PushFont(ctx, M.font_mono, M.type.mono)
  elseif kind == 'title' then ImGui.PushFont(ctx, M.font_bold, M.type.title)
  elseif kind == 'bold' then ImGui.PushFont(ctx, M.font_bold, M.type.body)
  elseif kind == 'small' then ImGui.PushFont(ctx, nil, M.type.small)
  else ImGui.PushFont(ctx, nil, M.type.body) end
end

function M.pop_font(ImGui, ctx)
  ImGui.PopFont(ctx)
end

return M
