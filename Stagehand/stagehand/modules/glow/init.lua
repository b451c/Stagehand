-- modules/glow/init.lua - the Glow module: a per-frame overlay composited over the arrange
-- that glows with the sound (js_ReaScriptAPI). Module contract (app.register): init, tick,
-- draw, selftest, restore, shutdown. The overlay never touches the project; restore() and shutdown() release
-- the bitmap. Lua 5.4; no globals.

local log = require('lib.log')
local config = require('config')
local state = require('state')
local i18n = require('i18n')
local E = require('modules.glow.engine')
local O = require('modules.glow.overlay')
local U = require('modules.glow.ui')
local ST = require('modules.glow.selftest')

local t = i18n.t

local S = { msg = '', msg_frames = 0, compact = false }

local M = { name = 'glow', title = t('glow.title') }

local app

-- the config keys the glow depends on: its own and the Navigator's families / marker classes (the tints and the cut
-- flashes come from them)
local WATCHED = { 'glow', 'navigator.families', 'navigator.marker_classes' }

-- true when a changed key touches a watched one: everything (''), the key itself, a sub-key of it, or a group above
-- it (a reset of 'navigator' changes the families too)
function M.watches(k)
  if k == '' then return true end
  for _, w in ipairs(WATCHED) do
    if k == w or k:sub(1, #w + 1) == w .. '.' or w:sub(1, #k + 1) == k .. '.' then return true end
  end
  return false
end

local function bind_project()
  E.rescan()
  E.reconfigure()
  log.info('glow bound to "%s": %d tracks, composite=%s', state.project_name(), #E.tracks, tostring(O.available()))
end

function M.init(app_)
  app = app_
  E.init(app)
  U.init(app, E, S)
  ST.init(app, E, S, U)
  bind_project()
  app.on('project_changed', bind_project)
  app.on('command', function(name)
    if name == 'glow_toggle' then U.toggle_enable()
    elseif name == 'glow_on' then if config.get('glow.enable') == false then U.toggle_enable() end
    elseif name == 'glow_off' then if config.get('glow.enable') ~= false then U.toggle_enable() end
    end
  end)
  config.on_change(function(keys)
    for _, k in ipairs(keys) do
      if M.watches(k) then
        E.request_reconfigure()   -- once per frame however many keys a drag or a preset touched
        return
      end
    end
  end)
end

function M.tick()
  E.tick()
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

-- a frame error or the exit: the overlay disappears (nothing in the project to put back)
function M.restore()
  E.release()
  return nil
end

function M.shutdown()
  E.log_flush()
  E.release()
end

M.E, M.O, M.S = E, O, S
return M
