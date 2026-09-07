-- modules/director/selftest.lua - the scripted Director scenario the test harness runs against the demo project
-- (tests/fixtures/README.md is the oracle for track names, scenes and envelopes). Every expectation about the
-- project is computed by an independent walk of the REAPER API (never through the engine); geometry is read
-- back from REAPER (I_TCPY / I_WNDH / I_TCPH), envelope visibility from the state chunk's VIS line.
-- Sabotage "leave_height" (negative control) leaves one height override behind after Stop so the restore diff
-- must go red. Lua 5.4; no globals.

local tracks = require('lib.tracks')
local view = require('lib.view')
local journal = require('lib.journal')
local layout = require('lib.layout')
local arrange = require('lib.arrange')
local envelopes = require('lib.envelopes')
local regions = require('lib.regions')
local state = require('state')
local config = require('config')
local js = require('platform.js')

local ST = {}

local app, E, MD, S, U

function ST.init(app_, E_, MD_, S_, U_)
  app, E, MD, S, U = app_, E_, MD_, S_, U_
end

-- independent walks --------------------------------------------------------------------------------------------------

local function track_by_name(name)
  for k = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, k)
    local _, n = reaper.GetTrackName(tr)
    if n == name then return tr end
  end
  return nil
end

local function visible_names()
  local set, n = {}, 0
  for k = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, k)
    if reaper.GetMediaTrackInfo_Value(tr, 'B_SHOWINTCP') == 1 then
      local _, name = reaper.GetTrackName(tr)
      set[name] = true
      n = n + 1
    end
  end
  return set, n
end

local function names_overlapping(t0, t1)
  local out = {}
  for k = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, k)
    if tracks.has_items_in(tr, t0, t1) then
      local _, name = reaper.GetTrackName(tr)
      out[#out + 1] = { tr = tr, name = name }
    end
  end
  return out
end

local function top_ancestor_name(tr)
  local x, top = tr, nil
  local guard = 0
  while x and guard < 64 do
    top = x
    x = reaper.GetParentTrack(x)
    guard = guard + 1
  end
  local _, name = reaper.GetTrackName(top)
  return name
end

local function set_equal(expected, got)
  local missing, extra = {}, {}
  for n in pairs(expected) do if not got[n] then missing[#missing + 1] = n end end
  for n in pairs(got) do if not expected[n] then extra[#extra + 1] = n end end
  table.sort(missing)
  table.sort(extra)
  return #missing == 0 and #extra == 0, string.format('missing=[%s] extra=[%s]', table.concat(missing, ','), table.concat(extra, ','))
end

local function visible_bottom()
  local bottom = 0
  for k = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, k)
    if reaper.GetMediaTrackInfo_Value(tr, 'B_SHOWINTCP') == 1 then
      local y = reaper.GetMediaTrackInfo_Value(tr, 'I_TCPY') + reaper.GetMediaTrackInfo_Value(tr, 'I_WNDH')
      if y > bottom then bottom = y end
    end
  end
  return math.floor(bottom)
end

-- envelope visibility from the chunk (independent of the API path the engine uses)
local function env_vis_by_name()
  local out, visible, total = {}, 0, 0
  for k = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, k)
    local _, tname = reaper.GetTrackName(tr)
    for i = 0, reaper.CountTrackEnvelopes(tr) - 1 do
      local env = reaper.GetTrackEnvelope(tr, i)
      local _, ename = reaper.GetEnvelopeName(env)
      local v = envelopes.vis_from_chunk(env) or -1
      out[tname .. ' / ' .. ename] = v
      total = total + 1
      if v == 1 then visible = visible + 1 end
    end
  end
  return out, visible, total
end

local function frac_of_cursor()
  local v0, v1 = view.get()
  local pos = view.position()
  if v1 <= v0 then return -1 end
  return (pos - v0) / (v1 - v0)
end

-- the scenario -------------------------------------------------------------------------------------------------------

function ST.run(T)
  local demo = T.variant == ''
  T.fact('variant', demo and 'demo' or T.variant)
  T.fact('sabotage', T.sabotage == '' and 'none' or T.sabotage)
  T.fact('js_window_rects', tostring(js.caps.window_rects))
  T.fact('js_scroll', tostring(js.caps.scroll))
  T.fact('env_api', string.format('info_string=%s info_value=%s', tostring(envelopes.api.info_string), tostring(envelopes.api.info_value)))
  T.wait(2)

  -- 0. baseline ---------------------------------------------------------------------------------------------------
  if E.active then E.stop('selftest') end
  -- the HUD bar would dock into the bottom docker when the run starts and change the arrange height (its own
  -- scenario covers that); keep it out of this one so the height checks compare like with like
  config.set('hud.auto_show', false, 'project')
  app.emit('command', 'hud_hide')
  T.wait(8)
  local before = layout.dump()
  layout.write(T.out_path('layout_before.json'), before)
  local vb0, vb1 = view.get()
  local scroll_before = arrange.scroll_pos()
  local cont_before = layout.cont_scroll_state()
  local _, env_visible_before, env_total = env_vis_by_name()
  T.fact('view_before', string.format('%.3f-%.3f', vb0, vb1))
  T.fact('scroll_before', tostring(scroll_before))
  T.fact('cont_scroll_before', cont_before)
  T.fact('envelopes', string.format('%d visible of %d', env_visible_before, env_total))
  local H0, exact = arrange.height(config.get('director.heights.arrange_fallback_px'))
  T.fact('arrange_h', string.format('%d exact=%s', H0, tostring(exact)))
  if demo then
    T.check('tracks', reaper.CountTracks(0), 53)
    T.check('track envelopes', env_total, 5)
  end

  -- 1. the shot list -------------------------------------------------------------------------------------------------
  MD.clear()
  config.set('director.pins.rows', { { rule = '=PICTURE', height_px = 60 } }, 'project')
  config.set('director.layout.mode', 'focus', 'project')
  config.set('director.layout.parents', 'none', 'project')
  config.set('director.view.mode', 'page', 'project')
  config.set('director.envelopes.mode', 'story', 'project')
  config.set('director.ruler.mode', 'keep', 'project')
  config.set('director.timing.lead_s', 0.4, 'project')
  local score = track_by_name('Score L1')
  MD.add(MD.new_shot({ name = 'A dialogue', t0 = 0, t1 = 11, caption = 'Two voices open the film.', lanes = { { kind = 'rule', rule = '=DX Mara|=DX Keeper' } } }))
  MD.add(MD.new_shot({ name = 'B foley', t0 = 11, t1 = 22, caption = 'Every step and prop is played by hand.', lanes = { { kind = 'family', name = 'Foley' } } }))
  MD.add(MD.new_shot({ name = 'C storm', t0 = 22, t1 = 33, caption = 'The score ducks under the radio call.',
    lanes = { { kind = 'items', family = 'Music' }, { kind = 'items', family = 'Ambience' } },
    envelopes = { { track = '=MUSIC', env = 'Volume' } }, parents = 'bus' }))
  MD.add(MD.new_shot({ name = 'D lamp', t0 = 33, t1 = 44, caption = 'Effects layers under a following view.',
    lanes = { { kind = 'items', family = 'SFX' }, { kind = 'track', guid = score and reaper.GetTrackGUID(score) or nil, name = 'Score L1' } }, view = 'follow' }))
  MD.add(MD.new_shot({ name = 'E empty rule', t0 = 44, t1 = 56, caption = string.rep('x', 140), lanes = { { kind = 'rule', rule = 'zzqx' } } }))
  T.check('shots stored', #MD.shots, 5)
  local persisted = state.pget_json('director.shots')
  T.check('shots persisted', type(persisted) == 'table' and #persisted or -1, 5)
  T.check('shots sorted', MD.shots[3].name, 'C storm')
  T.check('shot_at lead', MD.shot_at(10.7, 0.4), 2)
  T.check('shot_at before lead', MD.shot_at(10.5, 0.4), 1)

  -- 2. validation ----------------------------------------------------------------------------------------------------
  local issues = U.validate()
  local c = S.issue_counts
  T.fact('issues', string.format('errors=%d warnings=%d infos=%d', c.error, c.warn, c.info))
  for _, i in ipairs(issues) do T.log(string.format('ISSUE %s #%s %s', i.level, tostring(i.k), i.text)) end
  local err5, cap5 = 0, 0
  for _, i in ipairs(issues) do
    if i.k == 5 and i.level == 'error' then err5 = err5 + 1 end
    if i.k == 5 and i.level == 'warn' and i.text:lower():find('caption', 1, true) then cap5 = cap5 + 1 end
  end
  T.ok('validation flags the empty lane rule', err5 >= 1, 'errors on shot 5: ' .. err5)
  T.ok('validation flags the long caption', cap5 == 1, 'caption warnings on shot 5: ' .. cap5)
  local other_errors = 0
  for _, i in ipairs(issues) do if i.level == 'error' and i.k ~= 5 then other_errors = other_errors + 1 end end
  T.check('no errors on shots 1-4', other_errors, 0)

  -- 3. start: shot 1 -------------------------------------------------------------------------------------------------
  reaper.SetEditCurPos2(0, 0.5, false, false)
  local t_start = reaper.time_precise()
  E.start('selftest')
  T.fact('start_ms', string.format('%.1f', (reaper.time_precise() - t_start) * 1000))
  T.check('run active', E.active, true)
  T.check('shot 1 applied', E.k, 1)
  T.wait_until(function() return E.verify == nil end, 30, 'verify settled shot 1')
  local L = E.last
  T.fact('shot1_apply', string.format('ms=%.1f sets=%d lane_h=%d H=%d bottom=%s tries=%d fits=%s', L.apply_ms, L.sets, L.lane_h, L.H, tostring(L.bottom), L.verify_tries, tostring(L.fits)))
  local got, n_vis = visible_names()
  local ok1, detail1 = set_equal({ PICTURE = true, ['DX Mara'] = true, ['DX Keeper'] = true }, got)
  T.ok('shot 1 visible set', ok1, detail1)
  T.check('shot 1 visible count', n_vis, 3)
  local mara = track_by_name('DX Mara')
  T.check('lane locked', reaper.GetMediaTrackInfo_Value(mara, 'B_HEIGHTLOCK'), 1)
  T.check('lane override = lane_h', reaper.GetMediaTrackInfo_Value(mara, 'I_HEIGHTOVERRIDE'), L.lane_h)
  local pic = track_by_name('PICTURE')
  T.check('pin height', reaper.GetMediaTrackInfo_Value(pic, 'I_HEIGHTOVERRIDE'), 60)
  T.check('pin flag', reaper.GetMediaTrackInfo_Value(pic, 'B_TCPPIN'), 1)
  local bottom1 = visible_bottom()
  T.ok('shot 1 fills the arrange', bottom1 <= L.H + 2 and (bottom1 >= L.H - 8 or L.lane_h >= 110), string.format('bottom=%d H=%d lane_h=%d', bottom1, L.H, L.lane_h))
  local _, env_vis_now = env_vis_by_name()
  T.check('story mode hides every envelope lane', env_vis_now, 0)
  if cont_before >= 0 then T.check('continuous scroll off for the run', layout.cont_scroll_state(), 0) end
  T.wait(14)
  local v0, v1 = view.get()
  T.check('page view start', v0, 0, 0.02)
  T.check('page view end', v1, 11.5, 0.05)
  T.check('director journal has layout entries', journal.count('layout', 'director') > 0, true)

  -- 4. rehearsal: next, goto ------------------------------------------------------------------------------------------
  E.next_shot()
  T.check('next shot', E.k, 2)
  T.check('next moves the cursor', reaper.GetCursorPosition(), 11, 0.001)
  T.wait_until(function() return E.verify == nil end, 30, 'verify settled shot 2')
  L = E.last
  T.fact('shot2_apply', string.format('ms=%.1f sets=%d lane_h=%d H=%d bottom=%s tries=%d fits=%s', L.apply_ms, L.sets, L.lane_h, L.H, tostring(L.bottom), L.verify_tries, tostring(L.fits)))
  got, n_vis = visible_names()
  local ok2, detail2 = set_equal({ PICTURE = true, Steps = true, Props = true, ['Cloth L1'] = true, ['Cloth L2'] = true, ['Cloth L3'] = true }, got)
  T.ok('shot 2 visible set (family Foley, parents none)', ok2, detail2)
  T.check('shot 2 visible count', n_vis, 6)
  local bottom2 = visible_bottom()
  T.ok('shot 2 fills the arrange', bottom2 <= L.H + 2 and (bottom2 >= L.H - 12 or L.lane_h >= 110), string.format('bottom=%d H=%d lane_h=%d', bottom2, L.H, L.lane_h))

  E.goto_shot(3)
  T.check('goto shot 3', E.k, 3)
  T.wait_until(function() return E.verify == nil end, 30, 'verify settled shot 3')
  L = E.last
  T.fact('shot3_apply', string.format('ms=%.1f sets=%d lane_h=%d H=%d bottom=%s tries=%d fits=%s envs=%d', L.apply_ms, L.sets, L.lane_h, L.H, tostring(L.bottom), L.verify_tries, tostring(L.fits), L.env_shown))
  -- lanes = tracks with items in 22-33 under the MUSIC and AMBIENCE top folders (the shipped family rules), plus
  -- those two folders as parents (bus mode) and the pinned PICTURE row
  local expected3 = { PICTURE = true }
  for _, r in ipairs(names_overlapping(22, 33)) do
    local top = top_ancestor_name(r.tr)
    if top:find('^MUSIC') or top:find('^AMB') then
      expected3[r.name] = true
      expected3[top] = true
    end
  end
  got, n_vis = visible_names()
  local ok3, detail3 = set_equal(expected3, got)
  T.ok('shot 3 visible set (items of two families + top parents)', ok3, detail3)
  local env_map = env_vis_by_name()
  T.check('shot 3 shows the MUSIC volume lane', env_map['MUSIC / Volume'], 1)
  T.check('shot 3 keeps the other lanes hidden', env_map['AMBIENCE / Volume'], 0)
  local music = track_by_name('MUSIC')
  T.ok('MUSIC row carries its envelope lane', arrange.extra_of(music) > 10, 'extra=' .. arrange.extra_of(music))
  local bottom3 = visible_bottom()
  local lane_min = tonumber(config.get('director.heights.lane_min_px')) or 26
  local flagged3 = false
  for _, i in ipairs(S.issues) do
    if i.k == 3 and i.level == 'warn' and i.text:lower():find('do not fit', 1, true) then flagged3 = true end
  end
  -- a small arrange (the Windows leg runs REAPER with a 279 px arrange) cannot hold the lanes at the minimum
  -- height: then the engine stops at the minimum and the validator must have warned about it
  T.ok('shot 3 fits after the verify pass, or the validator warned that it cannot', bottom3 <= L.H + 2 or (L.lane_h <= lane_min and flagged3),
    string.format('bottom=%d H=%d lane_h=%d tries=%d flagged=%s', bottom3, L.H, L.lane_h, L.verify_tries, tostring(flagged3)))
  T.fact('shot3_fit', string.format('bottom=%d H=%d lane_h=%d tries=%d flagged=%s', bottom3, L.H, L.lane_h, L.verify_tries, tostring(flagged3)))

  -- 5. switch timing while playing ------------------------------------------------------------------------------------
  E.set_auto(true)
  reaper.SetEditCurPos2(0, 10.0, false, false)
  T.wait(2)
  T.check('auto puts shot 1 back at 10.0', E.k, 1)
  local sw_frame = T.frame()
  reaper.OnPlayButton()
  local switched = T.wait_until(function() return E.k == 2 end, 90, 'follow switch to shot 2')
  if switched then
    local sw = E.switch_log[#E.switch_log]
    T.fact('switch1', string.format('late=%.3f pos=%.3f frames=%d', sw.late, sw.pos, T.frame() - sw_frame))
    T.ok('switch 1 within one frame of the lead', sw.late >= -0.001 and sw.late <= 0.07, string.format('late=%.3f', sw.late))
  end
  T.wait(12)
  local drift = 0
  local vs = E.view_set
  for _ = 1, 10 do
    local a, b = view.get()
    if vs and (math.abs(a - vs[1]) > 0.02 or math.abs(b - vs[2]) > 0.02) then drift = drift + 1 end
    T.wait(1)
  end
  T.check('page view does not drift while playing', drift, 0)
  reaper.OnStopButton()
  T.wait(3)

  -- 5b. project edits during a run (docs/research/failures.md B2): a region edge moved on 45 consecutive frames
  -- must not re-apply the shot, move the view or change the layout; the track rescan waits for the edit to settle.
  -- Each move sits in an undo block: the probe (tests/fixtures/probe_edits.lua) showed that only an undo block bumps
  -- GetProjectStateChangeCount from a script, and a mouse gesture in the ruler bumps it once per gesture
  local rid, r_t0, r_t1, r_name, r_col
  for i = 0, reaper.CountProjectMarkers(0) - 1 do
    local _, isrgn, p0, p1, name, id, col = reaper.EnumProjectMarkers3(0, i)
    if isrgn then rid, r_t0, r_t1, r_name, r_col = id, p0, p1, name, col end
  end
  if rid then
    T.wait(20)   -- REAPER's own scroll after a stop lands late; the view is read once that settled
    local apply_before, k_before = E.apply_count, E.k
    local ve0, ve1 = view.get()
    local view_ext0 = E.view_ext or 0
    local _, nvis_before = visible_names()
    local lane_before = E.last.lane_h
    local r0, d0 = E.edit_rescans or 0, E.edits_deferred or 0
    local sc0 = reaper.GetProjectStateChangeCount(0)
    local ms_sum, ms_max = 0, 0
    for f = 1, 45 do
      reaper.Undo_BeginBlock2(0)
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
    local va, vb = view.get()
    local _, nvis_after = visible_names()
    T.fact('edit_burst', string.format('state_delta=%d rescans=%d deferred=%d frame_ms_avg=%.2f max=%.2f', state_delta, rescans,
      (E.edits_deferred or 0) - d0, ms_sum / 45, ms_max))
    T.ok('region edits bump the project state', state_delta >= 45, 'delta=' .. state_delta)
    T.check('edits do not re-apply the shot', E.apply_count - apply_before, 0)
    T.check('edits keep the shot', E.k, k_before)
    T.ok('edits leave the view alone', math.abs(va - ve0) < 0.02 and math.abs(vb - ve1) < 0.02, string.format('%.3f-%.3f -> %.3f-%.3f', ve0, ve1, va, vb))
    T.check('edits keep the visible count', nvis_after, nvis_before)
    T.check('edits keep the lane height', E.last.lane_h, lane_before)
    T.ok('track rescans wait for the edit to settle', rescans >= 1 and rescans <= 4, 'rescans=' .. rescans)
    T.fact('view_external_changes', string.format('before=%d during=%d', view_ext0, (E.view_ext or 0) - view_ext0))
  else
    T.ok('a region exists for the edit burst', false, 'no region')
  end
  reaper.SetEditCurPos2(0, 21.0, false, false)
  T.wait(2)
  T.check('auto puts shot 2 back at 21.0', E.k, 2)
  reaper.OnPlayButton()
  local switched2 = T.wait_until(function() return E.k == 3 end, 90, 'follow switch to shot 3')
  if switched2 then
    local sw = E.switch_log[#E.switch_log]
    T.fact('switch2', string.format('late=%.3f pos=%.3f', sw.late, sw.pos))
    T.ok('switch 2 within one frame of the lead', sw.late >= -0.001 and sw.late <= 0.07, string.format('late=%.3f', sw.late))
  end
  reaper.OnStopButton()
  T.wait(3)

  -- 6. follow view (shot 4 overrides the view mode) ------------------------------------------------------------------------
  E.goto_shot(4)
  T.check('goto shot 4', E.k, 4)
  T.wait_until(function() return E.verify == nil end, 30, 'verify settled shot 4')
  L = E.last
  T.fact('shot4_apply', string.format('ms=%.1f sets=%d lane_h=%d H=%d bottom=%s tries=%d fits=%s', L.apply_ms, L.sets, L.lane_h, L.H, tostring(L.bottom), L.verify_tries, tostring(L.fits)))
  got = visible_names()
  T.check('shot 4 track rule shows Score L1', got['Score L1'] == true, true)
  T.check('shot 4 hides Score L2', got['Score L2'] == nil, true)
  reaper.OnPlayButton()
  T.wait(16)
  local fr = frac_of_cursor()
  T.fact('follow_cursor_frac', string.format('%.3f', fr))
  T.ok('follow view keeps the cursor at a third', math.abs(fr - 0.333) < 0.08, string.format('frac=%.3f', fr))
  reaper.OnStopButton()
  T.wait(3)

  -- 7. mode "all": every track stays, lanes tall, the rest compact ------------------------------------------------------------
  config.set('director.layout.mode', 'all', 'project')
  E.reapply()
  T.wait(3)
  local _, n_all = visible_names()
  T.check('mode all shows every track', n_all, reaper.CountTracks(0))
  local birds = track_by_name('Birds')
  T.check('mode all compact height on a non-lane track', reaper.GetMediaTrackInfo_Value(birds, 'I_HEIGHTOVERRIDE'), 20)
  T.check('mode all lane height on Score L1', reaper.GetMediaTrackInfo_Value(score, 'I_HEIGHTOVERRIDE'), E.last.lane_h)
  config.set('director.layout.mode', 'focus', 'project')
  E.reapply()
  T.wait_until(function() return E.verify == nil end, 30, 'verify settled after mode focus')

  -- 7b. ruler lanes (opt-in): blind toggles queued with wait frames, journaled, toggled back at stop ------------------------
  E.stop('ruler test')
  T.wait(2)
  config.set('director.ruler.mode', 'hide', 'project')
  reaper.SetEditCurPos2(0, 0.5, false, false)
  local h_ruler_before = arrange.height(config.get('director.heights.arrange_fallback_px'))
  E.start('ruler')
  T.wait_until(function() return E.ruler == nil end, 150, 'ruler queue done')
  T.check('ruler lanes journaled', journal.count('ruler_lane', 'director'), 2)
  local h_ruler_after = arrange.height(config.get('director.heights.arrange_fallback_px'))
  T.fact('ruler_arrange', string.format('before=%d after=%d', h_ruler_before, h_ruler_after))
  T.ok('arrange did not shrink with the ruler lanes hidden', h_ruler_after >= h_ruler_before, string.format('%d -> %d', h_ruler_before, h_ruler_after))
  T.check('shot 1 applied again after the ruler change', E.k, 1)
  T.wait_until(function() return E.verify == nil end, 30, 'verify settled after ruler')
  config.set('director.ruler.mode', 'keep', 'project')

  -- 8. stop: everything back --------------------------------------------------------------------------------------------------
  journal.flush()
  T.fact('journal_director_entries', journal.count(nil, 'director'))
  local t_stop = reaper.time_precise()
  local stats = E.stop('selftest')
  T.fact('stop_ms', string.format('%.1f', (reaper.time_precise() - t_stop) * 1000))
  T.wait(3)
  T.check('run inactive', E.active, false)
  T.check('stop restored something', stats and stats.restored > 0, true)
  T.check('stop gone none', stats and stats.gone or -1, 0)
  T.check('director journal empty', journal.count(nil, 'director'), 0)
  local va0, va1 = view.get()
  T.check('view restored start', va0, vb0, 0.01)
  T.check('view restored end', va1, vb1, 0.01)
  if scroll_before then T.check('scroll restored', arrange.scroll_pos(), scroll_before) end
  if cont_before >= 0 then T.check('continuous scroll restored', layout.cont_scroll_state(), cont_before) end
  -- the ruler keeps its own minimum height (docs/research/failures.md H5): after the blind toggles come back the
  -- arrange may keep one lane's worth of the band, so give REAPER time and accept a one-lane difference
  local fb = config.get('director.heights.arrange_fallback_px')
  T.wait_until(function() return arrange.height(fb) == h_ruler_before end, 60)
  local h_ruler_restored = arrange.height(fb)
  T.fact('ruler_arrange_after_stop', h_ruler_restored)
  -- what hiding the lanes gained stays after they come back (10 px on the legs, 15 px on macOS: the ruler keeps its
  -- minimum height, failures.md H5), so the tolerance is the measured gain, never a constant
  local gain = math.max(0, h_ruler_after - h_ruler_before)
  local tol = math.max(12, gain + 1)
  T.fact('ruler_gain_px', gain)
  T.ok('arrange height back within one ruler lane after the lanes returned', math.abs(h_ruler_restored - h_ruler_before) <= tol,
    string.format('%d -> %d -> %d (tolerance %d)', h_ruler_before, h_ruler_after, h_ruler_restored, tol))
  local _, env_visible_after = env_vis_by_name()
  T.check('envelope lanes restored', env_visible_after, env_visible_before)
  if T.sabotage == 'leave_height' then
    reaper.SetMediaTrackInfo_Value(track_by_name('DX Keeper'), 'I_HEIGHTOVERRIDE', 33)   -- negative control
    T.log('SABOTAGE leave_height applied')
  end
  local after = layout.dump()
  layout.write(T.out_path('layout_after.json'), after)
  local diff = layout.diff(before, after)
  for i, d in ipairs(diff) do
    if i <= 20 then T.log('DIFF ' .. d) end
  end
  T.log('RESTORE_DIFF ' .. #diff)
  T.check('restore diff', #diff, 0)
  if T.sabotage == 'leave_height' then reaper.SetMediaTrackInfo_Value(track_by_name('DX Keeper'), 'I_HEIGHTOVERRIDE', 0) end

  -- 9. shots from scenes, cleanup --------------------------------------------------------------------------------------------
  local scenes = regions.scan(nil, 5)
  local from = MD.from_scenes(scenes)
  T.check('shots from scenes', #from, #scenes)
  if demo then T.check('first scene shot name', from[1].name, '01 Harbor dawn') end
  MD.clear()
  for _, key in ipairs({ 'director.pins.rows', 'director.layout.mode', 'director.layout.parents', 'director.view.mode',
      'director.envelopes.mode', 'director.ruler.mode', 'director.timing.lead_s', 'hud.auto_show' }) do
    config.reset(key, 'project')
  end
  S.validate_request = true
  -- shots for the screenshots after DONE (harness): the scene list, previewed in post()
  for _, s in ipairs(from) do MD.shots[#MD.shots + 1] = s end
  MD.sort()
  MD.save()
  S.hi = 0
  local max_apply, max_sets = 0, 0
  T.fact('apply_count', E.apply_count)
  T.fact('frame', T.frame())
  max_apply = math.max(max_apply, E.last.apply_ms or 0)
  max_sets = math.max(max_sets, E.last.sets or 0)
  T.fact('last_apply_ms', string.format('%.1f', max_apply))
  T.fact('last_apply_sets', max_sets)
end

-- after DONE: a run on shot 3 for the screenshots, then everything back
function ST.post(frames_since_done)
  if frames_since_done == 1 then
    S.validate_request = true
  elseif frames_since_done == 50 then
    if #MD.shots >= 3 then E.goto_shot(3) end
  elseif frames_since_done == 190 then
    if E.active then E.stop('post') end
  elseif frames_since_done == 250 then
    MD.clear()
  end
end

return ST
