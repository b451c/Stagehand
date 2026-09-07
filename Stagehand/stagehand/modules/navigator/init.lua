-- modules/navigator/init.lua - the Navigator module: scenes, markers, tracks, items, search,
-- jump, audition, scene solo / mute with exact restore, families, focus, transport strip, per-project persistence.
-- Module contract (docs/architecture.md section 3): init, tick, draw, selftest, restore, shutdown.
-- Lua 5.4; no globals.

local log = require('lib.log')
local journal = require('lib.journal')
local state = require('state')
local config = require('config')
local i18n = require('i18n')
local D = require('modules.navigator.data')
local A = require('modules.navigator.actions')
local U = require('modules.navigator.ui')
local E = require('modules.navigator.editors')
local ST = require('modules.navigator.selftest')

local t = i18n.t

local S = {
  tab = 1, hi = 0, search = '', focus = false, timesel = true, loop = false, fam = {},
  rows = nil, msg = '', msg_frames = 0, compact = false, dirty = false, scroll_to_hi = false,
  focus_search = true, search_active = false, tab_request = nil, scene_name = nil, scene_t0 = nil,
  recover = nil, recover_request = nil, clipper = nil, menu_row = nil, menu_tab = nil, menu_request = nil,
  director_active = false, time_w = 60,
}

local M = { name = 'navigator', title = t('nav.title') }

local app

local function scope()
  return config.get('navigator.persist.scope')
end

function S.load()
  S.timesel = config.get('navigator.jump.time_selection') ~= false
  S.focus = config.get('navigator.jump.focus_tracks') == true
  S.loop = config.get('navigator.audition.loop') == true
  S.fam = {}
  S.tab = 1
  S.scene_name, S.scene_t0 = nil, nil
  local v = state.get_scoped('nav.ui', scope())
  if type(v) == 'table' then
    S.tab = math.max(1, math.min(4, math.floor(tonumber(v.tab) or 1)))
    if v.focus ~= nil then S.focus = v.focus == true end
    if v.timesel ~= nil then S.timesel = v.timesel == true end
    if v.loop ~= nil then S.loop = v.loop == true end
    if type(v.fam) == 'table' then
      for k, on in pairs(v.fam) do S.fam[k] = on ~= false end
    end
    S.scene_name, S.scene_t0 = v.scene_name, tonumber(v.scene_t0)
  end
end

function S.save()
  state.set_scoped('nav.ui', {
    tab = S.tab, focus = S.focus, timesel = S.timesel, loop = S.loop, fam = S.fam,
    scene_name = S.scene_name, scene_t0 = S.scene_t0,
  }, scope())
end

local function bind_project()
  A.stop()
  S.load()
  local left = journal.load()
  D.refresh()
  D.scene = S.scene_name and D.find_scene(S.scene_name, S.scene_t0) or nil
  S.tab_request = S.tab
  S.hi = 0
  A.solo_scene_name, A.mute_scene_name = nil, nil
  if left > 0 then
    if log.selftest_armed() then
      log.selftest('FACT journal_left_from_previous_run=' .. left)
      journal.restore()
    else
      S.recover = left
      S.recover_request = true
    end
  end
  log.info('navigator bound to "%s": %d scenes, %d markers, %d tracks', state.project_name(), #D.scenes, #D.markers, #D.tracks)
end

function M.init(app_)
  app = app_
  A.init(app, D, S)
  U.init(app, D, A, S)
  E.init(app, D, S, A)
  ST.init(app, D, A, S)
  S.clipper = app.ImGui.CreateListClipper(app.ctx)
  app.ImGui.Attach(app.ctx, S.clipper)
  bind_project()
  app.on('project_changed', bind_project)
  app.on('director_active', function(on) S.director_active = on == true end)
  app.on('open_editor', function(kind) E.request_open(kind) end)
  -- the Settings tab (or a preset) changed a navigator list or knob: rebuild the caches that hold them
  config.on_change(function(keys)
    for _, k in ipairs(keys) do
      if k == '' or k == 'navigator' or k:sub(1, 10) == 'navigator.' then
        D.refresh()
        D.invalidate_items()
        return
      end
    end
  end)
end

function M.tick(app_)
  A.tick()
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

-- called by the app on a frame error and at exit: put back everything the navigator changed
function M.restore()
  A.stop()
  local stats = journal.restore(journal.not_owner_pred('director'))
  A.solo_scene_name, A.mute_scene_name = nil, nil
  return stats
end

function M.shutdown()
  journal.flush()
  S.save()
end

M.D, M.A, M.S = D, A, S
return M
