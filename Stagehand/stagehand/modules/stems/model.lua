-- modules/stems/model.lua - the stem set of a project: stems, their cells, bulk builders, persistence, presets and
-- the track extension state that lets a track template carry its stem membership (BRIEF 3.10).
--
-- stem = { id, name, enabled, cells = { [track GUID] = 'S' | 'I' | 'M' }, names = { [GUID] = track name },
--          variant = nil | 'master' | 'nofx' | 'dry', source = { kind, name }, range = nil | { name, t0, t1 } }
-- Cells: S = solo in place (I_SOLO 2), I = solo ignore routing (I_SOLO 1), M = mute (B_MUTE 1). A stem without
-- cells renders the full mix (a per-scene mix has a range and no cells). names[] lets a preset or a track
-- template re-find a track in another project by name when the GUID is unknown. The set lives in the project
-- (ProjExtState 'stems.set'); nothing is written to disk until the user saves. The track cache (tracks with
-- families, scenes) is rebuilt when the project state count changes. Lua 5.4; no globals.

local state = require('state')
local config = require('config')
local edits = require('lib.edits')
local text = require('lib.text')
local tracks = require('lib.tracks')
local families = require('lib.families')
local regions = require('lib.regions')
local json = require('lib.json')
local log = require('lib.log')

local MD = { stems = {}, loaded_for = nil, on_change = nil }

MD.CELLS = { 'S', 'I', 'M' }
MD.VARIANTS = { 'master', 'nofx', 'dry' }
MD.SOURCES = { 'family', 'folder', 'selection', 'scene', 'capture', 'manual' }

local KEY = 'stems.set'
local P_EXT = 'P_EXT:stagehand_stems'
local VERSION = 1

-- the project cache --------------------------------------------------------------------------------------------------------

local D = { tracks = {}, by_guid = {}, fams = nil, family_count = {}, scenes = {}, state_count = -1 }
MD.D = D

function MD.refresh()
  D.fams = families.compile()
  D.tracks = tracks.scan()
  D.family_count = families.assign(D.fams, D.tracks)
  D.by_guid = {}
  for _, e in ipairs(D.tracks) do D.by_guid[e.guid] = e end
  D.scenes = regions.scan(nil, 5)
  edits.taken(D)
end

function MD.check_refresh()
  if edits.due(D) then
    MD.refresh()
    return true
  end
  return false
end

-- stems --------------------------------------------------------------------------------------------------------------------

local function new_id()
  return string.format('%x%04x', math.floor(reaper.time_precise() * 1000) % 0x7FFFFFFF, math.random(0, 0xFFFF))
end

local function cell_ok(c)
  return c == 'S' or c == 'I' or c == 'M'
end

function MD.sanitize(s)
  local out = {
    id = tostring(s.id or new_id()),
    name = text.trim(tostring(s.name or '')),
    enabled = s.enabled ~= false,
    cells = {}, names = {},
    variant = (s.variant == 'master' or s.variant == 'nofx' or s.variant == 'dry') and s.variant or nil,
    source = type(s.source) == 'table' and { kind = tostring(s.source.kind or 'manual'), name = tostring(s.source.name or '') } or { kind = 'manual', name = '' },
  }
  if out.name == '' then out.name = 'Stem' end
  for guid, c in pairs(s.cells or {}) do
    if cell_ok(c) then out.cells[tostring(guid)] = c end
  end
  for guid, n in pairs(s.names or {}) do out.names[tostring(guid)] = tostring(n) end
  if type(s.range) == 'table' and tonumber(s.range.t0) and tonumber(s.range.t1) then
    local t0, t1 = tonumber(s.range.t0), tonumber(s.range.t1)
    if t1 < t0 then t0, t1 = t1, t0 end
    out.range = { name = tostring(s.range.name or ''), t0 = t0, t1 = t1 }
  end
  return out
end

function MD.copy(s)
  return MD.sanitize(json.decode(json.encode(s)))
end

function MD.find_by_name(name)
  for k, s in ipairs(MD.stems) do
    if s.name == name then return s, k end
  end
  return nil
end

function MD.index_of(stem)
  for k, s in ipairs(MD.stems) do
    if s == stem then return k end
  end
  return nil
end

-- "Music", "Music 2", "Music 3"... so two stems never share a name (file names come from it)
function MD.unique_name(name)
  name = text.trim(name)
  if name == '' then name = 'Stem' end
  if not MD.find_by_name(name) then return name end
  local n = 2
  while MD.find_by_name(name .. ' ' .. n) do n = n + 1 end
  return name .. ' ' .. n
end

function MD.count_cells(s)
  local n, by = 0, { S = 0, I = 0, M = 0 }
  for _, c in pairs(s.cells) do
    n = n + 1
    by[c] = (by[c] or 0) + 1
  end
  return n, by
end

function MD.enabled_count()
  local n = 0
  for _, s in ipairs(MD.stems) do
    if s.enabled then n = n + 1 end
  end
  return n
end

-- the tracks a stem's cells resolve to: { { e = track entry, cell } ... }, plus the number of cells without a track
-- (GUID gone; a name match from names[] rescues a track that came from another project or a template)
function MD.resolve(s)
  MD.check_refresh()
  local out, missing = {}, 0
  local by_name = nil
  for guid, c in pairs(s.cells) do
    local e = D.by_guid[guid]
    if not e and s.names[guid] then
      if not by_name then
        by_name = {}
        for _, x in ipairs(D.tracks) do by_name[x.name] = by_name[x.name] or x end
      end
      e = by_name[s.names[guid]]
    end
    if e then out[#out + 1] = { e = e, cell = c } else missing = missing + 1 end
  end
  table.sort(out, function(a, b) return a.e.n < b.e.n end)
  return out, missing
end

function MD.set_cell(s, guid, cell, name)
  if cell == nil or cell == '' or cell == '-' then
    s.cells[guid] = nil
    s.names[guid] = nil
  elseif cell_ok(cell) then
    s.cells[guid] = cell
    if name then s.names[guid] = name end
  end
end

-- the next state of a matrix cell on a click: off -> S -> I -> M -> off
function MD.next_cell(cur)
  if cur == nil then return 'S' elseif cur == 'S' then return 'I' elseif cur == 'I' then return 'M' end
  return nil
end

-- one line for the list: "6 tracks solo, 1 mute" / "full mix" / "scene 0:12.00-0:31.50"
function MD.summary(s)
  local n, by = MD.count_cells(s)
  local parts = {}
  if by.S + by.I > 0 then parts[#parts + 1] = string.format('%d solo%s', by.S + by.I, by.I > 0 and (' (' .. by.I .. ' ignore routing)') or '') end
  if by.M > 0 then parts[#parts + 1] = by.M .. ' mute' end
  if n == 0 then parts[#parts + 1] = 'full mix' end
  if s.range then parts[#parts + 1] = text.fmt_time(s.range.t0) .. '-' .. text.fmt_time(s.range.t1) end
  if s.variant and s.variant ~= 'master' then parts[#parts + 1] = s.variant == 'nofx' and 'no master FX' or 'dry' end
  return table.concat(parts, ', ')
end

-- persistence --------------------------------------------------------------------------------------------------------------

function MD.load()
  local v = state.pget_json(KEY)
  MD.stems = {}
  if type(v) == 'table' and type(v.stems) == 'table' then
    for _, s in ipairs(v.stems) do
      if type(s) == 'table' then MD.stems[#MD.stems + 1] = MD.sanitize(s) end
    end
  end
  return #MD.stems
end

function MD.save()
  if #MD.stems == 0 then
    state.pset(KEY, '')
  else
    state.pset_json(KEY, { version = VERSION, stems = MD.stems })
  end
  if config.get('stems.membership.write_tracks') ~= false then MD.write_p_ext() end
  if MD.on_change then MD.on_change() end
end

function MD.add(stem)
  stem.name = MD.unique_name(stem.name)
  MD.stems[#MD.stems + 1] = stem
  MD.save()
  return #MD.stems
end

function MD.remove(k)
  if not MD.stems[k] then return end
  table.remove(MD.stems, k)
  MD.save()
end

function MD.clear()
  MD.stems = {}
  MD.save()
end

function MD.move(k, delta)
  local j = k + delta
  if not MD.stems[k] or not MD.stems[j] then return k end
  MD.stems[k], MD.stems[j] = MD.stems[j], MD.stems[k]
  MD.save()
  return j
end

function MD.duplicate(k)
  local s = MD.stems[k]
  if not s then return nil end
  local c = MD.copy(s)
  c.id = new_id()
  c.name = MD.unique_name(s.name)
  table.insert(MD.stems, k + 1, c)
  MD.save()
  return k + 1
end

function MD.rename(k, name)
  local s = MD.stems[k]
  if not s then return end
  name = text.trim(name)
  if name == '' or name == s.name then return end
  local other = MD.find_by_name(name)
  if other and other ~= s then name = MD.unique_name(name) end
  s.name = name
  MD.save()
end

-- membership in the tracks (P_EXT): "Stem name=S;Other=M" per track, so a track template carries it and
-- MD.adopt() puts a track inserted from a template back into the stems of the same names --------------------------------

function MD.write_p_ext()
  MD.check_refresh()
  local per = {}
  for _, s in ipairs(MD.stems) do
    for guid, c in pairs(s.cells) do
      per[guid] = per[guid] or {}
      per[guid][#per[guid] + 1] = s.name:gsub('[;=]', '_') .. '=' .. c
    end
  end
  local written = 0
  for _, e in ipairs(D.tracks) do
    local want = per[e.guid] and table.concat(per[e.guid], ';') or ''
    local _, cur = reaper.GetSetMediaTrackInfo_String(e.tr, P_EXT, '', false)
    if (cur or '') ~= want then
      reaper.GetSetMediaTrackInfo_String(e.tr, P_EXT, want, true)
      written = written + 1
    end
  end
  return written
end

-- tracks whose extension state names a stem of this set but which the stem does not hold (a template insert):
-- returns the number of cells adopted; unknown stem names are reported, never created
function MD.adopt()
  MD.check_refresh()
  local adopted, unknown = 0, {}
  for _, e in ipairs(D.tracks) do
    local _, v = reaper.GetSetMediaTrackInfo_String(e.tr, P_EXT, '', false)
    if v and v ~= '' then
      for pair in v:gmatch('[^;]+') do
        local name, c = pair:match('^(.-)=(%u)$')
        if name and cell_ok(c) then
          local s = MD.find_by_name(name)
          if s then
            if s.cells[e.guid] == nil then
              s.cells[e.guid] = c
              s.names[e.guid] = e.name
              adopted = adopted + 1
            end
          else
            unknown[name] = true
          end
        end
      end
    end
  end
  if adopted > 0 then MD.save() end
  local names = {}
  for n in pairs(unknown) do names[#names + 1] = n end
  table.sort(names)
  return adopted, names
end

function MD.p_ext_of(tr)
  local _, v = reaper.GetSetMediaTrackInfo_String(tr, P_EXT, '', false)
  return v or ''
end

-- bulk builders (they return stems; the caller adds them) ------------------------------------------------------------------

local function solo_cell()
  return config.get('stems.bulk.solo_mode') == 'ignore_routing' and 'I' or 'S'
end

local function stem(name, kind, src_name)
  return MD.sanitize({ name = name, source = { kind = kind, name = src_name or name } })
end

-- one stem per family with at least one track (folders of the family included: the family is assigned by the top ancestor)
function MD.from_families()
  MD.check_refresh()
  local out = {}
  local cell = solo_cell()
  for _, f in ipairs(D.fams.all) do
    if (D.family_count[f.name] or 0) > 0 then
      local s = stem(f.name, 'family')
      for _, e in ipairs(D.tracks) do
        if e.fam == f.name then MD.set_cell(s, e.guid, cell, e.name) end
      end
      out[#out + 1] = s
    end
  end
  return out
end

-- one stem per top-level folder: the parent soloed in place hears its children; stems.bulk.folder_children = 'all'
-- marks the children too (for users who prefer explicit cells)
function MD.from_folders()
  MD.check_refresh()
  local out = {}
  local cell = solo_cell()
  local all = config.get('stems.bulk.folder_children') == 'all'
  for k, e in ipairs(D.tracks) do
    if e.depth == 0 and e.folder then
      local s = stem(e.name, 'folder')
      MD.set_cell(s, e.guid, cell, e.name)
      if all then
        for j = k + 1, #D.tracks do
          local c = D.tracks[j]
          if c.depth == 0 then break end
          MD.set_cell(s, c.guid, cell, c.name)
        end
      end
      out[#out + 1] = s
    end
  end
  return out
end

-- one stem from the selected tracks
function MD.from_selection(name)
  MD.check_refresh()
  local cell = solo_cell()
  local s, n, first = nil, 0, nil
  for _, e in ipairs(D.tracks) do
    if reaper.GetMediaTrackInfo_Value(e.tr, 'I_SELECTED') == 1 then
      s = s or stem(name or e.name, 'selection', e.name)
      first = first or e.name
      MD.set_cell(s, e.guid, cell, e.name)
      n = n + 1
    end
  end
  if s and n > 1 and not name then s.name = first .. ' +' .. (n - 1) end
  return s, n
end

-- one full-mix stem per scene (region), with the scene as its range
function MD.from_scenes()
  MD.check_refresh()
  local out = {}
  for _, sc in ipairs(D.scenes) do
    local s = stem(sc.name, 'scene')
    s.range = { name = sc.name, t0 = sc.t0, t1 = sc.t1 }
    out[#out + 1] = s
  end
  return out
end

-- the project's current solo / mute state as one stem
function MD.capture(name)
  MD.check_refresh()
  local s, n = stem(name or 'Captured', 'capture', ''), 0
  for _, e in ipairs(D.tracks) do
    local solo = reaper.GetMediaTrackInfo_Value(e.tr, 'I_SOLO')
    local mute = reaper.GetMediaTrackInfo_Value(e.tr, 'B_MUTE')
    if solo == 2 or solo == 6 then MD.set_cell(s, e.guid, 'S', e.name); n = n + 1
    elseif solo == 1 or solo == 5 then MD.set_cell(s, e.guid, 'I', e.name); n = n + 1
    elseif mute == 1 then MD.set_cell(s, e.guid, 'M', e.name); n = n + 1 end
  end
  return s, n
end

-- presets: a stem set as a file { stagehand_stems = { name, version, created, project }, stems = [...] };
-- tracks travel by name (names[]) and are re-found in the target project by GUID first, then by name ------------------------

function MD.to_preset(name)
  local list = {}
  for _, s in ipairs(MD.stems) do list[#list + 1] = MD.copy(s) end
  return { stagehand_stems = { name = name, version = VERSION, created = os.date('%Y-%m-%d %H:%M:%S'), project = state.project_name(), count = #list }, stems = list }
end

function MD.from_preset(tbl)
  if type(tbl) ~= 'table' or type(tbl.stagehand_stems) ~= 'table' or type(tbl.stems) ~= 'table' then return nil, 'no stagehand_stems header or no stems list' end
  MD.check_refresh()
  local by_name = {}
  for _, x in ipairs(D.tracks) do by_name[x.name] = by_name[x.name] or x end
  local out, found, lost = {}, 0, 0
  for _, raw in ipairs(tbl.stems) do
    local s = MD.sanitize(raw)
    s.id = new_id()
    local cells, names = {}, {}
    for guid, c in pairs(s.cells) do
      local e = D.by_guid[guid] or (s.names[guid] and by_name[s.names[guid]])
      if e then
        cells[e.guid] = c
        names[e.guid] = e.name
        found = found + 1
      else
        lost = lost + 1
      end
    end
    s.cells, s.names = cells, names
    out[#out + 1] = s
  end
  return out, nil, found, lost
end

local sep = package.config:sub(1, 1)

function MD.preset_dir()
  local dir = reaper.GetResourcePath() .. sep .. 'Stagehand' .. sep .. 'stems'
  reaper.RecursiveCreateDirectory(dir, 0)
  return dir
end

local function safe_name(name)
  return (tostring(name):gsub('[/\\:*?"<>|]', '_'):gsub('^%s+', ''):gsub('%s+$', ''))
end

function MD.preset_path(name)
  return MD.preset_dir() .. sep .. safe_name(name) .. '.json'
end

function MD.save_preset(name)
  local path = MD.preset_path(name)
  local f = io.open(path, 'w')
  if not f then return nil, 'cannot write ' .. path end
  f:write(json.encode(MD.to_preset(name), { pretty = true }), '\n')
  f:close()
  log.info('stems: preset "%s" saved to %s (%d stems)', name, path, #MD.stems)
  return path
end

function MD.list_presets()
  local out = {}
  local dir = MD.preset_dir()
  local i = 0
  while true do
    local fn = reaper.EnumerateFiles(dir, i)
    if not fn then break end
    i = i + 1
    if fn:lower():match('%.json$') then out[#out + 1] = { name = fn:gsub('%.[Jj][Ss][Oo][Nn]$', ''), path = dir .. sep .. fn } end
  end
  table.sort(out, function(a, b) return a.name:lower() < b.name:lower() end)
  return out
end

-- load_preset(path, mode = 'replace' | 'append') -> n stems, found cells, lost cells | nil, err
function MD.load_preset(path, mode)
  local f = io.open(path, 'r')
  if not f then return nil, 'cannot read ' .. tostring(path) end
  local txt = f:read('a')
  f:close()
  local v, err = json.decode(txt)
  if type(v) ~= 'table' then return nil, 'not a JSON object: ' .. tostring(err) end
  local list, perr, found, lost = MD.from_preset(v)
  if not list then return nil, perr end
  if mode ~= 'append' then MD.stems = {} end
  for _, s in ipairs(list) do
    s.name = MD.unique_name(s.name)
    MD.stems[#MD.stems + 1] = s
  end
  MD.save()
  return #list, found, lost
end

return MD
