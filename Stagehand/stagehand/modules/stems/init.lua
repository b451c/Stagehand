-- modules/stems/init.lua - the Stems module: stem definitions in bulk from what the Navigator knows
-- (families, top folders, the selection, scenes, the project's solo / mute state), a matrix editor for the
-- exceptions, stem-set presets, render settings owned by Stagehand, a sequential renderer with a pre-flight
-- checklist and a results page. Module contract (docs/architecture.md section 3): init, tick, draw, selftest,
-- restore, shutdown. The other modules are never required: the Navigator's families come from lib/families,
-- scenes from lib/regions; commands stems_render / stems_stop and the ctl verb "stems ..." serve launchers and
-- the companion checker (tools/stems_check.py). Lua 5.4; no globals.

local log = require('lib.log')
local journal = require('lib.journal')
local state = require('state')
local config = require('config')
local ctl = require('lib.ctl')
local i18n = require('i18n')
local MD = require('modules.stems.model')
local R = require('modules.stems.render')
local E = require('modules.stems.engine')
local U = require('modules.stems.ui')
local ST = require('modules.stems.selftest')

local t = i18n.t

local S = { msg = '', msg_frames = 0, compact = false, hi = 0, show_preflight = false, show_results = false, matrix = nil }

local M = { name = 'stems', title = t('stems.title') }

local app

local function bind_project()
  if E.active then E.abort('project switch') end
  MD.refresh()
  MD.load()
  local adopted, unknown = MD.adopt()
  if adopted > 0 then log.info('stems: %d cells adopted from track extension state', adopted) end
  if #unknown > 0 then log.info('stems: tracks name stems this project does not have: %s', table.concat(unknown, ', ')) end
  E.results = state.pget_json('stems.results')
  S.hi = 0
  log.info('stems bound to "%s": %d stems, %d journal entries of ours', state.project_name(), #MD.stems, journal.count(nil, 'stems'))
end

-- the ctl verb: "stems list | render [all] | stop | status"
local function ctl_verb(args)
  local verb = (args or ''):match('^(%S*)')
  if verb == 'list' then
    local names = {}
    for k, s in ipairs(MD.stems) do names[#names + 1] = string.format('%d:%s:%s', k, s.enabled and 'on' or 'off', s.name:gsub('%s', '_')) end
    ctl.write('STEMS', { n = #MD.stems, enabled = MD.enabled_count(), list = table.concat(names, ',') })
  elseif verb == 'render' then
    local ok, err = E.start(nil, 'ctl')
    if ok then
      ctl.write('STEMS_START', { n = E.run.n, dir = R.out_dir() or '' })
    else
      local rows = E.preflight_rows or {}
      local errs = {}
      for _, r in ipairs(rows) do
        if r.level == 'error' then errs[#errs + 1] = r.text end
      end
      ctl.write('ERROR', 'stems render: ' .. tostring(err) .. ' ' .. table.concat(errs, ' | '))
    end
  elseif verb == 'stop' then
    ctl.write('STEMS_STOP', E.stop('ctl') and 'requested' or 'idle')
  elseif verb == 'status' then
    local r = E.run
    ctl.write('STEMS_STATUS', r and { active = 1, i = r.i, n = r.n, phase = r.phase } or { active = 0 })
  else
    ctl.write('ERROR', 'stems: unknown verb "' .. tostring(verb) .. '" (list | render | stop | status)')
  end
end

function M.init(app_)
  app = app_
  E.init(app)
  U.init(app, S, MD, R, E)
  ST.init(app, S, MD, R, E, U)
  ctl.on('stems', ctl_verb)
  bind_project()
  app.on('project_changed', bind_project)
  app.on('command', function(name)
    if name == 'stems_render' then E.start(nil, 'command')
    elseif name == 'stems_stop' then E.stop('command')
    elseif name == 'stems_show' then app.set_tab('stems') end
  end)
  app.on('stem_done', function(n, total, row)
    ctl.write('STEM_DONE', { k = n, n = total, ok = row.ok and 1 or 0, file = row.file or '' })
  end)
  app.on('stems_done', function(results)
    ctl.write('STEMS_DONE', { n = #results.rows, ok = results.ok, failed = results.failed, skipped = results.skipped, silent = results.silent,
      results = results.files and results.files.json or '' })
  end)
  MD.on_change = function() S.dirty = true end
end

function M.tick(app_)
  E.tick()
  if S.msg_frames > 0 then S.msg_frames = S.msg_frames - 1 end
  journal.flush()
end

function M.draw(app_)
  U.draw(app_)
end

function M.selftest(T)
  ST.run(T)
end

function M.selftest_post(frames_since_done)
  ST.post(frames_since_done)
end

-- a frame error or the exit: the batch is dropped and everything it changed goes back (also entries a previous
-- session left in the project)
function M.restore()
  if E.active or journal.count(nil, 'stems') > 0 then return E.abort('restore') end
  return nil
end

function M.shutdown()
  journal.flush()
end

M.MD, M.R, M.E, M.S, M.U = MD, R, E, S, U
return M
