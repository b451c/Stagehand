-- modules/director/model.lua - the shot list: shots, their lane and envelope rules, persistence per project.
--
-- shot = { name, t0, t1, caption, caption2, lanes = { lane... }, envelopes = { { track, env }... },
--          view = nil | 'page' | 'follow', parents = nil | 'none' | 'bus' | 'all', pad_before, pad_after }
-- lane = { kind = 'items', family = nil | name }        tracks with items in the shot range (optionally one family)
--      | { kind = 'family', name = family name }        every non-folder track of that family
--      | { kind = 'rule', rule = 'DX|=MUSIC|^Score' }   lib/match rule on the track name
--      | { kind = 'track', guid = ..., name = ... }     one track picked from the tree (re-found by GUID, then by name)
-- Envelope rules use the same rule syntax on the track name and on the envelope name.
-- Stored in the project (ProjExtState 'director.shots'); nothing is written to disk until the user saves.
-- Lua 5.4; no globals.

local state = require('state')
local text = require('lib.text')

local MD = { shots = {}, loaded_for = nil }

MD.KINDS = { 'items', 'family', 'rule', 'track' }
MD.VIEWS = { 'page', 'follow' }
MD.PARENTS = { 'none', 'bus', 'all' }

local KEY = 'director.shots'

local function num(v, default)
  v = tonumber(v)
  if v == nil then return default end
  return v
end

local function sanitize_lane(l)
  if type(l) ~= 'table' then return nil end
  local kind = l.kind
  if kind == 'items' then
    return { kind = 'items', family = (l.family and l.family ~= '') and tostring(l.family) or nil }
  elseif kind == 'family' then
    if not l.name or l.name == '' then return nil end
    return { kind = 'family', name = tostring(l.name) }
  elseif kind == 'rule' then
    return { kind = 'rule', rule = tostring(l.rule or '') }
  elseif kind == 'track' then
    if not l.guid and not l.name then return nil end
    return { kind = 'track', guid = l.guid and tostring(l.guid) or nil, name = tostring(l.name or '') }
  end
  return nil
end

function MD.sanitize(s)
  local out = {
    name = text.trim(tostring(s.name or '')),
    t0 = num(s.t0, 0), t1 = num(s.t1, 0),
    caption = tostring(s.caption or ''), caption2 = tostring(s.caption2 or ''),
    lanes = {}, envelopes = {},
    view = (s.view == 'page' or s.view == 'follow') and s.view or nil,
    parents = (s.parents == 'none' or s.parents == 'bus' or s.parents == 'all') and s.parents or nil,
    pad_before = tonumber(s.pad_before), pad_after = tonumber(s.pad_after),
  }
  if out.t1 < out.t0 then out.t0, out.t1 = out.t1, out.t0 end
  for _, l in ipairs(s.lanes or {}) do
    local c = sanitize_lane(l)
    if c then out.lanes[#out.lanes + 1] = c end
  end
  for _, e in ipairs(s.envelopes or {}) do
    if type(e) == 'table' then
      out.envelopes[#out.envelopes + 1] = { track = tostring(e.track or ''), env = tostring(e.env or '') }
    end
  end
  return out
end

function MD.new_shot(o)
  o = o or {}
  local s = MD.sanitize(o)
  if #s.lanes == 0 and not o.no_default_lane then s.lanes = { { kind = 'items' } } end
  return s
end

function MD.load()
  local v = state.pget_json(KEY)
  MD.shots = {}
  if type(v) == 'table' then
    for _, s in ipairs(v) do
      if type(s) == 'table' then MD.shots[#MD.shots + 1] = MD.sanitize(s) end
    end
  end
  MD.sort()
  return #MD.shots
end

function MD.save()
  if #MD.shots == 0 then
    state.pset(KEY, '')
  else
    state.pset_json(KEY, MD.shots)
  end
  if MD.on_change then MD.on_change() end
end

function MD.sort()
  table.sort(MD.shots, function(a, b)
    if a.t0 ~= b.t0 then return a.t0 < b.t0 end
    return a.t1 < b.t1
  end)
end

function MD.index_of(shot)
  for k, s in ipairs(MD.shots) do
    if s == shot then return k end
  end
  return nil
end

-- returns the index the shot landed on after sorting
function MD.add(shot)
  MD.shots[#MD.shots + 1] = shot
  MD.sort()
  MD.save()
  return MD.index_of(shot)
end

function MD.replace(k, shot)
  MD.shots[k] = shot
  MD.sort()
  MD.save()
  return MD.index_of(shot)
end

function MD.remove(k)
  table.remove(MD.shots, k)
  MD.save()
end

function MD.clear()
  MD.shots = {}
  MD.save()
end

local function deep_copy(v)
  if type(v) ~= 'table' then return v end
  local out = {}
  for k, x in pairs(v) do out[k] = deep_copy(x) end
  return out
end

MD.copy = deep_copy

-- a copy placed right after the original in time (same length)
function MD.duplicate(k)
  local s = MD.shots[k]
  if not s then return nil end
  local c = deep_copy(s)
  local len = s.t1 - s.t0
  c.t0, c.t1 = s.t1, s.t1 + len
  c.name = s.name .. ' copy'
  return MD.add(c)
end

-- the last shot whose start minus lead is at or before pos; the first shot before that (nil without shots)
function MD.shot_at(pos, lead)
  if #MD.shots == 0 then return nil end
  for k = #MD.shots, 1, -1 do
    if pos >= MD.shots[k].t0 - (lead or 0) then return k end
  end
  return 1
end

function MD.length()
  if #MD.shots == 0 then return 0 end
  return MD.shots[#MD.shots].t1
end

-- one shot per scene (region): name and caption from the region, lanes = tracks with items in the range
function MD.from_scenes(scenes)
  local out = {}
  for _, sc in ipairs(scenes or {}) do
    out[#out + 1] = MD.new_shot({ name = sc.name, t0 = sc.t0, t1 = sc.t1, caption = sc.name, lanes = { { kind = 'items' } } })
  end
  return out
end

function MD.lane_label(l)
  if l.kind == 'items' then
    if l.family then return 'items in range: ' .. l.family end
    return 'items in range'
  elseif l.kind == 'family' then return 'family: ' .. tostring(l.name)
  elseif l.kind == 'rule' then return 'rule: ' .. tostring(l.rule)
  elseif l.kind == 'track' then return 'track: ' .. tostring(l.name)
  end
  return '?'
end

function MD.summary(s)
  local parts = { text.plural(#s.lanes, 'lane rule') }
  if #s.envelopes > 0 then parts[#parts + 1] = text.plural(#s.envelopes, 'envelope rule') end
  return table.concat(parts, ', ')
end

return MD
