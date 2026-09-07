-- modules/glow/overlay.lua - the LICE bitmap composited over the arrange (js_ReaScriptAPI) and the drawing
-- primitives the glow engine paints with (docs/research/mechanisms.md 5.1, 5.2, 5.6).
--
-- Lifecycle: ensure(S) creates the bitmap at the arrange client size times the oversampling S (2 = crisp on
-- Retina) and composites it; it recreates the bitmap when the client size, S or the window changed. Every
-- frame: clear(), draw, flush(drew) - the arrange is invalidated when something was drawn and once more after
-- the last drawing so the overlay disappears. release() unlinks and destroys the bitmap (exit, disable, error).
-- Mapping: mapping() asks REAPER for the times at the client's own screen x-range; a naive
-- client_w / view_span drifts because the client width includes the vertical scrollbar.
-- Compositing: LICE "COPY" writes the pixel; a spark or a flash drawn with COPY and a lower alpha than the
-- fill would punch a hole into the glow, so over() blends them by hand (combined alpha, blended colour) and
-- the caller draws the result with COPY. Colours are 0xRRGGBB + alpha 0..1 -> 0xAARRGGBB. Lua 5.4; nothing
-- here crashes without the extension (available() gates every call).

local js = require('platform.js')

local O = { hwnd = nil, bmp = nil, w = 0, h = 0, S = 1, dirty = false, ok = false, created = 0, fail = nil }

function O.available()
  return js.caps ~= nil and js.caps.composite == true
end

function O.client_size()
  local hw = js.arrange_hwnd()
  if not hw then return nil end
  local ok, w, h = reaper.JS_Window_GetClientSize(hw)
  if not ok then return nil end
  return w, h, hw
end

function O.release()
  if O.bmp then
    if O.sabotage_keep then
      -- negative control of the self-test: the bitmap stays composited (REAPER's list must go red)
      O.leaked, O.leaked_hwnd = O.bmp, O.hwnd
    else
      if O.hwnd then pcall(reaper.JS_Composite_Unlink, O.hwnd, O.bmp) end
      pcall(reaper.JS_LICE_DestroyBitmap, O.bmp)
      if O.hwnd then pcall(reaper.JS_Window_InvalidateRect, O.hwnd, 0, 0, O.w, O.h, false) end
    end
  end
  O.bmp, O.ok, O.dirty = nil, false, false
end

-- true when a bitmap of the right size is composited on the arrange
function O.ensure(S, check)
  if not O.available() then return false end
  S = math.floor(S or 1)
  if S < 1 then S = 1 elseif S > 2 then S = 2 end
  if O.bmp and check == false and O.S == S then return true end   -- between size checks the bitmap is trusted
  local w, h, hw = O.client_size()
  if not w or w < 10 or h < 10 then return false end
  if O.bmp and O.w == w and O.h == h and O.S == S and O.hwnd == hw then return true end
  O.release()
  local bmp = reaper.JS_LICE_CreateBitmap(true, w * S, h * S)
  if not bmp then
    O.fail = 'JS_LICE_CreateBitmap failed'
    return false
  end
  O.bmp, O.w, O.h, O.S, O.hwnd = bmp, w, h, S, hw
  reaper.JS_LICE_Clear(bmp, 0)
  reaper.JS_Composite(hw, 0, 0, w, h, bmp, 0, 0, w * S, h * S, true)
  O.ok = true
  O.created = O.created + 1
  return true
end

function O.clear()
  if O.bmp then reaper.JS_LICE_Clear(O.bmp, 0) end
end

function O.flush(drew)
  if not O.hwnd or not O.bmp then return end
  if drew or O.dirty then reaper.JS_Window_InvalidateRect(O.hwnd, 0, 0, O.w, O.h, false) end
  O.dirty = drew
end

-- bitmaps REAPER lists as composited on the arrange (independent oracle for the self-test)
function O.listed()
  if not O.available() or not reaper.JS_Composite_ListBitmaps then return -1, '' end
  local hw = js.arrange_hwnd()
  if not hw then return -1, '' end
  local ret, list = reaper.JS_Composite_ListBitmaps(hw)
  list = tostring(list or '')
  local n = 0
  for tok in list:gmatch('[^,%s]+') do
    if tok ~= '' then n = n + 1 end
  end
  return n, list, ret
end

-- t_left, t_right of the client and px per second (client px, not bitmap px)
function O.mapping()
  local a, b
  local ok, left = reaper.JS_Window_GetClientRect(O.hwnd)
  if ok and left then a, b = reaper.GetSet_ArrangeView2(0, false, left, left + O.w, 0, 0) end
  if not a or not b or b <= a then a, b = reaper.GetSet_ArrangeView2(0, false, 0, 0, 0, 0) end
  if b <= a then b = a + 1 end
  return a, b, O.w / (b - a)
end

-- colour helpers ---------------------------------------------------------------------------------------------------

function O.argb(rgb, a)
  if a < 0 then a = 0 elseif a > 1 then a = 1 end
  return (math.floor(a * 255 + 0.5) << 24) | (rgb & 0xFFFFFF)
end

function O.blend(c1, c2, k)
  if k < 0 then k = 0 elseif k > 1 then k = 1 end
  local r = math.floor(((c1 >> 16) & 255) * (1 - k) + ((c2 >> 16) & 255) * k + 0.5)
  local g = math.floor(((c1 >> 8) & 255) * (1 - k) + ((c2 >> 8) & 255) * k + 0.5)
  local b = math.floor((c1 & 255) * (1 - k) + (c2 & 255) * k + 0.5)
  return (r << 16) | (g << 8) | b
end

-- top (ct, at) over fill (cf, af): combined colour and alpha
function O.over(cf, af, ct, at)
  local a = at + af * (1 - at)
  if a <= 0 then return cf, 0 end
  return O.blend(cf, ct, at / a), a
end

-- drawing (coordinates in client px; scaled by S here) ------------------------------------------------------------

function O.rect(x, y, w, h, rgb, a)
  if w <= 0 or h <= 0 or a <= 0 then return end
  local S = O.S
  reaper.JS_LICE_FillRect(O.bmp, math.floor(x * S), math.floor(y * S), math.max(1, math.floor(w * S)), math.max(1, math.floor(h * S)), O.argb(rgb, a), 1.0, 'COPY')
end

-- a rectangle in bitmap px (the caller scaled)
function O.rect_px(x, y, w, h, rgb, a)
  if w <= 0 or h <= 0 or a <= 0 then return end
  reaper.JS_LICE_FillRect(O.bmp, x, y, w, h, O.argb(rgb, a), 1.0, 'COPY')
end

function O.outline(x, y, w, h, rgb, a, t)
  if w <= 0 or h <= 0 or a <= 0 then return end
  local S = O.S
  local X, Y, W, H = math.floor(x * S), math.floor(y * S), math.floor(w * S), math.floor(h * S)
  local T = math.max(1, math.floor((t or 1) * S))
  local c = O.argb(rgb, a)
  reaper.JS_LICE_FillRect(O.bmp, X, Y, W, T, c, 1.0, 'COPY')
  reaper.JS_LICE_FillRect(O.bmp, X, Y + H - T, W, T, c, 1.0, 'COPY')
  reaper.JS_LICE_FillRect(O.bmp, X, Y, T, H, c, 1.0, 'COPY')
  reaper.JS_LICE_FillRect(O.bmp, X + W - T, Y, T, H, c, 1.0, 'COPY')
end

-- horizontal gradient from (rgb0, a0) at x to (rgb1, a1) at x + w (bitmap px)
function O.gradient_px(x, y, w, h, rgb0, a0, rgb1, a1)
  if w <= 0 or h <= 0 then return end
  local r0, g0, b0 = ((rgb0 >> 16) & 255) / 255, ((rgb0 >> 8) & 255) / 255, (rgb0 & 255) / 255
  local r1, g1, b1 = ((rgb1 >> 16) & 255) / 255, ((rgb1 >> 8) & 255) / 255, (rgb1 & 255) / 255
  reaper.JS_LICE_GradRect(O.bmp, x, y, w, h, r0, g0, b0, a0, (r1 - r0) / w, (g1 - g0) / w, (b1 - b0) / w, (a1 - a0) / w, 0, 0, 0, 0, 'COPY')
end

-- a spark column with a tail fading back into the fill (fill = what is under it: rgb_f, a_f)
function O.spark(x, y, h, width, tail, rgb_s, a_s, rgb_f, a_f)
  if a_s <= 0.004 then return end
  local S = O.S
  local X, Y, H = math.floor(x * S), math.floor(y * S), math.max(1, math.floor(h * S))
  local W = math.max(1, math.floor(width * S))
  local c, a = O.over(rgb_f, a_f, rgb_s, a_s)
  reaper.JS_LICE_FillRect(O.bmp, X, Y, W, H, O.argb(c, a), 1.0, 'COPY')
  local T = math.floor(tail * S)
  if T > 1 then
    local ct, at = O.over(rgb_f, a_f, rgb_s, a_s * 0.6)
    O.gradient_px(X + W, Y, T, H, ct, at, rgb_f, a_f)
  end
end

-- a gradient band from (c0, a0) at xa to (c1, a1) at xb, clipped to [cx0, cx1) with the values interpolated
-- at the clip edges (bitmap px)
local function grad_clipped(xa, xb, y, h, c0, a0, c1, a1, cx0, cx1)
  if xb <= xa then return end
  local x0, x1 = math.max(xa, cx0), math.min(xb, cx1)
  if x1 <= x0 then return end
  local w = xb - xa
  local f0, f1 = (x0 - xa) / w, (x1 - xa) / w
  local ca, aa = O.blend(c0, c1, f0), a0 + (a1 - a0) * f0
  local cb, ab = O.blend(c0, c1, f1), a0 + (a1 - a0) * f1
  O.gradient_px(x0, y, x1 - x0, h, ca, aa, cb, ab)
end

-- "beam": a bright core with a soft halo on both sides (two linear bands per side approximate a quadratic
-- falloff), composited over the fill and clipped to [clip_x0, clip_x1) (client px)
function O.beam(x, y, h, core_w, halo_px, rgb_core, rgb_halo, a, rgb_f, a_f, clip_x0, clip_x1)
  if a <= 0.004 then return end
  local S = O.S
  local X, Y, H = math.floor(x * S), math.floor(y * S), math.max(1, math.floor(h * S))
  local W = math.max(1, math.floor(core_w * S))
  local R = math.floor(halo_px * S)
  local C0, C1 = math.floor(clip_x0 * S), math.floor(clip_x1 * S)
  local ch, ah = O.over(rgb_f, a_f, rgb_halo, a * 0.55)
  local cm, am = O.over(rgb_f, a_f, rgb_halo, a * 0.15)
  local R1 = math.floor(R * 0.45)
  local R2 = R - R1
  if R > 1 then
    grad_clipped(X + W, X + W + R1, Y, H, ch, ah, cm, am, C0, C1)
    grad_clipped(X + W + R1, X + W + R, Y, H, cm, am, rgb_f, a_f, C0, C1)
    grad_clipped(X - R, X - R + R2, Y, H, rgb_f, a_f, cm, am, C0, C1)
    grad_clipped(X - R + R2, X, Y, H, cm, am, ch, ah, C0, C1)
  end
  local cc, ac = O.over(rgb_f, a_f, rgb_core, a)
  local cx0, cx1 = math.max(X, C0), math.min(X + W, C1)
  if cx1 > cx0 then O.rect_px(cx0, Y, cx1 - cx0, H, cc, ac) end
end

-- "trail": a gradient growing from x_from (transparent) to x_to (alpha a), clipped (client px)
function O.trail(x_from, x_to, y, h, rgb, a, rgb_f, a_f, clip_x0, clip_x1)
  if a <= 0.004 or x_to <= x_from then return end
  local S = O.S
  local Y, H = math.floor(y * S), math.max(1, math.floor(h * S))
  local ct, at = O.over(rgb_f, a_f, rgb, a)
  grad_clipped(math.floor(x_from * S), math.floor(x_to * S), Y, H, rgb_f, a_f, ct, at, math.floor(clip_x0 * S), math.floor(clip_x1 * S))
end

function O.describe()
  return string.format('%dx%d S=%d bitmaps_created=%d ok=%s', O.w, O.h, O.S, O.created, tostring(O.ok))
end

return O
