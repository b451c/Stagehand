-- platform/js.lua - capability probe for the optional extensions and the coordinate helpers every module uses.
--
-- caps = { js = bool, js_version, sws = bool, sws_version, window_rects, scroll, composite, lice, viewport }
-- rect(hwnd) -> l, t, r, b normalised to y-down with top < bottom (js on macOS reports them swapped).
-- child_y(y) -> screen y of a child-window / I_TCPSCREENY value (macOS measures those from the main window's
--               bottom upwards: y_real = main_top + main_bottom - y). Verified on REAPER 7.79 macOS + Linux.
-- Lua 5.4; nothing here crashes when an extension is missing: every accessor checks the capability first.

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

function M.rect(hwnd)
  if not hwnd or not (M.caps and M.caps.window_rects) then return nil end
  local ok, l, t, r, b = reaper.JS_Window_GetRect(hwnd)
  if not ok then return nil end
  if t > b then t, b = b, t end
  return l, t, r, b
end

-- a CHILD window's rect in screen px, y down on every platform: on macOS JS_Window_GetRect measures child windows
-- from the main window's bottom (CLAUDE.md), so the two y values are flipped through the main window's rect
function M.child_rect(hwnd)
  local l, t, r, b = M.rect(hwnd)
  if not l or not M.is_mac then return l, t, r, b end
  local t2, b2 = M.child_y(b), M.child_y(t)
  if t2 > b2 then t2, b2 = b2, t2 end
  return l, t2, r, b2
end

function M.child_y(y)
  if not M.is_mac then return y end
  local l, t, r, b = M.rect(reaper.GetMainHwnd())
  if not l then return y end
  return t + b - y
end

-- work area (or full monitor) containing a rect, on every platform; nil without the API
function M.monitor_of(x1, y1, x2, y2, work_area)
  if not (M.caps and M.caps.viewport) then return nil end
  local l, t, r, b = reaper.my_getViewport(0, 0, 0, 0, x1, y1, x2, y2, work_area ~= false)
  return l, t, r, b
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

-- every monitor the API can reach (work areas): probe a grid of points around the main window and keep the
-- distinct rects; the first entry is the monitor holding the main window. nil without the API.
function M.monitors()
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

function M.set_rect(hwnd, l, t, w, h)
  if not (hwnd and M.caps and M.caps.window_move) then return false end
  reaper.JS_Window_SetPosition(hwnd, math.floor(l), math.floor(t), math.floor(w), math.floor(h))
  return true
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
