-- lib/meter.lua - track meters for the glow and the master loudness read for the HUD.
--
-- track_db(tr): the post-fader level in dB (Track_GetPeakInfo 0/1, max of the first two channels): what is
-- audible after fader, FX and ducking. step(env, level, dt, P, now, pos): the glow envelope of one track or
-- item - a display level with instant attack and a dB/s release (`fast`), an adaptive reference that follows
-- the recent peak and sinks slowly (`hold`, floored so quiet beds still pulse), and a fast-falling detector
-- (`det`); an onset = the level rose at least onset_db above the decayed detector, at least min_gap_s after the
-- last one. Brightness g = ((fast - (hold - window)) / window) ^ gamma, clamped to 0..1, 0 below the floor.
-- fake_db(items, pos, seed): synthetic dynamics from item bounds for headless legs (media offline, meters
-- silent); the caller still reads the real meter every frame (docs/architecture.md invariant 5).
-- master(): REAPER's LUFS-M / LUFS-S style values (channels 1024 / 1025; negative dB, a positive value would
-- be linear) and the sample peak of the master. Lua 5.4; no globals; no math.log10 (REAPER's Lua has none).

local M = {}

M.SILENCE = -100

function M.lin_to_db(v)
  if not v or v <= 1e-5 then return M.SILENCE end
  return 20 * math.log(v, 10)
end

function M.track_db(tr)
  local l = reaper.Track_GetPeakInfo(tr, 0)
  local r = reaper.Track_GetPeakInfo(tr, 1)
  local pk = l or 0
  if r and r > pk then pk = r end
  return M.lin_to_db(pk)
end

-- items = list of { t0, t1, mute }; the fake sound starts 150 ms after an item start, rings 600 ms past its end
function M.fake_db(items, pos, seed)
  local best = M.SILENCE
  for _, it in ipairs(items) do
    if not it.mute and pos >= it.t0 + 0.15 and pos < it.t1 + 0.6 then
      local a = pos - it.t0 - 0.15
      local v = -8 - 22 * (1 - math.exp(-a / 0.35)) + 5 * math.sin(2 * math.pi * 1.7 * pos + (seed or 0))
      if pos > it.t1 then v = v - 30 * (pos - it.t1) / 0.6 end
      if v > best then best = v end
    end
  end
  return best
end

-- P = { release_db_s, ref_decay_db_s, ref_floor_dbfs, window_db, gamma, onset_db, det_release_db_s, min_gap_s }
function M.new_env(P, now)
  return {
    fast = M.SILENCE, hold = P.ref_floor_dbfs, det = M.SILENCE, spark_t = -1e9, spark_pos = nil, sparks = 0,
    g = 0, gmax = 0, last = now or reaper.time_precise(),
  }
end

-- returns g (0..1) and true when an onset fired this step (s.spark_t = now, s.spark_pos = pos)
function M.step(s, lvl, dt, P, now, pos)
  if lvl > s.fast then s.fast = lvl else s.fast = math.max(lvl, s.fast - P.release_db_s * dt) end
  s.hold = math.max(s.fast, s.hold - P.ref_decay_db_s * dt, P.ref_floor_dbfs)
  local det_before = s.det
  s.det = math.max(lvl, s.det - P.det_release_db_s * dt)
  local onset = false
  if lvl - det_before >= P.onset_db and lvl > P.ref_floor_dbfs - 6 and now - s.spark_t > P.min_gap_s then
    s.spark_t = now
    s.spark_pos = pos
    s.sparks = s.sparks + 1
    onset = true
  end
  local g = (s.fast - (s.hold - P.window_db)) / P.window_db
  if g < 0 then g = 0 elseif g > 1 then g = 1 end
  g = g ^ P.gamma
  if s.fast <= P.ref_floor_dbfs - 6 then g = 0 end
  s.g = g
  if g > s.gmax then s.gmax = g end
  return g, onset
end

local function conv_lufs(v)
  if not v then return M.SILENCE end
  if v > 0 then return 20 * math.log(v, 10) end
  if v < -150 then return M.SILENCE end
  return v
end

-- momentary, short-term, sample peak (dB), raw 1024 and 1025 values (for the facts log)
function M.master()
  local m = reaper.GetMasterTrack(0)
  local a = reaper.Track_GetPeakInfo(m, 1024)
  local b = reaper.Track_GetPeakInfo(m, 1025)
  local pl = reaper.Track_GetPeakInfo(m, 0)
  local pr = reaper.Track_GetPeakInfo(m, 1)
  local pk = pl or 0
  if pr and pr > pk then pk = pr end
  return conv_lufs(a), conv_lufs(b), M.lin_to_db(pk), a, b
end

return M
