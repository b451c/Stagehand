-- state.lua - the project binding and the two persistence scopes.
--
-- Project scope: ProjExtState under the "Stagehand" extname (saved with the project when the user saves; nothing
-- here calls Main_SaveProject). Global scope: ExtState "Stagehand" (persisted in reaper-extstate.ini).
-- bind() notices a project switch (another project tab, a new project) so per-project state can be reloaded.
-- Lua 5.4; no globals.

local json = require('lib.json')

local M = {}

M.EXT = 'Stagehand'

local bound = { proj = nil, name = '' }

local function current_project()
  local proj, name = reaper.EnumProjects(-1, '')
  return proj, name or ''
end

-- returns true when the current project differs from the one bound before
function M.bind()
  local proj, name = current_project()
  local changed = proj ~= bound.proj or name ~= bound.name
  bound.proj, bound.name = proj, name
  return changed
end

function M.project_name()
  local _, name = current_project()
  name = name or ''
  local base = name:match('([^/\\]+)$') or name
  if base == '' then return '(unsaved project)' end
  return (base:gsub('%.[Rr][Pp][Pp]$', ''))
end

function M.state_count()
  return reaper.GetProjectStateChangeCount(0)
end

function M.pget(key)
  local ok, val = reaper.GetProjExtState(0, M.EXT, key)
  if ok == 1 and val ~= '' then return val end
  return nil
end

function M.pset(key, value)
  reaper.SetProjExtState(0, M.EXT, key, value or '')
end

function M.pget_json(key)
  local raw = M.pget(key)
  if not raw then return nil end
  local v = json.decode(raw)
  return v
end

function M.pset_json(key, tbl)
  if tbl == nil then M.pset(key, ''); return end
  M.pset(key, json.encode(tbl))
end

function M.gget(key)
  local v = reaper.GetExtState(M.EXT, key)
  if v == '' then return nil end
  return v
end

function M.gset(key, value)
  if value == nil or value == '' then
    reaper.DeleteExtState(M.EXT, key, true)
  else
    reaper.SetExtState(M.EXT, key, tostring(value), true)
  end
end

function M.gget_json(key)
  local raw = M.gget(key)
  if not raw then return nil end
  return json.decode(raw)
end

function M.gset_json(key, tbl)
  if tbl == nil then M.gset(key, nil); return end
  M.gset(key, json.encode(tbl))
end

-- scoped helpers: scope 'project' reads the project first and falls back to the global copy; writes go to both
-- (the global copy seeds new projects). scope 'global' uses only the global copy.
function M.get_scoped(key, scope)
  if scope ~= 'global' then
    local v = M.pget_json(key)
    if v ~= nil then return v end
  end
  return M.gget_json(key)
end

function M.set_scoped(key, tbl, scope)
  if scope ~= 'global' then M.pset_json(key, tbl) end
  M.gset_json(key, tbl)
end

return M
