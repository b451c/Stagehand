-- lib/view.lua - arrange view and transport helpers: zoom to a range, jump, select and scroll a track into view.
-- Every action Stagehand runs is looked up by name first (invariant 3); a mismatch is logged and the action
-- skipped. Lua 5.4, no globals.

local log = require('lib.log')

local M = {}

local SCROLL_TRACK_CMD = 40913   -- "Track: Vertical scroll selected tracks into view"
local scroll_cmd_checked = nil

local function scroll_cmd()
  if scroll_cmd_checked == nil then
    local name = reaper.kbd_getTextFromCmd(SCROLL_TRACK_CMD, 0) or ''
    scroll_cmd_checked = name:lower():find('scroll', 1, true) ~= nil and name:lower():find('track', 1, true) ~= nil
    if not scroll_cmd_checked then
      log.warn('action %d is "%s", not the vertical scroll action; track scrolling disabled', SCROLL_TRACK_CMD, name)
    end
  end
  return scroll_cmd_checked and SCROLL_TRACK_CMD or nil
end

function M.get()
  local v0, v1 = reaper.GetSet_ArrangeView2(0, false, 0, 0, 0, 0)
  return v0, v1
end

function M.set(v0, v1)
  reaper.GetSet_ArrangeView2(0, true, 0, 0, math.max(0, v0), math.max(v1, v0 + 0.01))
end

-- pad = max(pad_min, pad_frac * length) on both sides
function M.zoom_to(t0, t1, pad_min, pad_frac)
  local len = math.max(0, t1 - t0)
  local pad = math.max(pad_min or 0.3, len * (pad_frac or 0.06))
  M.set(t0 - pad, t1 + pad)
end

function M.cursor()
  return reaper.GetCursorPosition()
end

function M.playing()
  return reaper.GetPlayState() & 1 == 1
end

-- the position the user is looking at: play position while playing, else the edit cursor
function M.position()
  if M.playing() then return reaper.GetPlayPosition() end
  return reaper.GetCursorPosition()
end

function M.set_cursor(t, seek)
  reaper.SetEditCurPos2(0, t, false, seek == true)
end

function M.get_time_selection()
  local a, b = reaper.GetSet_LoopTimeRange2(0, false, false, 0, 0, false)
  return a, b
end

function M.set_time_selection(t0, t1)
  reaper.GetSet_LoopTimeRange2(0, true, false, t0, t1, false)
end

function M.get_loop_range()
  local a, b = reaper.GetSet_LoopTimeRange2(0, false, true, 0, 0, false)
  return a, b
end

function M.set_loop_range(t0, t1)
  reaper.GetSet_LoopTimeRange2(0, true, true, t0, t1, false)
end

function M.select_track(tr)
  reaper.SetOnlyTrackSelected(tr)
end

function M.scroll_track_into_view(tr)
  reaper.SetOnlyTrackSelected(tr)
  reaper.TrackList_AdjustWindows(false)
  local cmd = scroll_cmd()
  if cmd then reaper.Main_OnCommand(cmd, 0) end
end

function M.select_item(it)
  reaper.SelectAllMediaItems(0, false)
  reaper.SetMediaItemSelected(it, true)
end

-- toggle actions verified by name (invariant 3): state(cmd, word) -> 0/1, or -1 when the action's name does not
-- contain `word` (never toggle a command we cannot name); set_toggle(cmd, word, on) -> true when it was toggled
function M.toggle_state(cmd, word)
  local name = (reaper.kbd_getTextFromCmd(cmd, 0) or ''):lower()
  if word and not name:find(tostring(word):lower(), 1, true) then
    log.warn('action %d is "%s", not the expected toggle (%s)', cmd, name, tostring(word))
    return -1
  end
  return reaper.GetToggleCommandState(cmd)
end

function M.set_toggle(cmd, word, on)
  local cur = M.toggle_state(cmd, word)
  if cur < 0 then return false end
  if cur ~= (on and 1 or 0) then
    reaper.Main_OnCommand(cmd, 0)
    return true
  end
  return false
end

-- run fn between PreventUIRefresh(1)/(-1) and refresh once
function M.batch(fn, ...)
  reaper.PreventUIRefresh(1)
  local ok, err = pcall(fn, ...)
  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  if not ok then error(err, 0) end
end

return M
