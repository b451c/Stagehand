-- modules/hud/bar.lua - the caption bar window (the on-camera part of the HUD). One ReaImGui window in the
-- app's context, docked in a REAPER docker or floating. Three layout tiers by bar height: compact (< 72 px) =
-- one row; medium = shot name row with the loudness block and the time on the right, caption row below;
-- tall (>= 96 px) = the caption on its own full-width row (up to two lines) plus the momentary bar and, above
-- hints_above_px, the key hints. The caption tries the font sizes in order and word-wraps only in the tall
-- tier; an ASCII ellipsis is the last resort and the cut is UTF-8 safe (lib/text). The loudness block is fixed
-- width monospace so nothing jumps. While the flash sequencer paints, the whole bar is white. Colours come
-- from hud.colors (an on-camera palette, independent of the app theme). Lua 5.4; no globals.

local theme = require('ui.theme')
local text = require('lib.text')
local view = require('lib.view')
local loudness = require('lib.loudness')
local i18n = require('i18n')

local t = i18n.t

local B = { name = 'Stagehand HUD' }

local ImGui, ctx, app, H, F

function B.init(app_, H_, F_)
  app, H, F = app_, H_, F_
  ImGui = app.ImGui
end

-- pure helpers (also exercised by the self-test) --------------------------------------------------------------------------

function B.tier(h, L)
  L = L or {}
  if h < (tonumber(L.compact_below_px) or 72) then return 'compact' end
  if h >= (tonumber(L.tall_above_px) or 96) then return 'tall' end
  return 'medium'
end

-- greedy word wrap; returns lines, complete (false when max_lines was hit), rest (the words left over)
function B.wrap(s, max_w, mfn, max_lines)
  local words = {}
  for w in tostring(s or ''):gmatch('%S+') do words[#words + 1] = w end
  local lines, cur = {}, ''
  local i = 1
  while i <= #words and #lines < max_lines do
    local cand = cur == '' and words[i] or (cur .. ' ' .. words[i])
    if cur == '' or mfn(cand) <= max_w then
      cur = cand
      i = i + 1
    else
      lines[#lines + 1] = cur
      cur = ''
    end
  end
  if #lines < max_lines then
    if cur ~= '' then lines[#lines + 1] = cur end
    return lines, true, ''
  end
  local rest = {}
  if cur ~= '' then rest[#rest + 1] = cur end
  for j = i, #words do rest[#rest + 1] = words[j] end
  return lines, #rest == 0, table.concat(rest, ' ')
end

-- lines, size, truncated: sizes tried in order on one line, then wrapped (max_lines), then cut with "..."
function B.fit_caption(s, max_w, sizes, max_lines, mfn)
  s = text.trim(s)
  if s == '' or #sizes == 0 then return {}, sizes[1] or 12, false end
  for _, size in ipairs(sizes) do
    if mfn(s, size) <= max_w then return { s }, size, false end
  end
  if max_lines > 1 then
    for _, size in ipairs(sizes) do
      local lines, complete = B.wrap(s, max_w, function(x) return mfn(x, size) end, max_lines)
      if complete then return lines, size, false end
    end
  end
  local size = sizes[#sizes]
  local m = function(x) return mfn(x, size) end
  local lines, complete, rest = B.wrap(s, max_w, m, max_lines)
  if complete then return lines, size, false end
  local last = lines[#lines] or ''
  if rest ~= '' then last = last == '' and rest or (last .. ' ' .. rest) end
  lines[math.max(1, #lines)] = (text.fit(last, max_w, m))
  return lines, size, true
end

function B.time_string(pos, fmt)
  if fmt == 'timecode' then
    return reaper.format_timestr_pos(pos, '', 5)
  elseif fmt == 'seconds' then
    return string.format('%.2f s', pos)
  end
  return text.fmt_time(pos)
end

-- drawing helpers -----------------------------------------------------------------------------------------------------------

local function push(size, face)
  local font = nil
  if face == 'bold' then font = theme.font_bold elseif face == 'mono' then font = theme.font_mono end
  ImGui.PushFont(ctx, font, size)
end

local function pop()
  ImGui.PopFont(ctx)
end

local function col(name, a)
  return theme.rgba(H.colors[name] or 0xFF00FF, a)
end

local function measure(s, size, face)
  push(size, face)
  local w, h = ImGui.CalcTextSize(ctx, s)
  pop()
  return w, h
end

-- text at x, y (top) clipped to max_w; returns the width drawn
local function txt(dl, x, y, s, size, face, colname, max_w)
  push(size, face)
  local shown = s
  if max_w and max_w > 8 then shown = (text.fit(s, max_w, function(x_) return (ImGui.CalcTextSize(ctx, x_)) end)) end
  local w = ImGui.CalcTextSize(ctx, shown)
  ImGui.DrawList_AddText(dl, x, y, col(colname), shown)
  pop()
  return w
end

local function txt_right(dl, x_right, y, s, size, face, colname)
  local w = measure(s, size, face)
  txt(dl, x_right - w, y, s, size, face, colname)
  return w
end

-- the loudness block, right-aligned at x_right; returns its width
local function draw_loudness(dl, x_right, y, h, small)
  local Lc = H.cfg.loudness or {}
  if Lc.mode == 'off' then return 0 end
  local L = H.loud
  local fs = H.cfg.font or {}
  local digit = small and (tonumber(fs.mono_small_px) or 12) or (tonumber(fs.mono_px) or 24)
  local label = tonumber(fs.mono_small_px) or 12
  local in_target = L.i > -70 and math.abs(L.i - (tonumber(Lc.target_lufs) or -14)) <= (tonumber(Lc.target_tol_lu) or 0.5)
  local cols = { { 'M', loudness.fmt(L.m), 'text' }, { 'I', loudness.fmt(L.i), in_target and 'accent2' or 'text' } }
  if Lc.show_peak ~= false then cols[#cols + 1] = { 'PK', loudness.fmt(L.pk), L.pk > -1 and 'warn' or 'muted' } end
  local dw = measure('-00.0', digit, 'mono')
  local lw = measure('PK', label, 'mono')
  local gap = small and 6 or 10
  local total = #cols * (dw + lw + 4 + gap) - gap
  local x = x_right - total
  local x0 = x
  local _, dh = measure('0', digit, 'mono')
  for _, c in ipairs(cols) do
    if small then
      txt(dl, x, y + (h - dh) / 2, c[1], label, 'mono', 'muted')
      txt(dl, x + lw + 4, y + (h - dh) / 2, c[2], digit, 'mono', c[3])
    else
      txt(dl, x, y + (h - dh) / 2 - 1, c[1], label, 'mono', 'muted')
      txt(dl, x + lw + 4, y + (h - dh) / 2, c[2], digit, 'mono', c[3])
    end
    x = x + dw + lw + 4 + gap
  end
  return x_right - x0
end

-- momentary bar from bar_min to 0 LUFS with a tick; w x h at x, y
local function draw_momentary(dl, x, y, w, h)
  local Lc = H.cfg.loudness or {}
  if Lc.mode == 'off' then return end
  local lo = tonumber(Lc.bar_min_lufs) or -30
  local tick = tonumber(Lc.bar_tick_lufs) or -14
  local m = H.loud.m
  ImGui.DrawList_AddRectFilled(dl, x, y, x + w, y + h, col('panel'), 2)
  if m > lo then
    local f = math.min(1, (m - lo) / (0 - lo))
    ImGui.DrawList_AddRectFilled(dl, x, y, x + w * f, y + h, col(m > tick + 2 and 'warn' or 'accent'), 2)
  end
  local tx = x + w * (tick - lo) / (0 - lo)
  ImGui.DrawList_AddRectFilled(dl, tx, y - 2, tx + 1, y + h + 2, col('muted'))
end

local function draw_progress(dl, x, y, w, h)
  local P = H.cfg.progress or {}
  local style = P.style or 'bar'
  if style == 'off' or not H.shot then return end
  local pos = view.position()
  local s = H.shot
  if style == 'dots' and H.n_shots > 0 then
    local n = math.min(H.n_shots, 60)
    local d = math.max(3, h)
    local gap = 4
    local total = n * d + (n - 1) * gap
    local x0 = x + (w - total) / 2
    for i = 1, n do
      local cname = i < (H.shot_k or 0) and 'dim' or (i == H.shot_k and 'accent2' or 'muted')
      ImGui.DrawList_AddCircleFilled(dl, x0 + (i - 1) * (d + gap) + d / 2, y + h / 2, d / 2, col(cname), 10)
    end
    return
  end
  ImGui.DrawList_AddRectFilled(dl, x, y, x + w, y + h, col('panel'), 2)
  if s.t1 > s.t0 then
    local f = (pos - s.t0) / (s.t1 - s.t0)
    if f < 0 then f = 0 elseif f > 1 then f = 1 end
    if f > 0 then ImGui.DrawList_AddRectFilled(dl, x, y, x + w * f, y + h, col('accent2'), 2) end
  end
end

-- what the bar says ----------------------------------------------------------------------------------------------------------

function B.caption_text()
  local s = H.shot
  if not s then return '' end
  if H.cfg.caption_lang == 'secondary' and s.caption2 and s.caption2 ~= '' then return s.caption2 end
  return s.caption or ''
end

function B.title_text()
  local s = H.shot
  if not s then return '' end
  local name = s.name ~= '' and s.name or t('dir.row.unnamed')
  if H.n_shots > 0 and H.shot_k then return string.format('%d/%d  %s', H.shot_k, H.n_shots, name) end
  return name
end

local function idle_text()
  if H.msg_frames > 0 and H.msg ~= '' then return H.msg end
  if H.run_active then return t('hud.idle.run') end
  return t('hud.idle.no_run')
end

-- the body of the window ----------------------------------------------------------------------------------------------------

local function body()
  local x0, y0 = ImGui.GetCursorScreenPos(ctx)
  local w, h = ImGui.GetContentRegionAvail(ctx)
  local dl = ImGui.GetWindowDrawList(ctx)
  H.bar_w, H.bar_h = w, h
  H.bar_x, H.bar_y = x0, y0   -- screen position of the painted area (the recorder writes it to the hud file)
  local dock = ImGui.GetWindowDockID(ctx)
  if dock ~= H.dock then
    H.dock = dock
    if dock ~= 0 then H.last_dock = dock end
    H.dirty = true
  end
  if dock == 0 then
    local ww, wh = ImGui.GetWindowSize(ctx)
    if math.abs(ww - H.w) > 1 or math.abs(wh - H.h) > 1 then
      H.w, H.h = ww, wh
      H.dirty = true
    end
  end
  ImGui.DrawList_AddRectFilled(dl, x0, y0, x0 + w, y0 + h, col('bg'))
  if F.painting() then
    F.painted()
    ImGui.DrawList_AddRectFilled(dl, x0, y0, x0 + w, y0 + h, col('flash'))
    ImGui.Dummy(ctx, w, h)
    return
  end
  local L = H.cfg.layout or {}
  local fs = H.cfg.font or {}
  local tier = B.tier(h, L)
  H.tier = tier
  local pad = 10
  local pos = view.position()
  local time_s = H.cfg.show_time ~= false and B.time_string(pos, H.cfg.time_format) or nil
  local P = H.cfg.progress or {}
  local prog_h = P.style ~= 'off' and (tonumber(P.height_px) or 4) or 0
  local caption = B.caption_text()
  local title = B.title_text()
  local title_px = tonumber(fs.title_px) or 24
  if tier == 'compact' then
    local rh = h - prog_h
    local x_right = x0 + w - pad
    if time_s then x_right = x_right - txt_right(dl, x_right, y0 + (rh - 15) / 2, time_s, 14, 'mono', 'muted') - 12 end
    x_right = x_right - draw_loudness(dl, x_right, y0, rh, true) - 12
    local x = x0 + pad
    if H.shot then
      if H.cfg.show_name ~= false then x = x + txt(dl, x, y0 + (rh - 17) / 2, title, 15, 'bold', 'accent2', math.min(220, (x_right - x) * 0.4)) + 12 end
      local lines, size = B.fit_caption(caption, x_right - x, fs.caption_steps_compact or { 15, 14, 13, 12 }, 1, function(s_, sz) return (measure(s_, sz)) end)
      if lines[1] then txt(dl, x, y0 + (rh - size - 2) / 2, lines[1], size, nil, 'text') end
    else
      txt(dl, x, y0 + (rh - 15) / 2, idle_text(), 13, nil, 'muted', x_right - x)
    end
  else
    local row1_h = title_px + 8
    local y = y0 + 4
    local x_right = x0 + w - pad
    if time_s then x_right = x_right - txt_right(dl, x_right, y + (row1_h - 16) / 2, time_s, 15, 'mono', 'muted') - 14 end
    local loud_w = draw_loudness(dl, x_right, y, row1_h, false)
    local loud_left = x_right - loud_w
    if loud_w > 0 then x_right = loud_left - 14 end
    local x = x0 + pad
    if H.shot then
      if H.cfg.show_name ~= false then
        txt(dl, x, y + (row1_h - title_px - 2) / 2, title, title_px, 'bold', 'accent2', x_right - x)
      end
      if tier == 'tall' then
        local cap_top = y + row1_h
        local cap_w = w - 2 * pad
        local avail_h = h - row1_h - 4 - prog_h - 14 - (h >= (tonumber(L.hints_above_px) or 130) and H.cfg.show_hints and 16 or 0)
        local max_lines = avail_h >= 2 * 17 and 2 or 1
        local lines, size = B.fit_caption(caption, cap_w, fs.caption_steps or { 19, 17, 15 }, max_lines, function(s_, sz) return (measure(s_, sz)) end)
        local ly = cap_top
        for _, line in ipairs(lines) do
          txt(dl, x, ly, line, size, nil, 'text')
          ly = ly + size + 3
        end
        local bar_y = y0 + h - prog_h - 12
        draw_momentary(dl, x, bar_y, math.min(220, w * 0.3), 5)
        if H.cfg.show_hints and h >= (tonumber(L.hints_above_px) or 130) then
          txt_right(dl, x0 + w - pad, bar_y - 6, t('hud.hints'), tonumber(fs.small_px) or 13, nil, 'dim')
        end
      else
        local cap_top = y + row1_h - 2
        local cap_w = (loud_w > 0 and loud_left or (x0 + w)) - pad - x
        local lines, size = B.fit_caption(caption, cap_w, fs.caption_steps or { 19, 17, 15 }, 1, function(s_, sz) return (measure(s_, sz)) end)
        if lines[1] then txt(dl, x, cap_top, lines[1], size, nil, 'text') end
      end
    else
      txt(dl, x, y + (row1_h - 16) / 2, idle_text(), 15, nil, 'muted', x_right - x)
    end
  end
  if prog_h > 0 then draw_progress(dl, x0 + pad, y0 + h - prog_h - 3, w - 2 * pad, prog_h) end
  ImGui.Dummy(ctx, w, h)
end

function B.draw(app_)
  app = app_
  ctx = app.ctx
  if not H.visible then return end
  if H.pending_dock ~= nil then
    ImGui.SetNextWindowDockID(ctx, H.pending_dock)
    H.pending_dock = nil
  end
  ImGui.SetNextWindowSize(ctx, H.w, H.h, ImGui.Cond_Once)
  ImGui.PushStyleVar(ctx, ImGui.StyleVar_WindowPadding, 0, 0)
  ImGui.PushStyleColor(ctx, ImGui.Col_WindowBg, col('bg'))
  local flags = ImGui.WindowFlags_NoScrollbar | ImGui.WindowFlags_NoScrollWithMouse | ImGui.WindowFlags_NoCollapse
  local visible, open = ImGui.Begin(ctx, B.name, true, flags)
  if visible then
    local ok, err = pcall(body)
    ImGui.End(ctx)
    ImGui.PopStyleColor(ctx)
    ImGui.PopStyleVar(ctx)
    if not ok then error(err, 0) end
  else
    ImGui.PopStyleColor(ctx)
    ImGui.PopStyleVar(ctx)
  end
  if not open then
    H.visible = false
    H.dirty = true
  end
end

return B
