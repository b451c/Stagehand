-- modules/director/engine.lua - the follow-play engine (BRIEF 3.2, docs/research/mechanisms.md section 2).
--
-- A run owns the track layout: for the shot under the play position (LEAD seconds early) it shows the shot's
-- lanes (plus pinned rows and, by setting, their folder parents), locks their heights so they fill the arrange
-- (measured live; a verify pass in the next frames corrects the estimate), scrolls to the top, sets the
-- envelope lanes of the "story", and zooms the view to the shot's page (or slides it in follow view) with an
-- eased animation. Every change is journaled first (lib/journal, owner "director") and put back by stop(),
-- the app's restore hook and REAPER's exit. Heights: I_HEIGHTOVERRIDE is scaled by the vertical zoom unless
-- B_HEIGHTLOCK is set, so the push writes override then lock. Lua 5.4; no globals.

local log = require('lib.log')
local config = require('config')
local edits = require('lib.edits')
local journal = require('lib.journal')
local view = require('lib.view')
local arrange = require('lib.arrange')
local tracks = require('lib.tracks')
local families = require('lib.families')
local envelopes = require('lib.envelopes')
local easing = require('lib.easing')
local MD = require('modules.director.model')
local R = require('modules.director.resolve')

local E = {
  active = false, k = nil, auto = true, anim = nil, verify = nil, tracks = {}, fams = nil, state_count = -1,
  last = {}, ruler = nil, view_set = nil, msg = '', msg_frames = 0, journaled = {}, frame = 0,
  apply_count = 0, switch_log = {},
}

local CONT_SCROLL = 41817
local RULER_BASE = 43507

local app

local function cfg(key)
  return config.get('director.' .. key)
end

local function clamp(v, a, b)
  if v < a then return a elseif v > b then return b end
  return v
end

local function trace(fmt, ...)
  local line = string.format(fmt, ...)
  log.info('director %s', line)
  if log.selftest_armed() then log.selftest('DIRECTOR ' .. line) end
end

function E.init(app_)
  app = app_
  E.rescan()
end

function E.say(msg)
  E.msg = msg
  E.msg_frames = 40
end

-- track cache -----------------------------------------------------------------------------------------------------

-- extra height under a visible row = its visible envelope lanes (used by the "keep" envelope mode)
local function measure_extra(list)
  for _, e in ipairs(list) do
    if tracks.get(e.tr, 'B_SHOWINTCP') == 1 then
      e.extra_keep = arrange.extra_of(e.tr)
    else
      e.extra_keep = 0
    end
  end
end

function E.rescan()
  local old = {}
  for _, e in ipairs(E.tracks) do old[e.guid] = e end
  E.tracks = tracks.scan()
  E.fams = families.compile()
  families.assign(E.fams, E.tracks)
  if E.active then
    -- during a run the measured extra of a track is only valid from before the first push
    for _, e in ipairs(E.tracks) do
      local o = old[e.guid]
      e.extra_keep = o and o.extra_keep or 0
    end
  else
    measure_extra(E.tracks)
  end
  edits.taken(E)
end

-- a project edit rescans the tracks once the edit settled (lib/edits: a drag bumps the count every frame); it never
-- re-applies the shot - the layout follows the shot under the cursor only (docs/research/failures.md B2)
function E.check_refresh()
  if edits.due(E) then
    E.rescan()
    if E.active then
      E.edit_rescans = (E.edit_rescans or 0) + 1
      trace('EDIT rescan n=%d deferred=%d tracks=%d k=%s', E.edit_rescans, E.edits_deferred or 0, #E.tracks, tostring(E.k))
    end
    return true
  end
  return false
end

-- view ------------------------------------------------------------------------------------------------------------

function E.view_mode(s)
  return (s and s.view) or cfg('view.mode') or 'page'
end

function E.view_target(s, pos)
  if E.view_mode(s) == 'follow' then
    local len = math.max(tonumber(cfg('view.follow_len_s')) or 6, (s.t1 - s.t0) * (tonumber(cfg('view.follow_shot_frac')) or 0.6))
    local a = math.max(0, pos - len * (tonumber(cfg('view.follow_cursor_frac')) or 0.333))
    return a, a + len
  end
  local pb = tonumber(s.pad_before) or tonumber(cfg('view.pad_before_s')) or 0.6
  local pa = tonumber(s.pad_after) or tonumber(cfg('view.pad_after_s')) or 0.5
  return math.max(0, s.t0 - pb), s.t1 + pa
end

local function set_view(a, b)
  view.set(a, b)
  E.view_set = { a, b }
end

function E.start_anim(a, b)
  local c0, c1 = view.get()
  local dur = tonumber(cfg('view.anim_s')) or 0.3
  if dur <= 0 or (math.abs(c0 - a) + math.abs(c1 - b)) < 0.02 then
    set_view(a, b)
    E.anim = nil
    return
  end
  E.anim = { f0 = c0, f1 = c1, t0 = a, t1 = b, start = reaper.time_precise(), dur = dur, ease = easing.get(cfg('view.easing')) }
end

local function animate(pos)
  local s = E.k and MD.shots[E.k]
  if E.anim then
    local a = E.anim
    local p = a.ease((reaper.time_precise() - a.start) / a.dur)
    local ta, tb = a.t0, a.t1
    if s and E.view_mode(s) == 'follow' then ta, tb = E.view_target(s, pos) end
    set_view(a.f0 + (ta - a.f0) * p, a.f1 + (tb - a.f1) * p)
    if p >= 1 then E.anim = nil end
  elseif s and E.view_mode(s) == 'follow' and view.playing() then
    set_view(E.view_target(s, pos))
  end
end

-- layout push -----------------------------------------------------------------------------------------------------

local function snapshot_of(e)
  return {
    show = math.floor(tracks.get(e.tr, 'B_SHOWINTCP')),
    height = math.floor(tracks.get(e.tr, 'I_HEIGHTOVERRIDE')),
    lock = math.floor(tracks.get(e.tr, 'B_HEIGHTLOCK')),
    compact = e.folder and math.floor(tracks.get(e.tr, 'I_FOLDERCOMPACT')) or nil,
    pin = math.floor(tracks.get(e.tr, 'B_TCPPIN')),
  }
end

local function journal_track(e)
  if E.journaled[e.guid] then return end
  journal.add({ kind = 'layout', key = e.guid, was = snapshot_of(e), owner = 'director' })
  E.journaled[e.guid] = true
end

local function setv(tr, key, want)
  if tracks.get(tr, key) ~= want then tracks.set(tr, key, want) end
end

-- the push: visibility, locked heights, uncollapsed folders, pins. Skips tracks already in the wanted state
-- (Windows: every SetMediaTrackInfo_Value costs ~20x a Linux call). Runs inside the caller's PreventUIRefresh.
local function make_push(list, role, keep_h, uncollapse, all, parent_px, compact_px, pin_enable)
  return function(lane_h)
    local sets = 0
    for k, e in ipairs(list) do
      local r = role[k]
      local show = all or r ~= nil
      journal_track(e)
      if not show then
        if tracks.get(e.tr, 'B_SHOWINTCP') ~= 0 then tracks.set(e.tr, 'B_SHOWINTCP', 0); sets = sets + 1 end
      else
        local h = (r == 'keep' and keep_h[k]) or (r == 'parent' and parent_px) or (r == 'lane' and lane_h) or compact_px
        if tracks.get(e.tr, 'B_SHOWINTCP') ~= 1 then tracks.set(e.tr, 'B_SHOWINTCP', 1); sets = sets + 1 end
        local want_lock = h > 0 and 1 or 0
        if tracks.get(e.tr, 'I_HEIGHTOVERRIDE') ~= h or tracks.get(e.tr, 'B_HEIGHTLOCK') ~= want_lock then
          tracks.set(e.tr, 'B_HEIGHTLOCK', 0)
          tracks.set(e.tr, 'I_HEIGHTOVERRIDE', h)
          tracks.set(e.tr, 'B_HEIGHTLOCK', want_lock)
          sets = sets + 3
        end
        if e.folder and uncollapse[k] then setv(e.tr, 'I_FOLDERCOMPACT', 0) end
        if pin_enable then setv(e.tr, 'B_TCPPIN', r == 'keep' and 1 or 0) end
      end
    end
    reaper.TrackList_AdjustWindows(false)
    return sets
  end
end

local function apply_envelopes(s, list)
  local mode = cfg('envelopes.mode')
  local extra = {}
  local shown = 0
  if mode == 'story' then
    local want
    want, shown = R.envelopes(s, list)
    local env_px = tonumber(cfg('heights.env_lane_px')) or 26
    for k, rows in pairs(want) do
      local n = 0
      for _, row in ipairs(rows) do
        if row.guid then
          journal.add({ kind = 'env_vis', key = row.guid, was = envelopes.visible(row.env), owner = 'director' })
        end
        envelopes.set_visible(row.env, row.want)
        if row.want then n = n + 1 end
      end
      extra[k] = n * env_px
    end
  else
    for k, e in ipairs(list) do extra[k] = e.extra_keep or 0 end
  end
  return extra, shown
end

function E.apply(k, why)
  local s = MD.shots[k]
  if not s then return false end
  local t_start = reaper.time_precise()
  local list = E.tracks
  local mode = cfg('layout.mode') or 'focus'
  local all = mode == 'all'
  local parents = s.parents or cfg('layout.parents') or 'none'
  local pin_enable = cfg('pins.enable') ~= false
  local parent_px = math.floor(tonumber(cfg('heights.parent_px')) or 24)
  local compact_px = math.floor(tonumber(cfg('heights.compact_px')) or 20)
  local lane_min = math.floor(tonumber(cfg('heights.lane_min_px')) or 26)
  local lane_max = math.floor(tonumber(cfg('heights.lane_max_px')) or 110)
  local role, keep_h, uncollapse, counts = R.roles(s, list, { pins = cfg('pins.rows'), parents = parents, pin_enable = pin_enable })

  reaper.PreventUIRefresh(1)
  local extra, env_shown = apply_envelopes(s, list)
  local H, exact = arrange.height(cfg('heights.arrange_fallback_px'))
  local fixed = 0
  for kk, r in pairs(role) do
    if r == 'keep' then fixed = fixed + keep_h[kk] elseif r == 'parent' then fixed = fixed + parent_px end
    fixed = fixed + (extra[kk] or 0)
  end
  local nl = counts.lanes
  local lane_h = nl > 0 and clamp(math.floor((H - fixed) / nl), lane_min, lane_max) or lane_min
  local push = make_push(list, role, keep_h, uncollapse, all, parent_px, compact_px, pin_enable)
  local sets = push(lane_h)
  local scroll_was = arrange.scroll_pos()
  if scroll_was then journal.add({ kind = 'scroll', key = 'vscroll', was = scroll_was, owner = 'director' }) end
  if not all then
    arrange.scroll_top()
  else
    local pinned = 0
    if pin_enable then
      for kk, r in pairs(role) do
        if r == 'keep' then pinned = pinned + tracks.get(list[kk].tr, 'I_WNDH') end
      end
    end
    local first
    for kk, r in pairs(role) do
      if r == 'lane' and (not first or kk < first) then first = kk end
    end
    if first then arrange.scroll_to_track(list[first].tr, pinned) else arrange.scroll_top() end
  end
  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  E.state_count = reaper.GetProjectStateChangeCount(0)

  if not all and nl > 0 then
    E.verify = { role = role, nl = nl, lane_h = lane_h, H = H, push = push, tries = 0, frames = 0, lane_min = lane_min, lane_max = lane_max }
  else
    E.verify = nil
  end

  local pos = view.position()
  local v0, v1 = view.get()
  journal.add({ kind = 'view', key = 'view', was = { v0, v1 }, owner = 'director' })
  E.start_anim(E.view_target(s, pos))
  E.k = k
  local lead = tonumber(cfg('timing.lead_s')) or 0.4
  local late = (why == 'follow' and view.playing()) and (pos - (s.t0 - lead)) or nil   -- a real switch under playback
  E.apply_count = E.apply_count + 1
  E.last = {
    k = k, why = why, H = H, exact = exact, lanes = nl, parents = counts.parents, keeps = counts.keeps, lane_h = lane_h,
    fixed = fixed, total = fixed + nl * lane_h, env_shown = env_shown, late = late, pos = pos, sets = sets,
    apply_ms = (reaper.time_precise() - t_start) * 1000, verify_tries = 0, bottom = nil, fits = nil,
    view0 = E.anim and E.anim.t0 or v0, view1 = E.anim and E.anim.t1 or v1, mode = mode, parents_mode = parents,
  }
  if late then E.switch_log[#E.switch_log + 1] = { k = k, late = late, pos = pos } end
  trace('APPLY %s k=%d pos=%.3f H=%d%s lanes=%d parents=%d keeps=%d lane_h=%d fixed=%d total=%d envs=%d sets=%d ms=%.1f%s view=%.2f-%.2f',
    why, k, pos, H, exact and '' or '(fallback)', nl, counts.parents, counts.keeps, lane_h, fixed, E.last.total, env_shown, sets,
    E.last.apply_ms, late and string.format(' late=%.3f', late) or '', E.last.view0, E.last.view1)
  E.say(string.format('%d/%d  %s', k, #MD.shots, s.name))
  if app then app.emit('shot_changed', k, s) end
  return true
end

-- verify pass: real heights exist only after REAPER laid the list out (docs/research/failures.md H3)
local function verify_step()
  local v = E.verify
  if not v then return end
  v.frames = v.frames + 1
  if v.frames < (tonumber(cfg('heights.verify_wait_frames')) or 2) then return end
  -- the arrange may have changed height since the push (the HUD bar docking at the bottom when the run starts,
  -- a docker the user opens): measure again and correct against the current height
  local H_now = arrange.height(cfg('heights.arrange_fallback_px'))
  if math.abs(H_now - v.H) > 2 then
    trace('VERIFY arrange height changed %d -> %d', v.H, H_now)
    v.H = H_now
    E.last.H = H_now
  end
  local bottom = arrange.bottom(E.tracks, function(k) return v.role[k] ~= nil end)
  local new
  if bottom > v.H + 2 and v.lane_h > v.lane_min then
    new = clamp(v.lane_h - math.ceil((bottom - v.H) / v.nl), v.lane_min, v.lane_max)
  elseif bottom < v.H - v.nl - 2 and v.lane_h < v.lane_max then
    new = clamp(v.lane_h + math.floor((v.H - bottom) / v.nl), v.lane_min, v.lane_max)
  end
  E.last.bottom = bottom
  E.last.verify_tries = v.tries
  trace('VERIFY k=%s try=%d bottom=%d H=%d lane_h=%d -> %s', tostring(E.k), v.tries, bottom, v.H, v.lane_h, tostring(new or 'ok'))
  local max_tries = tonumber(cfg('heights.verify_tries')) or 3
  if new and new ~= v.lane_h and v.tries < max_tries then
    v.lane_h = new
    v.tries = v.tries + 1
    v.frames = 0
    reaper.PreventUIRefresh(1)
    v.push(new)
    arrange.scroll_top()
    reaper.PreventUIRefresh(-1)
    reaper.UpdateArrange()
    E.state_count = reaper.GetProjectStateChangeCount(0)
    E.last.lane_h = new
    E.last.total = E.last.fixed + v.nl * new
    E.last.verify_tries = v.tries
  else
    E.last.fits = bottom <= v.H + 2
    E.verify = nil
  end
end

-- ruler lanes (opt-in): blind toggles of 43507 + N with wait frames, journaled, then the current shot again
local function ruler_start()
  if cfg('ruler.mode') ~= 'hide' then return end
  local ids = cfg('ruler.lane_ids') or { 1, 2 }
  E.ruler = { queue = ids, i = 0, wait = 6, phase = 'next', h0 = nil }
end

local function ruler_step()
  local Rl = E.ruler
  if not Rl then return end
  if Rl.wait > 0 then Rl.wait = Rl.wait - 1; return end
  if Rl.phase == 'next' then
    Rl.i = Rl.i + 1
    if Rl.i > #Rl.queue then
      E.ruler = nil
      trace('RULER lanes toggled: %d', #Rl.queue)
      if E.k then E.apply(E.k, 'ruler') end
      return
    end
    local n = math.floor(tonumber(Rl.queue[Rl.i]) or 0)
    Rl.h0 = arrange.height(cfg('heights.arrange_fallback_px'))
    if journal.add({ kind = 'ruler_lane', key = 'ruler_lane_' .. n, was = n, owner = 'director' }) then
      reaper.Main_OnCommand(RULER_BASE + n, 0)
    end
    Rl.phase = 'measure'
    Rl.wait = 8
  else
    local h1 = arrange.height(cfg('heights.arrange_fallback_px'))
    trace('RULER lane %s toggled (arrange %d -> %d)', tostring(Rl.queue[Rl.i]), Rl.h0 or 0, h1)
    Rl.phase = 'next'
  end
end

-- run control --------------------------------------------------------------------------------------------------------

function E.start(why)
  if E.active then return false end
  if #MD.shots == 0 then return false end
  E.rescan()
  E.journaled = {}
  E.switch_log = {}
  if cfg('scroll.disable_continuous') ~= false then
    local st = view.toggle_state(CONT_SCROLL, 'continuous')
    if st >= 0 then
      journal.add({ kind = 'toggle', key = tostring(CONT_SCROLL), was = st, name = 'continuous', owner = 'director' })
      if st == 1 then reaper.Main_OnCommand(CONT_SCROLL, 0) end
    end
  end
  E.active = true
  if app then app.emit('director_active', true) end
  ruler_start()
  local lead = tonumber(cfg('timing.lead_s')) or 0.4
  local k = MD.shot_at(view.position(), lead) or 1
  trace('START %s shots=%d tracks=%d', why or 'ui', #MD.shots, #E.tracks)
  E.apply(k, why or 'start')
  return true
end

-- puts everything back; returns the journal stats
function E.stop(why)
  if not E.active then return nil end
  local t0 = reaper.time_precise()
  E.anim, E.verify, E.ruler = nil, nil, nil
  local stats = journal.restore(journal.owner_pred('director'))
  E.active = false
  E.k = nil
  E.journaled = {}
  E.view_set = nil
  if app then app.emit('director_active', false) end
  measure_extra(E.tracks)
  trace('STOP %s restored=%d kept=%d gone=%d ms=%.1f', why or 'ui', stats.restored, stats.kept, stats.gone, (reaper.time_precise() - t0) * 1000)
  return stats
end

-- called by the app on a frame error and at exit
function E.restore()
  return E.stop('restore')
end

-- the project switched under us: the old project keeps its journal (offered on the next launch); forget the run
function E.abandon()
  E.active, E.k, E.anim, E.verify, E.ruler = false, nil, nil, nil, nil
  E.journaled = {}
  if app then app.emit('director_active', false) end
end

function E.goto_shot(k)
  if #MD.shots == 0 then return end
  k = clamp(k, 1, #MD.shots)
  local s = MD.shots[k]
  reaper.SetEditCurPos2(0, s.t0, false, view.playing())
  if not E.active then
    E.start('jump')
  else
    E.apply(k, 'jump')
  end
end

function E.next_shot()
  E.goto_shot((E.k or 0) + 1)
end

function E.prev_shot()
  E.goto_shot((E.k or 2) - 1)
end

-- lay a shot out without moving the cursor; auto-follow pauses so the preview stays
function E.preview(k)
  if #MD.shots == 0 then return end
  k = clamp(k, 1, #MD.shots)
  if not E.active then
    E.active = false
    E.start('preview')
  end
  if E.k ~= k then
    E.auto = false
    E.apply(k, 'preview')
  end
end

function E.set_auto(on)
  E.auto = on == true
  if E.auto and E.active then
    local lead = tonumber(cfg('timing.lead_s')) or 0.4
    local k = MD.shot_at(view.position(), lead)
    if k and k ~= E.k then E.apply(k, 'follow') end
  end
end

-- after a settings change (mode, parents, view, envelopes): lay the current shot out again
function E.reapply()
  if E.active and E.k then E.apply(E.k, 'settings') end
end

-- a view change the Director did not make (REAPER's own scroll on stop, the user's zoom, another script): traced
-- so a "the arrange zoomed" report can be read against what the run did (docs/research/failures.md B2)
local function watch_view()
  local a, b = view.get()
  local vs = E.view_set
  if vs and (math.abs(a - vs[1]) > 0.02 or math.abs(b - vs[2]) > 0.02) then
    if not E.anim and E.frame - (E.view_ext_frame or -100) > 10 then
      E.view_ext = (E.view_ext or 0) + 1
      trace('VIEW external %.3f-%.3f (ours %.3f-%.3f) playing=%s k=%s', a, b, vs[1], vs[2], tostring(view.playing()), tostring(E.k))
    end
    E.view_ext_frame = E.frame
    E.view_set = { a, b }   -- the user's view is theirs from here on
  end
end

function E.tick()
  E.frame = E.frame + 1
  if E.msg_frames > 0 then E.msg_frames = E.msg_frames - 1 end
  if not E.active then return end
  E.check_refresh()
  ruler_step()
  watch_view()
  local pos = view.position()
  if E.auto and #MD.shots > 0 then
    local lead = tonumber(cfg('timing.lead_s')) or 0.4
    local k = MD.shot_at(pos, lead)
    if k and k ~= E.k then E.apply(k, 'follow') end
  end
  verify_step()
  animate(pos)
end

-- progress of the current shot at pos (0..1) or nil
function E.progress(pos)
  local s = E.k and MD.shots[E.k]
  if not s or s.t1 <= s.t0 then return nil end
  return clamp((pos - s.t0) / (s.t1 - s.t0), 0, 1)
end

function E.current()
  return E.k, E.k and MD.shots[E.k] or nil
end

return E
