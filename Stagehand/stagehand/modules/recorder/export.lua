-- modules/recorder/export.lua - shot-list export and import (BRIEF 3.5): JSON for editors and tools, CSV for
-- spreadsheets. The shots come from the Director module when it is loaded (soft reference through the app
-- registry, never a require). JSON: { stagehand_shots = { version, project, exported, time_format }, shots =
-- [ shot ... ] } with the Director's own shot model; CSV: one row per shot with seconds and timecode columns.
-- Import reads the JSON form back (replace or append). Lua 5.4; no globals.

local json = require('lib.json')
local config = require('config')
local state = require('state')

local EX = {}

local VERSION = 1
local sep = package.config:sub(1, 1)

local app

function EX.init(app_)
  app = app_
end

local function director()
  return app and app.by_name['director'] or nil
end

function EX.shots()
  local d = director()
  return d and d.MD.shots or {}
end

function EX.dir()
  local d = config.get('recorder.export.dir')
  if type(d) == 'string' and d ~= '' then return d end
  local _, name = reaper.EnumProjects(-1, '')
  local pd = (name or ''):match('^(.*)[/\\]')
  if not pd then return nil end
  return pd .. sep .. 'Render'
end

function EX.default_path(ext)
  local d = EX.dir()
  if not d then return nil end
  local base = state.project_name():gsub('[^%w%-_ ]', '_')
  return d .. sep .. base .. '_shots.' .. ext
end

local function timecode(s)
  return reaper.format_timestr_pos(s, '', 5)
end

local function min_sec(s)
  local m = math.floor(s / 60)
  return string.format('%d:%05.2f', m, s - m * 60)
end

local function fmt_time(s, mode)
  if mode == 'timecode' then return timecode(s) end
  if mode == 'min_sec' then return min_sec(s) end
  return string.format('%.3f', s)
end

local function lane_text(l)
  if l.kind == 'items' then return l.family and ('items:' .. l.family) or 'items' end
  if l.kind == 'family' then return 'family:' .. tostring(l.name) end
  if l.kind == 'rule' then return 'rule:' .. tostring(l.rule) end
  if l.kind == 'track' then return 'track:' .. tostring(l.name) end
  return '?'
end

function EX.to_json(shots)
  local out = {
    stagehand_shots = { version = VERSION, project = state.project_name(), exported = os.date('%Y-%m-%d %H:%M:%S'), count = #shots },
    shots = {},
  }
  for i, s in ipairs(shots) do
    local c = {}
    for k, v in pairs(s) do c[k] = v end
    c.index = i
    c.t0_tc, c.t1_tc = timecode(s.t0), timecode(s.t1)
    out.shots[i] = c
  end
  return json.encode(out, { pretty = true })
end

local function csv_cell(v)
  local s = tostring(v == nil and '' or v)
  if s:find('[",\r\n]') then s = '"' .. s:gsub('"', '""') .. '"' end
  return s
end

function EX.to_csv(shots)
  local mode = config.get('recorder.export.time_format') or 'seconds'
  local lines = { 'index,name,start,end,duration,start_tc,end_tc,caption,caption2,lanes,envelopes,view,parents' }
  for i, s in ipairs(shots) do
    local lanes, envs = {}, {}
    for _, l in ipairs(s.lanes or {}) do lanes[#lanes + 1] = lane_text(l) end
    for _, e in ipairs(s.envelopes or {}) do envs[#envs + 1] = tostring(e.track) .. '/' .. tostring(e.env) end
    local row = { i, s.name, fmt_time(s.t0, mode), fmt_time(s.t1, mode), fmt_time(s.t1 - s.t0, mode), timecode(s.t0), timecode(s.t1),
      s.caption or '', s.caption2 or '', table.concat(lanes, ' | '), table.concat(envs, ' | '), s.view or '', s.parents or '' }
    for k, v in ipairs(row) do row[k] = csv_cell(v) end
    lines[#lines + 1] = table.concat(row, ',')
  end
  return table.concat(lines, '\n') .. '\n'
end

function EX.write(path, text)
  local dir = path:match('^(.*)[/\\]')
  if dir then reaper.RecursiveCreateDirectory(dir, 0) end
  local f = io.open(path, 'w')
  if not f then return false, 'cannot write ' .. path end
  f:write(text)
  f:close()
  return true
end

-- export(kind = 'json' | 'csv', path = nil for the default); returns path or nil, error
function EX.export(kind, path)
  local shots = EX.shots()
  if #shots == 0 then return nil, 'no shots' end
  path = path or EX.default_path(kind)
  if not path then return nil, 'save the project first' end
  local text = kind == 'csv' and EX.to_csv(shots) or EX.to_json(shots)
  local ok, err = EX.write(path, text)
  if not ok then return nil, err end
  return path, #shots
end

-- read a JSON export; returns the shot list (sanitized by the Director when present) or nil, error
function EX.read_json(path)
  local f = io.open(path, 'r')
  if not f then return nil, 'cannot read ' .. tostring(path) end
  local text = f:read('a')
  f:close()
  local ok, v = pcall(json.decode, text)
  if not ok or type(v) ~= 'table' then return nil, 'not a JSON file' end
  local list = v.shots or (v[1] and v) or nil
  if type(list) ~= 'table' then return nil, 'no shots in the file' end
  local d = director()
  local out = {}
  for _, s in ipairs(list) do
    if type(s) == 'table' then out[#out + 1] = d and d.MD.sanitize(s) or s end
  end
  return out
end

-- import(path, mode = 'replace' | 'append'); returns count or nil, error
function EX.import(path, mode)
  local d = director()
  if not d then return nil, 'Director module not loaded' end
  local shots, err = EX.read_json(path)
  if not shots then return nil, err end
  if mode == 'replace' then d.MD.shots = {} end
  for _, s in ipairs(shots) do d.MD.shots[#d.MD.shots + 1] = s end
  d.MD.sort()
  d.MD.save()
  d.S.validate_request = true
  return #shots
end

-- a save dialog when js_ReaScriptAPI has one, else the default path
function EX.pick_save_path(kind)
  local def = EX.default_path(kind)
  if reaper.JS_Dialog_BrowseForSaveFile and def then
    local dir, base = def:match('^(.*)[/\\]([^/\\]+)$')
    local filter = kind == 'csv' and 'CSV files (*.csv)\0*.csv\0\0' or 'JSON files (*.json)\0*.json\0\0'
    local ok, chosen = reaper.JS_Dialog_BrowseForSaveFile('Export the shot list', dir or '', base or '', filter)
    if ok == 1 and chosen and chosen ~= '' then return chosen end
    return nil
  end
  return def
end

function EX.pick_open_path()
  if reaper.JS_Dialog_BrowseForOpenFiles then
    local ok, chosen = reaper.JS_Dialog_BrowseForOpenFiles('Import a shot list', EX.dir() or '', '', 'JSON files (*.json)\0*.json\0\0', false)
    if ok == 1 and chosen and chosen ~= '' then return chosen end
    return nil
  end
  return EX.default_path('json')
end

return EX
