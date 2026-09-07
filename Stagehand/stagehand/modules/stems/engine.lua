-- modules/stems/engine.lua - the sequential renderer (BRIEF 3.10): pre-flight, then for every enabled stem apply
-- its solo / mute state and variant through the journal (owner 'stems'), write the render settings, defuse the
-- overwrite case by policy, render with action 42230 (synchronous: the script resumes when the file is written),
-- measure the file, put the state back, settle, next. The batch runs as a coroutine resumed once per frame from
-- the module tick so the window paints progress and Stop is honoured between stems; every REAPER dialog that
-- could block an unattended run is refused before the batch starts (empty range, unsaved project with a relative
-- folder, colliding file names) or never provoked (skip-silent bit, render statistics read while the preference
-- is off). Everything the run changed (solo, mute, master FX, send mutes, render settings) is restored through
-- the journal after each stem / the batch, on Stop, on a frame error and at exit. Lua 5.4; no globals.

local log = require('lib.log')
local config = require('config')
local journal = require('lib.journal')
local state = require('state')
local tracks = require('lib.tracks')
local wav = require('lib.wav')
local i18n = require('i18n')
local MD = require('modules.stems.model')
local R = require('modules.stems.render')

local t = i18n.t

local E = { active = false, co = nil, stop_requested = false, run = nil, results = nil, msg = '', msg_frames = 0, last_error = nil }

local app
local STEM_KINDS = { solo = true, mute = true, master_fx = true, send_mute = true }

function E.init(app_)
  app = app_
  E.results = state.pget_json('stems.results')
end

local function say(msg)
  E.msg, E.msg_frames = msg, 60
  log.info('stems: %s', msg)
end

local function file_exists(p)
  local f = io.open(p, 'rb')
  if f then f:close(); return true end
  return false
end

local function file_size(p)
  local f = io.open(p, 'rb')
  if not f then return nil end
  local n = f:seek('end')
  f:close()
  return n
end

local function selftest(line)
  if log.selftest_armed() then log.selftest(line) end
end

-- pre-flight -------------------------------------------------------------------------------------------------------------------

-- the stems a batch would render: indices of the enabled stems (or the given subset that is enabled)
function E.batch_list(subset)
  local out = {}
  for k, s in ipairs(MD.stems) do
    if s.enabled and (not subset or subset[k]) then out[#out + 1] = k end
  end
  return out
end

-- rows: { level = 'error' | 'warn' | 'info' | 'ok', id, text, fix = fn | nil, fix_label }
function E.preflight(subset)
  local rows = {}
  local function add(level, id, text_, fix, fix_label)
    rows[#rows + 1] = { level = level, id = id, text = text_, fix = fix, fix_label = fix_label }
  end
  local list = E.batch_list(subset)
  local st = R.settings()
  local dir, rel = R.out_dir()
  -- 1. a folder REAPER can resolve
  if not dir then
    add('error', 'dir', string.format(t('stems.pf.dir_unsaved'), rel))
  else
    add('ok', 'dir', string.format(t('stems.pf.dir_ok'), dir))
  end
  -- 2. stems
  if #list == 0 then
    add('error', 'stems', t('stems.pf.no_stems'))
  else
    add('ok', 'stems', string.format(t('stems.pf.stems_ok'), #list, #MD.stems))
  end
  -- 3. the pattern must tell stems apart
  local expanded = st.pattern:gsub('%$stemnumber', ''):gsub('%$stem', ''):gsub('%$scene', '')
  if #list > 1 and expanded == st.pattern then
    add('error', 'pattern', string.format(t('stems.pf.pattern_no_stem'), st.pattern))
  else
    add('ok', 'pattern', string.format(t('stems.pf.pattern_ok'), st.pattern))
  end
  -- 4. every stem: tracks found, range, target file
  local seen, collisions, existing, empty = {}, 0, 0, 0
  for n, k in ipairs(list) do
    local s = MD.stems[k]
    local resolved, missing = MD.resolve(s)
    local cells = MD.count_cells(s)
    if cells > 0 and #resolved == 0 then
      empty = empty + 1
      add('warn', 'empty:' .. k, string.format(t('stems.pf.stem_empty'), s.name, missing))
    elseif missing > 0 then
      add('warn', 'missing:' .. k, string.format(t('stems.pf.stem_missing'), s.name, missing, #resolved))
    end
    local b = R.bounds_of(s)
    if b.t1 - b.t0 <= 0.001 then
      add('error', 'range:' .. k, string.format(t('stems.pf.range_empty'), s.name, b.desc))
    end
    local target = R.planned_target(s, n, s.variant or R.cfg('variant.default') or 'master')
    if seen[target] then
      collisions = collisions + 1
      add('error', 'collide:' .. k, string.format(t('stems.pf.collision'), s.name, seen[target], target:match('[^/\\]+$') or target))
    end
    seen[target] = s.name
    if file_exists(target) then existing = existing + 1 end
  end
  if existing > 0 then
    local pol = st.overwrite
    add(pol == 'skip' and 'warn' or 'info', 'existing', string.format(t(('stems.pf.existing_%s'):format(pol)), existing))
  end
  -- 5. transport
  local ps = reaper.GetPlayState()
  if ps & 4 ~= 0 then
    add('error', 'recording', t('stems.pf.recording'))
  elseif ps & 1 ~= 0 then
    add('warn', 'playing', t('stems.pf.playing'), function() reaper.OnStopButton(); return true end, t('stems.pf.fix_stop'))
  end
  -- 6. what REAPER's statistics will add
  local on = R.stats_enabled()
  if on then
    add('ok', 'stats', t('stems.pf.stats_on'))
  elseif R.can_enable_stats() and config.get('stems.results.reaper_stats') ~= false then
    add('info', 'stats', t('stems.pf.stats_sws'))
  else
    add('info', 'stats', t('stems.pf.stats_off'))
  end
  -- 7. format notes
  if st.format == 'flac' or st.format == 'mp3' then add('info', 'format', string.format(t('stems.pf.format_nowav'), st.format)) end
  if st.format == 'project' then add('info', 'format', t('stems.pf.format_project')) end
  -- 8. a variant that needs sends
  local n_sends = 0
  for i = 0, reaper.CountTracks(0) - 1 do n_sends = n_sends + reaper.GetTrackNumSends(reaper.GetTrack(0, i), 0) end
  for _, k in ipairs(list) do
    local s = MD.stems[k]
    if (s.variant or R.cfg('variant.default')) == 'dry' and n_sends == 0 then
      add('info', 'dry', t('stems.pf.dry_no_sends'))
      break
    end
  end
  local counts = { error = 0, warn = 0, info = 0, ok = 0 }
  for _, r in ipairs(rows) do counts[r.level] = (counts[r.level] or 0) + 1 end
  return rows, counts
end

-- applying a stem -----------------------------------------------------------------------------------------------------------------

-- solo for every track comes from the cells (off = not soloed: a temporary solo of the user is cleared for the
-- render and put back after); mute is written only where a cell says M (a track the user muted stays muted)
local function apply_stem(s, variant, foreign)
  local want = {}
  for guid, c in pairs(s.cells) do want[guid] = c end
  local resolved = MD.resolve(s)
  local by_guid = {}
  for _, r in ipairs(resolved) do by_guid[r.e.guid] = r end
  local n_solo, n_mute = 0, 0
  reaper.PreventUIRefresh(1)
  for _, e in ipairs(MD.D.tracks) do
    local r = by_guid[e.guid]
    local cell = r and r.cell or nil
    local solo_want = (cell == 'S') and 2 or ((cell == 'I') and 1 or 0)
    local cur = tracks.get(e.tr, 'I_SOLO')
    if cur ~= solo_want then
      if not journal.add({ kind = 'solo', key = e.guid, was = cur, set = solo_want, owner = 'stems' }) then
        foreign[#foreign + 1] = { tr = e.tr, key = 'I_SOLO', was = cur }
      end
      tracks.set(e.tr, 'I_SOLO', solo_want)
    end
    if solo_want > 0 then n_solo = n_solo + 1 end
    if cell == 'M' then
      local m = tracks.get(e.tr, 'B_MUTE')
      if m ~= 1 then
        if not journal.add({ kind = 'mute', key = e.guid, was = m, set = 1, owner = 'stems' }) then
          foreign[#foreign + 1] = { tr = e.tr, key = 'B_MUTE', was = m }
        end
        tracks.set(e.tr, 'B_MUTE', 1)
      end
      n_mute = n_mute + 1
    end
  end
  if variant == 'nofx' then
    local master = reaper.GetMasterTrack(0)
    local en = reaper.GetMediaTrackInfo_Value(master, 'I_FXEN')
    if en ~= 0 then
      journal.add({ kind = 'master_fx', key = 'master', was = en, owner = 'stems' })
      reaper.SetMediaTrackInfo_Value(master, 'I_FXEN', 0)
    end
  elseif variant == 'dry' then
    for _, e in ipairs(MD.D.tracks) do
      for i = 0, reaper.GetTrackNumSends(e.tr, 0) - 1 do
        local m = reaper.GetTrackSendInfo_Value(e.tr, 0, i, 'B_MUTE')
        if m ~= 1 then
          journal.add({ kind = 'send_mute', key = e.guid .. '#' .. i, was = m, owner = 'stems' })
          reaper.SetTrackSendInfo_Value(e.tr, 0, i, 'B_MUTE', 1)
        end
      end
    end
  end
  reaper.PreventUIRefresh(-1)
  journal.flush()
  return n_solo, n_mute
end

local function restore_stem(foreign)
  local stats = journal.restore(function(e) return e.owner == 'stems' and STEM_KINDS[e.kind] end)
  for i = #foreign, 1, -1 do
    local f = foreign[i]
    if tracks.valid(f.tr) then tracks.set(f.tr, f.key, f.was) end
    foreign[i] = nil
  end
  return stats
end

-- the overwrite policy before a render: returns target, action ('new' | 'replaced' | 'incremented' | 'skipped'), err
local function defuse_target(target, policy, stem, k, variant)
  if not file_exists(target) then return target, 'new' end
  if policy == 'skip' then return target, 'skipped' end
  if policy == 'increment' then
    local st = R.settings()
    local base = R.expand(st.pattern, stem, k, variant)
    for n = 2, 999 do
      reaper.GetSetProjectInfo_String(0, 'RENDER_PATTERN', base .. '_' .. n, true)
      local tg = R.targets()[1]
      if tg and not file_exists(tg) then return tg, 'incremented' end
    end
    return target, nil, 'no free name after 999 tries'
  end
  local ok, err = os.remove(target)
  if not ok then return target, nil, 'cannot replace ' .. target .. ': ' .. tostring(err) end
  return target, 'replaced'
end

-- the batch --------------------------------------------------------------------------------------------------------------------------

local function measure(row, path)
  local info = wav.info(path)
  if not info then
    row.duration_s = nil
    return nil
  end
  row.duration_s, row.srate, row.channels, row.bits = info.seconds, info.srate, info.ch, info.bits
  local sc = wav.scanner(path)
  return sc
end

local function run(list)
  local run_ = E.run
  local st = R.settings()
  local silent_below = tonumber(config.get('stems.results.silent_below_db')) or -90
  local settle = math.max(0, math.floor(tonumber(config.get('stems.run.settle_frames')) or 3))
  local dir = R.out_dir()
  reaper.RecursiveCreateDirectory(dir, 0)
  local results = { started = os.date('%Y-%m-%d %H:%M:%S'), project = state.project_name(), dir = dir, format = st.format,
    rows = {}, n = #list, ok = 0, failed = 0, skipped = 0, silent = 0 }
  E.results = results
  local prev_stats = nil
  if config.get('stems.results.reaper_stats') ~= false then prev_stats = R.enable_stats() end
  run_.stats_on = R.stats_enabled()
  selftest(string.format('STEMS START n=%d dir=%s stats=%s', #list, dir, tostring(run_.stats_on)))
  app.emit('stems_active', true)
  local foreign = {}
  for n, k in ipairs(list) do
    if E.stop_requested then break end
    local s = MD.stems[k]
    local variant = s.variant or config.get('stems.variant.default') or 'master'
    run_.i, run_.n, run_.name, run_.phase = n, #list, s.name, 'apply'
    local row = { k = k, i = n, name = s.name, variant = variant, source = s.source and s.source.kind or 'manual' }
    results.rows[#results.rows + 1] = row
    local t_apply = reaper.time_precise()
    row.n_solo, row.n_mute = apply_stem(s, variant, foreign)
    local b = R.write(s, n, variant)
    row.t0, row.t1, row.bounds = b.t0, b.t1, b.desc
    local target = R.targets()[1]
    local action, derr
    if not target then
      row.error = 'REAPER reports no target file'
    else
      target, action, derr = defuse_target(target, st.overwrite, s, n, variant)
      row.file, row.action = target, action
      if derr then row.error = derr end
    end
    row.apply_ms = (reaper.time_precise() - t_apply) * 1000
    if row.error then
      results.failed = results.failed + 1
    elseif action == 'skipped' then
      results.skipped = results.skipped + 1
      row.skipped = true
    else
      run_.phase = 'render'
      coroutine.yield()   -- one painted frame with "rendering" before the synchronous render
      local t_render = reaper.time_precise()
      reaper.Main_OnCommand(42230, 0)
      row.render_s = reaper.time_precise() - t_render
      run_.phase = 'measure'
      row.bytes = file_size(target)
      if not row.bytes or row.bytes < 48 then
        row.error = row.bytes and 'file is empty' or 'file not written'
        results.failed = results.failed + 1
      else
        local rs = R.stats()
        if rs and rs.file and (rs.file == target or rs.file:lower() == target:lower()) then
          row.lufs_i, row.lufs_m_max, row.lufs_s_max, row.lra = rs.lufs_i, rs.lufs_m_max, rs.lufs_s_max, rs.lra
          row.reaper_peak_db, row.reaper_length_s = rs.peak_db, rs.length_s
        end
        if st.ext == 'wav' or (not st.ext and target:lower():match('%.wav$')) then
          local sc = measure(row, target)
          if sc then
            while not sc.step(1 << 19) do coroutine.yield() end
            row.peak_db = sc.peak_db()
          end
        else
          row.peak_db = row.reaper_peak_db
        end
        row.silent = (row.peak_db ~= nil and row.peak_db <= silent_below) or (row.peak_db == nil and rs ~= nil and rs.peak_db == nil and rs.file ~= nil)
        if row.silent then results.silent = results.silent + 1 end
        results.ok = results.ok + 1
        row.ok = true
      end
    end
    run_.phase = 'restore'
    row.restore = restore_stem(foreign)
    selftest(string.format('STEM DONE k=%d name=%s ok=%s action=%s file=%s render_s=%.3f peak=%s lufs=%s silent=%s',
      n, s.name, tostring(row.ok == true), tostring(row.action), tostring(row.file), row.render_s or -1, tostring(row.peak_db), tostring(row.lufs_i), tostring(row.silent)))
    app.emit('stem_done', n, #list, row)
    for _ = 1, settle do coroutine.yield() end
  end
  results.stopped = E.stop_requested and #results.rows < #list
  run_.phase = 'finish'
  R.restore_settings()
  R.restore_stats(prev_stats)
  journal.flush()
  results.finished = os.date('%Y-%m-%d %H:%M:%S')
  results.seconds = reaper.time_precise() - run_.t_start
  local RS = require('modules.stems.results')
  results.files = RS.write_all(results)
  state.pset_json('stems.results', results)
  selftest(string.format('STEMS DONE n=%d ok=%d failed=%d skipped=%d silent=%d stopped=%s seconds=%.2f', #results.rows, results.ok, results.failed, results.skipped, results.silent, tostring(results.stopped), results.seconds))
  app.emit('stems_active', false)
  app.emit('stems_done', results)
  return results
end

-- start(subset = nil | { [k] = true }, why) -> ok, err
function E.start(subset, why)
  if E.active then return false, t('stems.msg.already') end
  local list = E.batch_list(subset)
  local rows, counts = E.preflight(subset)
  E.preflight_rows, E.preflight_counts = rows, counts
  if counts.error > 0 then
    say(string.format(t('stems.msg.preflight_errors'), counts.error))
    return false, 'preflight'
  end
  reaper.OnStopButton()
  MD.check_refresh()
  E.stop_requested = false
  E.active = true
  E.run = { list = list, i = 0, n = #list, name = '', phase = 'start', t_start = reaper.time_precise(), why = why or 'ui' }
  E.co = coroutine.create(function() return run(list) end)
  E.last_error = nil
  say(string.format(t('stems.msg.started'), #list))
  return true
end

function E.stop(why)
  if not E.active then return false end
  E.stop_requested = true
  say(t('stems.msg.stopping'))
  log.info('stems: stop requested (%s)', tostring(why))
  return true
end

-- called from the module tick: one resume per frame
function E.tick()
  if E.msg_frames > 0 then E.msg_frames = E.msg_frames - 1 end
  if not E.active or not E.co then return end
  local ok, err = coroutine.resume(E.co)
  if not ok then
    E.last_error = tostring(err)
    log.error('stems: batch failed: %s', E.last_error)
    E.abort('error: ' .. E.last_error)
    return
  end
  if coroutine.status(E.co) == 'dead' then
    E.active = false
    E.co = nil
    local r = E.results
    if r then say(string.format(t('stems.msg.done'), r.ok, r.failed + r.skipped, r.silent)) end
    E.run = nil
  end
end

-- put everything back and drop the batch (frame error, Restore, exit)
function E.abort(why)
  local was = E.active
  E.active, E.co = false, nil
  local stats = journal.restore(journal.owner_pred('stems'))
  journal.flush()
  if was then
    app.emit('stems_active', false)
    say(string.format(t('stems.msg.aborted'), tostring(why), stats.restored))
  end
  E.run = nil
  return stats
end

function E.progress()
  local r = E.run
  if not r or r.n == 0 then return 0 end
  return (r.i - 1 + (r.phase == 'render' and 0.5 or (r.phase == 'measure' and 0.8 or 0))) / r.n
end

E.say = say
return E
