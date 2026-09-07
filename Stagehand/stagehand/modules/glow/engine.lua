-- modules/glow/engine.lua - the glow overlay engine.
--
-- Every frame while something sounds: for each track shown in the TCP whose row is inside the arrange, read
-- the post-fader meter (always the real call; the fake meter replaces the VALUE on headless test machines), run the
-- track's glow envelope (lib/meter) and paint the items under the play head: a fill that follows the track's
-- own dynamics (meter mode) or the item bounds (item mode), a level bar from the take peaks (bar style), an
-- outline, sparks at the play head's x on onsets, a colour that warms with the level. The most recently ended
-- item keeps glowing while the track still sounds; rows without items (bus, folder, return) get a level band;
-- a marker of the "cut" class the play head just crossed flashes a full-height line. Nothing in the project is
-- touched: the overlay is a bitmap composited over the arrange (overlay.lua) and released on disable / exit.
-- Performance guard: the draw time per frame is measured; over the budget for over_frames frames the engine
-- steps down (sparks off, oversampling 1, bus band off) and steps back up after recover_frames quiet frames.
-- Evidence: with glow.debug.log (or the self-test armed) one line per lit track per frame goes to a text file,
-- flushed every 240 lines, plus a summary per track at stop. Lua 5.4; no globals.

local log = require('lib.log')
local config = require('config')
local edits = require('lib.edits')
local view = require('lib.view')
local tracks = require('lib.tracks')
local families = require('lib.families')
local regions = require('lib.regions')
local match = require('lib.match')
local meter = require('lib.meter')
local peaks = require('lib.peaks')
local theme = require('ui.theme')
local O = require('modules.glow.overlay')

local E = {
  enabled = true, cfg = nil, tracks = {}, fams = nil, state_count = -1, last_now = nil, alive = false,
  perf = { ms = 0, ema = 0, max = 0, over = 0, under = 0, level = 0, frames = 0, drawn = 0, sum = 0, hist = {} },
  stats = { lit = 0, sparks = 0, lit_max = 0, items_lit = 0, bus_lit = 0, items_lit_max = 0, bus_lit_max = 0, frames = 0, cut_flashes = 0 },
  cut = nil, markers = nil, markers_at = -1, last_pos = nil, log_buf = {}, log_path = nil, log_started = false,
  fake = false, evidence = false, frame_log = nil, msg = '', msg_frames = 0, run_tracks = {},
}

local SILENCE = meter.SILENCE
local HIST_MAX = 240

local app

local function clamp(v, a, b)
  if v < a then return a elseif v > b then return b end
  return v
end

local function trace(fmt, ...)
  local line = string.format(fmt, ...)
  log.info('glow %s', line)
  if log.selftest_armed() then log.selftest('GLOW ' .. line) end
end

function E.say(msg)
  E.msg = msg
  E.msg_frames = 40
end

-- configuration --------------------------------------------------------------------------------------------------

local function num(v, d)
  v = tonumber(v)
  if v == nil then return d end
  return v
end

-- the merged numbers of one profile (defaults overridden by the profile's meter / detector / spark tables)
local function profile_params(cfg, prof)
  local m, d, s = cfg.meter or {}, cfg.detector or {}, cfg.spark or {}
  local pm, pd, ps = (prof and prof.meter) or {}, (prof and prof.detector) or {}, (prof and prof.spark) or {}
  return {
    name = prof and prof.name or 'default',
    release_db_s = num(pm.release_db_s, num(m.release_db_s, 30)),
    ref_decay_db_s = num(pm.ref_decay_db_s, num(m.ref_decay_db_s, 3)),
    ref_floor_dbfs = num(pm.ref_floor_dbfs, num(m.ref_floor_dbfs, -42)),
    window_db = math.max(1, num(pm.window_db, num(m.window_db, 24))),
    gamma = math.max(0.1, num(pm.gamma, num(m.gamma, 1.6))),
    onset_db = num(pd.onset_db, num(d.onset_db, 6)),
    det_release_db_s = num(pd.release_db_s, num(d.release_db_s, 150)),
    min_gap_s = num(ps.min_gap_s, num(s.min_gap_s, 0.06)),
  }
end

local function compile_profiles(cfg)
  local out = {}
  for _, p in ipairs(cfg.profiles or {}) do
    out[#out + 1] = {
      name = tostring(p.name or 'profile'), family = p.family, test = p.rule and match.compile(p.rule) or nil,
      params = profile_params(cfg, p),
    }
  end
  return out, profile_params(cfg, nil)
end

local function profile_of(e)
  for _, p in ipairs(E.profiles) do
    if (p.family and e.fam == p.family) or (p.test and p.test(e.name)) then return p.params end
  end
  return E.default_params
end

function E.reconfigure()
  local cfg = config.get('glow') or {}
  E.reconf_count = (E.reconf_count or 0) + 1
  E.cfg = cfg
  E.enabled = cfg.enable ~= false
  E.mode = cfg.mode or 'meter'
  E.style = cfg.style or 'bar'
  E.fake = cfg.debug and cfg.debug.fake_meter == true
  E.evidence = (cfg.debug and cfg.debug.log == true) or log.selftest_armed()
  E.color = theme.parse_hex(cfg.color) or 0xFFFFFF
  E.warm_color = theme.parse_hex(cfg.warm_color) or 0xFFD070
  E.cut_color = theme.parse_hex(cfg.cut_flash and cfg.cut_flash.color) or 0xFFFFFF
  E.profiles, E.default_params = compile_profiles(cfg)
  for _, e in ipairs(E.tracks) do
    e.P = profile_of(e)
    e.env = e.env or meter.new_env(e.P, reaper.time_precise())
  end
  E.markers_at = -1
  E.perf.level_max = #((cfg.perf or {}).degrade_steps or {})
end

-- the active degrade steps
local function step_active(name)
  local steps = (E.cfg.perf or {}).degrade_steps or {}
  for i = 1, E.perf.level do
    if steps[i] == name then return true end
  end
  return false
end

function E.oversample()
  local S = num((E.cfg.render or {}).oversample, 2)
  if step_active('oversample_1') then S = 1 end
  return S
end

-- track and item cache ---------------------------------------------------------------------------------------------

local function scan_items(e)
  local list = {}
  for j = 0, reaper.CountTrackMediaItems(e.tr) - 1 do
    local it = reaper.GetTrackMediaItem(e.tr, j)
    local p = reaper.GetMediaItemInfo_Value(it, 'D_POSITION')
    local len = reaper.GetMediaItemInfo_Value(it, 'D_LENGTH')
    list[#list + 1] = {
      it = it, take = reaper.GetActiveTake(it), t0 = p, t1 = p + len, len = len,
      mute = reaper.GetMediaItemInfo_Value(it, 'B_MUTE') == 1, env = nil, edge_done = false,
    }
  end
  table.sort(list, function(a, b) return a.t0 < b.t0 end)
  return list
end

function E.rescan()
  local now = reaper.time_precise()
  local old = {}
  for _, e in ipairs(E.tracks) do old[e.guid] = e end
  E.tracks = tracks.scan()
  E.fams = families.compile()
  families.assign(E.fams, E.tracks)
  for k, e in ipairs(E.tracks) do
    e.items = scan_items(e)
    e.seed = k * 0.7
    local o = old[e.guid]
    e.P = E.profiles and profile_of(e) or nil
    e.env = (o and o.env) or (e.P and meter.new_env(e.P, now)) or nil
    e.tail = nil
    e.fake_items = e.items
  end
  -- the fake meter of an item-less parent (bus, folder) follows the items of its descendants
  for k, e in ipairs(E.tracks) do
    if #e.items == 0 and e.folder then
      local acc = {}
      for j = k + 1, #E.tracks do
        local d = E.tracks[j]
        local p = d.parent
        local under = false
        while p do
          if p == k then under = true; break end
          p = E.tracks[p].parent
        end
        if under then
          for _, item in ipairs(d.items) do acc[#acc + 1] = item end
        end
      end
      e.fake_items = acc
    end
  end
  edits.taken(E)
  E.markers_at = -1
end

-- a project edit rescans the items once the edit settled (lib/edits; failure note B2)
function E.check_refresh()
  if edits.due(E) then
    E.rescan()
    E.edit_rescans = (E.edit_rescans or 0) + 1
    return true
  end
  return false
end

-- a settings change from a slider drag or a listener: the profiles are recompiled once, at the next tick
function E.request_reconfigure()
  E.reconf_pending = true
end

local function refresh_markers(now)
  if E.markers and now - E.markers_at < 5 then return end
  local cf = E.cfg.cut_flash or {}
  local classes = regions.compile_classes(config.get('navigator.marker_classes'))
  local _, markers = regions.scan(classes, 5)
  local want = tostring(cf.marker_class or 'Cut'):lower()
  E.markers = {}
  for _, m in ipairs(markers) do
    if m.class and tostring(m.class.name):lower() == want then E.markers[#E.markers + 1] = m.t0 end
  end
  E.markers_at = now
end

-- evidence log ---------------------------------------------------------------------------------------------------------

local function log_line(s)
  local buf = E.log_buf
  buf[#buf + 1] = s
  if #buf >= 240 then E.log_flush() end
end

function E.log_flush()
  if #E.log_buf == 0 then return end
  if not E.log_path then
    local st = reaper.GetExtState('Stagehand', 'selftest')
    if st ~= '' then
      E.log_path = (st:match('^(.*)[/\\]') or '.') .. package.config:sub(1, 1) .. 'glow_meter.txt'
    else
      E.log_path = reaper.GetResourcePath() .. '/Stagehand/glow_meter.txt'
    end
  end
  local f = io.open(E.log_path, E.log_started and 'a' or 'w')
  if f then
    f:write(table.concat(E.log_buf, '\n'), '\n')
    f:close()
    E.log_started = true
  end
  E.log_buf = {}
end

function E.summary()
  local rows = {}
  for k, e in ipairs(E.tracks) do
    if e.env and e.env.gmax > 0.05 then
      rows[#rows + 1] = string.format('%d%s:%.2f/%d', k, (e.P and e.P.name or 'd'):sub(1, 1), e.env.gmax, e.env.sparks)
    end
  end
  return table.concat(rows, ' ')
end

-- drawing helpers ----------------------------------------------------------------------------------------------------

local lit_rects = {}   -- reused per frame: { x0, x1, y, h, rgb, a } for the cut flash compositing
local n_lit = 0

local function push_lit(x0, x1, y, h, rgb, a)
  n_lit = n_lit + 1
  local r = lit_rects[n_lit]
  if not r then
    r = {}
    lit_rects[n_lit] = r
  end
  r[1], r[2], r[3], r[4], r[5], r[6] = x0, x1, y, h, rgb, a
end

local function item_env(e, item, now)
  if not item.env then
    item.env = meter.new_env(e.P, now)
    item.env.last = now
  end
  return item.env
end

-- the item's own level from the take peaks (bar and spark timing); falls back to the track level
local function item_step(e, item, pos, now, dt, fallback)
  local s = item_env(e, item, now)
  local idt = clamp(now - s.last, 0, 0.2)
  s.last = now
  local lvl, at
  if E.fake then
    lvl, at = fallback, pos
    s.raw = false
  else
    lvl, at = peaks.take_db(item.it, item.take, pos, math.max(idt, 0.005))
    if lvl then s.raw = true else lvl, at, s.raw = fallback, pos, false end
  end
  local gi, onset = meter.step(s, lvl, idt, e.P, now, at or pos)
  return gi, s, onset
end

local function draw_fill(x0, x1, y, h, g, rgb_fill, a_fill, outline_a, style)
  local w = x1 - x0
  if w <= 0 then return end
  if style ~= 'edge' and a_fill > 0.003 then O.rect(x0, y, w, h, rgb_fill, a_fill) end
  local t = style == 'edge' and 2 or 1
  if outline_a > 0.003 then O.outline(x0, y, w, h, rgb_fill, outline_a, t) end
end

-- the spark at sx (client px) inside [x0, x1): column (a hard column with a one-sided tail), beam (a bright core
-- with a soft halo on both sides) or trail (a gradient growing from the onset to the play head plus the beam)
local function draw_spark(sx, x0, x1, y, h, sa, rgb_fill, a_fill, pos)
  local sp = E.cfg.spark or {}
  local style = sp.style or 'column'
  local width = num(sp.width_px, 3)
  if sx < x0 then sx = x0 end
  if sx >= x1 then return end
  if style == 'beam' or style == 'trail' then
    local core = O.blend(E.warm_color, 0xFFFFFF, 0.6)
    if style == 'trail' then
      local xh = math.floor((pos - E.t_left) * E.pps)
      if xh > x1 then xh = x1 end
      if xh > sx then
        local from = math.max(sx, xh - num(sp.trail_max_px, 160))
        O.trail(from, xh, y, h, E.warm_color, sa * 0.8, rgb_fill, a_fill, x0, x1)
        sx = math.max(xh - width, x0)
      end
    end
    O.beam(sx, y, h, width, num(sp.halo_px, 14), core, E.warm_color, sa, rgb_fill, a_fill, x0, x1)
  else
    local tail = math.min(num(sp.tail_px, 28), x1 - sx - width)
    if tail < 0 then tail = 0 end
    O.spark(sx, y, h, math.min(width, x1 - sx), tail, E.warm_color, sa, rgb_fill, a_fill)
  end
  E.stats.sparks_drawn = (E.stats.sparks_drawn or 0) + 1
end

-- meter mode: one item under the play head (or the tail item) of one track row
local function draw_meter_item(e, item, x0, x1, y, h, g, pos, now, dt, lvl, is_tail)
  local cfg = E.cfg
  local m, b, sp = cfg.meter or {}, cfg.bar or {}, cfg.spark or {}
  local style = E.style
  local warm = num(cfg.warm_amount, 0.55) * g * g
  local rgb = O.blend(E.color, E.warm_color, warm)
  local a_fill
  if style == 'fill' then
    a_fill = num(m.base_alpha, 0.03) + num(m.fill_gain, 0.36) * g
  elseif style == 'edge' then
    a_fill = 0
  else
    a_fill = num(m.base_alpha, 0.03) + num(m.tint_gain, 0.08) * g
  end
  local outline_a = style == 'edge' and (0.10 + 0.70 * g) or clamp(a_fill * (1 + num(cfg.outline_gain, 0.55)), 0, 1)
  draw_fill(x0, x1, y, h, g, rgb, a_fill, outline_a, style)
  push_lit(x0, x1, y, h, rgb, a_fill)
  if is_tail then return end
  local gi, s = item_step(e, item, pos, now, dt, lvl)
  if style == 'bar' and gi > 0.01 then
    local hb = math.floor(h * gi)
    if hb >= 1 then
      local ba = clamp(num(b.alpha_floor, 0.16) + num(b.alpha_gain, 0.16) * gi, 0, 1)
      local bc = O.blend(E.color, E.warm_color, num(cfg.warm_amount, 0.55) * gi)
      O.rect(x0, y + h - hb, x1 - x0, hb, bc, ba)
      O.rect(x0, y + h - hb, x1 - x0, 1, bc, clamp(ba + 0.3, 0, 1))
    end
  end
  if E.sparks_on and s.spark_t > 0 then
    local age = now - s.spark_t
    local decay = num(sp.decay_s, 0.32)
    if age >= 0 and age < decay * 4 then
      local sa = num(sp.alpha, 0.75) * math.exp(-age / decay)
      draw_spark(math.floor((s.spark_pos - E.t_left) * E.pps), x0, x1, y, h, sa, rgb, a_fill, pos)
    end
  end
end

-- item mode (v1): flash at the item start, low glow while it plays, release after the end
local function draw_item_mode(e, item, x0, x1, y, h, pos, now)
  local cfg = E.cfg
  local I = cfg.item or {}
  local peak, sustain = num(I.peak_alpha, 0.42), num(I.sustain_alpha, 0.14)
  local attack, release = math.max(0.01, num(I.attack_s, 0.35)), math.max(0.01, num(I.release_s, 0.30))
  local a
  if pos < item.t1 then
    local t = pos - item.t0
    a = sustain + (peak - sustain) * math.exp(-t / attack)
  else
    a = sustain * math.exp(-(pos - item.t1) / release)
  end
  if item.len > num(I.long_item_s, 8) then a = a * num(I.long_factor, 0.5) end
  if a < 0.004 then return false end
  local rgb = E.color
  draw_fill(x0, x1, y, h, a, rgb, a, clamp(a * (1 + num(cfg.outline_gain, 0.55)), 0, 1), E.style == 'edge' and 'edge' or 'fill')
  push_lit(x0, x1, y, h, rgb, a)
  if E.sparks_on and pos < item.t1 then
    local t = pos - item.t0
    local ea = num(cfg.spark and cfg.spark.alpha, 0.75) * math.exp(-t / math.max(0.01, num(I.edge_decay_s, 0.28)))
    if ea > 0.01 then draw_spark(x0, x0, x1, y, h, ea, rgb, a, pos) end
  end
  return true
end

local function draw_cut(now)
  local c = E.cut
  if not c then return false end
  local cf = E.cfg.cut_flash or {}
  local decay = math.max(0.01, num(cf.decay_s, 0.22))
  local age = now - c.t
  if age > decay * 4 then
    E.cut = nil
    return false
  end
  local a = num(cf.alpha, 0.35) * math.exp(-age / decay)
  local x = math.floor((c.pos - E.t_left) * E.pps)
  local w = math.max(1, math.floor(num(cf.width_px, 2)))
  if x < 0 or x >= O.w then return false end
  O.rect(x, 0, w, O.h, E.cut_color, a)
  for i = 1, n_lit do
    local r = lit_rects[i]
    if x + w > r[1] and x < r[2] then
      local cc, ca = O.over(r[5], r[6], E.cut_color, a)
      O.rect(x, r[3], w, r[4], cc, ca)
    end
  end
  return true
end

-- performance guard ------------------------------------------------------------------------------------------------

local function perf_update(ms)
  local P = E.perf
  local pc = E.cfg.perf or {}
  local budget = num(pc.budget_ms, 2.0)
  P.ms = ms
  P.frames = P.frames + 1
  P.sum = P.sum + ms
  if ms > P.max then P.max = ms end
  P.ema = P.ema == 0 and ms or (P.ema * 0.9 + ms * 0.1)
  local hist = P.hist
  hist[#hist + 1] = ms
  if #hist > HIST_MAX then table.remove(hist, 1) end
  local steps = pc.degrade_steps or {}
  if ms > budget then
    P.over = P.over + 1
    P.under = 0
    if P.over >= num(pc.over_frames, 30) and P.level < #steps then
      P.level = P.level + 1
      P.over = 0
      trace('DEGRADE level=%d step=%s ema=%.2f budget=%.2f', P.level, tostring(steps[P.level]), P.ema, budget)
      E.say(string.format('Glow over budget: %s', tostring(steps[P.level])))
    end
  else
    P.over = 0
    if P.ema < budget * 0.5 then
      P.under = P.under + 1
      if P.under >= num(pc.recover_frames, 300) and P.level > 0 then
        trace('RECOVER level=%d -> %d ema=%.2f', P.level, P.level - 1, P.ema)
        P.level = P.level - 1
        P.under = 0
      end
    else
      P.under = 0
    end
  end
end

function E.perf_reset()
  local P = E.perf
  P.ms, P.ema, P.max, P.over, P.under, P.frames, P.sum, P.hist = 0, 0, 0, 0, 0, 0, 0, {}
end

function E.perf_stats()
  local P = E.perf
  local hist = {}
  for i, v in ipairs(P.hist) do hist[i] = v end
  table.sort(hist)
  local p95 = hist[math.max(1, math.floor(#hist * 0.95))] or 0
  return { avg = P.frames > 0 and P.sum / P.frames or 0, max = P.max, ema = P.ema, p95 = p95, frames = P.frames, level = P.level }
end

-- the frame ----------------------------------------------------------------------------------------------------------

function E.release()
  if O.bmp then
    E.log_flush()
    O.release()
    trace('RELEASE bitmaps=%d', O.created)
  end
  E.alive, E.cut = false, nil
end

function E.active()
  return E.enabled and E.mode ~= 'off' and O.available()
end

function E.tick()
  if E.msg_frames > 0 then E.msg_frames = E.msg_frames - 1 end
  if E.reconf_pending then
    E.reconf_pending = false
    E.reconfigure()
  end
  if not E.active() then
    if O.bmp then E.release() end
    E.last_pos = nil
    return
  end
  E.frame_n = (E.frame_n or 0) + 1
  E.check_refresh()
  local now = reaper.time_precise()
  local dt = E.last_now and clamp(now - E.last_now, 0, 0.2) or 0.033
  E.last_now = now
  local playing = view.playing()
  local pos = view.position()
  local cf = E.cfg.cut_flash or {}
  if cf.enable ~= false then
    refresh_markers(now)
    if playing and E.last_pos and pos > E.last_pos and pos - E.last_pos < 0.5 then
      for _, mt in ipairs(E.markers) do
        if E.last_pos < mt and mt <= pos then
          E.cut = { t = now, pos = mt }
          E.stats.cut_flashes = E.stats.cut_flashes + 1
          break
        end
      end
    end
  end
  E.last_pos = playing and pos or nil
  if not playing and not E.alive and not E.cut then
    if E.was_playing then
      E.was_playing = false
      E.log_flush()
      trace('STOP frames=%d lit_max=%d sparks=%d cuts=%d ms_avg=%.2f ms_max=%.2f level=%d summary=%s', E.stats.frames, E.stats.lit_max,
        E.stats.sparks, E.stats.cut_flashes, E.perf.frames > 0 and E.perf.sum / E.perf.frames or 0, E.perf.max, E.perf.level, E.summary())
    end
    -- idle: nothing to draw, so nothing stays composited on the arrange. REAPER paints every arrange refresh
    -- through a composited bitmap (a region drag, a zoom), which is where macOS showed a coarse, "pixelated" arrange
    -- with the glow merely enabled (failure note B2); the bitmap comes back with the next play
    if O.bmp then E.release() end
    return
  end
  -- the client size is re-read every 5 frames (the arrange hwnd lookup and the size query cost ~0.15 ms on Windows)
  if not O.ensure(E.oversample(), (E.frame_n % 5) == 0) then return end
  if playing and not E.was_playing then
    E.was_playing = true
    E.stats.lit_max, E.stats.sparks, E.stats.frames, E.stats.cut_flashes = 0, 0, 0, 0
    E.stats.items_lit_max, E.stats.bus_lit_max = 0, 0
    E.perf_reset()
    for _, e in ipairs(E.tracks) do
      if e.env then e.env.gmax, e.env.sparks = 0, 0 end
    end
    trace('PLAY pos=%.3f mode=%s style=%s fake=%s S=%d overlay=%s', pos, E.mode, E.style, tostring(E.fake), O.S, O.describe())
  end
  local t_draw = reaper.time_precise()
  O.clear()
  E.t_left, E.t_right, E.pps = O.mapping()
  E.sparks_on = not step_active('sparks_off')
  local bus_on = (E.cfg.bus or {}).enable ~= false and not step_active('bus_off')
  local tail_max = num((E.cfg.meter or {}).tail_max_s, 2.5)
  local B = E.cfg.bus or {}
  n_lit = 0
  local drew = false
  local lit, items_lit, bus_lit = 0, 0, 0
  local alive = false
  local H = O.h
  for k, e in ipairs(E.tracks) do
    if reaper.GetMediaTrackInfo_Value(e.tr, 'B_SHOWINTCP') == 1 then
      local y = reaper.GetMediaTrackInfo_Value(e.tr, 'I_TCPY')
      local rh = reaper.GetMediaTrackInfo_Value(e.tr, 'I_TCPH')
      if rh > 2 and y + rh > 0 and y < H then
        local muted = reaper.GetMediaTrackInfo_Value(e.tr, 'B_MUTE') == 1
        local real = meter.track_db(e.tr)   -- always the real read (a missing API is caught on the test machine)
        local lvl = E.fake and meter.fake_db(e.fake_items or e.items, pos, e.seed) or real
        if muted or not playing then lvl = SILENCE end
        local g = 0
        if e.env then g = meter.step(e.env, lvl, dt, e.P, now, pos) end
        if g > 0.005 then alive = true end
        local yy, hh = y + 1, rh - 2
        local row_lit = false
        if E.mode == 'item' then
          for _, item in ipairs(e.items) do
            if playing and not item.mute and item.t0 <= pos and pos < item.t1 + num((E.cfg.item or {}).release_s, 0.3) * 5 then
              local x0 = clamp(math.floor((item.t0 - E.t_left) * E.pps), 0, O.w)
              local x1 = clamp(math.ceil((item.t1 - E.t_left) * E.pps), 0, O.w)
              if x1 - x0 >= 1 and draw_item_mode(e, item, x0, x1, yy, hh, pos, now) then
                row_lit = true
                items_lit = items_lit + 1
                alive = true
              end
            end
          end
        else
          local tail_item
          for _, item in ipairs(e.items) do
            if not item.mute then
              if item.t0 <= pos and pos < item.t1 then
                local x0 = clamp(math.floor((item.t0 - E.t_left) * E.pps), 0, O.w)
                local x1 = clamp(math.ceil((item.t1 - E.t_left) * E.pps), 0, O.w)
                if x1 - x0 >= 1 and (g > 0.005 or (playing and num((E.cfg.meter or {}).base_alpha, 0.03) > 0)) then
                  draw_meter_item(e, item, x0, x1, yy, hh, g, pos, now, dt, lvl, false)
                  row_lit = true
                  items_lit = items_lit + 1
                end
              elseif item.t1 <= pos and pos - item.t1 < tail_max then
                if not tail_item or item.t1 > tail_item.t1 then tail_item = item end
              end
            end
          end
          if not row_lit and tail_item and g > 0.01 then
            local x0 = clamp(math.floor((tail_item.t0 - E.t_left) * E.pps), 0, O.w)
            local x1 = clamp(math.ceil((tail_item.t1 - E.t_left) * E.pps), 0, O.w)
            if x1 - x0 >= 1 then
              draw_meter_item(e, tail_item, x0, x1, yy, hh, g, pos, now, dt, lvl, true)
              row_lit = true
            end
          end
          if #e.items == 0 and bus_on and g > 0.01 then
            local hb = math.floor(hh * num(B.max_frac, 0.35) * g)
            if hb >= 1 then
              local ba = clamp(num(B.alpha_floor, 0.10) + num(B.alpha_gain, 0.14) * g, 0, 1)
              local bc = O.blend(E.color, E.warm_color, num(E.cfg.warm_amount, 0.55) * g * g)
              O.rect(0, yy + hh - hb, O.w, hb, bc, ba)
              O.rect(0, yy + hh - hb, O.w, 1, bc, clamp(ba + 0.2, 0, 1))
              row_lit = true
              bus_lit = bus_lit + 1
            end
          end
        end
        if row_lit then
          lit = lit + 1
          drew = true
          if E.evidence and playing then
            local s = e.env
            log_line(string.format('%.3f %d %.1f %.2f %d %s', pos, k, lvl, g, s and s.sparks or 0, E.mode))
          end
        end
      end
    end
  end
  if draw_cut(now) then drew = true; alive = true end
  O.flush(drew)
  E.alive = alive
  local ms = (reaper.time_precise() - t_draw) * 1000
  perf_update(ms)
  if playing then
    E.stats.frames = E.stats.frames + 1
    E.stats.lit = lit
    E.stats.items_lit, E.stats.bus_lit = items_lit, bus_lit
    if lit > E.stats.lit_max then E.stats.lit_max = lit end
    if items_lit > E.stats.items_lit_max then E.stats.items_lit_max = items_lit end
    if bus_lit > E.stats.bus_lit_max then E.stats.bus_lit_max = bus_lit end
    local sparks = 0
    for _, e in ipairs(E.tracks) do
      if e.env then sparks = sparks + e.env.sparks end
      for _, item in ipairs(e.items) do
        if item.env then sparks = sparks + item.env.sparks end
      end
    end
    E.stats.sparks = sparks
  end
end

-- the x (client px) of a project time with the current mapping; nil when nothing is mapped yet
function E.x_of(t)
  if not E.pps then return nil end
  return (t - E.t_left) * E.pps
end

-- the item envelope of one item (self-test oracle for spark timing)
function E.item_state(it)
  for _, e in ipairs(E.tracks) do
    for _, item in ipairs(e.items) do
      if item.it == it then return item, e end
    end
  end
  return nil
end

function E.init(app_)
  app = app_
  E.reconfigure()
  E.rescan()
  E.reconfigure()
end

function E.set_enabled(on)
  E.enabled = on == true
  if not E.enabled then E.release() end
  trace('ENABLE %s', tostring(E.enabled))
end

return E
