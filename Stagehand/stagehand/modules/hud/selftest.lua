-- modules/hud/selftest.lua - the scripted HUD scenario the test harness runs against the demo project.
-- Pure parts first (layout tiers, caption fitting with a measure stub and a multi-byte caption, the gated
-- loudness integration, the curve parser) so a regression is caught without a window; then the bar window
-- (docking into a bottom docker when the leg's config has one, else floating), the Director's events driving
-- the shot and caption, the live loudness read while Dummy Audio plays, and the flash sequence with its tokens
-- in order and the transport really starting (sabotage "flash_no_play" is the negative control: the sequencer
-- never presses play, so the transport check must go red). Lua 5.4; no globals.

local layout = require('lib.layout')
local view = require('lib.view')
local config = require('config')
local loudness = require('lib.loudness')
local text = require('lib.text')

local ST = {}

local app, H, F, B, U

function ST.init(app_, H_, F_, B_, U_)
  app, H, F, B, U = app_, H_, F_, B_, U_
end

local function set(key, v)
  config.set('hud.' .. key, v, 'project')
end

local function utf8_ok(s)
  return utf8.len(s) ~= nil
end

local function has_token(names, want)
  for _, n in ipairs(names) do
    if n == want then return true end
  end
  return false
end

local function index_of(names, want)
  for i, n in ipairs(names) do
    if n == want then return i end
  end
  return 0
end

function ST.run(T)
  local demo = T.variant == ''
  T.fact('variant', demo and 'demo' or T.variant)
  T.fact('sabotage', T.sabotage == '' and 'none' or T.sabotage)
  T.wait(2)
  reaper.OnStopButton()
  local before = layout.dump()
  layout.write(T.out_path('layout_before.json'), before)

  -- 1. pure: tiers, caption fitting, loudness maths, curve parsing ----------------------------------------------------
  local L = { compact_below_px = 72, tall_above_px = 96, hints_above_px = 130 }
  T.check('tier compact', B.tier(60, L), 'compact')
  T.check('tier medium', B.tier(84, L), 'medium')
  T.check('tier tall', B.tier(120, L), 'tall')
  local function stub(s, size) return (utf8.len(s) or #s) * size * 0.55 end
  local short = 'Two voices open the film.'
  local lines, size = B.fit_caption(short, 600, { 19, 17, 15 }, 1, stub)
  T.check('short caption keeps the first size', size, 19)
  T.check('short caption one line', #lines, 1)
  local long = string.rep('Zażółć gęślą jaźń ', 8)
  lines, size = B.fit_caption(long, 400, { 19, 17, 15 }, 1, stub)
  T.check('long caption falls to the smallest size', size, 15)
  T.ok('long caption cut is UTF-8 safe', #lines == 1 and utf8_ok(lines[1]) and lines[1]:sub(-3) == '...', tostring(lines[1]))
  T.ok('long caption fits the width', stub(lines[1], 15) <= 400, string.format('%.0f px', stub(lines[1], 15)))
  local lines2, size2, cut2 = B.fit_caption(long, 400, { 19, 17, 15 }, 2, stub)
  T.ok('two-line wrap keeps every character of a medium caption', #lines2 == 2 and utf8_ok(lines2[1]) and utf8_ok(lines2[2]), string.format('%d lines size %d cut=%s', #lines2, size2, tostring(cut2)))
  local words = 0
  for _ in (lines2[1] .. ' ' .. (lines2[2] or '')):gmatch('%S+') do words = words + 1 end
  T.fact('wrap_words', string.format('%d of 24 (cut=%s)', words, tostring(cut2)))
  T.check('gated integration of equal blocks', loudness.gated({ -20, -20, -20, -20 }, -10), -20, 0.01)
  T.check('gate drops a block far below the mean', loudness.gated({ -20, -20, -20, -20, -60 }, -10), -20, 0.01)
  T.check('gate needs four blocks', loudness.gated({ -20, -20 }, -10), nil)
  local rows = loudness.parse_curve('# t M S I\n0.0 -23.1 -23.5 -22.0\n0.1, -20.0, -21.0, -21.5\n0.2 -18.0 -19.0 -21.0\nend of file\n')
  T.check('curve rows parsed', #rows, 3)
  T.check('curve row lookup', loudness.curve_row(rows, 0.15)[2], -20.0)
  T.check('curve before the first row', loudness.curve_row(rows, -1), nil)
  T.check('time string min_sec', B.time_string(65.25, 'min_sec'), '1:05.25')
  T.check('time string seconds', B.time_string(65.25, 'seconds'), '65.25 s')
  T.fact('time_string_timecode', B.time_string(65.25, 'timecode'))

  -- 2. the bar window ---------------------------------------------------------------------------------------------------
  local dockers = {}
  if reaper.DockGetPosition then
    for i = 0, 15 do
      local p = reaper.DockGetPosition(i)
      if p >= 0 then dockers[#dockers + 1] = string.format('%d=%d', i, p) end
    end
  end
  T.fact('dockers', #dockers > 0 and table.concat(dockers, ' ') or 'none')
  local bottom = nil
  for i = 0, 15 do
    if reaper.DockGetPosition and reaper.DockGetPosition(i) == 0 then bottom = i; break end
  end
  set('dock', 'bottom'); set('auto_show', true); set('loudness.mode', 'live'); set('caption_lang', 'primary')
  set('show_time', true); set('time_format', 'min_sec'); set('progress.style', 'bar'); set('show_hints', false)
  set('flash.frames', 3); set('flash.gap_frames', 6); set('flash.end_mode', 'custom')
  H.reconfigure()
  H.show(true)
  T.wait(4)
  T.check('bar visible', H.visible, true)
  T.ok('bar drawn with a size', H.bar_w > 100 and H.bar_h > 20, string.format('%dx%d', H.bar_w, H.bar_h))
  T.fact('bar_dock', string.format('dock=%d expected_bottom=%s tier=%s size=%dx%d', H.dock, tostring(bottom), H.tier, H.bar_w, H.bar_h))
  if bottom then
    T.check('bar docked in the bottom docker', H.dock, ~bottom)
  else
    T.check('bar floats (no bottom docker in this config)', H.dock, 0)
  end

  -- 3. the Director's events drive the bar --------------------------------------------------------------------------------
  app.emit('director_shots', 5, 56)
  app.emit('director_active', true)
  app.emit('shot_changed', 2, { name = 'B foley', t0 = 11, t1 = 22, caption = 'Every step and prop is played by hand.', caption2 = 'Second language caption.' })
  T.wait(2)
  T.check('shot received', H.shot_k, 2)
  T.check('title text', B.title_text(), '2/5  B foley')
  T.check('caption primary', B.caption_text(), 'Every step and prop is played by hand.')
  set('caption_lang', 'secondary')
  H.reconfigure()
  T.check('caption secondary', B.caption_text(), 'Second language caption.')
  set('caption_lang', 'primary')
  H.reconfigure()
  T.check('run active seen', H.run_active, true)
  T.check('end at follows the custom mode', H.end_at(), 0, 0.001)

  -- 4. live loudness while Dummy Audio plays ---------------------------------------------------------------------------------
  reaper.SetEditCurPos2(0, 33.5, false, false)
  reaper.OnPlayButton()
  T.wait(20)
  local Ld = H.loud
  T.fact('loudness_live', string.format('m=%.1f s=%.1f i=%.1f pk=%.1f raw1024=%s raw1025=%s blocks=%d', Ld.m, Ld.s, Ld.i, Ld.pk, tostring(Ld.raw[1]), tostring(Ld.raw[2]), #Ld.blocks))
  T.ok('loudness state updates while playing', Ld.last_pos and Ld.last_pos > 33.4, 'last_pos=' .. tostring(Ld.last_pos))
  reaper.OnStopButton()
  T.wait(3)
  set('loudness.mode', 'curve')
  local curve_path = T.out_path('lufs_curve.txt')
  local f = io.open(curve_path, 'w')
  if f then
    f:write('# synthetic curve for the self-test: t M S I\n')
    for i = 0, 400 do f:write(string.format('%.1f %.1f %.1f %.1f\n', i / 10, -20 - (i % 10), -21, -19.5)) end
    f:close()
  end
  set('loudness.curve_file', curve_path)
  H.reconfigure()
  T.check('curve loaded', H.loud.curve ~= nil, true)
  reaper.SetEditCurPos2(0, 5.0, false, false)
  reaper.OnPlayButton()
  T.wait(6)
  T.ok('curve values follow the play position', H.loud.m <= -20 and H.loud.m >= -29.5 and math.abs(H.loud.i - -19.5) < 0.01, string.format('m=%.1f i=%.1f pos=%.2f', H.loud.m, H.loud.i, view.position()))
  reaper.OnStopButton()
  T.wait(3)
  set('loudness.mode', 'live')
  H.reconfigure()

  -- 5. the sync flash: white frames, dark gap, play, tokens, end flash, stop -----------------------------------------------
  F.sabotage = T.sabotage ~= '' and T.sabotage or nil
  reaper.SetEditCurPos2(0, 1.0, false, false)
  set('flash.end_custom_s', 2.2)
  H.reconfigure()
  T.check('end at custom', H.end_at(), 2.2, 0.001)
  H.arm_and_play()
  T.check('flash phase white', F.phase, 'white')
  local white_frames = 0
  T.wait(1)
  for _ = 1, 8 do
    if F.painting() and F.phase == 'white' then white_frames = white_frames + 1 end
    T.wait(1)
  end
  T.check('white phase lasted 3 frames', white_frames, 3)
  local dark_seen = T.wait_until(function() return F.phase == 'dark' or F.phase == 'playing' end, 5)
  T.ok('dark gap follows the white frames', dark_seen, F.phase)
  local play_seen = T.wait_until(function() return F.phase == 'playing' end, 20, 'play phase reached')
  T.ok('transport playing after the flash', play_seen and T.wait_until(function() return view.playing() end, 12), tostring(view.playing()))
  local ended = T.wait_until(function() return F.phase == 'idle' end, 120, 'end flash and stop')
  T.wait(2)
  local names = F.token_names()
  T.fact('flash_tokens', table.concat(names, ' '))
  T.check('tokens start with PLAY_REQUEST', names[1], 'PLAY_REQUEST')
  T.ok('token order', index_of(names, 'FLASH_START') > index_of(names, 'PLAY_REQUEST') and index_of(names, 'PLAY_CMD') > index_of(names, 'FLASH_START')
    and index_of(names, 'PLAY_POS') > index_of(names, 'PLAY_CMD') and index_of(names, 'FLASH_END') > index_of(names, 'PLAY_MOVING') and index_of(names, 'END') > index_of(names, 'FLASH_END'),
    table.concat(names, ' '))
  T.check('transport stopped after the end flash', view.playing(), false)
  T.ok('END token present', has_token(names, 'END'), tostring(ended))
  T.check('start flash painted 3 white frames', F.painted_start, 3)
  T.check('end flash painted 3 white frames', F.painted_end, 3)
  local ft = F.tokens
  if #ft >= 2 then
    local ps, pm, fe = nil, nil, nil
    for _, tk in ipairs(ft) do
      if tk.name == 'PLAY_POS' then ps = tk elseif tk.name == 'PLAY_MOVING' then pm = tk elseif tk.name == 'FLASH_END' then fe = tk end
    end
    if ps and pm then T.fact('engine_start_latency_ms', string.format('%.0f', (pm.t - ps.t) * 1000)) end
    if fe then T.ok('end flash at the custom end', fe.pos >= 2.2 and fe.pos < 2.4, string.format('pos=%.3f', fe.pos)) end
  end
  F.sabotage = nil

  -- 6. hide, restore diff ------------------------------------------------------------------------------------------------------------
  app.emit('director_active', false)
  T.wait(2)
  T.check('auto-show hides the bar when the run ends', H.visible, false)
  local after = layout.dump()
  layout.write(T.out_path('layout_after.json'), after)
  local diff = layout.diff(before, after)
  for i, d in ipairs(diff) do
    if i <= 20 then T.log('DIFF ' .. d) end
  end
  T.log('RESTORE_DIFF ' .. #diff)
  T.check('restore diff', #diff, 0)
  for _, key in ipairs({ 'dock', 'auto_show', 'loudness.mode', 'loudness.curve_file', 'caption_lang', 'show_time', 'time_format', 'progress.style', 'show_hints',
      'flash.frames', 'flash.gap_frames', 'flash.end_mode', 'flash.end_custom_s' }) do
    config.reset('hud.' .. key, 'project')
  end
  H.reconfigure()
  T.fact('frame', T.frame())
end

-- after DONE: the bar with a shot and captions for the screenshots (medium tier docked), then hidden again
function ST.post(frames_since_done)
  if frames_since_done == 5 then
    app.emit('director_shots', 8, 90)
    app.emit('director_active', true)
    app.emit('shot_changed', 4, { name = '04 The lamp goes out', t0 = 33, t1 = 44, caption = 'The keeper climbs the tower as the storm takes the lamp; every step and prop is played by hand.', caption2 = '' })
    H.show(true)
    reaper.SetEditCurPos2(0, 34.0, false, false)
    reaper.OnPlayButton()
  elseif frames_since_done == 260 then
    reaper.OnStopButton()
    app.emit('director_active', false)
  end
end

return ST
