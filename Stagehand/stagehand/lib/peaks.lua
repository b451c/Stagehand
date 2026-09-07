-- lib/peaks.lua - the raw source level of an item under the play head from the take peaks
-- (GetMediaItemTake_Peaks at 400 Hz): cheap, exact to the peak file, and free of REAPER's meter ballistics,
-- which smear fast transients (a four-shot burst gave one or two onsets on the meter). take_db(it, take, pos,
-- dt) -> dB, time of the maximum inside [pos - dt, pos] | nil when the take has no peaks (MIDI, video, offline
-- media). The item volume, the take volume and the fades are applied. One reusable reaper.array holds the
-- maximum and minimum blocks. Lua 5.4; no globals.

local M = {}

M.RATE = 400
local MAXN = 512
local buf = nil

local function buffer()
  if not buf then buf = reaper.new_array(MAXN * 2) end
  buf.clear()
  return buf
end

function M.take_db(it, take, pos, dt)
  take = take or reaper.GetActiveTake(it)
  if not take or reaper.TakeIsMIDI(take) then return nil end
  local p = reaper.GetMediaItemInfo_Value(it, 'D_POSITION')
  local len = reaper.GetMediaItemInfo_Value(it, 'D_LENGTH')
  local t0 = math.max(p, pos - dt)
  local t1 = math.min(p + len, pos)
  if t1 <= t0 then return nil end
  local n = math.ceil((t1 - t0) * M.RATE) + 1
  if n < 2 then n = 2 end
  if n > MAXN then n = MAXN end
  local b = buffer()
  local ret = reaper.GetMediaItemTake_Peaks(take, M.RATE, t0, 1, n, 0, b)
  local got = (ret or 0) & 0xFFFFF   -- nil while REAPER still builds the peak file
  if got <= 0 then return nil end
  local pk, at = 0, t0
  for i = 1, got do
    local v = b[i] or 0
    if v < 0 then v = -v end
    local w = b[n + i] or 0
    if w < 0 then w = -w end
    if w > v then v = w end
    if v > pk then
      pk = v
      at = t0 + (i - 1) / M.RATE
    end
  end
  local vol = reaper.GetMediaItemInfo_Value(it, 'D_VOL') * reaper.GetMediaItemTakeInfo_Value(take, 'D_VOL')
  if vol < 0 then vol = -vol end
  local fi = reaper.GetMediaItemInfo_Value(it, 'D_FADEINLEN')
  local fo = reaper.GetMediaItemInfo_Value(it, 'D_FADEOUTLEN')
  local fg = 1
  if fi > 0 and pos - p < fi then fg = fg * math.max(0, (pos - p) / fi) end
  if fo > 0 and p + len - pos < fo then fg = fg * math.max(0, (p + len - pos) / fo) end
  pk = pk * vol * fg
  if pk <= 1e-5 then return -100, at end
  return 20 * math.log(pk, 10), at
end

function M.buffer()
  return buffer()
end

-- true when the take can deliver peaks right now (media online); used by the self-test facts
function M.available(it)
  local take = reaper.GetActiveTake(it)
  if not take or reaper.TakeIsMIDI(take) then return false end
  local p = reaper.GetMediaItemInfo_Value(it, 'D_POSITION')
  local b = buffer()
  local ret = reaper.GetMediaItemTake_Peaks(take, M.RATE, p, 1, 4, 0, b)
  return ((ret or 0) & 0xFFFFF) > 0
end

return M
