-- platform/js.lua - capability probe for the optional extensions and the coordinate helpers every module uses.
--
-- caps = { js = bool, js_version, sws = bool, sws_version, window_rects, scroll, composite, lice, viewport }
-- rect(hwnd)        -> l, t, r, b as js_ReaScriptAPI reports them, sorted so t < b: NATIVE coordinates (Cocoa on
--                      macOS, see below). Kept for the journal's window_rect round trip with set_rect().
-- screen_rect(hwnd) -> l, t, r, b in screen px, y down (Quartz on macOS), any window, top-level or child.
-- place_rect(hwnd, l, t, w, h) moves a window to a y-down rect; monitor_of_quartz(), viewport_quartz() and
-- monitors() answer with y-down rects. Lua 5.4; nothing here crashes when an extension is missing: every accessor
-- checks the capability first.
--
-- Screen coordinates (failures.md W1, X1, X7; measured 2026-10-02 on a Mac with three displays):
--   Windows / Linux: one system, y down from the top of the primary display, shared by the OS, js_ReaScriptAPI and
--     ImGui. Every conversion below is the identity there (M.is_mac false): the same numbers as before.
--   macOS has two:
--     Cocoa  - y UP from the bottom of the main display (the one whose frame starts at 0,0). SWELL hands these to
--              scripts: JS_Window_GetRect of top-level AND child windows (once rect() sorted the pair, t is the
--              window's BOTTOM edge), JS_Window_SetPosition (its y is the window's bottom edge), my_getViewport
--              (the query rect and the answer).
--     Quartz - y DOWN from the top of the main display: ImGui window positions (SetNextWindowPos, GetWindowPos,
--              app.place_window, the HUD bar rect), the OS window lists, screencapture -R, CGEvent mouse points.
--   quartz_y = main_h - cocoa_y for a point (main_h = the main display's height); a rect whose bottom edge sits at
--   Cocoa y with height h has its top at Quartz main_h - y - h, and back with the same formula. The two agree only
--   for a window spanning the main display's full height, which is what every macOS run before 2026-10-02 used.
-- Stagehand's own numbers (overview geometry and RECT reply, recorder layout and hud file, ctl replies) are y down
-- (Quartz) on every platform; native values stay inside the journal's window_rect entries.

local M = {}

local os_name = reaper.GetOS()
M.is_mac = os_name:find('OSX') ~= nil or os_name:find('macOS') ~= nil
M.is_win = os_name:find('Win') ~= nil
M.is_linux = not M.is_mac and not M.is_win

local function has(name)
  return reaper.APIExists(name)
end

function M.probe()
  local caps = {}
  caps.js = has('JS_ReaScriptAPI_Version')
  caps.js_version = caps.js and reaper.JS_ReaScriptAPI_Version() or nil
  caps.window_rects = caps.js and has('JS_Window_GetRect') and has('JS_Window_FindChildByID')
    and has('JS_Window_GetClientSize') and has('JS_Window_GetClientRect')
  caps.window_move = caps.js and has('JS_Window_SetPosition')
  caps.scroll = caps.js and has('JS_Window_GetScrollInfo') and has('JS_Window_SetScrollPos')
  caps.lice = caps.js and has('JS_LICE_CreateBitmap') and has('JS_LICE_FillRect') and has('JS_LICE_GradRect')
    and has('JS_LICE_Clear') and has('JS_LICE_DestroyBitmap')
  caps.composite = caps.lice and has('JS_Composite') and has('JS_Composite_Unlink')
    and has('JS_Window_InvalidateRect')
  caps.viewport = has('my_getViewport')
  caps.sws = has('CF_GetSWSVersion')
  caps.sws_version = caps.sws and reaper.CF_GetSWSVersion() or nil
  caps.dock_api = has('DockGetPosition') and has('GetConfigWantsDock') and has('Dock_UpdateDockID')
  caps.action_options = has('set_action_options')
  M.caps = caps
  return caps
end

function M.main_hwnd()
  return reaper.GetMainHwnd()
end

function M.arrange_hwnd()
  if not (M.caps and M.caps.window_rects) then return nil end
  return reaper.JS_Window_FindChildByID(reaper.GetMainHwnd(), 1000)
end

-- a window's rect in NATIVE coordinates (on macOS Cocoa: t is the bottom edge), sorted so t < b
function M.rect(hwnd)
  if not hwnd or not (M.caps and M.caps.window_rects) then return nil end
  local ok, l, t, r, b = reaper.JS_Window_GetRect(hwnd)
  if not ok then return nil end
  if t > b then t, b = b, t end
  return l, t, r, b
end

-- every monitor the API can reach in NATIVE coordinates (work area l, t, r, b, w, h and the full display in full):
-- a grid of points around the main window is probed in my_getViewport's own coordinates and the distinct rects
-- kept; the first entry is the monitor holding the main window. nil without the API.
function M.monitors_native()
  if not (M.caps and M.caps.viewport) then return nil end
  local l, t, r, b = M.rect(reaper.GetMainHwnd())
  if not l then l, t, r, b = 0, 0, 100, 100 end
  local out, seen = {}, {}
  local function consider(x, y)
    local ml, mt, mr, mb = reaper.my_getViewport(0, 0, 0, 0, x, y, x + 8, y + 8, true)
    if not ml or not mr or mr - ml < 200 or mb - mt < 200 then return end
    local key = string.format('%d,%d,%d,%d', ml, mt, mr, mb)
    if seen[key] then return end
    seen[key] = true
    local fl, ft, fr, fb = reaper.my_getViewport(0, 0, 0, 0, x, y, x + 8, y + 8, false)
    out[#out + 1] = { l = ml, t = mt, r = mr, b = mb, w = mr - ml, h = mb - mt, full = { fl, ft, fr, fb } }
  end
  consider((l + r) // 2, (t + b) // 2)
  for x = l - 3200, r + 3200, 320 do
    for y = t - 2000, b + 2000, 320 do consider(x, y) end
  end
  return out
end

-- the main display's height: what every Cocoa <-> Quartz flip goes through. The main display's frame starts at 0,0
-- (Cocoa) and my_getViewport answers it for a point on it. nil without the API.
function M.main_h()
  if not reaper.my_getViewport then return nil end
  local l, t, r, b = reaper.my_getViewport(0, 0, 0, 0, 1, 1, 2, 2, false)
  if not l or not t or not r or not b then return nil end
  if t > b then t, b = b, t end
  if l == 0 and t == 0 and b > 0 then return b end
  -- the answer does not start at 0,0: look for the display that does
  for _, m in ipairs(M.monitors_native() or {}) do
    local f = m.full
    if f[1] == 0 and f[2] == 0 and f[4] and f[4] > 0 then return f[4] end
  end
  return b - t
end

-- Quartz top of a rect whose Cocoa bottom edge is y_bottom (h = 0 or nil for a point); identity off macOS
function M.cocoa_to_quartz_y(y_bottom, h, main_h)
  if not M.is_mac or not y_bottom then return y_bottom end
  main_h = main_h or M.main_h()
  if not main_h then return y_bottom end
  return main_h - y_bottom - (h or 0)
end

-- Cocoa bottom edge of a rect whose Quartz top is y_top (h = 0 or nil for a point); identity off macOS (the flip is
-- its own inverse)
function M.quartz_to_cocoa_y(y_top, h, main_h)
  return M.cocoa_to_quartz_y(y_top, h, main_h)
end

-- a native rect (l, t, r, b with t < b) as a y-down rect; identity off macOS
function M.to_quartz(l, t, r, b, main_h)
  if not M.is_mac or not l or not t or not b then return l, t, r, b end
  main_h = main_h or M.main_h()
  if not main_h then return l, t, r, b end
  return l, main_h - b, r, main_h - t
end

-- a y-down rect as a native one (the same flip)
function M.from_quartz(l, t, r, b, main_h)
  return M.to_quartz(l, t, r, b, main_h)
end

-- any window's rect, top-level or child, in screen px, y down (Quartz on macOS)
function M.screen_rect(hwnd)
  return M.to_quartz(M.rect(hwnd))
end

-- a CHILD window's rect, y down on every platform (X1). SWELL reports child rects in the same screen coordinates as
-- top-level ones (Cocoa on macOS), so this is screen_rect(); the earlier flip through the main window's own rect was
-- right only for a main window spanning the main display's full height (X7)
function M.child_rect(hwnd)
  return M.screen_rect(hwnd)
end

-- a y that SWELL reports in screen coordinates (a child-window rect edge) as a y-down screen y
function M.child_y(y)
  return M.cocoa_to_quartz_y(y, 0)
end

-- work area (or full monitor) containing a NATIVE rect, as a native rect; nil without the API
function M.monitor_of(x1, y1, x2, y2, work_area)
  if not (M.caps and M.caps.viewport) then return nil end
  local l, t, r, b = reaper.my_getViewport(0, 0, 0, 0, x1, y1, x2, y2, work_area ~= false)
  return l, t, r, b
end

-- work area (work_area ~= false) or full display under a y-down rect, as a y-down rect: the rect goes to
-- my_getViewport in its own (Cocoa) coordinates and the answer comes back flipped. nil without the API.
function M.monitor_of_quartz(x1, y1, x2, y2, work_area)
  if not (M.caps and M.caps.viewport) then return nil end
  local mh = M.is_mac and M.main_h() or nil
  local nl, nt, nr, nb = M.from_quartz(x1, y1, x2, y2, mh)
  local l, t, r, b = M.monitor_of(nl, nt, nr, nb, work_area)
  if not l or not t or not b then return nil end
  if t > b then t, b = b, t end
  return M.to_quartz(l, t, r, b, mh)
end

-- the display (work area by default) under a y-down point, as a y-down rect. On macOS the query is 2 px tall below
-- the point: flipped to Cocoa its centre is the point's own pixel row (a 1 px rect on a display's top row would
-- centre on the boundary and land on the display above).
function M.viewport_quartz(x, y, work_area)
  x, y = math.floor(x), math.floor(y)
  return M.monitor_of_quartz(x, y, x + 1, y + (M.is_mac and 2 or 1), work_area)
end

-- every monitor as y-down rects (Quartz on macOS): { l, t, r, b, w, h, full = { l, t, r, b }, native = { l, t, r, b },
-- native_full = { l, t, r, b } }; the first entry holds the main window. nil without the API.
function M.monitors()
  local list = M.monitors_native()
  if not list then return nil end
  local mh = M.is_mac and M.main_h() or nil
  local out = {}
  for _, m in ipairs(list) do
    local l, t, r, b = M.to_quartz(m.l, m.t, m.r, m.b, mh)
    local fl, ft, fr, fb = M.to_quartz(m.full[1], m.full[2], m.full[3], m.full[4], mh)
    out[#out + 1] = { l = l, t = t, r = r, b = b, w = r - l, h = b - t, full = { fl, ft, fr, fb },
      native = { m.l, m.t, m.r, m.b }, native_full = m.full }
  end
  return out
end

-- a top-level window by title: one title (exact) or a list of candidates (exact first, then a prefix match)
function M.find_window(titles, exact_only)
  if not (M.caps and M.caps.js and reaper.JS_Window_Find) then return nil end
  if type(titles) == 'string' then titles = { titles } end
  for _, name in ipairs(titles) do
    local h = reaper.JS_Window_Find(name, true)
    if h then return h end
  end
  if exact_only then return nil end
  for _, name in ipairs(titles) do
    local h = reaper.JS_Window_Find(name, false)
    if h then return h end
  end
  return nil
end

M.VIDEO_TITLES = { 'Video Window', 'Video window', 'Okno wideo', 'Videofenster', 'Fenetre video' }

function M.find_video_window()
  return M.find_window(M.VIDEO_TITLES)
end

-- move a window in NATIVE coordinates (JS_Window_SetPosition: on macOS y is the window's Cocoa bottom edge); the
-- journal's window_rect restorer and set_rect(rect()) round trips stay in these
function M.set_rect(hwnd, l, t, w, h)
  if not (hwnd and M.caps and M.caps.window_move) then return false end
  reaper.JS_Window_SetPosition(hwnd, math.floor(l), math.floor(t), math.floor(w), math.floor(h))
  return true
end

-- move a window to a y-down rect (top-left l, t and the size; Quartz on macOS)
function M.place_rect(hwnd, l, t, w, h)
  if not t or not h then return false end
  return M.set_rect(hwnd, l, M.quartz_to_cocoa_y(t, h), w, h)
end

-- one line of coordinate facts for logs and self-tests: the main display's height and the main window natively and
-- y down (on Windows / Linux both rects are the same numbers)
function M.coords_fact()
  local mh = M.main_h()
  local l, t, r, b = M.rect(reaper.GetMainHwnd())
  if not l then return string.format('mac=%s main_h=%s main=unreadable', tostring(M.is_mac), tostring(mh)) end
  local ql, qt, qr, qb = M.to_quartz(l, t, r, b, mh)
  return string.format('mac=%s main_h=%s main_native=%d,%d-%d,%d main_quartz=%d,%d-%d,%d', tostring(M.is_mac), tostring(mh),
    l, t, r, b, ql, qt, qr, qb)
end

-- one line per capability for logs and the about panel
function M.describe(caps)
  caps = caps or M.caps or M.probe()
  local rows = {
    { 'js_ReaScriptAPI', caps.js and ('yes (' .. tostring(caps.js_version) .. ')') or 'no' },
    { 'window rects / move', (caps.window_rects and 'yes' or 'no') .. ' / ' .. (caps.window_move and 'yes' or 'no') },
    { 'arrange scrolling', caps.scroll and 'yes' or 'no' },
    { 'LICE + composite (glow)', caps.composite and 'yes' or 'no' },
    { 'monitor query', caps.viewport and 'yes' or 'no' },
    { 'SWS', caps.sws and ('yes (' .. tostring(caps.sws_version) .. ')') or 'no' },
    { 'docker API', caps.dock_api and 'yes' or 'no' },
  }
  return rows
end

return M
