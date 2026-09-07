-- lib/layout.lua - a dump of everything Stagehand may touch in a project, for the restore-diff test.
--
-- dump() -> { tracks = { [guid] = {...} }, items = { [guid] = { mute } }, envs = { [guid] = { name, vis } },
-- transport = { repeat, master_vis, master_fx }, toggles = { cont_scroll, mixer, video }, sends = { [guid#i] =
-- { name, mute } }, render = { [RENDER_*] = value } (the settings the Stems run writes, M6) }. diff(a, b) -> list of "path: before -> after" strings
-- (empty when the two dumps agree). Selection, the edit cursor, the time selection, the loop range (linked to
-- the time selection by REAPER's default option), the arrange view and the scroll position are not part of
-- the dump: a jump sets them on purpose; the Director journals the view and the scroll it changed and the
-- self-test checks them explicitly. Ruler lanes have no readable state (blind toggles). Lua 5.4; no globals.

local json = require('lib.json')
local items = require('lib.items')
local envelopes = require('lib.envelopes')

local M = {}

local TRACK_FIELDS = {
  { 'solo', 'I_SOLO' }, { 'mute', 'B_MUTE' }, { 'tcp', 'B_SHOWINTCP' }, { 'mcp', 'B_SHOWINMIXER' },
  { 'height', 'I_HEIGHTOVERRIDE' }, { 'lock', 'B_HEIGHTLOCK' }, { 'compact', 'I_FOLDERCOMPACT' },
  { 'pin', 'B_TCPPIN' }, { 'depth', 'I_FOLDERDEPTH' },
}

local CONT_SCROLL = 41817

local MIXER = 40078
local VIDEO = 50125

-- the render settings a Stems run writes (journaled as render_num / render_str); RENDER_TARGETS and RENDER_STATS
-- are read-only and never part of a dump (the stats read can raise a dialog, see failure note T1
M.RENDER_NUM = { 'RENDER_SETTINGS', 'RENDER_BOUNDSFLAG', 'RENDER_CHANNELS', 'RENDER_SRATE', 'RENDER_STARTPOS', 'RENDER_ENDPOS',
  'RENDER_TAILFLAG', 'RENDER_TAILMS', 'RENDER_ADDTOPROJ', 'RENDER_DITHER', 'RENDER_NORMALIZE', 'RENDER_NORMALIZE_TARGET' }
M.RENDER_STR = { 'RENDER_FILE', 'RENDER_PATTERN', 'RENDER_FORMAT', 'RENDER_FORMAT2' }

function M.toggle_state(cmd, word)
  local name = (reaper.kbd_getTextFromCmd(cmd, 0) or ''):lower()
  if not name:find(word, 1, true) then return -1 end
  return reaper.GetToggleCommandState(cmd)
end

function M.cont_scroll_state()
  return M.toggle_state(CONT_SCROLL, 'continuous')
end

function M.dump()
  local d = { tracks = {}, items = {}, envs = {}, transport = {}, toggles = {}, sends = {}, render = {} }
  for k = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, k)
    local _, name = reaper.GetTrackName(tr)
    local rec = { name = name or '' }
    for _, f in ipairs(TRACK_FIELDS) do
      rec[f[1]] = math.floor(reaper.GetMediaTrackInfo_Value(tr, f[2]))
    end
    d.tracks[reaper.GetTrackGUID(tr)] = rec
    for i = 0, reaper.GetTrackNumSends(tr, 0) - 1 do
      d.sends[reaper.GetTrackGUID(tr) .. '#' .. i] = { name = (name or '') .. ' / send ' .. i, mute = math.floor(reaper.GetTrackSendInfo_Value(tr, 0, i, 'B_MUTE')) }
    end
    for _, ev in ipairs(envelopes.scan(tr)) do
      d.envs[ev.guid or (reaper.GetTrackGUID(tr) .. '#' .. ev.idx)] = {
        name = (name or '') .. ' / ' .. ev.name, vis = envelopes.visible(ev.env), lane = envelopes.lane_line(ev.env) or '',
      }
    end
  end
  for k = 0, reaper.CountMediaItems(0) - 1 do
    local it = reaper.GetMediaItem(0, k)
    d.items[items.guid(it)] = { mute = math.floor(reaper.GetMediaItemInfo_Value(it, 'B_MUTE')) }
  end
  d.transport['repeat'] = reaper.GetSetRepeat(-1)
  d.transport.master_vis = reaper.GetMasterTrackVisibility()
  d.transport.master_fx = math.floor(reaper.GetMediaTrackInfo_Value(reaper.GetMasterTrack(0), 'I_FXEN'))   -- the stems' "master FX bypassed" variant
  for _, k in ipairs(M.RENDER_NUM) do d.render[k] = reaper.GetSetProjectInfo(0, k, 0, false) end
  for _, k in ipairs(M.RENDER_STR) do
    local _, v = reaper.GetSetProjectInfo_String(0, k, '', false)
    d.render[k] = v
  end
  d.toggles.cont_scroll = M.cont_scroll_state()
  d.toggles.mixer = M.toggle_state(MIXER, 'mixer')     -- the overview and the recorder checklist hide the mixer
  d.toggles.video = M.toggle_state(VIDEO, 'video')     -- and the video window; both journaled
  return d
end

local function fmt(v)
  if type(v) == 'table' then return json.encode(v) end
  return tostring(v)
end

local function diff_tables(path, a, b, out)
  a = a or {}
  b = b or {}
  local keys = {}
  for k in pairs(a) do keys[k] = true end
  for k in pairs(b) do keys[k] = true end
  local sorted = {}
  for k in pairs(keys) do sorted[#sorted + 1] = k end
  table.sort(sorted, function(x, y) return tostring(x) < tostring(y) end)
  for _, k in ipairs(sorted) do
    local va, vb = a[k], b[k]
    local p = path .. '/' .. tostring(k)
    if type(va) == 'table' and type(vb) == 'table' then
      if va.name and va.name == vb.name then p = path .. '/' .. va.name end
      diff_tables(p, va, vb, out)
    elseif va ~= vb and not (type(va) == 'number' and type(vb) == 'number' and math.abs(va - vb) < 1e-6) then
      out[#out + 1] = string.format('%s: %s -> %s', p, fmt(va), fmt(vb))
    end
  end
end

function M.diff(a, b)
  local out = {}
  diff_tables('', a, b, out)
  return out
end

function M.write(path, dump)
  local f = io.open(path, 'w')
  if not f then return false end
  f:write(json.encode(dump, { pretty = true }), '\n')
  f:close()
  return true
end

return M
