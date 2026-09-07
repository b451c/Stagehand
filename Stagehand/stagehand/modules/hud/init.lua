-- modules/hud/init.lua - the HUD module (BRIEF section 3.4): a dockable caption bar for the recording (shot
-- name, caption, progress, loudness, time, sync flashes) plus the HUD tab that controls it. The bar is a second
-- ReaImGui window drawn through the app's draw_extra hook every frame; it learns about shots from the
-- Director's events (shot_changed, director_active, director_shots) and never requires that module.
-- Module contract (docs/architecture.md section 3): init, tick, draw, draw_extra, selftest, restore, shutdown.
-- The HUD changes nothing in the project; the flash sequencer starts and stops the transport on purpose.
-- Lua 5.4; no globals.

local log = require('lib.log')
local config = require('config')
local state = require('state')
local view = require('lib.view')
local theme = require('ui.theme')
local loudness = require('lib.loudness')
local i18n = require('i18n')
local F = require('modules.hud.flash')
local B = require('modules.hud.bar')
local U = require('modules.hud.ui')
local ST = require('modules.hud.selftest')

local t = i18n.t

local H = {
  visible = false, dock = 0, last_dock = nil, w = 900, h = 84, tier = 'medium', bar_w = 0, bar_h = 0,
  shot_k = nil, shot = nil, n_shots = 0, t_end = nil, run_active = false, loud = nil, msg = '', msg_frames = 0,
  dirty = false, pending_dock = nil, colors = {}, cfg = {}, compact = false, curve_status = '', curve_loaded = nil,
  shown_once = false, tab_msg = '', tab_msg_frames = 0,
}

local M = { name = 'hud', title = t('hud.title') }

local app

local DEFAULT_COLORS = {
  bg = 0x0E1014, text = 0xF2F4F7, muted = 0x8D95A7, dim = 0x4A5163, accent = 0x3AD1FF, accent2 = 0xFFB347,
  warn = 0xF5E663, panel = 0x1A1E26, line = 0x2A2F3B, flash = 0xFFFFFF,
}

local function scope()
  return (H.cfg.persist and H.cfg.persist.scope) or 'project'
end

function H.say(msg)
  H.msg = msg
  H.msg_frames = tonumber(H.cfg.message_frames) or 40
end

-- the curve file: the configured path or <project dir>/Render/stagehand_ctl/lufs_curve.txt
function H.curve_path()
  local Lc = H.cfg.loudness or {}
  if Lc.curve_file and Lc.curve_file ~= '' then return Lc.curve_file end
  local _, name = reaper.EnumProjects(-1, '')
  name = name or ''
  local dir = name:match('^(.*)[/\\]')
  if not dir or dir == '' then return nil end
  local sep = package.config:sub(1, 1)
  return dir .. sep .. 'Render' .. sep .. 'stagehand_ctl' .. sep .. 'lufs_curve.txt'
end

function H.load_curve(path)
  path = path or H.curve_path()
  H.curve_tried = path
  if not path then
    H.curve_status = t('hud.curve.no_project')
    H.curve_loaded = nil
    return false
  end
  local ok, n = loudness.load_curve(H.loud, path)
  if ok then
    H.curve_status = string.format(t('hud.curve.loaded'), n, path)
    H.curve_loaded = path
  else
    H.curve_status = string.format(t('hud.curve.failed'), tostring(H.loud.curve_err), path)
    H.curve_loaded = nil
  end
  log.info('hud curve: %s', H.curve_status)
  return ok
end

function H.reconfigure()
  H.cfg = config.get('hud') or {}
  local cols = H.cfg.colors or {}
  for k, v in pairs(DEFAULT_COLORS) do H.colors[k] = theme.parse_hex(cols[k]) or v end
  local Lc = H.cfg.loudness or {}
  if not H.loud then H.loud = loudness.new(Lc) end
  H.loud.block_s = (tonumber(Lc.block_ms) or 100) / 1000
  H.loud.gate_lu = tonumber(Lc.gate_lu) or -10
  if Lc.mode == 'curve' then
    local want = H.curve_path()
    if want ~= H.curve_loaded and want ~= H.curve_tried then H.load_curve(want) end
  end
end

-- window state ----------------------------------------------------------------------------------------------------------

function H.load()
  local v = state.get_scoped('hud.window', scope())
  H.w = tonumber(H.cfg.window and H.cfg.window.w_px) or 900
  H.h = tonumber(H.cfg.window and H.cfg.window.h_px) or 84
  H.visible, H.dock, H.last_dock = false, 0, nil
  if type(v) == 'table' then
    H.w = tonumber(v.w) or H.w
    H.h = tonumber(v.h) or H.h
    H.last_dock = tonumber(v.last_dock)
    if v.visible == true then
      H.visible = true
      H.pending_dock = tonumber(v.dock) or 0
      H.shown_once = true
    end
  end
end

function H.save()
  state.set_scoped('hud.window', { dock = H.dock, last_dock = H.last_dock, w = math.floor(H.w), h = math.floor(H.h), visible = H.visible }, scope())
  H.dirty = false
end

local function bottom_docker()
  if reaper.DockGetPosition then
    for i = 0, 15 do
      if reaper.DockGetPosition(i) == 0 then return ~i end
    end
  end
  return nil
end

function H.default_dock()
  local mode = H.cfg.dock or 'bottom'
  if mode == 'float' then return 0 end
  if mode == 'last' and H.last_dock and H.last_dock ~= 0 then return H.last_dock end
  return bottom_docker() or 0
end

local MIXER_TOGGLE = 40078

function H.show(on)
  on = on ~= false
  if on == H.visible then return end
  H.visible = on
  if on then
    -- the bar may land in the docker that holds the mixer (Windows leg: the mixer docked at the bottom); when the
    -- bar closes again REAPER leaves the mixer's toggle off, so the mixer state is remembered and re-asserted
    H.mixer_at_show = view.toggle_state(MIXER_TOGGLE, 'mixer')
    H.mixer_check = nil
  else
    H.mixer_check = 4
  end
  if on and not H.shown_once then
    H.shown_once = true
    H.pending_dock = H.default_dock()
  end
  H.dirty = true
end

function H.mixer_recheck()
  if not H.mixer_check then return end
  H.mixer_check = H.mixer_check - 1
  if H.mixer_check > 0 then return end
  H.mixer_check = nil
  if H.mixer_at_show == 1 and view.toggle_state(MIXER_TOGGLE, 'mixer') == 0 then
    reaper.Main_OnCommand(MIXER_TOGGLE, 0)
    log.info('hud: the mixer toggle went off when the bar closed (shared docker); toggled back on')
  end
end

function H.toggle_dock()
  if H.dock ~= 0 then
    H.pending_dock = 0
  else
    local target = H.last_dock
    if not target or target == 0 then target = bottom_docker() or 0 end
    H.pending_dock = target
  end
end

-- the flash ----------------------------------------------------------------------------------------------------------------

function H.end_at()
  local fl = H.cfg.flash or {}
  local pad = tonumber(fl.end_pad_s) or 0.17
  local mode = fl.end_mode or 'last_shot'
  if mode == 'custom' then return tonumber(fl.end_custom_s) or 0 end
  if mode == 'last_shot' and H.t_end and H.t_end > 0 then return H.t_end + pad end
  return reaper.GetProjectLength(0) + pad
end

function H.arm_and_play()
  H.show(true)
  F.start(H.cfg.flash or {}, H.end_at())
  H.say(t('hud.msg.armed'))
end

-- module ----------------------------------------------------------------------------------------------------------------------

local function bind_project()
  H.reconfigure()
  H.load()
  H.shot_k, H.shot, H.run_active = nil, nil, false
  H.curve_loaded, H.curve_tried = nil, nil
  if H.cfg.loudness and H.cfg.loudness.mode == 'curve' then H.load_curve() end
  log.info('hud bound to "%s": visible=%s dock=%s', state.project_name(), tostring(H.visible), tostring(H.pending_dock or H.dock))
end

function M.init(app_)
  app = app_
  F.init(app)
  B.init(app, H, F)
  U.init(app, H, F, B)
  ST.init(app, H, F, B, U)
  bind_project()
  app.on('project_changed', bind_project)
  app.on('shot_changed', function(k, s)
    H.shot_k, H.shot = k, s
  end)
  app.on('director_active', function(on)
    H.run_active = on == true
    if not H.run_active then H.shot_k, H.shot = nil, nil end
    if H.cfg.auto_show ~= false and H.cfg.enable ~= false then H.show(H.run_active) end
  end)
  app.on('director_shots', function(n, t_end)
    H.n_shots, H.t_end = tonumber(n) or 0, tonumber(t_end)
  end)
  app.on('command', function(name)
    if name == 'hud_show' then H.show(true) elseif name == 'hud_hide' then H.show(false) elseif name == 'hud_toggle' then H.show(not H.visible)
    elseif name == 'hud_arm_play' then H.arm_and_play()
    elseif name == 'hud_cancel' then
      if F.active() then F.cancel('command') end
      reaper.OnStopButton()
    end
  end)
  app.on('message', function(msg) H.say(tostring(msg)) end)
  config.on_change(function(keys)
    for _, k in ipairs(keys) do
      if k == '' or k == 'hud' or k:sub(1, 4) == 'hud.' then H.reconfigure(); return end
    end
  end)
end

function M.tick(app_)
  if app_.frame % 60 == 0 then H.reconfigure() end
  if H.msg_frames > 0 then H.msg_frames = H.msg_frames - 1 end
  local mode = (H.cfg.loudness and H.cfg.loudness.mode) or 'live'
  if H.visible or F.active() then
    -- the master loudness channels cost about 0.05 ms per read on the legs: every frame while playing, every
    -- sixth frame while the transport stands still (the values do not move then)
    local playing = view.playing()
    if playing or app_.frame % 6 == 0 then
      loudness.update(H.loud, mode, playing, view.position(), reaper.time_precise())
    end
  end
  F.tick(H.visible)
  H.mixer_recheck()
  if H.dirty and app_.frame % 30 == 0 then H.save() end
end

function M.draw(app_)
  U.draw(app_)
end

function M.draw_extra(app_)
  B.draw(app_)
end

function M.selftest(T)
  ST.run(T)
end

function M.selftest_post(frames_since_done)
  ST.post(frames_since_done)
end

-- a frame error or the exit: a running flash sequence ends and the transport it started stops
function M.restore()
  if F.phase == 'playing' or F.phase == 'end_white' then reaper.OnStopButton() end
  F.cancel('restore')
  return nil
end

function M.shutdown()
  H.save()
end

M.H, M.F, M.B = H, F, B
return M
