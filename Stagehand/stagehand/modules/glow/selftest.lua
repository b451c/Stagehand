-- modules/glow/selftest.lua - the scripted Glow scenario the test harness runs against the demo project with
-- its media online. Oracles independent of the engine: REAPER's
-- own list of composited bitmaps (JS_Composite_ListBitmaps), the take peaks read directly, item positions from
-- the API, lib/layout.dump() before and after (the glow must not touch the project). The fake meter drives the
-- pipeline on a test machine without audio (Dummy Audio keeps the meters silent); one section switches it off to prove
-- the sparks come from the real take peaks of the generated media. Sabotage "leave_bitmap" (negative control)
-- skips the unlink at disable so the bitmap oracle must go red. Lua 5.4; no globals.

local layout = require('lib.layout')
local view = require('lib.view')
local config = require('config')
local meter = require('lib.meter')
local peaks = require('lib.peaks')
local js = require('platform.js')
local O = require('modules.glow.overlay')

local ST = {}

local app, E, S, U

function ST.init(app_, E_, S_, U_)
  app, E, S, U = app_, E_, S_, U_
end

local function track_by_name(name)
  for k = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, k)
    local _, n = reaper.GetTrackName(tr)
    if n == name then return tr end
  end
  return nil
end

-- the first item on a track whose start lies within tol of t
local function item_starting_at(tr, t, tol)
  for j = 0, reaper.CountTrackMediaItems(tr) - 1 do
    local it = reaper.GetTrackMediaItem(tr, j)
    local p = reaper.GetMediaItemInfo_Value(it, 'D_POSITION')
    if math.abs(p - t) <= (tol or 0.01) then return it, p end
  end
  return nil
end

local function marker_named(prefix)
  local i = 0
  while true do
    local ret, isrgn, pos, _, name = reaper.EnumProjectMarkers3(0, i)
    if ret == 0 then break end
    i = i + 1
    if not isrgn and name:sub(1, #prefix) == prefix then return pos, name end
  end
  return nil
end

local function play_from(t)
  reaper.OnStopButton()
  reaper.SetEditCurPos2(0, t, false, false)
  reaper.OnPlayButton()
end

local function set(key, v)
  config.set('glow.' .. key, v, 'project')
end

-- the last region of the project (id for SetProjectMarker3, bounds, name, colour)
local function last_region()
  local rid, r_t0, r_t1, r_name, r_col
  for i = 0, reaper.CountProjectMarkers(0) - 1 do
    local _, isrgn, p0, p1, name, id, col = reaper.EnumProjectMarkers3(0, i)
    if isrgn then rid, r_t0, r_t1, r_name, r_col = id, p0, p1, name, col end
  end
  return rid, r_t0, r_t1, r_name, r_col
end

local look = nil

-- the B2 visual check (failure note B2, macOS test machine): the overlay enabled and idle after a short play,
-- then a companion drags the last region's end in the ruler with the real mouse while this samples REAPER's list
-- of composited bitmaps (must stay 0: the arrange paints on its own path), the project state bumps and the frame
-- cost; the companion captures the arrange during the drag (the pictures are the visual evidence). drag.txt:
-- "x y" of the region end in the ruler (screen, y down) and the arrange rect on the second line.
function ST.b2drag(T)
  local sep = package.config:sub(1, 1)
  local edits = require('lib.edits')
  T.fact('js_composite', tostring(js.caps.composite))
  if not O.available() then
    T.ok('glow needs js_ReaScriptAPI (composite)', false, 'not available on this machine')
    return
  end
  T.wait(2)
  reaper.OnStopButton()
  local before = layout.dump()
  layout.write(T.out_path('layout_before.json'), before)
  set('enable', true); set('mode', 'meter'); set('style', 'bar'); set('debug.fake_meter', false); set('debug.log', true)
  E.reconfigure()
  T.check('engine active', E.active(), true)
  play_from(0.5)
  T.wait(30)
  T.ok('bitmap composited while playing', O.bmp ~= nil, O.describe())
  reaper.OnStopButton()
  T.wait_until(function() return O.bmp == nil end, 200, 'bitmap released after the stop')
  T.wait(20)
  local listed_idle = O.listed()
  T.check('idle: REAPER lists no composited bitmap', listed_idle, 0)
  -- the geometry for the companion: the last region's end in the ruler, view over the region
  local r_idx, r_t0, r_t1, r_name, r_col = last_region()
  T.ok('a region to drag', r_t1 ~= nil, tostring(r_t1))
  if not r_t1 then return end
  reaper.GetSet_ArrangeView2(0, true, 0, 0, math.max(0, r_t1 - 8), r_t1 + 4)
  T.wait(5)
  local main = reaper.GetMainHwnd()
  local arrange = reaper.JS_Window_FindChildByID(main, 1000)
  local ruler = reaper.JS_Window_FindChildByID(main, 1005)
  local al, at, ar, ab = js.child_rect(arrange)   -- y down on macOS too
  local rl, rt, rr, rb = js.child_rect(ruler)
  local ml, mt, mr, mb = js.rect(main)
  local v0, v1 = view.get()
  local pps = (ar - al) / (v1 - v0)
  local x = math.floor(al + (r_t1 - v0) * pps + 0.5)
  local y = rt + 8   -- the region lane is the ruler's top band (macOS default theme: 15 px); the companion tries rt + 8 and rt + 12
  T.fact('drag_geometry', string.format('main=%d,%d-%d,%d arrange=%d,%d-%d,%d ruler=%d,%d-%d,%d view=%.2f-%.2f pps=%.2f x=%d y=%d region=%.3f-%.3f',
    ml, mt, mr, mb, al, at, ar, ab, rl, rt, rr, rb, v0, v1, pps, x, y, r_t0, r_t1))
  local f = io.open(T.out_path('drag.txt'), 'w')
  if f then f:write(string.format('%d %d\n%d %d %d %d\n%d %d %d %d\n', x, y, al, at, ar, ab, rl, rt, rr, rb)); f:close() end
  local go = io.open(T.out_path('companion_go.txt'), 'w')
  if go then go:write('go\n'); go:close() end
  T.log('COMPANION GO drag')
  -- phase 1 (0-18 s): the companion's mouse gestures; phase 2 (18-26 s): the region end moved by parameter from here,
  -- in undo blocks like a user's edit in the Region/Marker Manager (the owner's suggestion: a region change needs no
  -- mouse), 0.05 s per frame out and back; the companion keeps capturing the arrange through both phases. Sampled per
  -- frame: the composite list, the state count, the frame cost, the rescans.
  local t0 = reaper.time_precise()
  local c0 = reaper.GetProjectStateChangeCount(0)
  local bumps, listed_max, frame_max, frames, slow = 0, 0, 0, 0, 0
  local rescans0 = E.edits_rescanned or 0
  local c_last = c0
  local mouse_bumps, mouse_t1 = 0, nil
  local api_steps, api_moved_max = 0, 0
  while reaper.time_precise() - t0 < 26 do
    T.wait(1)
    frames = frames + 1
    local now = reaper.time_precise() - t0
    if now >= 18 then
      if not mouse_t1 then
        mouse_bumps = bumps
        local _, _, t1m = last_region()
        mouse_t1 = t1m or r_t1
      end
      api_steps = api_steps + 1
      local k = api_steps
      local d = (k <= 80) and (0.05 * k) or (0.05 * math.max(0, 160 - k))
      reaper.Undo_BeginBlock2(0)
      reaper.SetProjectMarker3(0, r_idx, true, r_t0, r_t1 + d, r_name or '', r_col or 0)
      reaper.Undo_EndBlock2(0, 'b2drag region end', -1)
      reaper.UpdateTimeline()
      if d > api_moved_max then api_moved_max = d end
    end
    local c = reaper.GetProjectStateChangeCount(0)
    if c ~= c_last then bumps = bumps + 1; c_last = c end
    local l = O.listed()
    if l > listed_max then listed_max = l end
    local ms = app.tick_ms_last
    if ms > frame_max then frame_max = ms end
    if ms > 50 then slow = slow + 1 end
  end
  local _, t0_now, t1_now = last_region()
  T.fact('drag_result', string.format('frames=%d state_bumps=%d mouse_bumps=%d mouse_region_end=%.3f region_before=%.3f-%.3f api_steps=%d api_moved_max=%.2f after=%.3f-%.3f rescans=%d frame_max_ms=%.1f slow_frames=%d listed_max=%d',
    frames, bumps, mouse_bumps, mouse_t1 or -1, r_t0, r_t1, api_steps, api_moved_max, t0_now or -1, t1_now or -1, (E.edits_rescanned or 0) - rescans0, frame_max, slow, listed_max))
  T.fact('mouse_gesture', string.format('bumps=%d region_end_after_mouse=%.3f (a synthetic drag on macOS scrolls the ruler; informational)', mouse_bumps, mouse_t1 or -1))
  T.ok('the region end moved by parameter while the overlay was idle', api_steps > 20 and api_moved_max >= 1.0, string.format('steps=%d max=%.2f s', api_steps, api_moved_max))
  T.ok('the parameter edits bumped the project state (undo blocks)', bumps - mouse_bumps >= 20, string.format('%d bumps during the api phase', bumps - mouse_bumps))
  T.check('idle overlay during the edits: REAPER lists no composited bitmap', listed_max, 0)
  T.ok('no slow frame during the edits', slow == 0, string.format('%d frames over 50 ms, max %.1f ms', slow, frame_max))
  T.ok('bitmap still absent after the edits', O.bmp == nil, O.describe())
  -- put the region back
  if t1_now and math.abs(t1_now - r_t1) > 1e-6 then reaper.SetProjectMarker3(0, r_idx, true, r_t0, r_t1, r_name or '', r_col or 0) end
  T.wait(5)
  local _, t0_b, t1_b = last_region()
  T.check('region end back', t1_b or -1, r_t1, 0.001)
  set('enable', false); E.reconfigure()
  T.wait(5)
  local after = layout.dump()
  layout.write(T.out_path('layout_after.json'), after)
  local diff = layout.diff(before, after)
  T.log('RESTORE_DIFF ' .. #diff)
  T.check('restore diff', #diff, 0)
  for _, k in ipairs({ 'enable', 'mode', 'style', 'debug.fake_meter', 'debug.log' }) do config.reset('glow.' .. k, 'project') end
end

function ST.run(T)
  local demo = T.variant == ''
  T.fact('variant', demo and 'demo' or T.variant)
  if T.variant:sub(1, 5) == 'look:' then
    -- screenshots of one spark style: no checks, the fake meter, a slow spark decay so the shape is on the picture
    look = T.variant:sub(6)
    set('enable', true); set('mode', 'meter'); set('style', 'bar'); set('debug.fake_meter', true)
    set('spark.style', look); set('spark.decay_s', 1.2); set('spark.alpha', 0.85)
    E.reconfigure()
    T.fact('look', look)
    T.check('look style set', E.cfg.spark.style, look)
    return
  end
  if T.variant == 'b2drag' then return ST.b2drag(T) end
  T.fact('sabotage', T.sabotage == '' and 'none' or T.sabotage)
  T.fact('js_composite', tostring(js.caps.composite))
  T.fact('js_version', tostring(js.caps.js_version))
  if not O.available() then
    T.ok('glow needs js_ReaScriptAPI (composite)', false, 'not available on this machine')
    return
  end
  T.wait(2)

  -- 0. baseline ---------------------------------------------------------------------------------------------------
  reaper.OnStopButton()
  local before = layout.dump()
  layout.write(T.out_path('layout_before.json'), before)
  local cw, ch = O.client_size()
  T.fact('arrange_client', string.format('%sx%s', tostring(cw), tostring(ch)))
  local keys = { 'enable', 'mode', 'style', 'debug.fake_meter', 'debug.log', 'cut_flash.enable', 'perf.budget_ms', 'perf.over_frames',
    'perf.recover_frames', 'render.oversample', 'bus.enable' }
  set('enable', true); set('mode', 'meter'); set('style', 'bar'); set('debug.fake_meter', true); set('debug.log', true)
  set('cut_flash.enable', true); set('perf.budget_ms', 2.0); set('perf.over_frames', 30); set('perf.recover_frames', 300)
  set('render.oversample', 2); set('bus.enable', true)
  E.reconfigure()
  E.perf_reset()
  E.perf.level = 0
  T.check('engine active', E.active(), true)
  T.check('fake meter on', E.fake, true)
  if demo then T.check('tracks', #E.tracks, 53) end

  -- 1. the overlay exists and REAPER lists it ------------------------------------------------------------------------
  play_from(0.5)
  T.wait(3)
  T.ok('bitmap created', O.bmp ~= nil, O.describe())
  T.check('oversample 2', O.S, 2)
  T.check('bitmap size follows the client', O.w == cw and O.h == ch, true)
  local n_listed, list = O.listed()
  T.check('REAPER lists one composited bitmap', n_listed, 1)
  T.fact('composite_list', list)
  T.wait(20)
  local x_right = E.x_of(E.t_right)
  T.ok('px mapping spans the client width', x_right and math.abs(x_right - O.w) < 2, string.format('x(t_right)=%s w=%d pps=%.2f', tostring(x_right), O.w, E.pps or 0))
  T.ok('rows lit under the play head (fake meter)', E.stats.lit > 0, 'lit=' .. E.stats.lit)
  T.ok('items lit', E.stats.items_lit_max > 0, 'items_lit_max=' .. E.stats.items_lit_max)
  T.wait(40)
  T.ok('sparks fired from the fake onsets', E.stats.sparks > 0, 'sparks=' .. E.stats.sparks)
  T.ok('bus band lit on an item-less parent', E.stats.bus_lit_max > 0, 'bus_lit_max=' .. E.stats.bus_lit_max)
  local real = meter.track_db(track_by_name('DX Mara') or reaper.GetTrack(0, 0))
  local lm, ls, lpk, ra, rb = meter.master()
  T.fact('real_meter_while_playing', string.format('track=%.1f master_m=%.1f master_s=%.1f peak=%.1f raw1024=%s raw1025=%s', real, lm, ls, lpk, tostring(ra), tostring(rb)))

  -- 1b. region edits while playing (failure note B2): a region edge dragged for 30 frames bumps the
  -- project state every frame; the item rescan waits for the edit to settle and the bitmap stays
  local rid, r_t0, r_t1, r_name, r_col = last_region()
  if rid then
    local r0, d0 = E.edit_rescans or 0, E.edits_deferred or 0
    local created0 = O.created
    local sc0 = reaper.GetProjectStateChangeCount(0)
    local ms_sum, ms_max = 0, 0
    for f = 1, 30 do
      reaper.Undo_BeginBlock2(0)   -- the only scripted edit that bumps the project state (an edit probe)
      reaper.SetProjectMarker3(0, rid, true, r_t0, r_t1 + 0.01 * f, r_name, r_col)
      reaper.Undo_EndBlock2(0, 'Stagehand self-test: region edge', -1)
      T.wait(1)
      ms_sum = ms_sum + app.tick_ms_last
      if app.tick_ms_last > ms_max then ms_max = app.tick_ms_last end
    end
    reaper.SetProjectMarker3(0, rid, true, r_t0, r_t1, r_name, r_col)
    T.wait(3)
    local rescans = (E.edit_rescans or 0) - r0
    local state_delta = reaper.GetProjectStateChangeCount(0) - sc0
    T.fact('edit_burst_playing', string.format('state_delta=%d rescans=%d deferred=%d bitmaps=%d frame_ms_avg=%.2f max=%.2f',
      state_delta, rescans, (E.edits_deferred or 0) - d0, O.created - created0, ms_sum / 30, ms_max))
    T.ok('region edits bump the project state', state_delta >= 30, 'delta=' .. state_delta)
    T.ok('item rescans wait for the edit to settle', rescans >= 1 and rescans <= 3, 'rescans=' .. rescans)
    T.check('the overlay bitmap survives the edits', O.created - created0, 0)
  else
    T.ok('a region exists for the edit burst', false, 'no region')
  end
  reaper.OnStopButton()
  T.wait(3)
  local ps = E.perf_stats()
  T.fact('draw_ms_meter_bar', string.format('avg=%.3f max=%.3f p95=%.3f frames=%d lit_max=%d', ps.avg, ps.max, ps.p95, ps.frames, E.stats.lit_max))
  T.ok('draw time under the 2 ms budget (avg)', ps.avg < 2.0, string.format('avg=%.3f', ps.avg))
  T.ok('draw time p95 under 4 ms', ps.p95 < 4.0, string.format('p95=%.3f', ps.p95))
  local overlay_cleared = T.wait_until(function() return not E.alive end, 120, 'overlay decays after stop')
  T.fact('decay_after_stop', tostring(overlay_cleared))
  -- idle: nothing composited (macOS drew the arrange coarse through an idle composite, failures B2)
  T.wait(3)
  T.check('idle: bitmap released when nothing is drawn', O.bmp == nil, true)
  local n_idle = O.listed()
  T.check('idle: REAPER lists no composited bitmap', n_idle, 0)

  -- 2. the take peaks: real level and spark timing from the generated media ------------------------------------------
  local hit_t = marker_named('HIT lamp') or 40.0
  local impacts = track_by_name('Impacts L1')
  local it, it_t0
  if impacts then it, it_t0 = item_starting_at(impacts, hit_t, 0.02) end
  T.fact('hit_marker', tostring(hit_t))
  if it then
    -- GetMediaItemTake_Peaks returns nil when called from a coroutine (the scenario runs in one; verified on
    -- both test machines, failure note G1, so every take-peak read of the scenario goes through a plain
    -- defer callback in the main Lua state - the engine's own reads happen in the app's tick anyway
    local fresh = reaper.new_array(16)
    fresh.clear()
    local take = reaper.GetActiveTake(it)
    local r_co = reaper.GetMediaItemTake_Peaks(take, 400, it_t0, 1, 4, 0, fresh)
    local box = {}
    local function in_main(fn)
      box = {}
      reaper.defer(function() box.ok, box.a, box.b = pcall(fn) end)
      T.wait(2)
      return box
    end
    local t_peaks = reaper.time_precise()
    local online = false
    for _ = 1, 75 do
      local r = in_main(function() return peaks.available(it) end)
      if r.ok and r.a then online = true; break end
    end
    T.fact('peaks_in_coroutine', tostring(r_co))
    T.fact('peaks_online', string.format('%s after %.1f s', tostring(online), reaper.time_precise() - t_peaks))
    T.ok('take peaks readable from the main state', online, 'media offline or no peaks')
    if online then
      local r = in_main(function() return peaks.take_db(it, nil, it_t0 + 0.05, 0.05) end)
      T.ok('take peaks give a level for the impact', r.ok and r.a ~= nil and r.a > -30, string.format('db=%s at=%s', tostring(r.a), tostring(r.b)))
      set('debug.fake_meter', false)
      E.reconfigure()
      T.check('fake meter off', E.fake, false)
      -- the glow paints only rows inside the arrange client: bring the impacts row on screen (scroll is not part
      -- of the restore diff; it is put back after the check anyway)
      local arrange = require('lib.arrange')
      local scroll0 = arrange.scroll_pos()
      arrange.scroll_to_track(impacts, 0)
      T.wait(2)
      T.fact('impacts_row', string.format('tcpy=%d tcph=%d client_h=%d', reaper.GetMediaTrackInfo_Value(impacts, 'I_TCPY'), reaper.GetMediaTrackInfo_Value(impacts, 'I_TCPH'), O.h))
      play_from(hit_t - 0.6)
      T.wait_until(function() return view.position() > hit_t + 0.4 end, 90, 'played across the hit')
      reaper.OnStopButton()
      if scroll0 then arrange.set_scroll_pos(scroll0) end
      local item = E.item_state(it)
      local st = item and item.env
      T.ok('item envelope ran on the impact', st ~= nil, tostring(st ~= nil))
      if st then
        T.fact('impact_item', string.format('sparks=%d spark_pos=%s raw=%s gmax=%.2f', st.sparks, tostring(st.spark_pos), tostring(st.raw), st.gmax))
        T.ok('spark from the real take peaks', st.sparks >= 1 and st.raw == true, string.format('sparks=%d raw=%s', st.sparks, tostring(st.raw)))
        T.ok('first spark within 60 ms of the impact start', st.spark_pos ~= nil and st.spark_pos >= it_t0 - 0.001 and st.spark_pos <= it_t0 + 0.06,
          string.format('spark_pos=%s item_t0=%.3f', tostring(st.spark_pos), it_t0))
      end
      T.wait(3)
    end
  else
    T.log('NOTE no impact item at the HIT marker: take-peak checks skipped')
  end
  set('debug.fake_meter', true)
  E.reconfigure()

  -- 3. cut flash on a marker crossing -------------------------------------------------------------------------------------
  local cut_t = marker_named('CUT 07') or 27.541667
  E.stats.cut_flashes = 0
  play_from(cut_t - 0.4)
  T.wait_until(function() return E.stats.cut_flashes > 0 or view.position() > cut_t + 0.6 end, 60)
  T.ok('cut flash fired on the marker crossing', E.stats.cut_flashes >= 1, 'cut_flashes=' .. E.stats.cut_flashes)
  reaper.OnStopButton()
  T.wait(3)

  -- 4. item mode and the other styles ----------------------------------------------------------------------------------------
  set('mode', 'item')
  E.reconfigure()
  E.perf_reset()
  play_from(44.5)
  T.wait(30)
  T.ok('item mode lights the items under the head', E.stats.items_lit_max > 0, 'items_lit_max=' .. E.stats.items_lit_max)
  reaper.OnStopButton()
  ps = E.perf_stats()
  T.fact('draw_ms_item', string.format('avg=%.3f max=%.3f p95=%.3f', ps.avg, ps.max, ps.p95))
  T.wait(3)
  set('mode', 'meter')
  for _, style in ipairs({ 'fill', 'edge' }) do
    set('style', style)
    E.reconfigure()
    E.perf_reset()
    play_from(56.5)
    T.wait(30)
    T.ok('style ' .. style .. ' draws', E.stats.lit_max > 0, 'lit_max=' .. E.stats.lit_max)
    reaper.OnStopButton()
    ps = E.perf_stats()
    T.fact('draw_ms_' .. style, string.format('avg=%.3f max=%.3f p95=%.3f', ps.avg, ps.max, ps.p95))
    T.wait(3)
  end
  set('style', 'bar')
  E.reconfigure()

  -- 5. performance guard: an impossible budget degrades in steps, a sane one recovers ---------------------------------------
  set('perf.budget_ms', 0.1); set('perf.over_frames', 5); set('perf.recover_frames', 30)   -- the smallest values the schema allows (an out-of-range value is dropped by config, verified in M4)
  E.reconfigure()
  E.perf_reset()
  E.perf.level = 0
  play_from(33.5)
  T.wait_until(function() return E.perf.level >= 3 end, 90, 'degrade reaches level 3')
  T.check('degrade level', E.perf.level, 3)
  T.wait(3)
  T.check('oversample dropped to 1 by the guard', O.S, 1)
  -- recovery needs the average under half the budget for recover_frames frames: a generous budget makes it
  -- deterministic on both test machines (the real draw time sits at 0.7-1.3 ms, right at half of the 2 ms default)
  set('perf.budget_ms', 10.0)   -- the largest value the schema allows
  E.reconfigure()
  T.wait_until(function() return E.perf.level == 0 end, 150, 'guard recovers with the budget back')
  T.check('recovered level', E.perf.level, 0)
  T.wait(3)
  T.check('oversample back to 2', O.S, 2)
  reaper.OnStopButton()
  T.wait(3)
  set('perf.budget_ms', 2.0); set('perf.over_frames', 30); set('perf.recover_frames', 300)

  -- 6. disable: the bitmap goes away (REAPER's list is the oracle) --------------------------------------------------------
  if T.sabotage == 'leave_bitmap' then
    O.sabotage_keep = true
    T.log('SABOTAGE leave_bitmap armed')
  end
  -- the bitmap exists only while something is drawn: disable under playback so the release path is the one tested
  play_from(0.5)
  T.wait(5)
  T.ok('bitmap composited while playing', O.bmp ~= nil, O.describe())
  set('enable', false)
  E.reconfigure()
  T.wait(3)
  T.check('engine inactive', E.active(), false)
  T.check('bitmap released', O.bmp == nil, true)
  local n_after = O.listed()
  T.check('REAPER lists no composited bitmap after disable', n_after, 0)
  reaper.OnStopButton()
  if O.sabotage_keep then
    O.sabotage_keep = nil
    if O.leaked then
      pcall(reaper.JS_Composite_Unlink, O.leaked_hwnd, O.leaked)
      pcall(reaper.JS_LICE_DestroyBitmap, O.leaked)
      O.leaked = nil
    end
  end

  -- 7. restore diff: the glow touched nothing ---------------------------------------------------------------------------------
  E.log_flush()
  local after = layout.dump()
  layout.write(T.out_path('layout_after.json'), after)
  local diff = layout.diff(before, after)
  for i, d in ipairs(diff) do
    if i <= 20 then T.log('DIFF ' .. d) end
  end
  T.log('RESTORE_DIFF ' .. #diff)
  T.check('restore diff', #diff, 0)
  T.fact('glow_log', tostring(E.log_path))

  -- cleanup for the screenshots: on again with the fake meter
  set('enable', true)
  E.reconfigure()
  for _, key in ipairs(keys) do
    if key ~= 'enable' and key ~= 'debug.fake_meter' then config.reset('glow.' .. key, 'project') end
  end
  E.reconfigure()

  -- 8. a slider drag (failure note B1): the tab previews every frame and writes the file once at the
  -- release, the engine recompiles once per frame through its listener; the old path (a write and a recompile
  -- per frame) is measured next to it for the record
  -- the scripted drag has no active ImGui item, so the tab's own release commit would run every frame: the tab
  -- is switched away for the drag (the commit at the release is the tab's contract, proven by the count of writes)
  app.set_tab('navigator')
  T.wait(2)
  local saves0, reconf0 = config.stats.saves, E.reconf_count or 0
  local ms_prev = 0
  for f = 1, 30 do
    app.note('glow.spark.alpha')
    config.preview('glow.spark.alpha', 0.3 + 0.01 * f, 'global')
    T.wait(1)
    ms_prev = ms_prev + app.tick_ms_last
  end
  local saves_drag = config.stats.saves - saves0
  app.set_tab('glow')   -- the release: the tab commits the drag once
  T.wait(2)
  local saves_commit = config.stats.saves - saves0
  local reconf_drag = (E.reconf_count or 0) - reconf0
  T.check('drag: previews write nothing', saves_drag, 0)
  T.check('drag: the release writes once', saves_commit, 1)
  T.check('drag: the preview reached the engine', tonumber(E.cfg.spark.alpha), 0.6, 1e-6)
  T.ok('drag: one recompile per frame at most', reconf_drag >= 1 and reconf_drag <= 31, 'reconfigures=' .. reconf_drag)
  local saves1 = config.stats.saves
  local ms_set = 0
  for f = 1, 30 do
    config.set('glow.spark.alpha', 0.3 + 0.01 * f, 'global')
    E.reconfigure()
    T.wait(1)
    ms_set = ms_set + app.tick_ms_last
  end
  T.fact('drag_frame_ms', string.format('preview=%.2f set=%.2f writes_preview=%d writes_set=%d reconf_preview=%d', ms_prev / 30, ms_set / 30,
    saves_drag, config.stats.saves - saves1, reconf_drag))
  config.reset('glow.spark.alpha', 'global')
  E.reconfigure()
  T.fact('slow_frames_so_far', app.slow_frames)

  -- idle cost: the overlay enabled, the transport stopped, nothing alive
  T.wait_until(function() return not E.alive end, 120)
  T.wait(10)
  local sum, n = 0, 0
  for _ = 1, 30 do
    T.wait(1)
    sum = sum + app.mod_tick_ms_last
    n = n + 1
  end
  T.fact('glow_idle_tick_ms', string.format('%.3f', sum / n))
  T.ok('idle module ticks stay under 0.3 ms with the glow enabled', sum / n < 0.3, string.format('%.3f ms', sum / n))
  T.fact('frame', T.frame())
end

-- after DONE: three glow states for the harness screenshots (meter/bar, fill, item), then everything back
local scroll_was = nil

local function scroll_to(name)
  local tr = track_by_name(name)
  if not tr then return end
  local arrange = require('lib.arrange')
  if scroll_was == nil then scroll_was = arrange.scroll_pos() or false end
  arrange.scroll_to_track(tr, 0)
end

function ST.post(frames_since_done)
  if (reaper.GetExtState('Stagehand', 'selftest_variant') or '') == 'b2drag' then return end   -- the view stays where the drag left it
  if look then
    if frames_since_done == 10 then
      scroll_to('FOLEY')
      play_from(33.5)
    elseif frames_since_done == 400 then
      reaper.OnStopButton()
    end
    return
  end
  if frames_since_done == 10 then
    set('mode', 'meter'); set('style', 'bar'); E.reconfigure()
    scroll_to('FOLEY')
    play_from(33.5)
  elseif frames_since_done == 100 then
    reaper.OnStopButton()
    set('style', 'fill'); E.reconfigure()
    play_from(44.5)
  elseif frames_since_done == 190 then
    reaper.OnStopButton()
    set('mode', 'item'); set('style', 'bar'); E.reconfigure()
    play_from(56.5)
  elseif frames_since_done == 280 then
    reaper.OnStopButton()
  elseif frames_since_done == 300 then
    config.reset('glow.mode', 'project'); config.reset('glow.style', 'project'); config.reset('glow.debug.fake_meter', 'project')
    E.reconfigure()
    if scroll_was then require('lib.arrange').set_scroll_pos(scroll_was) end
  end
end

return ST
