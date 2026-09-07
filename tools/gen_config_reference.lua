-- tools/gen_config_reference.lua - writes docs/config-reference.md from stagehand/schema.lua, config.defaults and
-- the English string table, so the reference can never drift from the code. Runs under a plain Lua 5.4 on the
-- development machine (a tiny `reaper` stub covers the calls the config module makes at load) and inside REAPER.
--
--   lua5.4 tools/gen_config_reference.lua > docs/config-reference.md
--   lua5.4 tools/gen_config_reference.lua --check docs/config-reference.md   (exit 1 when the file is stale)
--
-- Lua 5.4; no globals besides the stub.

local root = (arg and arg[0] or ''):match('^(.*)[/\\]tools[/\\]') or '.'
if not reaper then
  reaper = {
    GetResourcePath = function() return '.' end,
    RecursiveCreateDirectory = function() return 0 end,
    GetExtState = function() return '' end,
    SetExtState = function() end,
    DeleteExtState = function() end,
    GetProjExtState = function() return 0, '' end,
    SetProjExtState = function() end,
    EnumProjects = function() return nil, '' end,
    time_precise = os.clock,
    GetProjectStateChangeCount = function() return 0 end,
  }
end
local base = root .. '/Stagehand/stagehand/'
package.path = base .. '?.lua;' .. base .. '?/init.lua;' .. package.path

local schema = require('schema')
local config = require('config')
local i18n = require('i18n')
local json = require('lib.json')

local t = i18n.t

local function s(key, fallback)
  if i18n.has(key) then return t(key) end
  return fallback
end

local function default_text(entry)
  local v = config.default(entry.key)
  if entry.type == 'list' or entry.type == 'table' then
    if type(v) == 'table' and #v == 0 then return 'empty' end
    return '`' .. json.encode(v):gsub('|', '\\|') .. '`'
  end
  local txt = schema.format(entry, v)
  if txt == '' then return 'empty' end
  return '`' .. txt .. '`'
end

local function type_text(entry)
  local ty = entry.type
  local r = schema.range_text(entry)
  if ty == 'enum' then return r end
  if ty == 'bool' then return 'on / off' end
  if ty == 'int' or ty == 'num' then return (ty == 'int' and 'whole number' or 'number') .. (r and (', ' .. r) or '') end
  if ty == 'int_list' then return 'list of whole numbers' .. (r and (', each ' .. r) or '') end
  if ty == 'str_list' then return 'list of names' .. (r and (', ' .. r) or '') end
  if ty == 'color' then return 'colour `#RRGGBB`' end
  if ty == 'path' then return 'file path' end
  if ty == 'str' then return 'text' end
  if ty == 'list' or ty == 'table' then return 'list (JSON)' end
  return ty
end

local out = {}
local function w(line) out[#out + 1] = line or '' end

w('# Stagehand configuration reference')
w()
w(string.format('Generated from `stagehand/schema.lua` (schema version %d) by `tools/gen_config_reference.lua`; do not edit by hand.', schema.VERSION))
w('Every key is a setting in the Settings tab (label, tooltip, range, default, reset per key and per group) and a key of the')
w('JSON layers: the global file `<REAPER resource path>/Stagehand/config.json`, the per-project overrides stored with the')
w('project, and preset files. Layers merge in that order: defaults <- global <- project. Lists (families, marker classes,')
w('groups, pinned rows, profiles) are replaced whole by an override; everything else merges key by key. A value outside its')
w('range or of the wrong type is reported in the Settings tab and left out of the merge (the default applies); the file is')
w('not rewritten. Layers written by an older schema are migrated on load (schema 1 -> 2: `navigator.layout.compact_below_px`')
w('became `ui.compact_below_px`).')
w()
w(string.format('%d keys in %d groups.', #schema.keys, #schema.groups))
w()
for _, mod in ipairs(schema.MODULES) do
  w('## ' .. s('cfg.module.' .. mod, mod) .. ' (`' .. mod .. '.*`)')
  w()
  for _, g in ipairs(schema.groups_of(mod)) do
    w('### ' .. s('cfg.group.' .. g.id, g.id))
    w()
    w('| Key | Setting | Type and range | Default | Meaning |')
    w('|---|---|---|---|---|')
    for _, e in ipairs(g.keys) do
      local label = s('cfg.' .. e.key, e.key)
      local tip = s('cfg.' .. e.key .. '.tip', ''):gsub('|', '\\|')
      w(string.format('| `%s` | %s | %s | %s | %s |', e.key, label, type_text(e):gsub('|', '\\|'), default_text(e), tip))
    end
    w()
  end
end
w('## Preset file format')
w()
w('```json')
w('{')
w('  "stagehand_preset": { "name": "My preset", "description": "...", "stagehand_version": "0.1.0", "schema": ' .. schema.VERSION .. ', "created": "2026-09-07" },')
w('  "config": { "glow": { "style": "edge", "spark": { "alpha": 0.4 } } }')
w('}')
w('```')
w()
w('`config` is a partial tree of the keys above; a preset written by an older schema is migrated when it is read. The four')
w('shipped presets live in `Stagehand/stagehand/presets/`, the user\'s own in `<REAPER resource path>/Stagehand/presets/`.')

local text = table.concat(out, '\n') .. '\n'
if arg and arg[1] == '--check' then
  local f = io.open(arg[2] or (root .. '/docs/config-reference.md'), 'r')
  local cur = f and f:read('a') or nil
  if f then f:close() end
  if cur ~= text then
    io.stderr:write('config-reference.md is stale: regenerate with lua5.4 tools/gen_config_reference.lua > docs/config-reference.md\n')
    os.exit(1)
  end
  io.stderr:write('config-reference.md is up to date\n')
  os.exit(0)
end
io.write(text)
