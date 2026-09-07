-- lib/regions.lua - scenes (regions) and markers from the project, with marker classes. Lua 5.4, no globals.
--
-- scan(classes) -> scenes, markers. scenes: { t0, t1, name, idx, color, items = 0 } sorted by time; a region
-- without a name is called "Region <idx>". markers: { t0, t1 (start of the next marker, or t0 + last_len),
-- name, idx, color, class = <class table or nil> } sorted by time; unnamed markers are kept with "Marker <idx>".
-- classes: list of { name, color, rule } evaluated in order with lib/match; the first hit wins.

local match = require('lib.match')

local M = {}

function M.compile_classes(classes)
  local out = {}
  for _, c in ipairs(classes or {}) do
    out[#out + 1] = { name = c.name, color = c.color, test = match.compile(c.rule) }
  end
  return out
end

function M.classify(compiled, name)
  for _, c in ipairs(compiled) do
    if c.test(name) then return c end
  end
  return nil
end

function M.scan(compiled_classes, last_len)
  local scenes, markers = {}, {}
  local i = 0
  while true do
    local ret, isrgn, pos, rend, name, idx, color = reaper.EnumProjectMarkers3(0, i)
    if ret == 0 then break end
    i = i + 1
    if isrgn then
      scenes[#scenes + 1] = { t0 = pos, t1 = rend, name = name ~= '' and name or ('Region ' .. idx), idx = idx,
        color = color, items = 0 }
    else
      markers[#markers + 1] = { t0 = pos, name = name ~= '' and name or ('Marker ' .. idx), idx = idx, color = color,
        class = compiled_classes and M.classify(compiled_classes, name) or nil }
    end
  end
  table.sort(scenes, function(a, b) if a.t0 ~= b.t0 then return a.t0 < b.t0 end return a.t1 < b.t1 end)
  table.sort(markers, function(a, b) if a.t0 ~= b.t0 then return a.t0 < b.t0 end return a.idx < b.idx end)
  for k, m in ipairs(markers) do
    m.t1 = markers[k + 1] and markers[k + 1].t0 or (m.t0 + (last_len or 5))
  end
  return scenes, markers
end

-- the shortest scene containing t (nested regions: the inner one wins)
function M.scene_at(scenes, t)
  local best
  for _, s in ipairs(scenes) do
    if t >= s.t0 and t < s.t1 and (not best or (s.t1 - s.t0) < (best.t1 - best.t0)) then best = s end
  end
  return best
end

function M.count_items(scenes)
  for _, s in ipairs(scenes) do s.items = 0 end
  for k = 0, reaper.CountMediaItems(0) - 1 do
    local it = reaper.GetMediaItem(0, k)
    local p = reaper.GetMediaItemInfo_Value(it, 'D_POSITION')
    local e = p + reaper.GetMediaItemInfo_Value(it, 'D_LENGTH')
    for _, s in ipairs(scenes) do
      if p < s.t1 and e > s.t0 then s.items = s.items + 1 end
    end
  end
end

return M
