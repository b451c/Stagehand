-- modules/director/init.lua - the Director module: shot list with validation, follow-play
-- engine (lanes, locked heights with a verify pass, pins, parents, envelope story mode, page / follow view with
-- an eased zoom, ruler lanes, continuous-scroll off), full restore through the journal, rehearsal controls.
-- Module contract (docs/architecture.md section 3): init, tick, draw, selftest, restore, shutdown.
-- Lua 5.4; no globals.

local log = require('lib.log')
local journal = require('lib.journal')
local state = require('state')
local config = require('config')
local i18n = require('i18n')
local MD = require('modules.director.model')
local R = require('modules.director.resolve')
local E = require('modules.director.engine')
local ED = require('modules.director.editor')
local U = require('modules.director.ui')
local ST = require('modules.director.selftest')

local t = i18n.t

local S = {
  hi = 0, msg = '', msg_frames = 0, issues = {}, issue_counts = nil, worst = {}, validate_request = true,
  compact = false, show_issues = false, menu_row = nil, menu_request = nil, clipper = nil, dirty = false,
  scroll_to_hi = false, time_w = 60,
}

local M = { name = 'director', title = t('dir.title') }

local app

local function scope()
  return config.get('director.persist.scope') or 'project'
end

function S.load()
  local v = state.get_scoped('director.ui', scope())
  if type(v) == 'table' then
    if v.auto ~= nil then E.auto = v.auto == true end
    S.show_issues = v.show_issues == true
  end
end

function S.save()
  state.set_scoped('director.ui', { auto = E.auto, show_issues = S.show_issues }, scope())
end

local function bind_project()
  E.abandon()
  E.rescan()
  MD.load()
  S.load()
  S.hi = 0
  S.validate_request = true
  if MD.on_change then MD.on_change() end
  log.info('director bound to "%s": %d shots, %d tracks', state.project_name(), #MD.shots, #E.tracks)
end

function M.init(app_)
  app = app_
  E.init(app)
  ED.init(app, E, MD, R, S)
  U.init(app, E, MD, S)
  ST.init(app, E, MD, S, U)
  S.clipper = app.ImGui.CreateListClipper(app.ctx)
  app.ImGui.Attach(app.ctx, S.clipper)
  -- the HUD (and later the recorder) learn the list's size and end through this event, never by requiring us
  MD.on_change = function() app.emit('director_shots', #MD.shots, MD.length()) end
  bind_project()
  app.on('project_changed', bind_project)
  -- the recorder's ctl protocol (arm / quit) drives a run through commands, never by requiring this module
  app.on('command', function(name)
    if name == 'director_start' then
      if not E.active and #MD.shots > 0 then E.start('command') end
    elseif name == 'director_stop' then
      if E.active then E.stop('command') end
    end
  end)
end

function M.tick(app_)
  E.tick()
  journal.flush()
  if S.dirty and app_.frame % 30 == 0 then
    S.save()
    S.dirty = false
  end
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

-- called by the app on a frame error and at exit: put back everything the Director changed (also entries a
-- previous run left in the project when no run is active now)
function M.restore()
  if E.active then return E.restore() end
  if journal.count(nil, 'director') > 0 then return journal.restore(journal.owner_pred('director')) end
  return nil
end

function M.shutdown()
  journal.flush()
  S.save()
end

M.E, M.MD, M.S, M.U = E, MD, S, U
return M
