-- lib/journal.lua - the restore journal: every project change Stagehand makes is recorded BEFORE it is made,
-- persisted to the project (ProjExtState "journal"), and replayed in reverse to put things back exactly.
--
-- Entry: { kind, key, was, set, owner }. Edit kinds (M1): solo (key = track GUID, I_SOLO), item_mute (key =
-- item GUID, B_MUTE), show (key = track GUID, B_SHOWINTCP), repeat (GetSetRepeat), loop_range (was = { t0, t1 }).
-- Layout kinds (M2, owner director): layout (key = track GUID, was = { show, height, lock, compact, pin }),
-- env_vis (key = envelope GUID, was = 0/1), view (was = { v0, v1 }), scroll (was = px), toggle (key = command
-- id, was = 0/1, name = a word the action name must contain), ruler_lane (was = lane N, blind toggle).
-- M5 kinds: master_vis, env_lane_h, window_rect, dock_id. M6 kinds (stems): mute, master_fx, send_mute,
-- render_num, render_str (see the restorers below).
-- owner names who made the change so a subset can be restored. add() keeps the first entry for a kind+key
-- (its `was` is the truth); restore() puts an edit value back only when the project still holds the value
-- Stagehand set (a value the user changed since is left alone and reported as "kept"); layout kinds are put
-- back unconditionally (the layout belongs to the Director while a run is active). The whole replay runs
-- under PreventUIRefresh; view and scroll are applied after the track list was laid out again.
-- Lua 5.4; no globals.

local log = require('lib.log')
local state = require('state')
local tracks = require('lib.tracks')
local items = require('lib.items')
local envelopes = require('lib.envelopes')

local M = {}

local entries = {}
local KEY = 'journal'
local dirty = false

-- the JSON copy in the project is written once per frame (flush) rather than on every add: a scene solo on a
-- 150-track session adds hundreds of entries in one call
local function persist()
  if #entries == 0 then
    state.pset(KEY, '')
  else
    state.pset_json(KEY, entries)
  end
  dirty = false
end

local function mark()
  dirty = true
end

-- write the journal to the project when something changed since the last write; call once per frame
function M.flush()
  if dirty then persist() end
end

function M.is_dirty()
  return dirty
end

function M.load()
  local v = state.pget_json(KEY)
  entries = type(v) == 'table' and v or {}
  return #entries
end

function M.entries()
  return entries
end

-- an entry was edited in place: write it with the next flush
function M.save()
  mark()
end

function M.count(kind, owner)
  local n = 0
  for _, e in ipairs(entries) do
    if (not kind or e.kind == kind) and (not owner or e.owner == owner) then n = n + 1 end
  end
  return n
end

function M.has(kind, key)
  for _, e in ipairs(entries) do
    if e.kind == kind and e.key == key then return true end
  end
  return false
end

function M.find(kind, key)
  for _, e in ipairs(entries) do
    if e.kind == kind and e.key == key then return e end
  end
  return nil
end

-- returns true when the entry was added (the caller then applies the change), false when the kind+key is
-- already journaled (the earlier `was` stays authoritative; the caller may still apply its value)
function M.add(entry)
  if M.has(entry.kind, entry.key) then return false end
  entries[#entries + 1] = entry
  mark()
  return true
end

local restorers = {}
local maps = { tracks = nil, items = nil, envs = nil }   -- GUID -> pointer, built once per restore() call

local function track_of(e)
  maps.tracks = maps.tracks or tracks.guid_map()
  return maps.tracks[e.key]
end

local function item_of(e)
  maps.items = maps.items or items.guid_map()
  return maps.items[e.key]
end

local function env_of(e)
  maps.envs = maps.envs or envelopes.guid_map()
  return maps.envs[e.key]
end

restorers.solo = function(e)
  local tr = track_of(e)
  if not tr then return 'gone' end
  local cur = tracks.get(tr, 'I_SOLO')
  if e.set ~= nil and cur ~= e.set then return 'kept' end
  tracks.set(tr, 'I_SOLO', e.was)
  return 'restored'
end

restorers.item_mute = function(e)
  local it = item_of(e)
  if not it then return 'gone' end
  local cur = items.get(it, 'B_MUTE')
  if e.set ~= nil and cur ~= e.set then return 'kept' end
  items.set(it, 'B_MUTE', e.was)
  return 'restored'
end

restorers.show = function(e)
  local tr = track_of(e)
  if not tr then return 'gone' end
  local cur = tracks.get(tr, 'B_SHOWINTCP')
  if e.set ~= nil and cur ~= e.set then return 'kept' end
  tracks.set(tr, 'B_SHOWINTCP', e.was)
  return 'restored'
end

restorers['repeat'] = function(e)
  reaper.GetSetRepeat(e.was)
  return 'restored'
end

restorers.loop_range = function(e)
  reaper.GetSet_LoopTimeRange2(0, true, true, e.was[1] or 0, e.was[2] or 0, false)
  return 'restored'
end

-- order matters (H1 in docs/research/failures.md): show, unlock, override, original lock, compact, pin
restorers.layout = function(e)
  local tr = track_of(e)
  if not tr then return 'gone' end
  local w = e.was or {}
  tracks.set(tr, 'B_SHOWINTCP', w.show or 1)
  tracks.set(tr, 'B_HEIGHTLOCK', 0)
  tracks.set(tr, 'I_HEIGHTOVERRIDE', w.height or 0)
  tracks.set(tr, 'B_HEIGHTLOCK', w.lock or 0)
  if w.compact ~= nil then tracks.set(tr, 'I_FOLDERCOMPACT', w.compact) end
  if w.pin ~= nil then tracks.set(tr, 'B_TCPPIN', w.pin) end
  return 'restored'
end

restorers.env_vis = function(e)
  local env = env_of(e)
  if not env then return 'gone' end
  envelopes.set_visible(env, e.was == 1)
  return 'restored'
end

restorers.view = function(e)
  reaper.GetSet_ArrangeView2(0, true, 0, 0, e.was[1] or 0, e.was[2] or 1)
  return 'restored'
end

restorers.scroll = function(e)
  local arrange = require('lib.arrange')
  if arrange.set_scroll_pos(e.was or 0) then return 'restored' end
  return 'gone'
end

restorers.toggle = function(e)
  local cmd = tonumber(e.key)
  if not cmd then return 'gone' end
  local name = (reaper.kbd_getTextFromCmd(cmd, 0) or ''):lower()
  if e.name and not name:find(tostring(e.name):lower(), 1, true) then
    log.warn('journal: action %d is "%s" now, not toggled back', cmd, name)
    return 'gone'
  end
  if reaper.GetToggleCommandState(cmd) ~= e.was then reaper.Main_OnCommand(cmd, 0) end
  return 'restored'
end

restorers.ruler_lane = function(e)
  local n = tonumber(e.was)
  if not n then return 'gone' end
  reaper.Main_OnCommand(43507 + n, 0)   -- blind toggle (no readable state): the run toggled it once, this undoes it
  return 'restored'
end

-- M5 kinds. master_vis (was = GetMasterTrackVisibility), env_lane_h (key = envelope GUID, was = the LANEHEIGHT
-- line of the chunk or nil), window_rect (key = 'main' | 'video', was = { l, t, w, h } screen px, y down; the video
-- window is found by its title), dock_id (key = window ident, was = the docker index GetConfigWantsDock returned)
restorers.master_vis = function(e)
  local v = tonumber(e.was)
  if not v then return 'gone' end
  reaper.SetMasterTrackVisibility(math.floor(v))
  return 'restored'
end

restorers.env_lane_h = function(e)
  local env = env_of(e)
  if not env then return 'gone' end
  envelopes.set_lane_line(env, e.was)
  return 'restored'
end

restorers.window_rect = function(e)
  local js = require('platform.js')
  if not (js.caps and js.caps.window_move) then return 'gone' end
  local w = e.was
  if type(w) ~= 'table' or not w[1] then return 'gone' end
  local hwnd
  if e.key == 'main' then
    hwnd = reaper.GetMainHwnd()
  else
    hwnd = js.find_window(e.name or e.key)
  end
  if not hwnd then return 'gone' end
  reaper.JS_Window_SetPosition(hwnd, math.floor(w[1]), math.floor(w[2]), math.floor(w[3]), math.floor(w[4]))
  return 'restored'
end

restorers.dock_id = function(e)
  if not reaper.Dock_UpdateDockID then return 'gone' end
  local idx = tonumber(e.was)
  if not idx then return 'gone' end
  reaper.Dock_UpdateDockID(tostring(e.key), math.floor(idx))
  return 'restored'
end

-- M6 kinds (owner stems). mute (key = track GUID, B_MUTE; edit kind: kept when the user changed it since),
-- master_fx (key = 'master', was = I_FXEN of the master track), send_mute (key = track GUID .. '#' .. send index,
-- was = B_MUTE of that send), render_num (key = a GetSetProjectInfo RENDER_* name, was = the number),
-- render_str (key = a GetSetProjectInfo_String RENDER_* name, was = the string). Render kinds are put back
-- unconditionally: the run owns the render settings while it is active, like the Director owns the layout.
restorers.mute = function(e)
  local tr = track_of(e)
  if not tr then return 'gone' end
  local cur = tracks.get(tr, 'B_MUTE')
  if e.set ~= nil and cur ~= e.set then return 'kept' end
  tracks.set(tr, 'B_MUTE', e.was)
  return 'restored'
end

restorers.master_fx = function(e)
  local v = tonumber(e.was)
  if not v then return 'gone' end
  reaper.SetMediaTrackInfo_Value(reaper.GetMasterTrack(0), 'I_FXEN', math.floor(v))
  return 'restored'
end

restorers.send_mute = function(e)
  local guid, idx = tostring(e.key):match('^(.-)#(%d+)$')
  if not guid then return 'gone' end
  maps.tracks = maps.tracks or tracks.guid_map()
  local tr = maps.tracks[guid]
  if not tr then return 'gone' end
  idx = tonumber(idx)
  if idx >= reaper.GetTrackNumSends(tr, 0) then return 'gone' end
  reaper.SetTrackSendInfo_Value(tr, 0, idx, 'B_MUTE', tonumber(e.was) or 0)
  return 'restored'
end

restorers.render_num = function(e)
  local v = tonumber(e.was)
  if not v then return 'gone' end
  reaper.GetSetProjectInfo(0, tostring(e.key), v, true)
  return 'restored'
end

restorers.render_str = function(e)
  if type(e.was) ~= 'string' then return 'gone' end
  reaper.GetSetProjectInfo_String(0, tostring(e.key), e.was, true)
  return 'restored'
end

local LAYOUT_KINDS = { show = true, layout = true, env_vis = true, env_lane_h = true, master_vis = true }
local LATE_KINDS = { view = true, scroll = true }

local function run_one(e, stats)
  local fn = restorers[e.kind]
  local result = 'gone'
  if fn then
    local ok, res = pcall(fn, e)
    if ok then result = res else log.error('journal restore %s/%s failed: %s', e.kind, tostring(e.key), tostring(res)) end
  else
    log.warn('journal: unknown entry kind %s', tostring(e.kind))
  end
  stats[result] = (stats[result] or 0) + 1
  stats.by_kind[e.kind] = (stats.by_kind[e.kind] or 0) + 1
end

-- restore (and drop) every entry accepted by pred(entry) (nil = all), newest first; view and scroll last.
-- returns stats { restored, kept, gone, by_kind = { kind = n } }
function M.restore(pred)
  local stats = { restored = 0, kept = 0, gone = 0, by_kind = {} }
  local touched_layout = false
  local late = {}
  maps.tracks, maps.items, maps.envs = nil, nil, nil
  reaper.PreventUIRefresh(1)
  for i = #entries, 1, -1 do
    local e = entries[i]
    if not pred or pred(e) then
      if LATE_KINDS[e.kind] then
        late[#late + 1] = e
      else
        run_one(e, stats)
        if LAYOUT_KINDS[e.kind] then touched_layout = true end
      end
      table.remove(entries, i)
    end
  end
  if touched_layout then reaper.TrackList_AdjustWindows(false) end
  for _, e in ipairs(late) do
    if e.kind == 'view' then run_one(e, stats) end
  end
  reaper.PreventUIRefresh(-1)
  reaper.UpdateArrange()
  for _, e in ipairs(late) do
    if e.kind == 'scroll' then run_one(e, stats) end   -- after the relayout, so the new scroll range applies
  end
  maps.tracks, maps.items, maps.envs = nil, nil, nil
  persist()
  return stats
end

-- drop entries without restoring (the user chose "discard" after a crash)
function M.discard(pred)
  for i = #entries, 1, -1 do
    if not pred or pred(entries[i]) then table.remove(entries, i) end
  end
  persist()
end

function M.owner_pred(owner)
  return function(e) return e.owner == owner end
end

function M.not_owner_pred(owner)
  return function(e) return e.owner ~= owner end
end

function M.kind_pred(kind)
  return function(e) return e.kind == kind end
end

return M
