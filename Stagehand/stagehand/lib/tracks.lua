-- lib/tracks.lua - track tree scan and the few track operations the navigator needs. Lua 5.4, no globals.
--
-- scan() -> list of { tr, guid, name, depth, folder, parent (index in the list or nil), n (1-based track
-- number), items (count), color (native colour or 0) }. Depth follows I_FOLDERDEPTH (1 opens, < 0 closes that
-- many levels); the parent stack gives every track its parent so ancestors can be found without re-walking.

local M = {}

function M.valid(tr)
  return tr ~= nil and reaper.ValidatePtr2(0, tr, 'MediaTrack*')
end

function M.name(tr)
  local _, name = reaper.GetTrackName(tr)
  return name or ''
end

function M.scan()
  local list = {}
  local stack = {}
  local n = reaper.CountTracks(0)
  for k = 0, n - 1 do
    local tr = reaper.GetTrack(0, k)
    local fd = reaper.GetMediaTrackInfo_Value(tr, 'I_FOLDERDEPTH')
    local entry = {
      tr = tr, guid = reaper.GetTrackGUID(tr), name = M.name(tr), depth = #stack, folder = fd == 1,
      parent = stack[#stack], n = k + 1, items = reaper.CountTrackMediaItems(tr),
      color = reaper.GetMediaTrackInfo_Value(tr, 'I_CUSTOMCOLOR'),
    }
    list[#list + 1] = entry
    if fd == 1 then
      stack[#stack + 1] = #list
    elseif fd < 0 then
      for _ = 1, -fd do stack[#stack] = nil end
    end
  end
  return list
end

-- the top-level ancestor entry of a track entry (itself when at depth 0)
function M.top(list, k)
  local e = list[k]
  while e.parent do e = list[e.parent] end
  return e
end

function M.has_items_in(tr, t0, t1)
  for j = 0, reaper.CountTrackMediaItems(tr) - 1 do
    local it = reaper.GetTrackMediaItem(tr, j)
    local p = reaper.GetMediaItemInfo_Value(it, 'D_POSITION')
    local e = p + reaper.GetMediaItemInfo_Value(it, 'D_LENGTH')
    if p < t1 and e > t0 then return true end
  end
  return false
end

-- mark[k] = true for every ancestor of every marked track (folders stay open around their content)
function M.mark_ancestors(list, mark)
  for k, e in ipairs(list) do
    if mark[k] then
      local p = e.parent
      while p and not mark[p] do
        mark[p] = true
        p = list[p].parent
      end
    end
  end
  return mark
end

function M.find_guid(guid)
  for k = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, k)
    if reaper.GetTrackGUID(tr) == guid then return tr end
  end
  return nil
end

-- GUID -> MediaTrack for every track (one pass; use for many lookups at once)
function M.guid_map()
  local map = {}
  for k = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, k)
    map[reaper.GetTrackGUID(tr)] = tr
  end
  return map
end

function M.get(tr, key)
  return reaper.GetMediaTrackInfo_Value(tr, key)
end

function M.set(tr, key, value)
  reaper.SetMediaTrackInfo_Value(tr, key, value)
end

function M.adjust()
  reaper.TrackList_AdjustWindows(false)
  reaper.UpdateArrange()
end

return M
