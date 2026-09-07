-- lib/match.lua - the one rule matcher used by family chips and marker classes.
--
-- A rule is a string of tokens separated by "|". Matching is case-insensitive on the whole name:
--   TOKEN     the name contains TOKEN anywhere
--   ^TOKEN    the name starts with TOKEN
--   =TOKEN    the name equals TOKEN
-- Empty rules match nothing. compile(rule) returns a predicate; test(rule, name) is the one-shot form.

local M = {}

local function split(rule)
  local tokens = {}
  for tok in tostring(rule or ''):gmatch('[^|]+') do
    tok = tok:gsub('^%s+', ''):gsub('%s+$', '')
    if tok ~= '' then tokens[#tokens + 1] = tok end
  end
  return tokens
end

function M.compile(rule)
  local tests = {}
  for _, tok in ipairs(split(rule)) do
    local mode, body = tok:sub(1, 1), tok:sub(2)
    if mode == '^' and body ~= '' then
      body = body:lower()
      tests[#tests + 1] = function(n) return n:sub(1, #body) == body end
    elseif mode == '=' and body ~= '' then
      body = body:lower()
      tests[#tests + 1] = function(n) return n == body end
    else
      local t = tok:lower()
      tests[#tests + 1] = function(n) return n:find(t, 1, true) ~= nil end
    end
  end
  if #tests == 0 then return function() return false end end
  return function(name)
    local n = tostring(name or ''):lower()
    for _, f in ipairs(tests) do
      if f(n) then return true end
    end
    return false
  end
end

function M.test(rule, name)
  return M.compile(rule)(name)
end

-- describe a rule in words for tooltips
function M.describe(rule)
  local parts = {}
  for _, tok in ipairs(split(rule)) do
    local mode, body = tok:sub(1, 1), tok:sub(2)
    if mode == '^' then parts[#parts + 1] = 'starts with "' .. body .. '"'
    elseif mode == '=' then parts[#parts + 1] = 'is "' .. body .. '"'
    else parts[#parts + 1] = 'contains "' .. tok .. '"' end
  end
  if #parts == 0 then return 'matches nothing' end
  return table.concat(parts, ' or ')
end

return M
