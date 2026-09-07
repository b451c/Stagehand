-- modules/settings/init.lua - the Settings module (BRIEF section 3.7): every knob of every module in one tab
-- drawn from schema.lua, with search, tooltips, live preview, reset per key / group / scope, the two scopes
-- (this project / global), presets (shipped and the user's own, import / export as JSON) and the report of
-- invalid values found in the layers. Module contract (docs/architecture.md section 3): init, draw,
-- selftest, restore, shutdown. Settings changes nothing in the project besides the project's own config
-- record (ProjExtState), which is what the user asked for. Lua 5.4; no globals.

local log = require('lib.log')
local config = require('config')
local state = require('state')
local i18n = require('i18n')
local P = require('modules.settings.presets')
local U = require('modules.settings.ui')
local ST = require('modules.settings.selftest')

local t = i18n.t

local S = {
  scope = 'project', search = '', open = { navigator = true, director = false, hud = false, glow = false, ui = false },
  msg = '', msg_frames = 0, compact = false, edit = {}, errors = {}, visible_rows = 0, dirty = false,
  json = nil, json_request = false, confirm_reset = false, focus_search = false, search_active = false,
  presets = nil, presets_frame = nil, preset_name = nil, preset_source = nil,
}

local M = { name = 'settings', title = t('set.title') }

local app

function S.load()
  local v = state.gget_json('settings.ui')
  if type(v) == 'table' then
    if v.scope == 'project' or v.scope == 'global' then S.scope = v.scope end
    if type(v.open) == 'table' then
      for k, on in pairs(v.open) do S.open[k] = on == true end
    end
  end
end

function S.save()
  state.gset_json('settings.ui', { scope = S.scope, open = S.open })
  S.dirty = false
end

function M.init(app_)
  app = app_
  P.init(app)
  U.init(app, S)
  ST.init(app, S, U, P)
  S.load()
  app.on('command', function(name)
    if name == 'settings_show' then app.set_tab('settings') end
  end)
  log.info('settings ready: %d keys, %d groups, user presets in %s', #require('schema').keys, #require('schema').groups, P.user_dir())
end

function M.tick(app_)
  if S.dirty and app_.frame % 30 == 0 then S.save() end
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

-- nothing in the project to put back; a pending slider drag is written so no change is lost
function M.restore()
  config.commit('project')
  config.commit('global')
  return nil
end

function M.shutdown()
  config.commit('project')
  config.commit('global')
  S.save()
end

M.S, M.P = S, P
return M
