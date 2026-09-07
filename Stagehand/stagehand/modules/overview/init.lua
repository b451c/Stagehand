-- modules/overview/init.lua - the Overview module: one tall picture of the whole session.
-- The layout engine (layout.lua) lays the session out through the journal (owner 'overview'), serves the
-- capture geometry and the page plan, and answers the ctl verb "overview ..." for the companion drivers in
-- tools/ (overview_capture.py); the tab (ui.lua) offers apply / restore, quick settings, the companion command
-- and a guided mode with a page counter window for any screenshot tool. Module contract (docs/architecture.md
-- section 3): init, tick, draw, draw_extra, selftest, restore, shutdown. Lua 5.4; no globals.

local log = require('lib.log')
local journal = require('lib.journal')
local state = require('state')
local config = require('config')
local ctl = require('lib.ctl')
local i18n = require('i18n')
local L = require('modules.overview.layout')
local U = require('modules.overview.ui')
local ST = require('modules.overview.selftest')

local t = i18n.t

local S = { msg = '', msg_frames = 0, compact = false, geometry = nil, geometry_frame = nil, counter_placed = false }

local M = { name = 'overview', title = t('ovw.title') }

local app

local function bind_project()
  if L.capture then L.end_capture('project switch') end
  L.active = false
  L.stats = nil
  L.pages = nil
  log.info('overview bound to "%s": %d journal entries of ours', state.project_name(), journal.count(nil, 'overview'))
end

function M.init(app_)
  app = app_
  L.init(app)
  U.init(app, L, S)
  ST.init(app, L, S, U)
  ctl.on('overview', function(args) L.ctl(args, ctl) end)
  bind_project()
  app.on('project_changed', bind_project)
  app.on('command', function(name)
    if name == 'overview_apply' then L.apply('command')
    elseif name == 'overview_restore' then L.restore('command')
    elseif name == 'overview_guided' then U.start_guided() end
  end)
  config.on_change(function(keys)
    for _, k in ipairs(keys) do
      if (k == '' or k == 'overview' or k:sub(1, 9) == 'overview.') and L.active and not L.capture then
        L.apply('settings')
        return
      end
    end
  end)
end

function M.tick()
  L.tick()
  L.tick_reply(ctl)
  journal.flush()
end

function M.draw(app_)
  U.draw(app_)
end

function M.draw_extra(app_)
  U.draw_counter(app_)
end

function M.selftest(T)
  ST.run(T)
end

function M.selftest_post(frames_since_done)
  ST.post(frames_since_done)
end

-- a frame error or the exit: the overview layout goes back (also entries a previous session left in the project)
function M.restore()
  if L.capture then L.end_capture('restore') end
  if L.active or journal.count(nil, 'overview') > 0 then return L.restore('restore') end
  return nil
end

function M.shutdown()
  journal.flush()
end

M.L, M.S = L, S
return M
