-- lib/log.lua - file logger + ring buffer for the error panel + the self-test hook.
--
-- Levels: debug < info < warn < error. Lines go to <resource path>/Stagehand/stagehand.log (created on first
-- write), to a ring buffer the UI can show, and - when the harness armed ExtState Stagehand/selftest with a log
-- path - every line tagged with selftest() is appended there too. Lua 5.4; no globals.

local M = {}

local LEVELS = { debug = 1, info = 2, warn = 3, error = 4 }
local state = {
  level = 'info',
  path = nil,
  ring = {},
  ring_max = 400,
  selftest_path = reaper.GetExtState('Stagehand', 'selftest'),
  failed_open = false,
}

local function stamp()
  return os.date('%H:%M:%S')
end

local function push_ring(line)
  local ring = state.ring
  ring[#ring + 1] = line
  if #ring > state.ring_max then
    table.remove(ring, 1)
  end
end

local function append(path, line)
  local f = io.open(path, 'a')
  if not f then return false end
  f:write(line, '\n')
  f:close()
  return true
end

local function default_path()
  local dir = reaper.GetResourcePath() .. '/Stagehand'
  reaper.RecursiveCreateDirectory(dir, 0)
  return dir .. '/stagehand.log'
end

function M.set_level(level)
  if LEVELS[level] then state.level = level end
end

function M.path()
  if not state.path then state.path = default_path() end
  return state.path
end

function M.ring()
  return state.ring
end

function M.selftest_armed()
  return state.selftest_path ~= nil and state.selftest_path ~= ''
end

local function write(level, msg)
  if LEVELS[level] < LEVELS[state.level] then return end
  local line = string.format('%s %-5s %s', stamp(), level:upper(), msg)
  push_ring(line)
  if not state.failed_open and not append(M.path(), line) then
    state.failed_open = true
  end
end

function M.debug(fmt, ...) write('debug', select('#', ...) > 0 and string.format(fmt, ...) or tostring(fmt)) end
function M.info(fmt, ...) write('info', select('#', ...) > 0 and string.format(fmt, ...) or tostring(fmt)) end
function M.warn(fmt, ...) write('warn', select('#', ...) > 0 and string.format(fmt, ...) or tostring(fmt)) end
function M.error(fmt, ...) write('error', select('#', ...) > 0 and string.format(fmt, ...) or tostring(fmt)) end

-- selftest(line): one assertion/fact line for the harness; also mirrored into the normal log at info level.
function M.selftest(line)
  if M.selftest_armed() then append(state.selftest_path, line) end
  write('info', 'selftest: ' .. line)
end

return M
