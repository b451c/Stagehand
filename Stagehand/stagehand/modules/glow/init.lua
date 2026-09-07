-- modules/glow/init.lua - the Glow module (BRIEF section 3.3): a per-frame overlay composited over the arrange
-- that glows with the sound (js_ReaScriptAPI). Module contract (docs/architecture.md section 3): init, tick,
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
      if k == '' or k == 'glow' or k:sub(1, 5) == 'glow.' or k:sub(1, 20) == 'navigator.families' or k:sub(1, 26) == 'navigator.marker_classes' then
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
