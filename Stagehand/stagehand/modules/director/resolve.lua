-- modules/director/resolve.lua - from rules to tracks: which tracks are a shot's lanes, which rows are pinned,
-- which ancestors stay visible as parents, which envelope lanes the story shows.
--
-- lanes(shot, tracks) -> set { [k] = true }, counts (per lane rule: number of tracks it resolved to)
-- roles(shot, tracks, opts) -> role[k] = 'keep' | 'lane' | 'parent', keep_h[k], uncollapse[k], counts
-- envelopes(shot, tracks) -> want[k] = list of { env, guid, name, want }, shown (total), counts (per rule)
-- tracks = lib/tracks.scan() with .fam assigned (lib/families). Lua 5.4; no globals.

local match = require('lib.match')
local tracks = require('lib.tracks')
local envelopes = require('lib.envelopes')

local R = {}

local function lane_pred(l)
  if l.kind == 'items' then
    return function(e, shot) return e.items > 0 and (not l.family or e.fam == l.family) and tracks.has_items_in(e.tr, shot.t0, shot.t1) end
  elseif l.kind == 'family' then
    return function(e) return not e.folder and e.fam == l.name end
  elseif l.kind == 'rule' then
    local test = match.compile(l.rule)
    return function(e) return test(e.name) end
  elseif l.kind == 'track' then
    return function(e) return (l.guid and e.guid == l.guid) or (not l.guid and e.name == l.name) end
  end
  return function() return false end
end

function R.lanes(shot, list)
  local set, counts = {}, {}
  for i, l in ipairs(shot.lanes or {}) do
    local pred = lane_pred(l)
    local n = 0
    for k, e in ipairs(list) do
      if pred(e, shot) then
        if not set[k] then set[k] = true end
        n = n + 1
      end
    end
    -- a track rule that lost its GUID (copied project) falls back to the name
    if n == 0 and l.kind == 'track' and l.guid and l.name ~= '' then
      for k, e in ipairs(list) do
        if e.name == l.name then set[k] = true; n = n + 1 end
      end
    end
    counts[i] = n
  end
  return set, counts
end

-- pins: list of { rule, height_px }; the first pin rule that matches a track gives it the keep height
function R.pins(pins, list)
  local keep = {}
  for _, p in ipairs(pins or {}) do
    local test = match.compile(p.rule)
    local h = math.max(8, math.floor(tonumber(p.height_px) or 50))
    for k, e in ipairs(list) do
      if not keep[k] and test(e.name) then keep[k] = h end
    end
  end
  return keep
end

-- opts = { pins = list, parents = 'none' | 'bus' | 'all', pin_enable = bool }
function R.roles(shot, list, opts)
  opts = opts or {}
  local role, keep_h, uncollapse = {}, {}, {}
  local counts = { lanes = 0, parents = 0, keeps = 0 }
  if opts.pin_enable ~= false then
    for k, h in pairs(R.pins(opts.pins, list)) do
      role[k] = 'keep'
      keep_h[k] = h
      counts.keeps = counts.keeps + 1
    end
  end
  local set, lane_counts = R.lanes(shot, list)
  for k in pairs(set) do
    if not role[k] then
      role[k] = 'lane'
      counts.lanes = counts.lanes + 1
    end
  end
  local mode = opts.parents or 'none'
  local base = {}
  for k in pairs(role) do base[#base + 1] = k end
  for _, k in ipairs(base) do
    local p = list[k].parent
    while p do
      uncollapse[p] = true
      if not role[p] and mode ~= 'none' and (mode == 'all' or list[p].depth == 0) then
        role[p] = 'parent'
        counts.parents = counts.parents + 1
      end
      p = list[p].parent
    end
  end
  return role, keep_h, uncollapse, counts, lane_counts
end

-- every track envelope with the story's verdict for this shot
function R.envelopes(shot, list)
  local rules = {}
  for i, r in ipairs(shot.envelopes or {}) do
    rules[i] = { track = match.compile(r.track), env = match.compile(r.env), n = 0 }
  end
  local want, shown = {}, 0
  for k, e in ipairs(list) do
    local n_env = reaper.CountTrackEnvelopes(e.tr)
    if n_env > 0 then
      local rows = {}
      for _, ev in ipairs(envelopes.scan(e.tr)) do
        local on = false
        for _, r in ipairs(rules) do
          if r.track(e.name) and r.env(ev.name) then
            on = true
            r.n = r.n + 1
          end
        end
        rows[#rows + 1] = { env = ev.env, guid = ev.guid, name = ev.name, want = on }
        if on then shown = shown + 1 end
      end
      want[k] = rows
    end
  end
  local counts = {}
  for i, r in ipairs(rules) do counts[i] = r.n end
  return want, shown, counts
end

-- tracks that have items in the shot but are not shown (validation: "plays but is not on screen")
function R.playing_hidden(shot, list, role)
  local out = {}
  for k, e in ipairs(list) do
    if not role[k] and e.items > 0 and tracks.has_items_in(e.tr, shot.t0, shot.t1) then out[#out + 1] = e end
  end
  return out
end

return R
