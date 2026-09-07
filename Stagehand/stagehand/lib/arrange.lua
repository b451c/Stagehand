-- lib/arrange.lua - arrange-window geometry and scrolling for the layout push (docs/research/mechanisms.md 2.3-2.7).
--
-- height() -> H, exact: the arrange client height (js_ReaScriptAPI, minus the master row when it sits in the
-- TCP) or the configured fallback. scroll_top / scroll_to_track use JS_Window_SetScrollPos when available and
-- REAPER actions otherwise. bottom() measures where the last role track really ends (I_TCPY + I_WNDH): real
-- heights exist only after REAPER laid the list out, so the caller reads it in a later frame (verify pass).
-- Lua 5.4; nothing here crashes without the extension.

local js = require('platform.js')
local view = require('lib.view')

local M = {}

local ARRANGE_ID = 1000

function M.hwnd()
  if not (js.caps and js.caps.window_rects) then return nil end
  return reaper.JS_Window_FindChildByID(reaper.GetMainHwnd(), ARRANGE_ID)
end

-- H in px and whether it was measured (true) or taken from the fallback (false)
function M.height(fallback)
  local hw = M.hwnd()
  if hw then
    local ok, _, h = reaper.JS_Window_GetClientSize(hw)
    if ok and h and h > 100 then
      if reaper.GetMasterTrackVisibility() & 1 == 1 then
        h = h - reaper.GetMediaTrackInfo_Value(reaper.GetMasterTrack(0), 'I_WNDH')
      end
      return math.floor(h), true
    end
  end
  return math.floor(fallback or 760), false
end

function M.client_size()
  local hw = M.hwnd()
  if not hw then return nil end
  local ok, w, h = reaper.JS_Window_GetClientSize(hw)
  if not ok then return nil end
  return w, h
end

function M.can_scroll()
  return js.caps ~= nil and js.caps.scroll == true and M.hwnd() ~= nil
end

-- vertical scroll position in px, or nil without the extension
function M.scroll_pos()
  if not M.can_scroll() then return nil end
  local ok, pos = reaper.JS_Window_GetScrollInfo(M.hwnd(), 'v')
  if not ok then return nil end
  return pos
end

function M.set_scroll_pos(pos)
  if not M.can_scroll() then return false end
  reaper.JS_Window_SetScrollPos(M.hwnd(), 'v', math.max(0, math.floor(pos or 0)))
  return true
end

function M.scroll_top()
  if M.can_scroll() then
    reaper.JS_Window_SetScrollPos(M.hwnd(), 'v', 0)
  else
    reaper.CSurf_OnScroll(0, -100000)
  end
end

-- put a track's row right under `offset` px (the pinned rows); two passes because pinned rows shift I_TCPY
function M.scroll_to_track(tr, offset)
  offset = offset or 0
  if M.can_scroll() then
    local hw = M.hwnd()
    local _, pos = reaper.JS_Window_GetScrollInfo(hw, 'v')
    local y = reaper.GetMediaTrackInfo_Value(tr, 'I_TCPY')
    reaper.JS_Window_SetScrollPos(hw, 'v', math.max(0, (pos or 0) + y - offset))
    local y2 = reaper.GetMediaTrackInfo_Value(tr, 'I_TCPY')
    if math.abs(y2 - offset) > 4 then
      local _, pos2 = reaper.JS_Window_GetScrollInfo(hw, 'v')
      reaper.JS_Window_SetScrollPos(hw, 'v', math.max(0, (pos2 or 0) + y2 - offset))
    end
  else
    view.scroll_track_into_view(tr)
  end
end

-- extra height under a visible track row: its visible envelope lanes (I_WNDH - I_TCPH)
function M.extra_of(tr)
  local wh = reaper.GetMediaTrackInfo_Value(tr, 'I_WNDH')
  local th = reaper.GetMediaTrackInfo_Value(tr, 'I_TCPH')
  return math.max(0, math.floor(wh - th))
end

function M.row_height(tr)
  return math.floor(reaper.GetMediaTrackInfo_Value(tr, 'I_TCPH'))
end

-- the lowest bottom edge over the tracks accepted by pred(k, entry): max(I_TCPY + I_WNDH)
function M.bottom(list, pred)
  local bottom = 0
  for k, e in ipairs(list) do
    if not pred or pred(k, e) then
      local y = reaper.GetMediaTrackInfo_Value(e.tr, 'I_TCPY')
      local wh = reaper.GetMediaTrackInfo_Value(e.tr, 'I_WNDH')
      if y + wh > bottom then bottom = y + wh end
    end
  end
  return math.floor(bottom)
end

return M
