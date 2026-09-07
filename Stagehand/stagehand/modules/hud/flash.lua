-- modules/hud/flash.lua - the sync flash sequencer for screen recordings.
--
-- start(): the bar paints white for `frames` defer frames, then `gap` dark frames, then the transport starts;
-- while playing the sequencer waits for the play position to pass end_at, paints white again for `frames`
-- frames and stops. Tokens with the wall time (time_precise) and the play position are emitted at every phase
-- edge - PLAY_REQUEST, FLASH_START (the first dark frame), PLAY_CMD, PLAY_POS (the first playing frame),
-- PLAY_MOVING (position > start + 50 ms: the engine really runs), FLASH_END (the first white frame of the end
-- flash), END - as the app event "hud_flash" and as HUD FLASH lines in the log; the recorder companions (M5)
-- write them to their state file. A transport stop by the user cancels the sequence. Lua 5.4; no globals.

local log = require('lib.log')
local view = require('lib.view')

local F = { phase = 'idle', frame = 0, tokens = {}, start_pos = nil, end_at = nil, cfg = { frames = 3, gap = 6 },
  playing_seen = false, moving_seen = false, sabotage = nil, painted_start = 0, painted_end = 0 }

local app

function F.init(app_)
  app = app_
end

local function token(name, pos)
  local wall = reaper.time_precise()
  F.tokens[#F.tokens + 1] = { name = name, t = wall, pos = pos }
  log.info('hud flash %s pos=%.3f t=%.4f', name, pos, wall)
  if log.selftest_armed() then log.selftest(string.format('HUD FLASH %s pos=%.3f t=%.4f', name, pos, wall)) end
  if app then app.emit('hud_flash', name, wall, pos) end
end

-- cfg = { frames, gap_frames }; end_at = project time of the end flash (nil = never, stop by hand)
function F.start(cfg, end_at)
  F.cfg = { frames = math.max(1, math.floor(tonumber(cfg.frames) or 3)), gap = math.max(0, math.floor(tonumber(cfg.gap_frames) or 6)) }
  if view.playing() then reaper.OnStopButton() end
  F.phase = 'white'
  F.frame = 0
  F.tokens = {}
  F.end_at = end_at
  F.playing_seen, F.moving_seen = false, false
  F.painted_start, F.painted_end = 0, 0
  F.start_pos = reaper.GetCursorPosition()
  token('PLAY_REQUEST', F.start_pos)
  return true
end

function F.cancel(why)
  if F.phase == 'idle' then return false end
  local was = F.phase
  F.phase = 'idle'
  token('CANCEL', view.position())
  log.info('hud flash cancelled in phase %s (%s)', was, tostring(why))
  return true
end

function F.active()
  return F.phase ~= 'idle'
end

-- true while the bar must be painted white
function F.painting()
  return F.phase == 'white' or F.phase == 'end_white'
end

-- the bar reports every white frame it really painted (the self-test's oracle for the flash lengths)
function F.painted()
  if F.phase == 'white' then F.painted_start = F.painted_start + 1
  elseif F.phase == 'end_white' then F.painted_end = F.painted_end + 1 end
end

-- bar_visible: while the bar paints, the white phases are measured in painted frames (F.painted); without a
-- visible bar the tick counter stands in so the sequence still completes
function F.tick(bar_visible)
  local phase = F.phase
  if phase == 'idle' then return end
  local playing = view.playing()
  local pos = view.position()
  F.frame = F.frame + 1
  if phase == 'white' then
    local done = bar_visible and (F.painted_start >= F.cfg.frames) or (not bar_visible and F.frame > F.cfg.frames)
    if done then
      F.phase = 'dark'
      F.frame = 1   -- this frame is the first dark one
      token('FLASH_START', pos)
    end
  elseif phase == 'dark' then
    if F.frame > F.cfg.gap then
      if F.sabotage ~= 'flash_no_play' then reaper.OnPlayButton() end
      token('PLAY_CMD', pos)
      F.phase = 'playing'
      F.frame = 0
    end
  elseif phase == 'playing' then
    if playing then
      if not F.playing_seen then
        F.playing_seen = true
        token('PLAY_POS', pos)
      end
      if not F.moving_seen and pos > F.start_pos + 0.05 then
        F.moving_seen = true
        token('PLAY_MOVING', pos)
      end
      if F.end_at and pos >= F.end_at then
        F.phase = 'end_white'
        F.frame = 0
        token('FLASH_END', pos)
      end
    elseif F.playing_seen or F.frame > 90 then
      F.phase = 'idle'
      token('STOPPED', pos)
    end
  elseif phase == 'end_white' then
    local done = bar_visible and (F.painted_end >= F.cfg.frames) or (not bar_visible and F.frame > F.cfg.frames)
    if done then
      reaper.OnStopButton()
      F.phase = 'idle'
      token('END', pos)
    end
  end
end

function F.token_names()
  local out = {}
  for _, tk in ipairs(F.tokens) do out[#out + 1] = tk.name end
  return out
end

return F
