-- lib/wav.lua - a small RIFF/WAVE reader for the Stems results page: the header (format, channels, sample rate,
-- bit depth, frames, duration) and an optional bounded peak scan (PCM 16 / 24 / 32 and float 32). Used when
-- REAPER's render statistics do not cover a file (a format REAPER does not report, or a file written by another
-- tool) and by the self-test as an independent oracle. Nothing here depends on REAPER. Lua 5.4; no globals.

local M = {}

-- info(path [, scan_samples]) -> { fmt, ch, srate, bits, frames, seconds, bytes, peak_db (when scanned) } or nil, err
-- scan_samples: the peak scan reads at most this many samples spread over the file (0 / nil = no scan)
function M.info(path, scan_samples)
  local f = io.open(path, 'rb')
  if not f then return nil, 'cannot open' end
  local head = f:read(12)
  if not head or #head < 12 or head:sub(1, 4) ~= 'RIFF' or head:sub(9, 12) ~= 'WAVE' then
    f:close()
    return nil, 'not a RIFF/WAVE file'
  end
  local info = { bytes = f:seek('end') }
  f:seek('set', 12)
  while true do
    local ch = f:read(8)
    if not ch or #ch < 8 then break end
    local id, size = ch:sub(1, 4), string.unpack('<I4', ch, 5)
    if id == 'fmt ' then
      local d = f:read(size) or ''
      if #d >= 16 then
        info.fmt = string.unpack('<I2', d, 1)
        info.ch = string.unpack('<I2', d, 3)
        info.srate = string.unpack('<I4', d, 5)
        info.bits = string.unpack('<I2', d, 15)
        if info.fmt == 0xFFFE and #d >= 26 then info.fmt = string.unpack('<I2', d, 25) end   -- WAVE_FORMAT_EXTENSIBLE: the sub-format
      end
      if size % 2 == 1 then f:seek('cur', 1) end
    elseif id == 'data' then
      local bps = math.max(1, (info.bits or 16) // 8)
      local chn = math.max(1, info.ch or 1)
      info.data_size = size
      info.frames = size // (bps * chn)
      info.seconds = info.srate and info.srate > 0 and info.frames / info.srate or 0
      if scan_samples and scan_samples > 0 and size > 0 then
        info.peak_db = M.scan_peak(f, size, bps, info.fmt, scan_samples)
      end
      break
    else
      f:seek('cur', size + (size % 2))
    end
  end
  f:close()
  if not info.frames then return nil, 'no data chunk' end
  return info
end

-- reads at most `budget` samples spread over the data chunk (the file is positioned at its start)
function M.scan_peak(f, size, bps, fmt, budget)
  local n = size // bps
  if n == 0 then return -144 end
  local step = math.max(1, n // budget)
  local peak = 0
  local CHUNK = 65536
  local start = f:seek('cur')
  if step == 1 then
    local left = size
    while left > 0 do
      local data = f:read(math.min(CHUNK, left))
      if not data then break end
      left = left - #data
      local cnt = #data // bps
      for i = 0, cnt - 1 do
        local pos = i * bps + 1
        local v
        if fmt == 3 then v = string.unpack('<f', data, pos)
        elseif bps == 2 then v = string.unpack('<i2', data, pos) / 32768
        elseif bps == 3 then
          local b1, b2, b3 = data:byte(pos, pos + 2)
          local x = b1 + b2 * 256 + b3 * 65536
          if x >= 8388608 then x = x - 16777216 end
          v = x / 8388608
        else v = string.unpack('<i4', data, pos) / 2147483648 end
        if v < 0 then v = -v end
        if v > peak then peak = v end
      end
    end
  else
    for i = 0, n - 1, step do
      f:seek('set', start + i * bps)
      local s = f:read(bps)
      if not s or #s < bps then break end
      local v
      if fmt == 3 then v = string.unpack('<f', s, 1)
      elseif bps == 2 then v = string.unpack('<i2', s, 1) / 32768
      elseif bps == 3 then
        local b1, b2, b3 = s:byte(1, 3)
        local x = b1 + b2 * 256 + b3 * 65536
        if x >= 8388608 then x = x - 16777216 end
        v = x / 8388608
      else v = string.unpack('<i4', s, 1) / 2147483648 end
      if v < 0 then v = -v end
      if v > peak then peak = v end
    end
  end
  if peak <= 0 then return -144 end
  return 20 * math.log(peak, 10)
end

-- incremental peak scan for a coroutine: sc = M.scanner(path); repeat sc.step(bytes) per frame until it returns
-- true; sc.info holds the header, sc.peak_db() the exact sample peak over every sample read so far
function M.scanner(path)
  local info, err = M.info(path)
  if not info then return nil, err end
  local f = io.open(path, 'rb')
  if not f then return nil, 'cannot open' end
  -- find the data chunk start again
  f:seek('set', 12)
  local data_start, data_size
  while true do
    local ch = f:read(8)
    if not ch or #ch < 8 then break end
    local id, size = ch:sub(1, 4), string.unpack('<I4', ch, 5)
    if id == 'data' then
      data_start, data_size = f:seek('cur'), size
      break
    end
    f:seek('cur', size + (size % 2))
  end
  if not data_start then f:close(); return nil, 'no data chunk' end
  local bps = math.max(1, (info.bits or 16) // 8)
  local fmt = info.fmt
  local sc = { info = info, left = data_size, peak = 0, read = 0, done = data_size == 0 }
  if sc.done then f:close() end
  function sc.step(max_bytes)
    if sc.done then return true end
    local want = math.min(max_bytes or 262144, sc.left)
    want = want - (want % bps)
    local data = want > 0 and f:read(want) or nil
    if not data or #data == 0 then
      sc.done = true
      f:close()
      return true
    end
    sc.left = sc.left - #data
    sc.read = sc.read + #data
    local peak = sc.peak
    local cnt = #data // bps
    if fmt == 3 then
      for i = 0, cnt - 1 do
        local v = string.unpack('<f', data, i * 4 + 1)
        if v < 0 then v = -v end
        if v > peak then peak = v end
      end
    elseif bps == 2 then
      for i = 0, cnt - 1 do
        local v = string.unpack('<i2', data, i * 2 + 1)
        if v < 0 then v = -v end
        if v > peak then peak = v end
      end
      sc.scale = 32768
    elseif bps == 3 then
      for i = 0, cnt - 1 do
        local pos = i * 3 + 1
        local b1, b2, b3 = data:byte(pos, pos + 2)
        local v = b1 + b2 * 256 + b3 * 65536
        if v >= 8388608 then v = 16777216 - v end
        if v > peak then peak = v end
      end
      sc.scale = 8388608
    else
      for i = 0, cnt - 1 do
        local v = string.unpack('<i4', data, i * 4 + 1)
        if v < 0 then v = -v end
        if v > peak then peak = v end
      end
      sc.scale = 2147483648
    end
    sc.peak = peak
    if sc.left <= 0 then
      sc.done = true
      f:close()
    end
    return sc.done
  end
  function sc.peak_db()
    local p = sc.peak / (sc.scale or 1)
    if p <= 0 then return -144 end
    return 20 * math.log(p, 10)
  end
  function sc.close()
    if not sc.done then
      sc.done = true
      f:close()
    end
  end
  return sc
end

return M
