-- modules/navigator/actions.lua - what the navigator does to the project: jump, focus, audition with auto-stop,
-- scene solo / mute, track and item toggles, and the restore paths. Every project edit runs in an undo block
-- and is journaled before it happens (lib/journal.lua) so it can be put back exactly. Lua 5.4; no globals.

local log = require('lib.log')
local text = require('lib.text')
local tracks = require('lib.tracks')
local items = require('lib.items')
local view = require('lib.view')
local undo = require('lib.undo')
local journal = require('lib.journal')
local config = require('config')
local i18n = require('i18n')

local t = i18n.t

local A = { app = nil, D = nil, S = nil, aud = nil, solo_scene_name = nil, mute_scene_name = nil }

local function cfg(key)
  return config.get('navigator.' .. key)
end

function A.init(app, D, S)
  A.app, A.D, A.S = app, D, S
end

function A.say(msg)
  A.S.msg = msg
  A.S.msg_frames = 40
  log.info('navigator: %s', msg)
end

-- jumps ---------------------------------------------------------------------------------------------------------

function A.jump_range(t0, t1, label)
  local S = A.S
  local shown
  view.batch(function()
    view.set_cursor(t0)
    if S.timesel then view.set_time_selection(t0, t1) end
    view.zoom_to(t0, t1, cfg('jump.zoom_pad_min_s'), cfg('jump.zoom_pad_frac'))
    if S.focus then shown = A.focus_range(t0, t1) end
  end)
  if shown then
    A.say(string.format(t('nav.msg.jump_tracks'), label, text.fmt_time(t0), text.fmt_time(t1), shown))
  else
    A.say(string.format(t('nav.msg.jump'), label, text.fmt_time(t0), text.fmt_time(t1)))
  end
end

function A.jump_scene(s)
  A.D.scene = s
  A.D.invalidate_items()
  A.S.scene_name, A.S.scene_t0 = s.name, s.t0
  A.S.dirty = true
  A.jump_range(s.t0, s.t1, s.name)
end

function A.set_active_scene(s)
  A.D.scene = s
  A.D.invalidate_items()
  A.S.scene_name, A.S.scene_t0 = s.name, s.t0
  A.S.dirty = true
end

function A.jump_marker(m)
  local w = cfg('jump.marker_window_s') or 2.5
  view.batch(function()
    view.set_cursor(m.t0)
    view.set(m.t0 - w, m.t0 + w)
  end)
  A.say(string.format(t('nav.msg.marker'), m.name, text.fmt_time(m.t0)))
end

-- a hidden track is shown before scrolling to it; the change is journaled like any other
local function ensure_visible(e)
  if tracks.get(e.tr, 'B_SHOWINTCP') == 0 then
    journal.add({ kind = 'show', key = e.guid, was = 0, set = 1, owner = 'jump' })
    tracks.set(e.tr, 'B_SHOWINTCP', 1)
    reaper.TrackList_AdjustWindows(false)
  end
end

function A.jump_track(e)
  ensure_visible(e)
  view.scroll_track_into_view(e.tr)
  A.say(string.format(t('nav.msg.track'), e.n, e.name))
end

function A.jump_item(r)
  view.batch(function()
    view.set_cursor(r.t0)
    view.zoom_to(r.t0, r.t1, cfg('jump.zoom_pad_min_s'), cfg('jump.zoom_pad_frac'))
    view.select_item(r.it)
    ensure_visible(r.track)
    view.scroll_track_into_view(r.track.tr)
  end)
  A.say(string.format(t('nav.msg.item'), text.fmt_time(r.t0), r.name or '', r.track.name))
end

function A.jump_group(g)
  A.jump_range(g.t0, g.t1, string.format(t('nav.msg.group'), g.name))
end

-- track focus (TCP visibility, journaled) ----------------------------------------------------------------------

-- hide every track without items in [t0, t1) (ancestors of shown tracks stay); returns the number shown
function A.focus_range(t0, t1)
  local D = A.D
  if A.S.director_active then
    A.say(t('nav.msg.director_owns_layout'))
    return nil
  end
  local mark = {}
  for k, e in ipairs(D.tracks) do mark[k] = tracks.has_items_in(e.tr, t0, t1) end
  tracks.mark_ancestors(D.tracks, mark)
  local shown = 0
  reaper.PreventUIRefresh(1)
  for k, e in ipairs(D.tracks) do
    local want = mark[k] and 1 or 0
    if want == 1 then shown = shown + 1 end
    local cur = tracks.get(e.tr, 'B_SHOWINTCP')
    if cur ~= want then
      local entry = journal.find('show', e.guid)
      if entry then
        entry.set = want
        journal.save()
      else
        journal.add({ kind = 'show', key = e.guid, was = cur, set = want, owner = 'focus' })
      end
      tracks.set(e.tr, 'B_SHOWINTCP', want)
    end
  end
  reaper.PreventUIRefresh(-1)
  tracks.adjust()
  return shown
end

function A.restore_visibility()
  local stats = journal.restore(journal.kind_pred('show'))
  return stats.restored
end

-- every track visible in the TCP (a hidden track the user had is journaled too, so Restore puts it back)
function A.show_all()
  local n = 0
  if A.S.director_active then
    A.say(t('nav.msg.director_owns_layout'))
    return 0
  end
  reaper.PreventUIRefresh(1)
  for _, e in ipairs(A.D.tracks) do
    if tracks.get(e.tr, 'B_SHOWINTCP') == 0 then
      local entry = journal.find('show', e.guid)
      if entry then
        entry.set = 1
        journal.save()
      else
        journal.add({ kind = 'show', key = e.guid, was = 0, set = 1, owner = 'show_all' })
      end
      tracks.set(e.tr, 'B_SHOWINTCP', 1)
      n = n + 1
    end
  end
  reaper.PreventUIRefresh(-1)
  tracks.adjust()
  A.say(t('nav.msg.show_all'))
  return n
end

-- audition ------------------------------------------------------------------------------------------------------

function A.aud_restore()
  local a = A.aud
  if not a then return end
  A.aud = nil
  journal.restore(journal.owner_pred('audition'))
  A.say(string.format(t('nav.msg.stop'), a.label))
end

-- play [t0, t1) with an optional track soloed in place; auto-stop at t1 unless looping
function A.audition(t0, t1, label, solo_entry)
  local S = A.S
  if view.playing() then reaper.OnStopButton() end
  A.aud_restore()
  local a = { t0 = t0, t1 = t1, label = label, started = A.app.frame, loop = S.loop }
  if solo_entry and tracks.valid(solo_entry.tr) then
    local was = tracks.get(solo_entry.tr, 'I_SOLO')
    if was == 0 then
      journal.add({ kind = 'solo', key = solo_entry.guid, was = 0, set = 2, owner = 'audition' })
      tracks.set(solo_entry.tr, 'I_SOLO', 2)
    end
    a.solo_guid = solo_entry.guid
  end
  if S.loop then
    local l0, l1 = view.get_loop_range()
    journal.add({ kind = 'loop_range', key = 'loop', was = { l0, l1 }, owner = 'audition' })
    view.set_loop_range(t0, t1)
    journal.add({ kind = 'repeat', key = 'repeat', was = reaper.GetSetRepeat(-1), owner = 'audition' })
    reaper.GetSetRepeat(1)
  end
  view.set_cursor(t0, true)
  reaper.OnPlayButton()
  A.aud = a
  A.say(string.format(t('nav.msg.play'), label, text.fmt_time(t0), text.fmt_time(t1), S.loop and t('nav.msg.loop_suffix') or ''))
end

function A.stop()
  if view.playing() then reaper.OnStopButton() end
  A.aud_restore()
end

function A.tick()
  local a = A.aud
  if not a then return end
  local playing = view.playing()
  if playing and not a.loop and reaper.GetPlayPosition() >= a.t1 - (cfg('audition.stop_margin_s') or 0.015) then
    reaper.OnStopButton()
    playing = false
  end
  if not playing and A.app.frame > a.started + (cfg('audition.start_grace_frames') or 6) then
    A.aud_restore()
  end
end

function A.is_auditioning(t0, guid)
  local a = A.aud
  if not a or not view.playing() then return false end
  if t0 and math.abs(a.t0 - t0) > 1e-6 then return false end
  if guid and a.solo_guid ~= guid then return false end
  return true
end

-- scene solo / mute -----------------------------------------------------------------------------------------------

function A.clear_solo()
  local stats = journal.restore(journal.owner_pred('scene_solo'))
  A.solo_scene_name = nil
  return stats.restored
end

function A.solo_scene(s)
  local D, S = A.D, A.S
  local n, fams = 0, {}
  undo.block('Solo scene ' .. s.name, function()
    A.clear_solo()
    reaper.PreventUIRefresh(1)
    for _, e in ipairs(D.tracks_in_range(s.t0, s.t1, S.fam)) do
      local entry = journal.find('solo', e.guid)
      if entry then
        entry.owner = 'scene_solo'
        journal.save()
        n = n + 1
        fams[e.fam] = (fams[e.fam] or 0) + 1
      elseif tracks.get(e.tr, 'I_SOLO') == 0 then
        journal.add({ kind = 'solo', key = e.guid, was = 0, set = 2, owner = 'scene_solo' })
        tracks.set(e.tr, 'I_SOLO', 2)   -- solo in place: sends, returns and folders follow REAPER's own logic
        n = n + 1
        fams[e.fam] = (fams[e.fam] or 0) + 1
      end
    end
    reaper.PreventUIRefresh(-1)
  end)
  A.solo_scene_name = s.name
  reaper.UpdateArrange()
  local parts = {}
  for _, f in ipairs(D.all_families) do
    if fams[f.name] then parts[#parts + 1] = f.name .. ' ' .. fams[f.name] end
  end
  A.say(string.format(t('nav.msg.solo'), s.name, n, table.concat(parts, ', ')))
  return n
end

function A.clear_mute()
  local stats = journal.restore(journal.owner_pred('scene_mute'))
  A.mute_scene_name = nil
  return stats.restored
end

function A.mute_scene(s)
  local D, S = A.D, A.S
  local n = 0
  undo.block('Mute scene ' .. s.name, function()
    A.clear_mute()
    reaper.PreventUIRefresh(1)
    for _, r in ipairs(D.items_in_range(s.t0, s.t1, S.fam)) do
      if items.get(r.it, 'B_MUTE') == 0 then
        journal.add({ kind = 'item_mute', key = r.guid, was = 0, set = 1, owner = 'scene_mute' })
        items.set(r.it, 'B_MUTE', 1)
        n = n + 1
      end
    end
    reaper.PreventUIRefresh(-1)
  end)
  A.mute_scene_name = s.name
  reaper.UpdateArrange()
  A.say(string.format(t('nav.msg.mute'), s.name, n))
  return n
end

function A.toggle_solo_scene(s)
  if A.solo_scene_name == s.name then
    local n
    undo.block('Clear scene solo', function() n = A.clear_solo() end)
    A.say(string.format(t('nav.msg.unsolo'), n))
  else
    A.solo_scene(s)
  end
end

function A.toggle_mute_scene(s)
  if A.mute_scene_name == s.name then
    local n
    undo.block('Clear scene mute', function() n = A.clear_mute() end)
    A.say(string.format(t('nav.msg.unmute'), n))
  else
    A.mute_scene(s)
  end
end

function A.clear_all()
  A.stop()
  local a, b = 0, 0
  undo.block('Clear solo and mute', function()
    a = A.clear_solo()
    b = A.clear_mute()
  end)
  A.say(string.format(t('nav.msg.cleared'), a, b))
end

-- everything in the journal, newest first
function A.restore_all()
  A.stop()
  local stats
  local pred = A.S.director_active and journal.not_owner_pred('director') or nil
  undo.block('Restore', function() stats = journal.restore(pred) end)
  A.solo_scene_name, A.mute_scene_name = nil, nil
  if stats.restored + stats.kept + stats.gone == 0 then
    A.say(t('nav.msg.nothing_to_restore'))
  else
    A.say(string.format(t('nav.msg.restored'), stats.restored, stats.kept))
  end
  return stats
end

-- plain per-track / per-item toggles (the user's own intent, undoable, not journaled) -----------------------------

function A.track_solo_toggle(e)
  local cur = tracks.get(e.tr, 'I_SOLO')
  undo.block((cur > 0 and 'Unsolo ' or 'Solo ') .. e.name, function()
    tracks.set(e.tr, 'I_SOLO', cur > 0 and 0 or 2)
  end)
  reaper.UpdateArrange()
end

function A.track_mute_toggle(e)
  local cur = tracks.get(e.tr, 'B_MUTE')
  undo.block((cur > 0 and 'Unmute ' or 'Mute ') .. e.name, function()
    tracks.set(e.tr, 'B_MUTE', cur > 0 and 0 or 1)
  end)
  reaper.UpdateArrange()
end

function A.item_mute_toggle(r)
  if not items.valid(r.it) then return end
  local cur = items.get(r.it, 'B_MUTE')
  undo.block((cur > 0 and 'Unmute item ' or 'Mute item ') .. tostring(r.name or ''), function()
    items.set(r.it, 'B_MUTE', cur > 0 and 0 or 1)
  end)
  reaper.UpdateArrange()
end

-- audition helpers per row kind ------------------------------------------------------------------------------------

function A.audition_scene(s)
  A.set_active_scene(s)
  A.audition(s.t0, s.t1, s.name)
end

function A.audition_marker(m)
  A.audition(m.t0, m.t1, m.name)
end

function A.audition_track(e)
  local s = A.D.active_scene()
  if s then
    A.audition(s.t0, s.t1, e.name, e)
  else
    local c = view.cursor()
    A.audition(c, c + (cfg('audition.track_default_len_s') or 10), e.name, e)
  end
end

function A.audition_item(r)
  A.audition(r.t0, r.t1, r.name or r.track.name, r.track)
end

return A
