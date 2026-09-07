-- lib/json.lua - small JSON encoder/decoder for Lua 5.4 (REAPER). No dependencies, no globals.
--
-- encode(value, opts) -> string. Tables with keys 1..n are arrays, everything else an object with keys sorted
-- (stable output for diffs and files). opts.pretty = true indents with two spaces. Non-finite numbers become null.
-- decode(text) -> value | nil, error_message. Objects become tables, arrays become tables with 1..n, null -> nil
-- (inside arrays null keeps its slot as json.null so lengths survive a round trip).

local M = {}

M.null = setmetatable({}, { __tostring = function() return 'null' end })

local ESCAPES = { ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f', ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t' }

local function escape_string(s)
  return '"' .. s:gsub('[%c"\\]', function(c)
    return ESCAPES[c] or string.format('\\u%04x', c:byte())
  end) .. '"'
end

local function is_array(t)
  local n = #t
  if n == 0 then return next(t) == nil end
  for k in pairs(t) do
    if type(k) ~= 'number' or k < 1 or k > n or k ~= math.floor(k) then return false end
  end
  return true
end

local function sorted_keys(t)
  local keys = {}
  for k in pairs(t) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b)
    local ta, tb = type(a), type(b)
    if ta ~= tb then return ta < tb end
    return a < b
  end)
  return keys
end

local function encode_number(n)
  if n ~= n or n == math.huge or n == -math.huge then return 'null' end
  if math.type(n) == 'integer' then return tostring(n) end
  if n == math.floor(n) and math.abs(n) < 1e15 then return string.format('%d', n) end
  return string.format('%.10g', n)
end

local encode_value

local function encode_table(t, pretty, indent, out)
  if t == M.null then out[#out + 1] = 'null'; return end
  local nl = pretty and '\n' or ''
  local pad = pretty and string.rep('  ', indent + 1) or ''
  local pad0 = pretty and string.rep('  ', indent) or ''
  if is_array(t) then
    if #t == 0 then out[#out + 1] = '[]'; return end
    out[#out + 1] = '[' .. nl
    for i = 1, #t do
      out[#out + 1] = pad
      encode_value(t[i], pretty, indent + 1, out)
      out[#out + 1] = (i < #t and ',' or '') .. nl
    end
    out[#out + 1] = pad0 .. ']'
  else
    local keys = sorted_keys(t)
    if #keys == 0 then out[#out + 1] = '{}'; return end
    out[#out + 1] = '{' .. nl
    for i, k in ipairs(keys) do
      out[#out + 1] = pad .. escape_string(tostring(k)) .. (pretty and ': ' or ':')
      encode_value(t[k], pretty, indent + 1, out)
      out[#out + 1] = (i < #keys and ',' or '') .. nl
    end
    out[#out + 1] = pad0 .. '}'
  end
end

encode_value = function(v, pretty, indent, out)
  local tv = type(v)
  if tv == 'nil' then out[#out + 1] = 'null'
  elseif tv == 'boolean' then out[#out + 1] = v and 'true' or 'false'
  elseif tv == 'number' then out[#out + 1] = encode_number(v)
  elseif tv == 'string' then out[#out + 1] = escape_string(v)
  elseif tv == 'table' then encode_table(v, pretty, indent, out)
  else out[#out + 1] = escape_string(tostring(v)) end
end

function M.encode(value, opts)
  local out = {}
  encode_value(value, opts and opts.pretty, 0, out)
  return table.concat(out)
end

-- decoder ---------------------------------------------------------------------------------------------------------

local function decode_error(text, pos, msg)
  local line, col = 1, 1
  for i = 1, pos - 1 do
    if text:sub(i, i) == '\n' then line, col = line + 1, 1 else col = col + 1 end
  end
  return nil, string.format('json: %s at line %d column %d', msg, line, col)
end

local function skip_ws(text, pos)
  local _, e = text:find('^[ \t\r\n]*', pos)
  return e + 1
end

local function utf8_from_codepoint(cp)
  return utf8.char(cp)
end

local decode_value

local function decode_string(text, pos)
  local out = {}
  local i = pos + 1
  while true do
    local c = text:sub(i, i)
    if c == '' then return decode_error(text, i, 'unterminated string') end
    if c == '"' then return table.concat(out), i + 1 end
    if c == '\\' then
      local e = text:sub(i + 1, i + 1)
      if e == 'u' then
        local hex = text:sub(i + 2, i + 5)
        if not hex:match('^%x%x%x%x$') then return decode_error(text, i, 'bad unicode escape') end
        local cp = tonumber(hex, 16)
        i = i + 6
        if cp >= 0xD800 and cp <= 0xDBFF and text:sub(i, i + 1) == '\\u' then
          local lo = tonumber(text:sub(i + 2, i + 5), 16)
          if lo and lo >= 0xDC00 and lo <= 0xDFFF then
            cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
            i = i + 6
          end
        end
        out[#out + 1] = utf8_from_codepoint(cp)
      else
        local map = { ['"'] = '"', ['\\'] = '\\', ['/'] = '/', b = '\b', f = '\f', n = '\n', r = '\r', t = '\t' }
        if not map[e] then return decode_error(text, i, 'bad escape') end
        out[#out + 1] = map[e]
        i = i + 2
      end
    else
      local j = text:find('["\\]', i) or (#text + 1)
      out[#out + 1] = text:sub(i, j - 1)
      i = j
    end
  end
end

local function decode_number(text, pos)
  local s, e = text:find('^-?%d+%.?%d*[eE]?[-+]?%d*', pos)
  if not s then return decode_error(text, pos, 'bad number') end
  local str = text:sub(s, e)
  local n = tonumber(str)
  if not n then return decode_error(text, pos, 'bad number') end
  if math.type(n) == 'float' and n == math.floor(n) and not str:find('[.eE]') then n = math.tointeger(n) or n end
  return n, e + 1
end

local function decode_array(text, pos)
  local arr = {}
  pos = skip_ws(text, pos + 1)
  if text:sub(pos, pos) == ']' then return arr, pos + 1 end
  while true do
    local v, np = decode_value(text, pos)
    if v == nil and type(np) == 'string' then return nil, np end
    if v == nil then v = M.null end
    arr[#arr + 1] = v
    pos = skip_ws(text, np)
    local c = text:sub(pos, pos)
    if c == ',' then pos = skip_ws(text, pos + 1)
    elseif c == ']' then return arr, pos + 1
    else return decode_error(text, pos, 'expected , or ]') end
  end
end

local function decode_object(text, pos)
  local obj = {}
  pos = skip_ws(text, pos + 1)
  if text:sub(pos, pos) == '}' then return obj, pos + 1 end
  while true do
    if text:sub(pos, pos) ~= '"' then return decode_error(text, pos, 'expected string key') end
    local key, np = decode_string(text, pos)
    if key == nil then return nil, np end
    pos = skip_ws(text, np)
    if text:sub(pos, pos) ~= ':' then return decode_error(text, pos, 'expected :') end
    pos = skip_ws(text, pos + 1)
    local v, np2 = decode_value(text, pos)
    if v == nil and type(np2) == 'string' then return nil, np2 end
    obj[key] = v
    pos = skip_ws(text, np2)
    local c = text:sub(pos, pos)
    if c == ',' then pos = skip_ws(text, pos + 1)
    elseif c == '}' then return obj, pos + 1
    else return decode_error(text, pos, 'expected , or }') end
  end
end

decode_value = function(text, pos)
  pos = skip_ws(text, pos)
  local c = text:sub(pos, pos)
  if c == '{' then return decode_object(text, pos)
  elseif c == '[' then return decode_array(text, pos)
  elseif c == '"' then return decode_string(text, pos)
  elseif c == 't' and text:sub(pos, pos + 3) == 'true' then return true, pos + 4
  elseif c == 'f' and text:sub(pos, pos + 4) == 'false' then return false, pos + 5
  elseif c == 'n' and text:sub(pos, pos + 3) == 'null' then return nil, pos + 4
  elseif c == '-' or c:match('%d') then return decode_number(text, pos)
  end
  return decode_error(text, pos, 'unexpected character ' .. (c == '' and 'end of input' or ("'" .. c .. "'")))
end

function M.decode(text)
  if type(text) ~= 'string' then return nil, 'json: not a string' end
  local v, np = decode_value(text, 1)
  if v == nil and type(np) == 'string' then return nil, np end
  local rest = skip_ws(text, np)
  if rest <= #text then return decode_error(text, rest, 'trailing characters') end
  return v
end

return M
