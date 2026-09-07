-- lib/items.lua - item helpers: items overlapping a range, labels, GUID lookup. Lua 5.4, no globals.

local text = require('lib.text')

local M = {}

function M.valid(it)
  return it ~= nil and reaper.ValidatePtr2(0, it, 'MediaItem*')
end

function M.guid(it)
  local _, g = reaper.GetSetMediaItemInfo_String(it, 'GUID', '', false)
  return g or ''
end

-- active take name, else the first line of the item notes, else nil
function M.label(it)
  local take = reaper.GetActiveTake(it)
  local name = take and reaper.GetTakeName(take) or ''
  if name ~= '' then return name end
  local _, notes = reaper.GetSetMediaItemInfo_String(it, 'P_NOTES', '', false)
  name = text.first_line(notes)
  if name ~= '' then return name end
  return nil
end

-- items of one track overlapping [t0, t1): list of { it, t0, t1 }
function M.in_range(tr, t0, t1)
  local out = {}
  for j = 0, reaper.CountTrackMediaItems(tr) - 1 do
    local it = reaper.GetTrackMediaItem(tr, j)
    local p = reaper.GetMediaItemInfo_Value(it, 'D_POSITION')
    local e = p + reaper.GetMediaItemInfo_Value(it, 'D_LENGTH')
    if p < t1 and e > t0 then out[#out + 1] = { it = it, t0 = p, t1 = e } end
  end
  return out
end

function M.find_guid(guid)
  for k = 0, reaper.CountMediaItems(0) - 1 do
    local it = reaper.GetMediaItem(0, k)
    if M.guid(it) == guid then return it end
  end
  return nil
end

-- GUID -> MediaItem for every item (one pass; use for many lookups at once)
function M.guid_map()
  local map = {}
  for k = 0, reaper.CountMediaItems(0) - 1 do
    local it = reaper.GetMediaItem(0, k)
    map[M.guid(it)] = it
  end
  return map
end

function M.get(it, key)
  return reaper.GetMediaItemInfo_Value(it, key)
end

function M.set(it, key, value)
  reaper.SetMediaItemInfo_Value(it, key, value)
end

return M
