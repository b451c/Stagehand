-- lib/text.lua - string helpers: time formatting, UTF-8 safe truncation, trimming. Lua 5.4, no globals.

local M = {}

-- 0:07.25 style (minutes:seconds.hundredths); negative times keep their sign
function M.fmt_time(t)
  t = t or 0
  local sign = ''
  if t < 0 then sign = '-'; t = -t end
  local m = math.floor(t / 60)
  local s = t - m * 60
  return string.format('%s%d:%05.2f', sign, m, s)
end

-- h:mm:ss.cc for long projects (used in tooltips)
function M.fmt_time_long(t)
  t = t or 0
  local h = math.floor(t / 3600)
  local m = math.floor((t - h * 3600) / 60)
  local s = t - h * 3600 - m * 60
  if h > 0 then return string.format('%d:%02d:%05.2f', h, m, s) end
  return string.format('%d:%05.2f', m, s)
end

function M.trim(s)
  return (tostring(s or ''):gsub('^%s+', ''):gsub('%s+$', ''))
end

-- byte index of the last character start at or before byte position n (never splits a multi-byte sequence)
function M.utf8_cut(s, n)
  if n >= #s then return #s end
  if n < 1 then return 0 end
  while n > 1 do
    local b = s:byte(n + 1)
    if not b or b < 0x80 or b >= 0xC0 then break end
    n = n - 1
  end
  return n
end

-- shorten s so that measure(candidate) <= max_w; ellipsis is ASCII "..." (always renders). Bounded loop.
function M.fit(s, max_w, measure)
  if measure(s) <= max_w then return s, false end
  local n = #s
  local guard = 0
  while n > 0 and guard < 4096 do
    guard = guard + 1
    n = M.utf8_cut(s, n - 1)
    local candidate = s:sub(1, n) .. '...'
    if measure(candidate) <= max_w then return candidate, true end
  end
  return '...', true
end

function M.first_line(s)
  return (tostring(s or ''):match('^[^\r\n]*')) or ''
end

function M.lower(s)
  return tostring(s or ''):lower()
end

function M.plural(n, one, many)
  if n == 1 then return string.format('%d %s', n, one) end
  return string.format('%d %s', n, many or (one .. 's'))
end

return M
