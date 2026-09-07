-- modules/settings/presets.lua - named presets: the four shipped in stagehand/presets/*.json and the user's
-- own in <resource>/Stagehand/presets/. A preset file is { stagehand_preset = { name, description,
-- stagehand_version, schema, created }, config = <partial tree> }. Loading migrates the tree through the
-- schema chain and validates it; a preset with invalid values is listed with its problems and cannot be
-- applied until they are fixed in the file. Applying = config.apply(tree, scope). Lua 5.4; no globals.

local json = require('lib.json')
local log = require('lib.log')
local config = require('config')
local schema = require('schema')

local P = {}

local app
local sep = package.config:sub(1, 1)

function P.init(app_)
  app = app_
end

local function read_file(p)
  local f = io.open(p, 'r')
  if not f then return nil end
  local s = f:read('a')
  f:close()
  return s
end

local function write_file(p, s)
  local f = io.open(p, 'w')
  if not f then return false end
  f:write(s)
  f:close()
  return true
end

function P.builtin_dir()
  return (app and app.script_dir or '.') .. sep .. 'stagehand' .. sep .. 'presets'
end

function P.user_dir()
  local dir = reaper.GetResourcePath() .. sep .. 'Stagehand' .. sep .. 'presets'
  reaper.RecursiveCreateDirectory(dir, 0)
  return dir
end

-- parse(text) -> preset { name, description, version, schema_from, config, issues } or nil, err
function P.parse(text)
  local v, err = json.decode(text)
  if type(v) ~= 'table' then return nil, 'not a JSON object: ' .. tostring(err) end
  local head = v.stagehand_preset
  local tree = v.config
  if type(head) ~= 'table' or type(tree) ~= 'table' then return nil, 'no stagehand_preset header or no config block' end
  tree.schema = tonumber(head.schema) or 1
  local _, from = schema.migrate(tree)
  tree.schema = nil
  local issues = schema.validate(tree)
  local bad = {}
  for _, it in ipairs(issues) do
    if it.kind == 'invalid' then bad[#bad + 1] = it end
  end
  return {
    name = tostring(head.name or 'preset'), description = tostring(head.description or ''),
    version = tostring(head.stagehand_version or '?'), schema_from = from, config = tree, issues = bad,
    unknown = #issues - #bad,
  }
end

-- build(name, description, scope) -> the preset table of a layer's overrides ('effective' = the whole merged config)
function P.build(name, description, scope)
  local tree
  if scope == 'effective' then
    tree = {}
    for _, e in ipairs(schema.keys) do
      local parts = {}
      for seg in e.key:gmatch('[^.]+') do parts[#parts + 1] = seg end
      local cur = tree
      for i = 1, #parts - 1 do
        cur[parts[i]] = cur[parts[i]] or {}
        cur = cur[parts[i]]
      end
      cur[parts[#parts]] = config.get(e.key)
    end
  else
    tree = config.layer(scope)
    tree.schema = nil
  end
  return {
    stagehand_preset = {
      name = name, description = description or '', stagehand_version = app and app.version or '?',
      schema = schema.VERSION, created = os.date('%Y-%m-%d'),
    },
    config = tree,
  }
end

function P.encode(preset)
  return json.encode(preset, { pretty = true }) .. '\n'
end

local function list_dir(dir, source)
  local out = {}
  local i = 0
  while true do
    local f = reaper.EnumerateFiles(dir, i)
    if not f then break end
    i = i + 1
    if f:lower():match('%.json$') then
      local path = dir .. sep .. f
      local text = read_file(path)
      local p, err = P.parse(text or '')
      if p then
        p.path, p.source, p.file = path, source, f
        out[#out + 1] = p
      else
        out[#out + 1] = { name = f, path = path, source = source, file = f, broken = err, issues = {}, config = {} }
        log.warn('preset %s: %s', path, tostring(err))
      end
    end
  end
  table.sort(out, function(a, b) return a.name:lower() < b.name:lower() end)
  return out
end

-- every preset: shipped first, then the user's
function P.list()
  local out = {}
  for _, p in ipairs(list_dir(P.builtin_dir(), 'builtin')) do out[#out + 1] = p end
  for _, p in ipairs(list_dir(P.user_dir(), 'user')) do out[#out + 1] = p end
  return out
end

function P.find(list, name, source)
  for _, p in ipairs(list) do
    if p.name == name and (source == nil or p.source == source) then return p end
  end
  return nil
end

-- apply(preset, scope) -> keys written, or nil + reason
function P.apply(preset, scope)
  if preset.broken then return nil, preset.broken end
  if #preset.issues > 0 then return nil, string.format('%d invalid values', #preset.issues) end
  local keys = config.apply(preset.config, scope)
  log.info('preset "%s" applied to %s: %d keys', preset.name, scope, #keys)
  return keys
end

local function safe_name(name)
  local s = tostring(name):gsub('[^%w%-_ ]', ''):gsub('%s+', '_')
  if s == '' then s = 'preset' end
  return s
end

-- save the given layer's overrides as a user preset; returns path or nil, err
function P.save(name, description, scope)
  local preset = P.build(name, description, scope)
  local path = P.user_dir() .. sep .. safe_name(name) .. '.json'
  if not write_file(path, P.encode(preset)) then return nil, 'could not write ' .. path end
  log.info('preset saved: %s', path)
  return path
end

-- import a file the user picks (or a given path); returns preset or nil, err
function P.import(path)
  if not path then
    local ok, chosen = reaper.GetUserFileNameForRead('', 'Import a Stagehand preset', 'json')
    if not ok then return nil, 'cancelled' end
    path = chosen
  end
  local text = read_file(path)
  if not text then return nil, 'could not read ' .. tostring(path) end
  local p, err = P.parse(text)
  if not p then return nil, err end
  p.path, p.source = path, 'import'
  -- keep a copy in the user's folder so it shows up in the list from now on
  local copy = P.user_dir() .. sep .. safe_name(p.name) .. '.json'
  if copy ~= path then write_file(copy, text) end
  return p, copy
end

-- export a layer (or the effective config) to a file the user picks; returns path or nil, err
function P.export(name, scope, path)
  local preset = P.build(name, '', scope)
  if not path then
    local default_name = safe_name(name) .. '.json'
    if reaper.JS_Dialog_BrowseForSaveFile then
      local ok, chosen = reaper.JS_Dialog_BrowseForSaveFile('Export a Stagehand preset', P.user_dir(), default_name, 'JSON files (*.json)\0*.json\0\0')
      if ok ~= 1 or not chosen or chosen == '' then return nil, 'cancelled' end
      path = chosen
      if not path:lower():match('%.json$') then path = path .. '.json' end
    else
      path = P.user_dir() .. sep .. default_name
    end
  end
  if not write_file(path, P.encode(preset)) then return nil, 'could not write ' .. path end
  log.info('preset exported: %s', path)
  return path
end

return P
