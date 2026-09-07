-- modules/overview/selftest.lua - the scripted Overview scenario the test harness runs against the demo project.
-- The plan (hide rule, used lanes by point count) is checked against an independent count; apply is checked
-- field by field (mixer, video window, master row, every track's visibility / locked height / measured row
-- height / folder state, every lane's visibility and height, view, scroll); the capture geometry, the page plan
-- and the scroll through every page; restore diff 0. Variant 'companion': after the in-app checks the scenario
-- writes companion_go.txt and waits for the external driver (tools/overview_capture.py, started by the harness)
-- to apply, scroll, capture and restore through the ctl protocol, then checks the stitched PNG's size against
-- the geometry. Without the variant the guided mode is exercised instead. Sabotage 'leave_heights' drops the
-- track layout entries before the final restore (the negative control: the restore diff must go red).
-- Lua 5.4; no globals.

local layout = require('lib.layout')
local view = require('lib.view')
local config = require('config')
local journal = require('lib.journal')
local envelopes = require('lib.envelopes')
local arrange = require('lib.arrange')
local ctl = require('lib.ctl')
local match = require('lib.match')

local ST = {}

local app, L, S, U

function ST.init(app_, L_, S_, U_)
  app, L, S, U = app_, L_, S_, U_
end

local function set(key, v)
  config.set('overview.' .. key, v, 'project')
end

local function png_size(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local head = f:read(24)
  f:close()
  if not head or #head < 24 or head:sub(1, 8) ~= '\137PNG\r\n\26\n' then return nil end
  local w = string.unpack('>I4', head, 17)
  local h = string.unpack('>I4', head, 21)
  return w, h
end

local function file_exists(p)
  local f = io.open(p, 'rb')
  if f then f:close(); return true end
  return false
end

local function count_lines(path, pattern)
  local n = 0
  local f = io.open(path, 'r')
  if not f then return 0 end
  for line in f:lines() do
    if line:find(pattern) then n = n + 1 end
  end
  f:close()
  return n
end

-- independent truth: rows shown, lanes used, from the API alone
local function independent_counts(rule, minp)
  local hide = match.compile(rule)
  local shown, hidden, open, closed, folders_compact = 0, 0, 0, 0, 0
  for k = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, k)
    local _, name = reaper.GetTrackName(tr)
    local h = hide(name)
    if h then hidden = hidden + 1 else shown = shown + 1 end
    if reaper.GetMediaTrackInfo_Value(tr, 'I_FOLDERDEPTH') == 1 and reaper.GetMediaTrackInfo_Value(tr, 'I_FOLDERCOMPACT') > 0 then folders_compact = folders_compact + 1 end
    for i = 0, reaper.CountTrackEnvelopes(tr) - 1 do
      local env = reaper.GetTrackEnvelope(tr, i)
      local used = reaper.CountEnvelopePoints(env) >= minp or (reaper.CountAutomationItems and reaper.CountAutomationItems(env) > 0)
      if used and not h then open = open + 1 else closed = closed + 1 end
    end
  end
  return shown, hidden, open, closed, folders_compact
end

local function check_applied(T, tag, track_px, env_px, rule, minp)
  local hide = match.compile(rule)
  local bad_show, bad_lock, bad_h, bad_row, bad_compact, bad_pin, n_shown = 0, 0, 0, 0, 0, 0, 0
  local rows_sum = 0
  local rowh = {}
  for k = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, k)
    local _, name = reaper.GetTrackName(tr)
    local want_show = hide(name) and 0 or 1
    local show = reaper.GetMediaTrackInfo_Value(tr, 'B_SHOWINTCP')
    if show ~= want_show then bad_show = bad_show + 1 end
    if want_show == 1 then
      n_shown = n_shown + 1
      if reaper.GetMediaTrackInfo_Value(tr, 'B_HEIGHTLOCK') ~= 1 then bad_lock = bad_lock + 1 end
      if reaper.GetMediaTrackInfo_Value(tr, 'I_HEIGHTOVERRIDE') ~= track_px then bad_h = bad_h + 1 end
      local th = reaper.GetMediaTrackInfo_Value(tr, 'I_TCPH')
      rowh[#rowh + 1] = th
      if math.abs(th - track_px) > 2 then bad_row = bad_row + 1 end
      if reaper.GetMediaTrackInfo_Value(tr, 'I_FOLDERDEPTH') == 1 and reaper.GetMediaTrackInfo_Value(tr, 'I_FOLDERCOMPACT') ~= 0 then bad_compact = bad_compact + 1 end
      if reaper.GetMediaTrackInfo_Value(tr, 'B_TCPPIN') ~= 0 then bad_pin = bad_pin + 1 end
      rows_sum = rows_sum + reaper.GetMediaTrackInfo_Value(tr, 'I_WNDH')
    end
  end
  T.check(tag .. ' tracks shown / hidden by the rule', bad_show, 0)
  T.check(tag .. ' shown tracks height-locked', bad_lock, 0)
  T.check(tag .. ' shown tracks override = track px', bad_h, 0)
  T.check(tag .. ' measured row heights = track px (+-2)', bad_row, 0)
  T.check(tag .. ' folders uncollapsed', bad_compact, 0)
  T.check(tag .. ' pins off', bad_pin, 0)
  table.sort(rowh)
  T.fact(tag:gsub('%s', '_') .. '_row_heights', string.format('min=%d max=%d n=%d', rowh[1] or 0, rowh[#rowh] or 0, #rowh))
  -- lanes
  local bad_vis, bad_lane_h, n_open, lane_hs = 0, 0, 0, {}
  for k = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, k)
    local _, name = reaper.GetTrackName(tr)
    local h = hide(name)
    for i = 0, reaper.CountTrackEnvelopes(tr) - 1 do
      local env = reaper.GetTrackEnvelope(tr, i)
      local used = (reaper.CountEnvelopePoints(env) >= minp or (reaper.CountAutomationItems and reaper.CountAutomationItems(env) > 0)) and not h
      local vis = envelopes.vis_from_chunk(env)
      if vis ~= (used and 1 or 0) then bad_vis = bad_vis + 1 end
      if used then
        n_open = n_open + 1
        local lh = envelopes.lane_height(env)
        lane_hs[#lane_hs + 1] = lh
        if math.abs(lh - env_px) > 4 then bad_lane_h = bad_lane_h + 1 end
      end
    end
  end
  T.check(tag .. ' lane visibility by use (chunk oracle)', bad_vis, 0)
  T.check(tag .. ' open lanes at env px (+-4)', bad_lane_h, 0)
  table.sort(lane_hs)
  T.fact(tag:gsub('%s', '_') .. '_lane_heights', table.concat(lane_hs, ' '))
  T.check(tag .. ' content height = sum of shown rows', L.content_height(), math.floor(rows_sum))
  return n_shown, n_open
end

function ST.run(T)
  local companion = T.variant == 'companion'
  T.fact('variant', companion and 'companion' or 'demo')
  T.fact('sabotage', T.sabotage == '' and 'none' or T.sabotage)
  T.wait(2)
  reaper.OnStopButton()
  -- the mixer shown and the master row in the TCP, so hiding them is a real change; dumped as the "before"
  local mixer_before = view.toggle_state(40078, 'mixer')
  local master_before = reaper.GetMasterTrackVisibility()
  if mixer_before == 0 then reaper.Main_OnCommand(40078, 0) end
  if master_before & 1 == 0 then reaper.SetMasterTrackVisibility(master_before | 1) end
  T.wait(3)
  local before = layout.dump()
  layout.write(T.out_path('layout_before.json'), before)
  local js = app.caps
  T.fact('js', tostring(js.js) .. ' rects=' .. tostring(js.window_rects) .. ' scroll=' .. tostring(js.scroll))

  -- 1. settings for the run: known heights, a rule that hides five demo tracks, lanes with >= 12 points ------------------
  local RULE, MINP, TPX, EPX = '^Whoosh short|=Sub', 12, 30, 24   -- hides 4 demo tracks (one carries a pan envelope with 34 points)
  set('track_px', TPX); set('env_lane_px', EPX); set('env_min_points', MINP); set('hide_rule', RULE)
  set('range.mode', 'project'); set('range.pad_end_s', 0.5); set('uncollapse', 'all')
  set('hide_mixer', true); set('hide_master', true); set('hide_video_window', true)
  config.set('recorder.ctl.dir', T.out_path('ctl'), 'project')
  ctl.bind()
  local i_shown, i_hidden, i_open, i_closed, i_compact = independent_counts(RULE, MINP)
  local plan, counts = L.plan()
  T.fact('plan', string.format('shown=%d hidden=%d lanes_open=%d lanes_closed=%d folders=%d compact_before=%d', counts.shown, counts.hidden, counts.lanes_open, counts.lanes_closed, counts.folders, i_compact))
  T.check('plan rows shown', counts.shown, i_shown)
  T.check('plan rows hidden by the rule', counts.hidden, i_hidden)
  T.ok('rule hides something', counts.hidden > 0, tostring(counts.hidden))
  T.check('plan lanes open (>= min points)', counts.lanes_open, i_open)
  T.check('plan lanes closed', counts.lanes_closed, i_closed)
  T.ok('some lanes stay closed', counts.lanes_closed > 0, tostring(counts.lanes_closed))
  T.ok('a folder is compact before apply', i_compact > 0, tostring(i_compact))
  local end_s, rule = L.range_end()
  T.check('range rule project (no video item)', rule, 'project')
  T.check('range end = project length + pad', end_s, reaper.GetProjectLength(0) + 0.5, 0.001)
  local video_before = view.toggle_state(50125, 'video')
  T.fact('windows_before', string.format('mixer=%d video=%d master=%d (now mixer %d, master %d)', mixer_before, video_before, master_before, view.toggle_state(40078, 'mixer'), reaper.GetMasterTrackVisibility()))

  -- 2. apply -------------------------------------------------------------------------------------------------------------------
  local st = L.apply('selftest')
  T.wait(3)
  T.check('apply reports shown', st.shown, i_shown)
  T.check('apply reports open lanes', st.lanes_open, i_open)
  T.fact('apply_ms', string.format('%.1f', st.ms))
  T.fact('apply_sets', st.sets)
  T.check('mixer hidden', view.toggle_state(40078, 'mixer'), 0)
  T.check('video window hidden', math.max(0, view.toggle_state(50125, 'video')), 0)
  T.check('master row out of the TCP', reaper.GetMasterTrackVisibility() & 1, 0)
  local n_shown = check_applied(T, 'apply', TPX, EPX, RULE, MINP)
  local v0, v1 = view.get()
  T.check('view starts at 0', v0, 0, 0.01)
  T.check('view ends at the range end', v1, end_s, 0.02)
  local sp = arrange.scroll_pos()
  if sp then T.check('scrolled to the top', sp, 0) end
  T.check('journal entries of the overview', journal.count(nil, 'overview') > n_shown, true)
  T.fact('journal_entries', journal.count(nil, 'overview'))

  -- 3. geometry and pages -----------------------------------------------------------------------------------------------------------
  local g, gerr = L.geometry()
  if g then
    T.ok('geometry measured', true, L.rect_line(g))
    T.ok('ruler sits above the arrange', g.ruler_h > 10 and g.ruler_h < 300, tostring(g.ruler_h))
    T.ok('crop inside the main window', g.tcp_left >= g.main[1] and g.arrange[3] <= g.main[3] + 1 and g.arrange[4] <= g.main[4] + 1, string.format('tcp_left=%d arrange=%d,%d-%d,%d main=%d,%d-%d,%d', g.tcp_left, g.arrange[1], g.arrange[2], g.arrange[3], g.arrange[4], g.main[1], g.main[2], g.main[3], g.main[4]))
    T.ok('content taller than the arrange', g.content_h > g.client_h, string.format('content=%d client=%d', g.content_h, g.client_h))
    T.fact('geometry', string.format('crop=%d,%d,%d,%d ruler_h=%d content_h=%d client_h=%d scroll=%s', g.tcp_left, g.ruler_top or g.arrange[2], g.arrange[3] - g.tcp_left, g.arrange[4] - (g.ruler_top or g.arrange[2]), g.ruler_h, g.content_h, g.client_h, g.scroll and (g.scroll.page .. '/' .. g.scroll.max) or 'nil'))
    local pages = L.page_plan()
    if pages and g.scroll then
      local expect = 1 + math.ceil(math.max(0, g.scroll.max - g.scroll.page) / g.scroll.page)
      T.check('page plan covers the content', #pages, expect)
      T.fact('pages', #pages)
      local bad = 0
      for i, pg in ipairs(pages) do
        local got = L.goto_page(i)
        T.wait(2)
        got = arrange.scroll_pos()
        if math.abs((got or -1) - pg.pos) > 1 then bad = bad + 1; T.log(string.format('PAGE %d wanted %d got %s', i, pg.pos, tostring(got))) end
      end
      T.check('every page reachable by scroll', bad, 0)
      L.goto_page(1)
      T.wait(2)
      T.check('back at the top', arrange.scroll_pos(), 0)
      T.check('SCROLL reply well-formed', L.scroll_reply():match('^SCROLL %d+ %d+ %d+ %d+$') ~= nil, true)
      local dir = T.out_path('overview_geom')
      T.check('geometry files written', L.write_geometry(dir, g, pages), true)
      local sep = package.config:sub(1, 1)
      T.check('pages.txt rows', count_lines(dir .. sep .. 'pages.txt', '^%d'), #pages)
      T.check('geometry.txt has the crop', count_lines(dir .. sep .. 'geometry.txt', '^crop %d+ %d+ %d+ %d+'), 1)
    else
      T.ok('page plan (needs scrolling)', false, 'no scroll info')
    end
  else
    T.ok('geometry measured', false, tostring(gerr))
  end

  -- 4. restore ---------------------------------------------------------------------------------------------------------------------
  local rs = L.restore('selftest')
  T.wait(3)
  T.fact('restore_stats', string.format('restored=%d kept=%d gone=%d', rs.restored, rs.kept, rs.gone))
  T.check('mixer back', view.toggle_state(40078, 'mixer'), 1)
  T.check('master row back', reaper.GetMasterTrackVisibility() & 1, 1)
  local after1 = layout.dump()
  local diff1 = layout.diff(before, after1)
  for i, d in ipairs(diff1) do
    if i <= 20 then T.log('DIFF1 ' .. d) end
  end
  T.check('restore diff after apply', #diff1, 0)

  -- 5. the capture: companion through the ctl protocol, or the guided mode ----------------------------------------------------------
  if companion then
    local sep = package.config:sub(1, 1)
    local out_png = T.out_path('overview') .. sep .. 'Session_Overview.png'
    ctl.clear_state()
    local go = io.open(T.out_path('companion_go.txt'), 'w')
    if go then go:write('go\n'); go:close() end
    T.log('COMPANION waiting for tools/overview_capture.py on ctl ' .. tostring(ctl.dir()))
    local cs = ctl.status()
    local applied = T.wait_until(function() return L.capture ~= nil end, 2700, 'companion applied the layout')
    if applied then
      T.check('companion capture suspends the main window', app.suspended, true)
      check_applied(T, 'companion apply', TPX, EPX, RULE, MINP)
    end
    local restored = T.wait_until(function() return cs.last_cmd == 'overview restore' and not L.active end, 2700, 'companion restored the layout')
    T.wait(3)
    T.check('main window back after the capture', app.suspended, false)
    local state_path = ctl.path('state')
    T.fact('ctl_tokens', string.format('applied=%d rect=%d scroll=%d restored=%d', count_lines(state_path, ' APPLIED'), count_lines(state_path, ' RECT '), count_lines(state_path, ' SCROLL '), count_lines(state_path, ' RESTORED')))
    T.ok('SCROLL replies for every page', count_lines(state_path, ' SCROLL ') >= 2, tostring(count_lines(state_path, ' SCROLL ')))
    local have = T.wait_until(function() return file_exists(out_png) end, 1800, 'stitched PNG written')
    if have and restored then
      T.wait(10)
      local w, h = png_size(out_png)
      T.fact('stitched_png', string.format('%sx%s', tostring(w), tostring(h)))
      local gg = g
      if gg and w and h then
        local crop_w = gg.arrange[3] - gg.tcp_left
        local scale = w / crop_w
        T.fact('stitch_scale', string.format('%.3f', scale))
        local want_h = (gg.ruler_h + gg.content_h) * scale
        T.ok('stitched height = ruler + content (+-1%)', math.abs(h - want_h) <= math.max(4, want_h * 0.01), string.format('h=%d want=%.0f', h, want_h))
        T.ok('stitched width = crop width * scale', math.abs(w - crop_w * scale) < 1, string.format('w=%d crop_w=%d', w, crop_w))
      end
      local half = T.out_path('overview') .. sep .. 'Session_Overview_half.png'
      T.check('half-size copy written', T.wait_until(function() return file_exists(half) end, 600), true)
    end
  else
    local c, err = L.start_capture('guided', T.out_path('guided'))
    T.ok('guided capture started', c ~= nil, tostring(err))
    if c then
      T.wait_until(function() return c.pending == nil end, 20, 'guided: pages planned')
      T.wait(2)
      T.check('guided: page plan matches the earlier plan', #c.pages, L.page_plan() and #L.page_plan() or -1)
      T.check('guided: main window suspended', app.suspended, true)
      T.check('guided: first page', c.i, 1)
      T.check('guided: at the top', arrange.scroll_pos(), 0)
      local n = #c.pages
      for _ = 1, n do L.guided_next(); T.wait(2) end
      T.check('guided: ended after the last page', L.capture, nil)
      T.check('guided: main window back', app.suspended, false)
      T.fact('guided_pages', n)
    end
  end

  -- 6. final restore and diff -----------------------------------------------------------------------------------------------------------
  if L.active then
    if T.sabotage == 'leave_heights' then
      journal.discard(function(e) return e.owner == 'overview' and e.kind == 'layout' end)
    end
    L.restore('selftest end')
    T.wait(3)
  end
  local after = layout.dump()
  layout.write(T.out_path('layout_after.json'), after)
  local diff = layout.diff(before, after)
  for i, d in ipairs(diff) do
    if i <= 20 then T.log('DIFF ' .. d) end
  end
  T.log('RESTORE_DIFF ' .. #diff)
  T.check('restore diff', #diff, 0)
  if mixer_before == 0 and view.toggle_state(40078, 'mixer') == 1 then reaper.Main_OnCommand(40078, 0) end
  if master_before & 1 == 0 then reaper.SetMasterTrackVisibility(master_before) end
  for _, key in ipairs({ 'track_px', 'env_lane_px', 'env_min_points', 'hide_rule', 'range.mode', 'range.pad_end_s', 'uncollapse', 'hide_mixer', 'hide_master', 'hide_video_window' }) do
    config.reset('overview.' .. key, 'project')
  end
  config.reset('recorder.ctl.dir', 'project')
  T.fact('frame', T.frame())
end

-- after DONE: the layout applied for the second screenshot, the guided counter for the third, then restored
function ST.post(frames_since_done)
  if frames_since_done == 5 then
    app.set_tab('overview')
    L.apply('post')
  elseif frames_since_done == 110 then
    L.start_capture('guided')
  elseif frames_since_done == 240 then
    L.end_capture('post')
    L.restore('post')
  end
end

return ST
