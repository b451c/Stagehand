-- i18n.lua - every user-facing string goes through t(key, ...). English is the only table shipped (lang/en.lua);
-- another language is a second table with the same keys. A missing key returns the key itself so nothing
-- crashes, and is logged once. Lua 5.4; no globals.

local log = require('lib.log')

local M = {}

local tables = { en = require('lang.en') }
local current = 'en'
local reported = {}

function M.set_language(code)
  if tables[code] then current = code end
end

function M.t(key, ...)
  local s = tables[current][key] or tables.en[key]
  if not s then
    if not reported[key] then
      reported[key] = true
      log.warn('i18n: missing string "%s"', tostring(key))
    end
    s = tostring(key)
  end
  if select('#', ...) > 0 then return string.format(s, ...) end
  return s
end

function M.has(key)
  return tables[current][key] ~= nil
end

return M
