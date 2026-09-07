-- modules/stems/selftest.lua - the scripted Stems scenario the test harness runs against the demo project with its
-- media online. Oracles: the Navigator's census (families), the API (folders,
-- scenes, solo / mute values while a stem is applied), the files on disk (RIFF header, exact sample peak by
-- lib/wav), REAPER's render statistics when the preference is on, lib/layout.dump() before and after (restore
-- diff 0: solo, mute, master FX, send mutes, render settings). Variant 'companion': after the in-app batch the
-- scenario hands over to tools/stems_check.py (started by the harness) which renders a batch through the ctl
-- protocol, measures every WAV independently (numpy) and writes stems_check.json; the scenario checks its verdict.
-- Sabotage 'leave_solo' drops the solo entries before the last restore (the negative control: the restore diff
-- must go red). Lua 5.4; no globals.

local layout = require('lib.layout')
local config = require('config')
local journal = require('lib.journal')
local wav = require('lib.wav')
local json = require('lib.json')
local ctl = require('lib.ctl')

local ST = {}

local app, S, MD, R, E, U

function ST.init(app_, S_, MD_, R_, E_, U_)
  app, S, MD, R, E, U = app_, S_, MD_, R_, E_, U_
end

local sep = package.config:sub(1, 1)

local function set(key, v)
  config.set('stems.' .. key, v, 'project')
end

local function file_exists(p)
  local f = io.open(p, 'rb')
  if f then f:close(); return true end
  return false
end

local function read_file(p)
  local f = io.open(p, 'r')
  if not f then return nil end
  local s = f:read('a')
  f:close()
  return s
end

local function count_where(fn)
  local n = 0
  for i = 0, reaper.CountTracks(0) - 1 do
    if fn(reaper.GetTrack(0, i)) then n = n + 1 end
  end
  return n
end

local function state_has(token)
  local s = read_file(ctl.path('state') or '') or ''
  return s:find(' ' .. token, 1, true) ~= nil
end

local function wait_batch(T, max_frames)
  return T.wait_until(function() return not E.active end, max_frames or 3000, 'batch finished')
end

local function row_by_name(results, name)
  for _, r in ipairs(results and results.rows or {}) do
    if r.name == name then return r end
  end
  return nil
end

function ST.run(T)
  local companion = T.variant == 'companion'
  T.fact('variant', companion and 'companion' or 'demo')
  T.fact('sabotage', T.sabotage == '' and 'none' or T.sabotage)
  T.wait(2)
  app.set_tab('stems')
  if companion then config.set('recorder.ctl.dir', T.out_path('ctl'), 'project') end   -- the harness fetches out/ctl with the evidence

  -- 0. a known state, then the baseline dump ----------------------------------------------------------------------------------
  reaper.OnStopButton()
  MD.clear()
  local out_dir = T.out_path('stems_out')
  set('render.dir', out_dir)
  set('render.format', 'wav24')
  set('render.srate', 48000)
  set('render.channels', 2)
  set('render.bounds', 'stem')
  set('render.bounds_fallback', 'custom')
  set('render.custom_start_s', 2)
  set('render.custom_end_s', 8)
  set('render.tail_ms', 0)
  set('render.pattern', '$stemnumber $stem')
  set('render.overwrite', 'replace')
  set('run.settle_frames', 2)
  set('results.reaper_stats', true)
  local before = layout.dump()
  layout.write(T.out_path('layout_before.json'), before)
  T.fact('render_before', json.encode(before.render))

  -- 1. bulk creation against the census -----------------------------------------------------------------------------------------
  MD.refresh()
  local fam_stems = MD.from_families()
  local names = {}
  for _, s in ipairs(fam_stems) do names[#names + 1] = s.name .. '=' .. MD.count_cells(s) end
  T.fact('family_stems', table.concat(names, ' '))
  T.check('one stem per family with tracks', #fam_stems, 7)
  local by = {}
  for _, s in ipairs(fam_stems) do by[s.name] = MD.count_cells(s) end
  T.check('Dialogue stem holds the family', by.Dialogue or 0, 6)
  T.check('Music stem holds the family', by.Music or 0, 8)
  T.check('SFX stem holds the family', by.SFX or 0, 12)
  local folder_stems = MD.from_folders()
  T.check('one stem per top folder', #folder_stems, 7)   -- 8 folders in the census, one of them nested (RETURNS)
  T.check('folder stem marks the parent only', MD.count_cells(folder_stems[1]), 1)
  local scene_stems = MD.from_scenes()
  T.check('one mix per scene', #scene_stems, 8)
  T.ok('scene stem carries its range', scene_stems[1].range ~= nil and scene_stems[1].range.t1 > scene_stems[1].range.t0)
  -- selection: two tracks
  for i = 0, reaper.CountTracks(0) - 1 do reaper.SetMediaTrackInfo_Value(reaper.GetTrack(0, i), 'I_SELECTED', i < 2 and 1 or 0) end
  local sel, n_sel = MD.from_selection()
  T.check('selection stem holds the selected tracks', n_sel, 2)
  for i = 0, reaper.CountTracks(0) - 1 do reaper.SetMediaTrackInfo_Value(reaper.GetTrack(0, i), 'I_SELECTED', 0) end
  -- capture: solo one track by hand, capture, undo by hand
  local tr0 = reaper.GetTrack(0, 2)
  reaper.SetMediaTrackInfo_Value(tr0, 'I_SOLO', 2)
  local cap, n_cap = MD.capture('Cap')
  reaper.SetMediaTrackInfo_Value(tr0, 'I_SOLO', 0)
  T.check('capture reads the soloed track', n_cap, 1)
  T.check('capture cell is solo in place', cap.cells[reaper.GetTrackGUID(tr0)], 'S')

  -- 2. the set: Dialogue, Music, Ambience (families), scene 1 as a mix, plus a disabled one ------------------------------------------
  for _, s in ipairs(fam_stems) do
    if s.name == 'Dialogue' or s.name == 'Music' or s.name == 'Ambience' then MD.add(s) end
  end
  MD.add(scene_stems[1])
  local off = MD.sanitize({ name = 'Disabled', enabled = false })
  MD.add(off)
  T.check('stems in the set', #MD.stems, 5)
  T.check('enabled stems', MD.enabled_count(), 4)
  T.check('names unique after a duplicate', (function() local k = MD.duplicate(1); local n = MD.stems[k].name; MD.remove(k); return n end)(), 'Dialogue 2')
  -- persistence round trip
  MD.load()
  T.check('set reloads from the project', #MD.stems, 5)
  -- membership in the tracks
  local n_written = MD.write_p_ext()
  T.fact('p_ext_written', n_written)
  local guid_dx = nil
  for g in pairs(MD.stems[1].cells) do guid_dx = g break end
  local tr_dx = nil
  for i = 0, reaper.CountTracks(0) - 1 do
    if reaper.GetTrackGUID(reaper.GetTrack(0, i)) == guid_dx then tr_dx = reaper.GetTrack(0, i) end
  end
  local ext = tr_dx and MD.p_ext_of(tr_dx) or ''
  T.ok('track extension state names its stem', ext:find('Dialogue=S', 1, true) ~= nil, ext)
  -- adopt: drop a cell, adopt it back from the track
  MD.stems[1].cells[guid_dx] = nil
  local adopted = MD.adopt()
  T.check('adopt puts the cell back from the track', adopted, 1)
  T.check('adopted cell', MD.stems[1].cells[guid_dx], 'S')
  -- matrix track column: measured from the widest name, never a pixel constant
  local name_w, widest = U.matrix_name_width(720)
  T.fact('matrix_name_w', string.format('%d widest=%d', name_w, widest))
  T.ok('matrix track column fits the widest name', name_w >= math.min(widest, 432) and name_w >= 120, string.format('w=%d widest=%d', name_w, widest))

  -- matrix cell cycle
  T.check('cell cycle off -> S', MD.next_cell(nil), 'S')
  T.check('cell cycle M -> off', MD.next_cell('M'), nil)

  -- 3. render settings and wildcards -----------------------------------------------------------------------------------------------
  T.check('wav24 format bytes', R.format_string('wav24'), 'ZXZhdxgAAQ==')
  T.check('wav32f format bytes', R.format_string('wav32f'), 'ZXZhdyAAAQ==')
  T.check('pattern expansion', R.expand('$stemnumber $stem [$scene] $variant', MD.stems[4], 4, 'master'), '04 ' .. MD.stems[4].name .. ' [' .. R.sanitize_name(MD.stems[4].range.name) .. '] master')
  T.check('unsafe characters in a name', R.sanitize_name('a/b:c*d'), 'a_b_c_d')
  local b_scene = R.bounds_of(MD.stems[4])
  T.check('scene stem bounds = its range', b_scene.flag, 0)
  T.check('scene stem end', b_scene.t1, MD.stems[4].range.t1, 1e-6)
  local b_fam = R.bounds_of(MD.stems[1])
  T.check('family stem bounds = the fallback (custom 2..8)', b_fam.t1 - b_fam.t0, 6, 1e-6)

  -- 4. pre-flight ----------------------------------------------------------------------------------------------------------------------
  local rows, counts = E.preflight()
  for _, r in ipairs(rows) do T.log('PREFLIGHT ' .. r.level .. ' ' .. r.text) end
  T.check('pre-flight has no error', counts.error, 0)
  -- a colliding pattern
  set('render.pattern', 'fixed')
  local _, c2 = E.preflight()
  T.ok('pattern without $stem is an error', c2.error >= 1, c2.error)
  set('render.pattern', '$stemnumber $stem')
  -- an empty range
  set('render.custom_end_s', 2)
  local _, c3 = E.preflight()
  T.ok('empty range is an error', c3.error >= 1, c3.error)
  local started = E.start(nil, 'selftest')
  T.check('start refused on pre-flight errors', started, false)
  set('render.custom_end_s', 8)
  -- an unsaved-project folder case cannot be built here (the demo is saved); the relative-folder resolution is checked
  set('render.dir', 'Render/stems_probe')
  local dir_abs = R.out_dir()
  T.ok('relative folder resolves against the project', dir_abs ~= nil and dir_abs:find('stems_probe', 1, true) ~= nil, tostring(dir_abs))
  set('render.dir', out_dir)

  -- 5. the batch -----------------------------------------------------------------------------------------------------------------------
  local ok = E.start(nil, 'selftest')
  T.check('batch started', ok, true)
  -- while the first stem is applied: only Dialogue tracks soloed
  T.wait_until(function() return E.run and E.run.phase == 'render' end, 200, 'first stem reaches the render phase')
  local n_solo = count_where(function(tr) return reaper.GetMediaTrackInfo_Value(tr, 'I_SOLO') > 0 end)
  T.check('Dialogue stem: 6 tracks soloed while it renders', n_solo, 6)
  T.check('render settings written: master mix', reaper.GetSetProjectInfo(0, 'RENDER_SETTINGS', 0, false), 0)
  T.check('render settings written: bounds custom', reaper.GetSetProjectInfo(0, 'RENDER_BOUNDSFLAG', 0, false), 0)
  T.check('render settings written: 48k', reaper.GetSetProjectInfo(0, 'RENDER_SRATE', 0, false), 48000)
  local _, pat = reaper.GetSetProjectInfo_String(0, 'RENDER_PATTERN', '', false)
  T.check('pattern expanded for the first stem', pat, '01 Dialogue')
  T.ok('render_num journaled', journal.count('render_num', 'stems') >= 8, journal.count('render_num', 'stems'))
  T.ok('solo journaled', journal.count('solo', 'stems') >= 6, journal.count('solo', 'stems'))
  wait_batch(T, 3000)
  local res = E.results
  T.ok('results present', res ~= nil and #res.rows == 4, res and #res.rows or 0)
  T.check('all four rendered', res.ok, 4)
  T.check('none failed', res.failed, 0)
  T.check('no stem silent', res.silent, 0)
  T.fact('batch_seconds', string.format('%.2f', res.seconds or -1))
  T.fact('stats_on', tostring(E.run == nil and res.rows[1].lufs_i ~= nil))
  local peaks = {}
  for _, r in ipairs(res.rows) do
    T.log(string.format('RESULT %d %s file=%s action=%s dur=%.3f peak=%s reaper_peak=%s lufs=%s render_s=%.3f', r.i, r.name, tostring(r.file), tostring(r.action),
      r.duration_s or -1, tostring(r.peak_db), tostring(r.reaper_peak_db), tostring(r.lufs_i), r.render_s or -1))
    peaks[#peaks + 1] = r.peak_db or -999
    T.ok('file written: ' .. r.name, r.file ~= nil and file_exists(r.file), tostring(r.file))
    local info = r.file and wav.info(r.file, 200000) or nil
    T.ok('wav 24-bit 48k stereo: ' .. r.name, info ~= nil and info.bits == 24 and info.srate == 48000 and info.ch == 2, info and string.format('%d/%d/%d', info.bits, info.srate, info.ch) or 'no file')
    local want = r.name == MD.stems[4].name and (MD.stems[4].range.t1 - MD.stems[4].range.t0) or 6
    T.check('duration: ' .. r.name, r.duration_s or -1, want, 0.002)
    T.ok('file name from the pattern: ' .. r.name, (r.file or ''):match('[^/\\]+$') == string.format('%02d %s.wav', r.i, R.sanitize_name(r.name)), tostring(r.file))
    if r.reaper_peak_db then T.check('REAPER peak = scanned peak: ' .. r.name, r.peak_db, r.reaper_peak_db, 0.05) end
  end
  T.ok('stems differ (peaks not all equal)', not (peaks[1] == peaks[2] and peaks[2] == peaks[3]), table.concat(peaks, ' '))
  T.ok('results files written', res.files and res.files.json and file_exists(res.files.json), tostring(res.files and res.files.json))
  T.ok('csv written', res.files and res.files.csv and file_exists(res.files.csv))
  T.ok('md written', res.files and res.files.md and file_exists(res.files.md))
  -- everything back after the batch
  T.check('no track soloed after the batch', count_where(function(tr) return reaper.GetMediaTrackInfo_Value(tr, 'I_SOLO') > 0 end), 0)
  T.check('no stems journal entries left', journal.count(nil, 'stems'), 0)
  local _, pat_after = reaper.GetSetProjectInfo_String(0, 'RENDER_PATTERN', '', false)
  T.check('render pattern restored', pat_after, before.render.RENDER_PATTERN)
  T.check('render bounds restored', reaper.GetSetProjectInfo(0, 'RENDER_BOUNDSFLAG', 0, false), before.render.RENDER_BOUNDSFLAG)

  -- 6. existing files: replace (same files), then increment, then skip ------------------------------------------------------------------
  local first_file = res.rows[1].file
  local size_before = (function() local f = io.open(first_file, 'rb'); local n = f:seek('end'); f:close(); return n end)()
  E.start({ [1] = true }, 'selftest')
  wait_batch(T)
  T.check('replace: the file is written again', E.results.rows[1].action, 'replaced')
  T.ok('replace: same size', (function() local f = io.open(first_file, 'rb'); local n = f:seek('end'); f:close(); return n end)() == size_before)
  set('render.overwrite', 'increment')
  E.start({ [1] = true }, 'selftest')
  wait_batch(T)
  T.check('increment: numbered copy', E.results.rows[1].action, 'incremented')
  T.ok('increment: _2 file', (E.results.rows[1].file or ''):match('_2%.wav$') ~= nil, tostring(E.results.rows[1].file))
  set('render.overwrite', 'skip')
  E.start({ [1] = true }, 'selftest')
  wait_batch(T)
  T.check('skip: the stem is skipped', E.results.rows[1].action, 'skipped')
  T.check('skip: counted', E.results.skipped, 1)
  set('render.overwrite', 'replace')

  -- 7. variants: no master FX and dry, checked while the stem renders --------------------------------------------------------------------
  MD.stems[2].variant = 'nofx'
  MD.stems[3].variant = 'dry'
  MD.save()
  E.start({ [2] = true, [3] = true }, 'selftest')
  T.wait_until(function() return E.run and E.run.i == 1 and E.run.phase == 'render' end, 200, 'nofx stem reaches the render phase')
  T.check('nofx: master FX bypassed while rendering', reaper.GetMediaTrackInfo_Value(reaper.GetMasterTrack(0), 'I_FXEN'), 0)
  T.check('nofx: journaled', journal.count('master_fx', 'stems'), 1)
  T.wait_until(function() return E.run and E.run.i == 2 and E.run.phase == 'render' end, 400, 'dry stem reaches the render phase')
  local muted_sends, all_sends = 0, 0
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    for j = 0, reaper.GetTrackNumSends(tr, 0) - 1 do
      all_sends = all_sends + 1
      if reaper.GetTrackSendInfo_Value(tr, 0, j, 'B_MUTE') == 1 then muted_sends = muted_sends + 1 end
    end
  end
  T.check('dry: every send muted while rendering', muted_sends, all_sends)
  T.fact('sends', all_sends)
  wait_batch(T)
  T.check('master FX back after the batch', reaper.GetMediaTrackInfo_Value(reaper.GetMasterTrack(0), 'I_FXEN'), before.transport.master_fx)
  local still_muted = 0
  for i = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, i)
    for j = 0, reaper.GetTrackNumSends(tr, 0) - 1 do
      if reaper.GetTrackSendInfo_Value(tr, 0, j, 'B_MUTE') == 1 then still_muted = still_muted + 1 end
    end
  end
  local muted_before = 0
  for _, sd in pairs(before.sends) do if sd.mute == 1 then muted_before = muted_before + 1 end end
  T.check('send mutes back after the batch', still_muted, muted_before)
  MD.stems[2].variant, MD.stems[3].variant = nil, nil
  MD.save()

  -- 8. stop between stems -------------------------------------------------------------------------------------------------------------
  set('run.settle_frames', 20)
  E.start(nil, 'selftest')
  T.wait_until(function() return E.run and E.run.i == 1 and E.run.phase == 'restore' end, 300, 'first stem restored')
  E.stop('selftest')
  wait_batch(T)
  T.ok('stop ends the batch early', E.results.stopped == true and #E.results.rows < 4, #E.results.rows)
  set('run.settle_frames', 2)

  -- 9. a user solo survives a batch (kept semantics of the journal) ---------------------------------------------------------------------
  reaper.SetMediaTrackInfo_Value(tr0, 'I_SOLO', 2)
  E.start({ [2] = true }, 'selftest')
  wait_batch(T)
  T.check('user solo put back after the batch', reaper.GetMediaTrackInfo_Value(tr0, 'I_SOLO'), 2)
  reaper.SetMediaTrackInfo_Value(tr0, 'I_SOLO', 0)

  -- 10. presets: save, clear, load by name ---------------------------------------------------------------------------------------------
  local ppath = MD.save_preset('Selftest set')
  T.ok('preset saved', ppath ~= nil and file_exists(ppath), tostring(ppath))
  MD.clear()
  local n, found, lost = MD.load_preset(ppath, 'replace')
  T.check('preset loaded: stems', n, 5)
  T.check('preset loaded: every track found', lost, 0)
  T.ok('preset loaded: cells', found >= 21, found)
  os.remove(ppath)

  -- 11. the companion (variant) ---------------------------------------------------------------------------------------------------------
  if companion then
    T.ok('ctl folder available', ctl.available(), tostring(ctl.dir()))
    local go = io.open(T.out_path('companion_go.txt'), 'w')
    if go then go:write(tostring(ctl.dir()), '\n'); go:close() end
    T.log('COMPANION GO ' .. tostring(ctl.dir()))
    local check_path = T.out_path('stems_check.json')
    local arrived = T.wait_until(function() return file_exists(check_path) end, 4500, 'stems_check.json written by the companion')
    if arrived then
      T.wait(5)
      local v = json.decode(read_file(check_path) or '')
      T.ok('companion verdict ok', type(v) == 'table' and v.ok == true, v and tostring(v.summary) or 'no json')
      if type(v) == 'table' then
        T.fact('companion_files', v.n or 0)
        T.fact('companion_max_peak_diff_db', tostring(v.max_peak_diff_db))
        T.fact('companion_max_len_diff_s', tostring(v.max_len_diff_s))
        T.fact('companion_max_lufs_diff', tostring(v.max_lufs_diff))
        T.check('companion measured every file', v.n or 0, 4)
        T.ok('peaks agree within 0.1 dB', (tonumber(v.max_peak_diff_db) or 99) <= 0.1, tostring(v.max_peak_diff_db))
        T.ok('lengths agree within 1 ms', (tonumber(v.max_len_diff_s) or 99) <= 0.001, tostring(v.max_len_diff_s))
        if v.max_lufs_diff ~= nil then T.ok('LUFS-I agrees within 1 LU', (tonumber(v.max_lufs_diff) or 99) <= 1.0, tostring(v.max_lufs_diff)) end
      end
      T.ok('ctl STEMS_DONE token', state_has('STEMS_DONE'))
    end
    T.wait_until(function() return not E.active end, 600)
  end

  -- 12. restore diff -----------------------------------------------------------------------------------------------------------------------
  MD.clear()
  if T.sabotage == 'leave_solo' then
    -- the negative control: solo one track as the engine would, journaled, then drop the entry and restore
    reaper.SetMediaTrackInfo_Value(tr0, 'I_SOLO', 2)
    journal.add({ kind = 'solo', key = reaper.GetTrackGUID(tr0), was = 0, set = 2, owner = 'stems' })
    journal.discard(journal.owner_pred('stems'))
  end
  E.abort('selftest end')
  T.wait(3)
  local after = layout.dump()
  layout.write(T.out_path('layout_after.json'), after)
  local diff = layout.diff(before, after)
  for i, d in ipairs(diff) do
    if i <= 20 then T.log('DIFF ' .. d) end
  end
  T.log('RESTORE_DIFF ' .. #diff)
  T.check('restore diff', #diff, 0)
  if T.sabotage == 'leave_solo' then reaper.SetMediaTrackInfo_Value(tr0, 'I_SOLO', 0) end
  for _, key in ipairs({ 'render.dir', 'render.format', 'render.srate', 'render.channels', 'render.bounds', 'render.bounds_fallback', 'render.custom_start_s',
      'render.custom_end_s', 'render.tail_ms', 'render.pattern', 'render.overwrite', 'run.settle_frames', 'results.reaper_stats' }) do
    config.reset('stems.' .. key, 'project')
  end
  if companion then config.reset('recorder.ctl.dir', 'project') end
  T.fact('frame', T.frame())
end

-- after DONE: the tab with a set built from the families and the results panel open for the screenshots
function ST.post(frames_since_done)
  if frames_since_done == 5 then
    app.set_tab('stems')
    if #MD.stems == 0 then
      for _, s in ipairs(MD.from_families()) do MD.stems[#MD.stems + 1] = s end
      MD.save()
    end
    S.show_results = E.results ~= nil
    S.hi = 1
  elseif frames_since_done == 60 then
    U.open_matrix(1)
  elseif frames_since_done == 200 then
    U.MX.open = false
    S.show_results = false
    U.preflight()
  end
end

return ST
