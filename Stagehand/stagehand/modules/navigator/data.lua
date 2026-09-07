-- modules/navigator/data.lua - the navigator's project caches: scenes (regions), markers with classes, the track
-- tree with families, items of a scene. Rebuilt when GetProjectStateChangeCount changes; the active scene is
-- re-found by name and start time afterwards (pointers may be stale after an edit). Lua 5.4; no globals.

local tracks = require('lib.tracks')
local items = require('lib.items')
local edits = require('lib.edits')
local regions = require('lib.regions')
local families = require('lib.families')
local view = require('lib.view')
local config = require('config')
local theme = require('ui.theme')

local D = {
  scenes = {}, markers = {}, tracks = {}, families = {}, other = nil, classes = {}, fams = nil,
  items = {}, items_key = nil, state_count = -1, scene = nil,
  family_count = {}, class_count = {}, all_families = {},
}

function D.compile_rules()
  D.fams = families.compile()
  D.families, D.other, D.all_families = D.fams.list, D.fams.other, D.fams.all
  D.classes = regions.compile_classes(config.get('navigator.marker_classes'))
  for _, c in ipairs(D.classes) do c.rgb = theme.parse_hex(c.color) or 0x9AA3B5 end
end

function D.family_color(name)
  for _, f in ipairs(D.all_families) do
    if f.name == name then return f.color end
  end
  return D.other.color
end

function D.refresh()
  D.compile_rules()
  local last_len = config.get('navigator.audition.last_marker_len_s') or 5
  D.scenes, D.markers = regions.scan(D.classes, last_len)
  regions.count_items(D.scenes)
  D.tracks = tracks.scan()
  D.family_count = families.assign(D.fams, D.tracks)
  D.class_count = {}
  for _, m in ipairs(D.markers) do
    local name = m.class and m.class.name or ''
    D.class_count[name] = (D.class_count[name] or 0) + 1
  end
  if D.scene then
    local keep
    for _, s in ipairs(D.scenes) do
      if s.name == D.scene.name and math.abs(s.t0 - D.scene.t0) < 0.5 then keep = s end
    end
    D.scene = keep
  end
  D.items_key = nil
  edits.taken(D)
end

-- true when the project changed since the last refresh (and the caches were rebuilt); a running edit (a drag)
-- is left to settle first (lib/edits)
function D.check_refresh()
  if edits.due(D) then
    D.refresh()
    return true
  end
  return false
end

function D.scene_at_cursor()
  return regions.scene_at(D.scenes, view.position())
end

function D.active_scene()
  return D.scene or D.scene_at_cursor()
end

function D.find_scene(name, t0)
  for _, s in ipairs(D.scenes) do
    if s.name == name and (t0 == nil or math.abs(s.t0 - t0) < 0.5) then return s end
  end
  return nil
end

-- family filter: fam_state[name] == false switches a family off; anything else is on
function D.fam_on(fam_state, name)
  return not fam_state or fam_state[name] ~= false
end

local function fam_signature(fam_state)
  local parts = {}
  for _, f in ipairs(D.all_families) do parts[#parts + 1] = D.fam_on(fam_state, f.name) and '1' or '0' end
  return table.concat(parts)
end

-- track entries with at least one item overlapping [t0, t1), families applied
function D.tracks_in_range(t0, t1, fam_state)
  local out = {}
  for _, e in ipairs(D.tracks) do
    if D.fam_on(fam_state, e.fam) and tracks.has_items_in(e.tr, t0, t1) then out[#out + 1] = e end
  end
  return out
end

-- items overlapping [t0, t1) with families applied: { it, guid, t0, t1, name, track }, sorted by time then track
function D.items_in_range(t0, t1, fam_state)
  local out = {}
  for _, e in ipairs(D.tracks) do
    if D.fam_on(fam_state, e.fam) then
      for _, r in ipairs(items.in_range(e.tr, t0, t1)) do
        out[#out + 1] = { it = r.it, guid = items.guid(r.it), t0 = r.t0, t1 = r.t1, name = items.label(r.it), track = e }
      end
    end
  end
  table.sort(out, function(a, b)
    if a.t0 ~= b.t0 then return a.t0 < b.t0 end
    return a.track.n < b.track.n
  end)
  return out
end

-- the items list of a scene (cached per scene + family filter until the next refresh)
function D.build_items(scene, fam_state)
  if not scene then
    D.items, D.items_key = {}, nil
    return D.items
  end
  local key = scene.name .. '|' .. tostring(scene.t0) .. '|' .. fam_signature(fam_state)
  if D.items_key == key then return D.items end
  D.items = D.items_in_range(scene.t0, scene.t1, fam_state)
  D.items_key = key
  return D.items
end

function D.invalidate_items()
  D.items_key = nil
end

return D
