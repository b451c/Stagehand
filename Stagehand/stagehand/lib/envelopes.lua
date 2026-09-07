-- lib/envelopes.lua - track envelope lanes: scan, GUID, visibility, measured lane height.
--
-- Visibility goes through GetSetEnvelopeInfo_String(env, 'VISIBLE') (REAPER 6.x+; the state chunk's VIS line is
-- the fallback when the API is missing). The chunk read (vis_from_chunk) stays available as an independent
-- oracle for the self-tests. Envelopes are keyed by their GUID so a restore can find them again after edits.
-- Lua 5.4; no globals.

local M = {}

local has_info_string = reaper.APIExists('GetSetEnvelopeInfo_String')
local has_info_value = reaper.APIExists('GetEnvelopeInfo_Value')

function M.valid(env)
  return env ~= nil and reaper.ValidatePtr2(0, env, 'TrackEnvelope*')
end

function M.name(env)
  local _, name = reaper.GetEnvelopeName(env)
  return name or ''
end

function M.guid(env)
  if has_info_string then
    local ok, g = reaper.GetSetEnvelopeInfo_String(env, 'GUID', '', false)
    if ok and g and g ~= '' then return g end
  end
  local ok, chunk = reaper.GetEnvelopeStateChunk(env, '', false)
  if ok and chunk then
    local g = chunk:match('\nEGUID (%b{})')
    if g then return g end
  end
  return nil
end

-- the VIS line of the chunk: visible, lane, unknown -> visible flag (0/1) or nil
function M.vis_from_chunk(env)
  local ok, chunk = reaper.GetEnvelopeStateChunk(env, '', false)
  if not ok or not chunk then return nil end
  local v = chunk:match('\nVIS (%d)')
  return v and tonumber(v) or nil
end

function M.visible(env)
  if has_info_string then
    local ok, v = reaper.GetSetEnvelopeInfo_String(env, 'VISIBLE', '', false)
    if ok then return tonumber(v) == 1 and 1 or 0 end
  end
  return M.vis_from_chunk(env) or 1
end

-- returns true when the value changed (the caller relayouts with TrackList_AdjustWindows)
function M.set_visible(env, on)
  local want = on and 1 or 0
  if M.visible(env) == want then return false end
  if has_info_string then
    reaper.GetSetEnvelopeInfo_String(env, 'VISIBLE', tostring(want), true)
    return true
  end
  local ok, chunk = reaper.GetEnvelopeStateChunk(env, '', false)
  if not ok or not chunk then return false end
  chunk = chunk:gsub('\nVIS %d', '\nVIS ' .. want, 1)
  reaper.SetEnvelopeStateChunk(env, chunk, false)
  return true
end

-- the height the lane takes on screen right now (0 when hidden or not in its own lane)
function M.lane_height(env)
  if not has_info_value then return 0 end
  return math.max(0, reaper.GetEnvelopeInfo_Value(env, 'I_TCPH'))
end

-- the LANEHEIGHT line of the chunk ("LANEHEIGHT <px> <flag>") or nil when the chunk has none
function M.lane_line(env)
  local ok, chunk = reaper.GetEnvelopeStateChunk(env, '', false)
  if not ok or not chunk then return nil end
  return chunk:match('\nLANEHEIGHT [^\n]*')
end

-- put a LANEHEIGHT line back (nil = leave the chunk as it is); returns true when the chunk was written
function M.set_lane_line(env, line)
  if type(line) ~= 'string' or line == '' then return false end
  local ok, chunk = reaper.GetEnvelopeStateChunk(env, '', false)
  if not ok or not chunk then return false end
  if chunk:find(line, 1, true) then return false end
  local out, n = chunk:gsub('\nLANEHEIGHT [^\n]*', function() return line end, 1)
  if n == 0 then return false end
  reaper.SetEnvelopeStateChunk(env, out, false)
  return true
end

-- set the lane height in px (the chunk's LANEHEIGHT line: "<px> <lock flag>"); returns true when changed
function M.set_lane_height(env, px)
  local ok, chunk = reaper.GetEnvelopeStateChunk(env, '', false)
  if not ok or not chunk then return false end
  local want = string.format('\nLANEHEIGHT %d 0', math.floor(px))
  if chunk:find(want, 1, true) then return false end
  local out, n = chunk:gsub('\nLANEHEIGHT [^\n]*', function() return want end, 1)
  if n == 0 then return false end
  reaper.SetEnvelopeStateChunk(env, out, false)
  return true
end

function M.point_count(env)
  return reaper.CountEnvelopePoints(env)
end

-- "used" for the overview: at least min_points points or one automation item
function M.used(env, min_points)
  if reaper.CountEnvelopePoints(env) >= (min_points or 2) then return true end
  if reaper.CountAutomationItems and reaper.CountAutomationItems(env) > 0 then return true end
  return false
end

-- envelopes of one track: list of { env, name, idx, guid }
function M.scan(tr)
  local out = {}
  for i = 0, reaper.CountTrackEnvelopes(tr) - 1 do
    local env = reaper.GetTrackEnvelope(tr, i)
    out[#out + 1] = { env = env, name = M.name(env), idx = i, guid = M.guid(env) }
  end
  return out
end

-- GUID -> envelope for every track envelope in the project (one pass; for many lookups)
function M.guid_map()
  local map = {}
  for k = 0, reaper.CountTracks(0) - 1 do
    local tr = reaper.GetTrack(0, k)
    for i = 0, reaper.CountTrackEnvelopes(tr) - 1 do
      local env = reaper.GetTrackEnvelope(tr, i)
      local g = M.guid(env)
      if g then map[g] = env end
    end
  end
  return map
end

function M.count_all()
  local n = 0
  for k = 0, reaper.CountTracks(0) - 1 do
    n = n + reaper.CountTrackEnvelopes(reaper.GetTrack(0, k))
  end
  return n
end

M.api = { info_string = has_info_string, info_value = has_info_value }

return M
