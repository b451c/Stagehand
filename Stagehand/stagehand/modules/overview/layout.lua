-- modules/overview/layout.lua - the overview layout engine (BRIEF 3.6, docs/research/mechanisms.md section 7).
--
-- apply(): mixer, master row and video window hidden; every track shown at one locked height (tracks matching
-- the hide rule left out, folders uncollapsed, pins off); every USED envelope lane open at one height (used =
-- enough points or an automation item), the rest closed; view = 0 .. the picture end (last video item) or the
-- project end or a custom end, plus a pad; scrolled to the top. Every change is journaled first (owner
-- 'overview') and put back by restore(), the app's restore hook and REAPER's exit. The capture protocol (rect,
-- page plan, scroll) lives here too so the companion, the guided mode and the self-test share one truth.
-- Heights: I_HEIGHTOVERRIDE then B_HEIGHTLOCK, as in the Director. Lua 5.4; no globals.

local log = require('lib.log')
local config = require('config')
local journal = require('lib.journal')
local tracks = require('lib.tracks')
local envelopes = require('lib.envelopes')
local arrange = require('lib.arrange')
local view = require('lib.view')
local match = require('lib.match')
local js = require('platform.js')

local L = {
  active = false, tracks = {}, stats = nil, last_apply_ms = 0, pages = nil, page_i = 0, capture = nil,
  end_s = nil, journaled = {}, msg = '', msg_frames = 0,
}

local MIXER_TOGGLE = 40078
local VIDEO_TOGGLE = 50125
local RULER_ID = 1005

local app

local function cfg(key)
  return config.get('overview.' .. key)
end

local function trace(fmt, ...)
  local line = string.format(fmt, ...)
  log.info('overview %s', line)
  if log.selftest_armed() then log.selftest('OVERVIEW ' .. line) end
end

function L.init(app_)
  app = app_
end

function L.say(msg)
  L.msg = msg
  L.msg_frames = 40
end

-- the picture end: the last video item's end, else the project length ------------------------------------------------

function L.picture_end()
  local best
  for i = 0, reaper.CountMediaItems(0) - 1 do
    local it = reaper.GetMediaItem(0, i)
    local tk = reaper.GetActiveTake(it)
    if tk then
      local src = reaper.GetMediaItemTake_Source(tk)
      if src and reaper.GetMediaSourceType(src, '') == 'VIDEO' then
        local e = reaper.GetMediaItemInfo_Value(it, 'D_POSITION') + reaper.GetMediaItemInfo_Value(it, 'D_LENGTH')
        if not best or e > best then best = e end
      end
    end
  end
  return best
end

-- the view end by the range mode; second value says which rule applied
function L.range_end()
  local mode = cfg('range.mode') or 'picture'
  local pad = tonumber(cfg('range.pad_end_s')) or 0.4
  if mode == 'custom' then return (tonumber(cfg('range.custom_end_s')) or 60) + pad, 'custom' end
  if mode == 'picture' then
    local pe = L.picture_end()
    if pe then return pe + pad, 'picture' end
  end
  return reaper.GetProjectLength(0) + pad, 'project'
end

-- the plan: which tracks are shown, which lanes open --------------------------------------------------------------------

-- returns list of { e (track entry), hide, lanes = { { env, guid, used, pts, name } } }, counts
function L.plan()
  local list = tracks.scan()
  local hide = match.compile(cfg('hide_rule') or '')
  local hide_empty = cfg('hide_empty') == true
  local minp = math.floor(tonumber(cfg('env_min_points')) or 2)
  local plan, counts = {}, { shown = 0, hidden = 0, lanes_open = 0, lanes_closed = 0, folders = 0 }
  for _, e in ipairs(list) do
    local h = hide(e.name) or (hide_empty and not e.folder and e.items == 0)
    local row = { e = e, hide = h, lanes = {} }
    for _, ev in ipairs(envelopes.scan(e.tr)) do
      local used = envelopes.used(ev.env, minp)
      row.lanes[#row.lanes + 1] = { env = ev.env, guid = ev.guid, used = used and not h, pts = envelopes.point_count(ev.env), name = ev.name }
      if used and not h then counts.lanes_open = counts.lanes_open + 1 else counts.lanes_closed = counts.lanes_closed + 1 end
    end
    if h then counts.hidden = counts.hidden + 1 else counts.shown = counts.shown + 1 end
    if e.folder then counts.folders = counts.folders + 1 end
    plan[#plan + 1] = row
  end
  return plan, counts
end

-- the push ------------------------------------------------------------------------------------------------------------

local function snapshot_of(e)
  return {
    show = math.floor(tracks.get(e.tr, 'B_SHOWINTCP')),
    height = math.floor(tracks.get(e.tr, 'I_HEIGHTOVERRIDE')),
    lock = math.floor(tracks.get(e.tr, 'B_HEIGHTLOCK')),
    compact = e.folder and math.floor(tracks.get(e.tr, 'I_FOLDERCOMPACT')) or nil,
    pin = math.floor(tracks.get(e.tr, 'B_TCPPIN')),
  }
end

local function journal_toggle(cmd, word)
  local st = view.toggle_state(cmd, word)
  if st < 0 then return nil end
  journal.add({ kind = 'toggle', key = tostring(cmd), was = st, name = word, owner = 'overview' })
  return st
end

function L.apply(why)
  if L.active then L.restore('reapply') end
  local t0 = reaper.time_precise()
  local plan, counts = L.plan()
  local track_px = math.floor(tonumber(cfg('track_px')) or 34)
  local env_px = math.floor(tonumber(cfg('env_lane_px')) or 26)
  local uncollapse = cfg('uncollapse') or 'all'
  L.journaled = {}
  reaper.PreventUIRefresh(1)
  local sets = 0
  -- 1. windows: mixer and video hidden (journaled toggles), master row out of the TCP
  if cfg('hide_mixer') ~= false then
    local st = journal_toggle(MIXER_TOGGLE, 'mixer')
    if st == 1 then reaper.Main_OnCommand(MIXER_TOGGLE, 0) end
  end
  if cfg('hide_video_window') ~= false then
    local st = journal_toggle(VIDEO_TOGGLE, 'video')
    if st == 1 then reaper.Main_OnCommand(VIDEO_TOGGLE, 0) end
  end
  if cfg('hide_master') ~= false then
    local mv = reaper.GetMasterTrackVisibility()
    journal.add({ kind = 'master_vis', key = 'master', was = mv, owner = 'overview' })
    if mv & 1 == 1 then reaper.SetMasterTrackVisibility(mv & ~1) end
  end
  -- 2. tracks: show / hide, uniform locked height, folders open, pins off
  for _, row in ipairs(plan) do
    local e = row.e
    journal.add({ kind = 'layout', key = e.guid, was = snapshot_of(e), owner = 'overview' })
    L.journaled[e.guid] = true
    local show = row.hide and 0 or 1
    if tracks.get(e.tr, 'B_SHOWINTCP') ~= show then tracks.set(e.tr, 'B_SHOWINTCP', show); sets = sets + 1 end
    if show == 1 then
      if tracks.get(e.tr, 'B_TCPPIN') ~= 0 then tracks.set(e.tr, 'B_TCPPIN', 0); sets = sets + 1 end
      if e.folder and (uncollapse == 'all' or (uncollapse == 'top' and e.depth == 0)) and tracks.get(e.tr, 'I_FOLDERCOMPACT') ~= 0 then
        tracks.set(e.tr, 'I_FOLDERCOMPACT', 0); sets = sets + 1
      end
      if tracks.get(e.tr, 'I_HEIGHTOVERRIDE') ~= track_px or tracks.get(e.tr, 'B_HEIGHTLOCK') ~= 1 then
        tracks.set(e.tr, 'B_HEIGHTLOCK', 0)
        tracks.set(e.tr, 'I_HEIGHTOVERRIDE', track_px)
        tracks.set(e.tr, 'B_HEIGHTLOCK', 1)
        sets = sets + 3
      end
    end
    -- 3. envelope lanes: used ones open at env_px, the rest closed
    for _, ln in ipairs(row.lanes) do
      if ln.guid then
        journal.add({ kind = 'env_vis', key = ln.guid, was = envelopes.visible(ln.env), owner = 'overview' })
        journal.add({ kind = 'env_lane_h', key = ln.guid, was = envelopes.lane_line(ln.env), owner = 'overview' })
      end
      if ln.used then
        if envelopes.set_lane_height(ln.env, env_px) then sets = sets + 1 end
        if envelopes.set_visible(ln.env, true) then sets = sets + 1 end
      else
        if envelopes.set_visible(ln.env, false) then sets = sets + 1 end
      end
    end
  end
  reaper.TrackList_AdjustWindows(false)
  -- 4. view and scroll
  local v0, v1 = view.get()
  journal.add({ kind = 'view', key = 'view', was = { v0, v1 }, owner = 'overview' })
  local end_s, rule = L.range_end()
  view.set(0, end_s)
  local scroll_was = arrange.scroll_pos()
  if scroll_was then journal.add({ kind = 'scroll', key = 'vscroll', was = scroll_was, owner = 'overview' }) end
  arrange.scroll_top()
  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  reaper.UpdateTimeline()
  L.active = true
  L.end_s = end_s
  L.tracks = plan
  L.last_apply_ms = (reaper.time_precise() - t0) * 1000
  L.stats = { shown = counts.shown, hidden = counts.hidden, lanes_open = counts.lanes_open, lanes_closed = counts.lanes_closed,
    folders = counts.folders, track_px = track_px, env_px = env_px, end_s = end_s, rule = rule, sets = sets, ms = L.last_apply_ms }
  trace('APPLY %s tracks=%d shown=%d hidden=%d lanes_open=%d lanes_closed=%d track_px=%d env_px=%d end=%.2f(%s) sets=%d ms=%.1f',
    why or 'ui', #plan, counts.shown, counts.hidden, counts.lanes_open, counts.lanes_closed, track_px, env_px, end_s, rule, sets, L.last_apply_ms)
  if app then app.emit('overview_active', true) end
  return L.stats
end

function L.restore(why)
  local t0 = reaper.time_precise()
  local stats = journal.restore(journal.owner_pred('overview'))
  L.active = false
  L.pages, L.page_i = nil, 0
  L.journaled = {}
  trace('RESTORE %s restored=%d kept=%d gone=%d ms=%.1f', why or 'ui', stats.restored, stats.kept, stats.gone, (reaper.time_precise() - t0) * 1000)
  if app then app.emit('overview_active', false) end
  return stats
end

-- geometry for the capture ---------------------------------------------------------------------------------------------

-- sum of the shown rows' heights (tracks plus their open lanes) = the height of the whole picture under the ruler
function L.content_height()
  local h = 0
  for k = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, k)
    if reaper.GetMediaTrackInfo_Value(tr, 'B_SHOWINTCP') == 1 then
      h = h + reaper.GetMediaTrackInfo_Value(tr, 'I_WNDH')
    end
  end
  return math.floor(h)
end

-- everything the companion and the stitcher need, in screen px (logical, y down) or nil without js_ReaScriptAPI:
-- { main = {l,t,r,b}, arrange = {l,t,r,b}, client_h, ruler_top (nil when the ruler does not sit right above the
--   arrange), tcp_left, content_h, scroll = { pos, page, min, max } }
function L.geometry()
  if not (js.caps and js.caps.window_rects) then return nil, 'no js_ReaScriptAPI' end
  local main = reaper.GetMainHwnd()
  local ml, mt, mr, mb = js.rect(main)
  local arr = js.arrange_hwnd()
  if not arr or not ml then return nil, 'no arrange window' end
  local al, at, ar, ab = js.child_rect(arr)   -- child rects: y down on macOS too (js.child_rect)
  local _, cw, ch = reaper.JS_Window_GetClientSize(arr)
  local ruler_top
  local ruler = reaper.JS_Window_FindChildByID(main, RULER_ID)
  if ruler then
    local rl, rt, rr, rb = js.child_rect(ruler)
    if rt and math.abs(rb - at) <= 4 and (at - rt) > 10 and (at - rt) < 300 then ruler_top = rt end
  end
  local tcp_left = ml
  if reaper.JS_Window_FindEx then
    local tcp = reaper.JS_Window_FindEx(main, main, 'REAPERTCPDisplay', '')
    if tcp then
      local tl = js.child_rect(tcp)
      if tl then tcp_left = tl end
    end
  end
  local g = {
    main = { ml, mt, mr, mb }, arrange = { al, at, ar, ab }, client_h = ch or (ab - at), client_w = cw or (ar - al),
    ruler_top = ruler_top, ruler_h = ruler_top and (at - ruler_top) or 0, tcp_left = tcp_left, content_h = L.content_height(),
  }
  if js.caps.scroll then
    local ok, pos, page, mn, mx = reaper.JS_Window_GetScrollInfo(arr, 'v')
    if ok then g.scroll = { pos = pos, page = page, min = mn, max = mx } end
  end
  return g
end

-- the RECT reply line and the geometry file lines (both carry the same numbers)
function L.rect_line(g)
  g = g or L.geometry()
  if not g then return 'RECT error no js_ReaScriptAPI' end
  local top = g.ruler_top or g.arrange[2]
  local crop = { g.tcp_left, top, g.arrange[3] - g.tcp_left, g.arrange[4] - top }
  return string.format('RECT %d %d %d %d ruler_top %s ruler_h %d tcp_left %d arr_client_h %d main %d,%d-%d,%d content_h %d crop %d,%d,%d,%d scroll %s',
    g.arrange[1], g.arrange[2], g.arrange[3], g.arrange[4], tostring(g.ruler_top or 'nil'), g.ruler_h, g.tcp_left, g.client_h,
    g.main[1], g.main[2], g.main[3], g.main[4], g.content_h, crop[1], crop[2], crop[3], crop[4],
    g.scroll and string.format('%d/%d/%d/%d', g.scroll.pos, g.scroll.page, g.scroll.min, g.scroll.max) or 'nil')
end

-- the page plan: scroll positions that cover the content top to bottom (nil without scrolling)
function L.page_plan()
  local g = L.geometry()
  if not g or not g.scroll then return nil, g end
  local page = g.scroll.page
  local mx = g.scroll.max
  local overlap = math.floor(tonumber(cfg('capture.page_overlap_px')) or 0)
  if page <= 0 then return { { pos = 0 } }, g end
  local step = math.max(1, page - overlap)
  local pages = {}
  local pos = 0
  local limit = math.max(0, mx - page)
  while true do
    pages[#pages + 1] = { pos = pos }
    if pos >= limit or #pages > 200 then break end
    pos = math.min(pos + step, limit)
  end
  return pages, g
end

-- scroll to a page; returns the real position after REAPER clamped it
function L.goto_page(i)
  local pages = L.pages or L.page_plan()
  L.pages = pages
  if not pages then return nil end
  i = math.max(1, math.min(i, #pages))
  L.page_i = i
  arrange.set_scroll_pos(pages[i].pos)
  reaper.UpdateArrange()
  return arrange.scroll_pos()
end

function L.scroll_reply()
  local g = L.geometry()
  if not g or not g.scroll then return 'SCROLL -1 -1 -1 -1' end
  return string.format('SCROLL %d %d %d %d', g.scroll.pos, g.scroll.page, g.scroll.min, g.scroll.max)
end

-- capture sessions ------------------------------------------------------------------------------------------------------

local function output_dir()
  local d = cfg('output.dir')
  if type(d) == 'string' and d ~= '' then return d end
  local _, name = reaper.EnumProjects(-1, '')
  local pd = (name or ''):match('^(.*)[/\\]')
  if not pd then return nil end
  local sep = package.config:sub(1, 1)
  return pd .. sep .. 'Render' .. sep .. 'overview_' .. os.date('%Y%m%d_%H%M%S')
end

-- pages.txt (i pos page max) and geometry.txt next to the captured pages: the stitcher reads both
function L.write_geometry(dir, g, pages)
  if not dir then return false end
  reaper.RecursiveCreateDirectory(dir, 0)
  local sep = package.config:sub(1, 1)
  local f = io.open(dir .. sep .. 'geometry.txt', 'w')
  if not f then return false end
  local top = g.ruler_top or g.arrange[2]
  f:write('# Stagehand overview geometry: screen px (logical, y down)\n')
  f:write(string.format('crop %d %d %d %d\n', g.tcp_left, top, g.arrange[3] - g.tcp_left, g.arrange[4] - top))
  f:write(string.format('ruler_h %d\ncontent_h %d\ntcp_w %d\narrange %d %d %d %d\nmain %d %d %d %d\nclient_h %d\n',
    g.ruler_h, g.content_h, g.arrange[1] - g.tcp_left, g.arrange[1], g.arrange[2], g.arrange[3], g.arrange[4],
    g.main[1], g.main[2], g.main[3], g.main[4], g.client_h))
  f:write(string.format('half_copy %s\ndpi_mode %s\n', cfg('output.half_copy') ~= false and 1 or 0, tostring(cfg('output.dpi_mode') or 'auto')))
  f:close()
  if pages then
    local p = io.open(dir .. sep .. 'pages.txt', 'w')
    if p then
      for i, pg in ipairs(pages) do
        p:write(string.format('%d %d %d %d\n', i - 1, pg.pos, g.scroll and g.scroll.page or g.client_h, g.scroll and g.scroll.max or g.content_h))
      end
      p:close()
    end
  end
  return true
end

-- mode 'guided': the main window hides, a page counter window shows, the user captures each page
-- mode 'companion': the main window hides while an external driver scrolls through the ctl protocol
function L.start_capture(mode, dir)
  if not (js.caps and js.caps.scroll) then return nil, 'no scrolling (js_ReaScriptAPI missing)' end
  local fresh = not L.active
  if fresh then L.apply('capture') end
  if mode == 'guided' then dir = dir or output_dir() end
  -- the page plan is read a few frames later: after an apply the arrange gets its new size (the mixer gone)
  -- only once REAPER laid the window out, and the scroll range with it
  L.capture = { mode = mode, dir = dir, pages = {}, i = 0, started = reaper.time_precise(), auto_s = tonumber(cfg('guided.auto_s')) or 0, next_at = nil,
    pending = fresh and 3 or 1 }
  if app then app.suspend_window(true) end
  trace('CAPTURE start mode=%s dir=%s', mode, tostring(dir))
  return L.capture
end

-- second phase of start_capture: the page plan, the geometry files (guided) and the first page
local function capture_ready()
  local c = L.capture
  local pages, g = L.page_plan()
  if not pages then
    L.end_capture('no page plan')
    return
  end
  c.pages = pages
  L.pages = pages
  if c.mode == 'guided' then
    L.write_geometry(c.dir, g, pages)   -- the companion writes its own geometry from the RECT reply
    L.guided_next()
  end
  trace('CAPTURE ready mode=%s pages=%d', c.mode, #pages)
end

function L.guided_next()
  local c = L.capture
  if not c or c.pending then return false end
  if c.i >= #c.pages then return L.end_capture('done') end
  c.i = c.i + 1
  L.goto_page(c.i)
  if c.auto_s > 0 then c.next_at = reaper.time_precise() + c.auto_s end
  trace('CAPTURE page %d/%d pos=%d', c.i, #c.pages, c.pages[c.i].pos)
  return true
end

function L.guided_prev()
  local c = L.capture
  if not c or c.i <= 1 then return false end
  c.i = c.i - 1
  L.goto_page(c.i)
  if c.auto_s > 0 then c.next_at = reaper.time_precise() + c.auto_s end
  return true
end

function L.end_capture(why)
  local c = L.capture
  if not c then return false end
  L.capture = nil
  if app then app.suspend_window(false) end
  trace('CAPTURE end %s pages_done=%d', why or 'ui', c.i)
  L.say(string.format('%d pages, files in %s', c.i, tostring(c.dir)))
  return true
end

function L.tick()
  if L.msg_frames > 0 then L.msg_frames = L.msg_frames - 1 end
  local c = L.capture
  if c and c.pending then
    c.pending = c.pending - 1
    if c.pending <= 0 then
      c.pending = nil
      capture_ready()
    end
    return
  end
  if c and c.mode == 'guided' and c.next_at and reaper.time_precise() >= c.next_at then
    c.next_at = nil
    L.guided_next()
  end
end

-- ctl verbs (registered by init.lua): "overview apply | restore | rect | scroll <px> | pages | page <i>"
function L.ctl(args, ctl)
  local verb, rest = tostring(args or ''):match('^(%S*)%s*(.*)$')
  if verb == 'apply' then
    local st = L.apply('ctl')
    if not L.capture then L.start_capture('companion') end
    ctl.write('APPLIED', { shown = st.shown, lanes = st.lanes_open, end_s = st.end_s })
  elseif verb == 'rect' then
    ctl.write(L.rect_line())
  elseif verb == 'scroll' then
    local px = tonumber(rest) or 0
    arrange.set_scroll_pos(px)
    reaper.UpdateArrange()
    L.pending_reply = { frames = math.floor(tonumber(cfg('ctl.reply_frames')) or 3) }
  elseif verb == 'pages' then
    local pages = L.page_plan()
    ctl.write('PAGES', { n = pages and #pages or 0 })
  elseif verb == 'restore' then
    L.end_capture('ctl')
    local st = L.restore('ctl')
    ctl.write('RESTORED', { restored = st.restored })
  else
    ctl.write('UNKNOWN', 'overview ' .. tostring(args))
  end
end

-- the SCROLL reply waits reply_frames so the redraw happened before the companion grabs the screen
function L.tick_reply(ctl)
  local p = L.pending_reply
  if not p then return end
  p.frames = p.frames - 1
  if p.frames <= 0 then
    L.pending_reply = nil
    ctl.write(L.scroll_reply())
  end
end

return L
