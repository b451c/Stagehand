-- modules/navigator/selftest.lua - the scripted scenario the test harness runs against the demo project
-- (the generated demo project) and, in the "realism" variant, against any project with counts only (no names logged).
-- Expected numbers for the demo come from the demo project's census (an oracle independent of this code);
-- everything else is computed by an independent walk of the project before the action under test runs.
-- Sabotage "leave_solo" (negative control) leaves one solo un-restored so the restore diff must go red.
-- Lua 5.4; no globals.

local tracks = require('lib.tracks')
local items = require('lib.items')
local view = require('lib.view')
local journal = require('lib.journal')
local layout = require('lib.layout')
local search = require('lib.search')
local state = require('state')
local config = require('config')

local ST = {}

local app, D, A, S

function ST.init(app_, D_, A_, S_)
  app, D, A, S = app_, D_, A_, S_
end

-- independent walks (no navigator code) ---------------------------------------------------------------------------

local function count_soloed()
  local n = 0
  for k = 0, reaper.CountTracks(0) - 1 do
    if reaper.GetMediaTrackInfo_Value(reaper.GetTrack(0, k), 'I_SOLO') > 0 then n = n + 1 end
  end
  return n
end

local function count_tcp_visible()
  local n = 0
  for k = 0, reaper.CountTracks(0) - 1 do
    if reaper.GetMediaTrackInfo_Value(reaper.GetTrack(0, k), 'B_SHOWINTCP') == 1 then n = n + 1 end
  end
  return n
end

local function tracks_overlapping(t0, t1)
  local out = {}
  for k = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, k)
    if tracks.has_items_in(tr, t0, t1) then out[#out + 1] = tr end
  end
  return out
end

-- expected visible set of a focus: overlapping tracks plus every ancestor (GetParentTrack chain)
local function expected_focus_count(t0, t1)
  local keep = {}
  for _, tr in ipairs(tracks_overlapping(t0, t1)) do
    local x = tr
    local guard = 0
    while x and guard < 64 do
      keep[tostring(x)] = true
      x = reaper.GetParentTrack(x)
      guard = guard + 1
    end
  end
  local n = 0
  for _ in pairs(keep) do n = n + 1 end
  return n
end

local function items_overlapping(t0, t1)
  local out = {}
  for k = 0, reaper.CountMediaItems(0) - 1 do
    local it = reaper.GetMediaItem(0, k)
    local p = reaper.GetMediaItemInfo_Value(it, 'D_POSITION')
    local e = p + reaper.GetMediaItemInfo_Value(it, 'D_LENGTH')
    if p < t1 and e > t0 then out[#out + 1] = it end
  end
  return out
end

local function count_muted(list)
  local n = 0
  for _, it in ipairs(list) do
    if reaper.GetMediaItemInfo_Value(it, 'B_MUTE') == 1 then n = n + 1 end
  end
  return n
end

local function all_on()
  return {}
end

local function only(name)
  local fam = {}
  for _, f in ipairs(D.all_families) do fam[f.name] = (f.name == name) end
  return fam
end

-- the scenario ------------------------------------------------------------------------------------------------------

function ST.run(T)
  ST.variant = T.variant
  local names_ok = T.variant ~= 'realism'
  local demo = T.variant == ''
  local function nm(s) return names_ok and s or '(hidden)' end

  T.fact('variant', T.variant == '' and 'demo' or T.variant)
  T.fact('sabotage', T.sabotage == '' and 'none' or T.sabotage)
  T.wait(2)

  -- 0. baseline dump ------------------------------------------------------------------------------------------------
  local before = layout.dump()
  if names_ok then layout.write(T.out_path('layout_before.json'), before) end

  -- 1. census ----------------------------------------------------------------------------------------------------
  T.fact('scenes', #D.scenes)
  T.fact('markers', #D.markers)
  T.fact('tracks', #D.tracks)
  local fam_parts = {}
  for _, f in ipairs(D.all_families) do fam_parts[#fam_parts + 1] = f.name .. '=' .. tostring(D.family_count[f.name] or 0) end
  T.fact('families', table.concat(fam_parts, ' '))
  local cls_parts = {}
  for _, c in ipairs(D.classes) do cls_parts[#cls_parts + 1] = c.name .. '=' .. tostring(D.class_count[c.name] or 0) end
  cls_parts[#cls_parts + 1] = 'none=' .. tostring(D.class_count[''] or 0)
  T.fact('marker_classes', table.concat(cls_parts, ' '))
  if demo then
    T.check('scenes', #D.scenes, 8)
    T.check('markers', #D.markers, 40)
    T.check('tracks', #D.tracks, 53)
    T.check('family Dialogue', D.family_count.Dialogue or 0, 6)
    T.check('family Music', D.family_count.Music or 0, 8)
    T.check('family Ambience', D.family_count.Ambience or 0, 7)
    T.check('family Foley', D.family_count.Foley or 0, 7)
    T.check('family SFX', D.family_count.SFX or 0, 12)
    T.check('family Design', D.family_count.Design or 0, 8)
    T.check('family Other', D.family_count.Other or 0, 5)
    T.check('class Cut', D.class_count.Cut or 0, 25)
    T.check('class Dialogue', D.class_count.Dialogue or 0, 6)
    T.check('class Hit', D.class_count.Hit or 0, 6)
    T.check('class Todo', D.class_count.Todo or 0, 1)
    T.check('class Note', D.class_count.Note or 0, 2)
  end
  T.ok('has scenes', #D.scenes > 0)
  T.ok('has tracks', #D.tracks > 0)
  if #D.scenes == 0 then return end

  -- the scene under test: the demo's fourth scene, else the first scene with items
  local scene = demo and D.scenes[4] or nil
  if not scene then
    for _, s in ipairs(D.scenes) do if s.items > 0 then scene = s; break end end
  end
  scene = scene or D.scenes[1]
  T.fact('scene_under_test', names_ok and string.format('%s %.3f-%.3f items=%d', scene.name, scene.t0, scene.t1, scene.items)
    or string.format('%.3f-%.3f items=%d', scene.t0, scene.t1, scene.items))

  -- 2. jump to the scene ---------------------------------------------------------------------------------------------
  S.timesel, S.focus = true, false
  A.jump_scene(scene)
  T.wait(1)
  T.check('jump cursor', reaper.GetCursorPosition(), scene.t0, 0.001)
  local v0, v1 = view.get()
  T.ok('jump view covers scene', v0 <= scene.t0 + 0.001 and v1 >= scene.t1 - 0.001, string.format('view %.3f-%.3f', v0, v1))
  local ts0, ts1 = view.get_time_selection()
  T.check('jump time selection start', ts0, scene.t0, 0.001)
  T.check('jump time selection end', ts1, scene.t1, 0.001)
  local act = D.active_scene()
  T.check('active scene', act and act.name or '-', scene.name)

  -- 3. marker jump ------------------------------------------------------------------------------------------------------
  local marker
  for _, m in ipairs(D.markers) do
    if m.t0 >= scene.t0 and m.t0 < scene.t1 then marker = m; break end
  end
  marker = marker or D.markers[1]
  if marker then
    A.jump_marker(marker)
    T.wait(1)
    T.check('marker jump cursor', reaper.GetCursorPosition(), marker.t0, 0.001)
    local mv0, mv1 = view.get()
    T.ok('marker view around marker', mv0 <= marker.t0 and mv1 >= marker.t0, string.format('view %.3f-%.3f', mv0, mv1))
  end

  -- 4. items of the scene, families -----------------------------------------------------------------------------------------
  local all_items = D.items_in_range(scene.t0, scene.t1, all_on())
  T.check('items in scene (independent walk)', #all_items, #items_overlapping(scene.t0, scene.t1))
  if demo then
    T.check('items in scene 04', #all_items, 35)
    T.check('items scene 04 Foley only', #D.items_in_range(scene.t0, scene.t1, only('Foley')), 9)
    T.check('items scene 04 SFX only', #D.items_in_range(scene.t0, scene.t1, only('SFX')), 10)
  end
  local list = D.build_items(scene, all_on())
  T.ok('items sorted by time', (function()
    for i = 2, #list do if list[i].t0 < list[i - 1].t0 then return false end end
    return true
  end)())

  -- 5. focus: hide tracks without items in the scene, then restore ---------------------------------------------------------
  local vis_before = count_tcp_visible()
  local expected_shown = expected_focus_count(scene.t0, scene.t1)
  local t_focus = reaper.time_precise()
  local shown = A.focus_range(scene.t0, scene.t1)
  T.fact('focus_ms', string.format('%.1f', (reaper.time_precise() - t_focus) * 1000))
  T.wait(2)
  T.check('focus shown (independent walk)', shown, expected_shown)
  T.check('focus TCP visible', count_tcp_visible(), expected_shown)
  T.fact('focus_hidden', vis_before - count_tcp_visible())
  local restored_vis = A.restore_visibility()
  T.wait(2)
  T.check('focus restore count', restored_vis, vis_before - expected_shown)
  T.check('focus TCP visible after restore', count_tcp_visible(), vis_before)

  -- 6. scene solo with a pre-soloed track that must survive ---------------------------------------------------------------------
  local in_scene = D.tracks_in_range(scene.t0, scene.t1, all_on())
  local pre, aud_track
  for _, e in ipairs(in_scene) do
    if e.fam ~= D.other.name then
      if not pre then pre = e elseif not aud_track then aud_track = e end
    end
  end
  pre = pre or in_scene[1]
  aud_track = aud_track or in_scene[#in_scene] or pre
  T.fact('pre_soloed_track', nm(pre and pre.name or '-'))
  T.fact('audition_track', nm(aud_track and aud_track.name or '-'))
  local soloed_before = count_soloed()
  if pre then reaper.SetMediaTrackInfo_Value(pre.tr, 'I_SOLO', 1) end
  local expect_solo = 0
  for _, tr in ipairs(tracks_overlapping(scene.t0, scene.t1)) do
    if reaper.GetMediaTrackInfo_Value(tr, 'I_SOLO') == 0 then expect_solo = expect_solo + 1 end
  end
  local t_solo = reaper.time_precise()
  local n_solo = A.solo_scene(scene)
  T.fact('solo_ms', string.format('%.1f', (reaper.time_precise() - t_solo) * 1000))
  T.wait(1)
  T.check('scene solo set', n_solo, expect_solo)
  T.check('scene solo soloed now', count_soloed(), soloed_before + expect_solo + 1)
  T.check('scene solo journal entries', journal.count('solo', 'scene_solo'), expect_solo)
  T.check('scene solo toggle state', A.solo_scene_name == scene.name, true)
  A.toggle_solo_scene(scene)
  T.wait(1)
  T.check('scene unsolo soloed now', count_soloed(), soloed_before + 1)
  T.check('pre-soloed survives', pre and reaper.GetMediaTrackInfo_Value(pre.tr, 'I_SOLO') or -1, 1)
  T.check('scene solo journal empty', journal.count('solo', 'scene_solo'), 0)
  if pre then reaper.SetMediaTrackInfo_Value(pre.tr, 'I_SOLO', 0) end

  -- 7. scene mute with a pre-muted item that must survive -----------------------------------------------------------------------------
  local scene_items = items_overlapping(scene.t0, scene.t1)
  local muted_before = count_muted(scene_items)
  local preit = scene_items[1]
  if preit then reaper.SetMediaItemInfo_Value(preit, 'B_MUTE', 1) end
  local expect_mute = #scene_items - count_muted(scene_items)
  local t_mute = reaper.time_precise()
  local n_mute = A.mute_scene(scene)
  T.fact('mute_ms', string.format('%.1f', (reaper.time_precise() - t_mute) * 1000))
  T.wait(1)
  T.check('scene mute set', n_mute, expect_mute)
  T.check('scene mute muted now', count_muted(scene_items), #scene_items)
  A.toggle_mute_scene(scene)
  T.wait(1)
  T.check('scene unmute muted now', count_muted(scene_items), muted_before + 1)
  T.check('pre-muted survives', preit and reaper.GetMediaItemInfo_Value(preit, 'B_MUTE') or -1, 1)
  if preit then reaper.SetMediaItemInfo_Value(preit, 'B_MUTE', 0) end

  -- 8. audition with auto-stop and a temporary solo in place ----------------------------------------------------------------------------
  S.loop = false
  local aud_len = 1.2
  local t_play = T.frame()
  A.audition(scene.t0, scene.t0 + aud_len, 'selftest', aud_track)
  T.wait(4)
  T.check('audition playing after 4 frames', reaper.GetPlayState() & 1, 1)
  T.check('audition solo in place', aud_track and reaper.GetMediaTrackInfo_Value(aud_track.tr, 'I_SOLO') or -1, 2)
  local max_pos = 0
  local ended = T.wait_until(function()
    if reaper.GetPlayState() & 1 == 1 then max_pos = math.max(max_pos, reaper.GetPlayPosition()) end
    return A.aud == nil
  end, 240, 'audition ended')
  local frames = T.frame() - t_play
  T.fact('audition_frames', frames)
  T.fact('audition_max_pos', string.format('%.3f', max_pos))
  if ended then
    T.check('audition stopped', reaper.GetPlayState() & 1, 0)
    T.check('audition solo restored', aud_track and reaper.GetMediaTrackInfo_Value(aud_track.tr, 'I_SOLO') or -1, 0)
    T.ok('audition auto-stop near the end', max_pos >= scene.t0 + aud_len - 0.25 and max_pos <= scene.t0 + aud_len + 0.35,
      string.format('max_pos=%.3f target=%.3f', max_pos, scene.t0 + aud_len))
  end
  T.check('audition journal empty', journal.count(nil, 'audition'), 0)

  -- 9. loop audition: repeat and loop range set for the audition, put back afterwards -------------------------------------------------
  local rep_before = reaper.GetSetRepeat(-1)
  local l0b, l1b = view.get_loop_range()
  S.loop = true
  A.audition(scene.t0, scene.t0 + 1.0, 'loop', nil)
  T.wait(6)
  T.check('loop audition repeat on', reaper.GetSetRepeat(-1), 1)
  local l0, l1 = view.get_loop_range()
  T.check('loop range start', l0, scene.t0, 0.001)
  T.check('loop range end', l1, scene.t0 + 1.0, 0.001)
  A.stop()
  T.wait(2)
  T.check('loop audition repeat restored', reaper.GetSetRepeat(-1), rep_before)
  local l0a, l1a = view.get_loop_range()
  T.check('loop range restored start', l0a, l0b, 0.001)
  T.check('loop range restored end', l1a, l1b, 0.001)
  S.loop = false

  -- 10. search --------------------------------------------------------------------------------------------------------------
  if demo then
    local q = search.prepare('lamp', true)
    local hits = search.filter(q, D.scenes, function(s) return s.name end)
    T.check('search scenes "lamp" first', hits[1] and hits[1].name or '-', '04 The lamp goes out')
    local thits = search.filter(q, D.tracks, function(e) return e.name end)
    T.ok('search tracks "lamp" finds Lamp mechanism', (function()
      for _, e in ipairs(thits) do if e.name == 'Lamp mechanism' then return true end end
      return false
    end)(), 'hits=' .. #thits)
    local q2 = search.prepare('sto wa', true)
    local hits2 = search.filter(q2, D.scenes, function(s) return s.name end)
    T.check('search scenes "sto wa" first', hits2[1] and hits2[1].name or '-', '03 Storm warning')
    local q3 = search.prepare('zzqx', true)
    T.check('search no match', #search.filter(q3, D.scenes, function(s) return s.name end), 0)
  else
    local q = search.prepare(D.scenes[1].name:sub(1, 3), true)
    T.ok('search finds the first scene by prefix', #search.filter(q, D.scenes, function(s) return s.name end) >= 1)
  end

  -- 11. groups: a project-scoped group, jump, remove ----------------------------------------------------------------------------
  config.set('navigator.groups', { { name = 'Selftest group', key = '1', t0 = scene.t0, t1 = scene.t1 } }, 'project')
  T.check('group stored', #(config.get('navigator.groups') or {}), 1)
  A.jump_group({ name = 'Selftest group', t0 = scene.t0, t1 = scene.t1 })
  T.wait(1)
  local gv0, gv1 = view.get()
  T.ok('group jump view covers range', gv0 <= scene.t0 + 0.001 and gv1 >= scene.t1 - 0.001, string.format('view %.3f-%.3f', gv0, gv1))
  config.reset('navigator.groups', 'project')
  T.check('group removed', #(config.get('navigator.groups') or {}), 0)

  -- 12. per-project persistence ---------------------------------------------------------------------------------------------------
  local dirty_before = reaper.IsProjectDirty(0)
  S.tab = 3
  S.save()
  local saved = state.pget_json('nav.ui')
  T.check('persist tab', saved and saved.tab or -1, 3)
  T.fact('project_dirty_before_persist', dirty_before)
  T.fact('project_dirty_after_persist', reaper.IsProjectDirty(0))
  S.tab = 1
  S.tab_request = 1

  -- 13. restore everything and diff the dump ---------------------------------------------------------------------------------
  A.jump_scene(scene)
  A.focus_range(scene.t0, scene.t1)
  A.solo_scene(scene)
  A.mute_scene(scene)
  T.wait(2)
  journal.flush()
  T.fact('journal_before_restore', #journal.entries())
  local t_restore = reaper.time_precise()
  local stats = A.restore_all()
  T.fact('restore_ms', string.format('%.1f', (reaper.time_precise() - t_restore) * 1000))
  T.wait(2)
  T.check('restore kept none', stats.kept, 0)
  T.check('restore gone none', stats.gone, 0)
  T.check('journal empty after restore', #journal.entries(), 0)
  if T.sabotage == 'leave_solo' and aud_track then
    reaper.SetMediaTrackInfo_Value(aud_track.tr, 'I_SOLO', 2)   -- negative control: a leftover the diff must catch
    T.log('SABOTAGE leave_solo applied')
  end
  local after = layout.dump()
  if names_ok then layout.write(T.out_path('layout_after.json'), after) end
  local diff = layout.diff(before, after)
  for i, d in ipairs(diff) do
    if i <= 20 then T.log('DIFF ' .. (names_ok and d or '(hidden)')) end
  end
  T.log('RESTORE_DIFF ' .. #diff)
  T.check('restore diff', #diff, 0)
  if T.sabotage == 'leave_solo' and aud_track then reaper.SetMediaTrackInfo_Value(aud_track.tr, 'I_SOLO', 0) end
  S.search = ''
  S.hi = 0
end

-- after DONE: walk the tabs for the harness screenshots (about 2.5 s apart at 30 fps)
function ST.post(frames_since_done)
  if frames_since_done == 1 then S.tab_request = 1
  elseif frames_since_done == 75 then S.tab_request = 2
  elseif frames_since_done == 165 then S.tab_request = 3
  elseif frames_since_done == 255 then S.tab_request = 4
  elseif frames_since_done == 345 and ST.variant == 'realism' then
    -- the fifth screenshot: the Director's list built from the scenes (column layout with the project's times)
    local dir = app.by_name.director
    if dir and dir.MD then
      local scenes = require('lib.regions').scan(nil, 5)
      for _, sh in ipairs(dir.MD.from_scenes(scenes)) do dir.MD.shots[#dir.MD.shots + 1] = sh end
      dir.MD.sort()
      dir.MD.save()
      dir.S.validate_request = true
      dir.S.show_issues = true
      app.set_tab('director')
    end
  end
end

return ST
