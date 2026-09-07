-- lib/loudness.lua - the HUD's loudness block. Two sources: live = REAPER's master meter (lib/meter.master:
-- LUFS-M / -S style values, the sample peak) with a gated integration of 100 ms blocks in Lua (absolute gate
-- -70 LUFS, relative gate gate_lu below the ungated mean, restarted on a backwards jump); curve = a text file
-- with "t M S I" rows (e.g. from ffmpeg ebur128, one row per 100 ms) indexed by the play position, exact by
-- construction for a delivered mix. The live meter over-reads dense material by about +0.6 LU when polled at
-- 30 Hz and returns M = S; the tooltip says so. Lua 5.4; no globals; no math.log10.

local meter = require('lib.meter')

local M = {}

M.SILENCE = meter.SILENCE

function M.new(opts)
  opts = opts or {}
  return {
    m = M.SILENCE, s = M.SILENCE, i = M.SILENCE, pk = M.SILENCE, blocks = {}, last_t = -1, last_pos = -1,
    curve = nil, curve_path = nil, curve_err = nil, block_s = (tonumber(opts.block_ms) or 100) / 1000,
    gate_lu = tonumber(opts.gate_lu) or -10, raw = { nil, nil }, source = 'live',
  }
end

function M.reset(st)
  st.blocks = {}
  st.i = M.SILENCE
  st.last_t = -1
  st.last_pos = -1
end

-- gated mean of a list of momentary values (dB); nil with fewer than 4 blocks above the absolute gate
function M.gated(blocks, gate_lu)
  local kept = {}
  for _, v in ipairs(blocks) do
    if v > -70 then kept[#kept + 1] = v end
  end
  local n = #kept
  if n < 4 then return nil end
  local sum = 0
  for i = 1, n do sum = sum + 10 ^ (kept[i] / 10) end
  local thr = 10 * math.log(sum / n, 10) + (gate_lu or -10)
  local sum2, n2 = 0, 0
  for i = 1, n do
    if kept[i] > thr then
      sum2 = sum2 + 10 ^ (kept[i] / 10)
      n2 = n2 + 1
    end
  end
  if n2 == 0 then return nil end
  return 10 * math.log(sum2 / n2, 10)
end

function M.read_live(st)
  local m, s, pk, ra, rb = meter.master()
  st.m, st.s, st.pk = m, s, pk
  st.raw[1], st.raw[2] = ra, rb
end

-- one block per block_s while playing; restart when the position jumps back
function M.integrate(st, playing, pos, now)
  if not playing then
    st.last_pos = -1
    return
  end
  if st.last_pos >= 0 and pos < st.last_pos - 0.5 then M.reset(st) end
  st.last_pos = pos
  if st.last_t >= 0 and now - st.last_t < st.block_s then return end
  st.last_t = now
  if st.m > -70 then st.blocks[#st.blocks + 1] = st.m end
  local i = M.gated(st.blocks, st.gate_lu)
  if i then st.i = i end
end

-- curve file: "t M S I" rows (whitespace or comma separated); comment and header lines are skipped
function M.parse_curve(text)
  local rows = {}
  for line in tostring(text or ''):gmatch('[^\r\n]+') do
    if not line:match('^%s*#') then
      local nums = {}
      for tok in line:gmatch('[^%s,;]+') do
        local v = tonumber(tok)
        if v == nil then nums = nil; break end
        nums[#nums + 1] = v
      end
      if nums and #nums >= 4 then rows[#rows + 1] = { nums[1], nums[2], nums[3], nums[4] } end
    end
  end
  table.sort(rows, function(a, b) return a[1] < b[1] end)
  return rows
end

function M.load_curve(st, path)
  st.curve, st.curve_path, st.curve_err = nil, path, nil
  local f = io.open(path, 'r')
  if not f then
    st.curve_err = 'not found'
    return false
  end
  local text = f:read('a') or ''
  f:close()
  local rows = M.parse_curve(text)
  if #rows < 2 then
    st.curve_err = 'no "t M S I" rows'
    return false
  end
  st.curve = rows
  return true, #rows
end

-- the row at or before t (binary search); nil before the first row
function M.curve_row(rows, t)
  local lo, hi = 1, #rows
  if hi == 0 or t < rows[1][1] then return nil end
  while lo < hi do
    local mid = (lo + hi + 1) // 2
    if rows[mid][1] <= t then lo = mid else hi = mid - 1 end
  end
  return rows[lo]
end

function M.from_curve(st, pos, playing)
  local row = st.curve and M.curve_row(st.curve, pos)
  if not row then
    st.m, st.s = M.SILENCE, M.SILENCE
    return false
  end
  if playing then st.m, st.s = row[2], row[3] else st.m, st.s = M.SILENCE, M.SILENCE end
  st.i = row[4]
  return true
end

-- update for one frame according to the mode; the peak always comes from REAPER
function M.update(st, mode, playing, pos, now)
  st.source = mode
  if mode == 'off' then return end
  M.read_live(st)
  if mode == 'curve' and st.curve then
    M.from_curve(st, pos, playing)
  else
    M.integrate(st, playing, pos, now)
  end
end

-- "-18.3" or "--.-" for silence, fixed width
function M.fmt(v)
  if not v or v <= -70 then return ' --.-' end
  return string.format('%5.1f', v)
end

return M
