-- lib/ctl.lua - the control protocol for external drivers.
--
-- Files in <ctl dir> (recorder.ctl.dir or <project folder>/Render/stagehand_ctl):
--   cmd        one command line written by the driver; read and deleted by poll() (every recorder.ctl.poll_frames)
--   state      append-only replies: "<time_precise> TOKEN key=value ..." (the driver greps for " TOKEN")
--   hud        the HUD bar rect, the monitor rect and the work area (logical px, y down) written on arm
--   layout.txt the layout diary (what was wanted and what REAPER did; the only way to debug a remote layout)
--   reply_N.json a JSON reply (the agent verbs, M7): the token line names it as file=reply_N.json; the last
--              REPLY_KEEP files stay, older ones are deleted
-- Verbs are registered by the modules (ctl.on('ping', fn)); dispatch(line) splits the verb from its arguments and
-- returns what the handler returned. Without a saved project there is no ctl dir: available() is false and the
-- tab shows why. A stale cmd is deleted on bind. Every token also goes to the log and, when the self-test is
-- armed, to the self-test log as "CTL TOKEN ...". Lua 5.4; no globals.

local log = require('lib.log')
local config = require('config')

local M = {}

local sep = package.config:sub(1, 1)
local handlers = {}
local S = { dir = nil, ring = {}, last_cmd = nil, last_cmd_t = nil, last_cmd_frame = nil, n_cmds = 0, n_tokens = 0, bound_for = nil }

local RING_MAX = 60
local REPLY_KEEP = 12
local json = require('lib.json')

local function project_dir()
  local _, name = reaper.EnumProjects(-1, '')
  name = name or ''
  local dir = name:match('^(.*)[/\\]')
  if not dir or dir == '' then return nil end
  return dir
end

-- the directory the protocol lives in, or nil (unsaved project and no configured dir)
function M.dir()
  local want = config.get('recorder.ctl.dir')
  if type(want) == 'string' and want ~= '' then return want end
  local pd = project_dir()
  if not pd then return nil end
  return pd .. sep .. 'Render' .. sep .. 'stagehand_ctl'
end

function M.available()
  return M.dir() ~= nil
end

function M.path(name)
  local d = M.dir()
  if not d then return nil end
  return d .. sep .. name
end

local function ensure_dir()
  local d = M.dir()
  if not d then return false end
  if d ~= S.dir then
    reaper.RecursiveCreateDirectory(d, 0)
    S.dir = d
  end
  return true
end

local function append(name, line)
  if not ensure_dir() then return false end
  local f = io.open(S.dir .. sep .. name, 'a')
  if not f then return false end
  f:write(line, '\n')
  f:close()
  return true
end

-- called on every project switch: a cmd left by a driver of another session must not fire now
function M.bind()
  local d = M.dir()
  S.dir = nil
  if d and d ~= S.bound_for then
    os.remove(d .. sep .. 'cmd')
  end
  S.bound_for = d
  S.last_cmd, S.last_cmd_t, S.last_cmd_frame = nil, nil, nil
end

-- write one reply token: write('SCROLL', '12 400 0 2000') or write('PLAY_POS', { pos = 1.234 })
function M.write(token, extra)
  local parts = { string.format('%.4f', reaper.time_precise()), token }
  if type(extra) == 'table' then
    local keys = {}
    for k in pairs(extra) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do
      local v = extra[k]
      if type(v) == 'number' then v = string.format('%.3f', v):gsub('%.?0+$', '') end
      parts[#parts + 1] = k .. '=' .. tostring(v)
    end
  elseif extra ~= nil and extra ~= '' then
    parts[#parts + 1] = tostring(extra)
  end
  local line = table.concat(parts, ' ')
  S.n_tokens = S.n_tokens + 1
  S.ring[#S.ring + 1] = line
  if #S.ring > RING_MAX then table.remove(S.ring, 1) end
  log.info('ctl > %s', line)
  if log.selftest_armed() then log.selftest('CTL ' .. line) end
  return append('state', line)
end

-- a JSON reply: the table goes to <ctl>/reply_N.json (written whole, then renamed, so a driver never reads a
-- half-written file) and the token line carries n=, file= and bytes= plus any extra keys. Returns the path or nil.
function M.reply(token, tbl, extra)
  if not ensure_dir() then
    M.write('ERROR', token .. ' no ctl folder')
    return nil
  end
  S.n_replies = (S.n_replies or 0) + 1
  local n = S.n_replies
  local name = 'reply_' .. n .. '.json'
  local path = S.dir .. sep .. name
  local text = json.encode(tbl, { pretty = true })
  local f = io.open(path .. '.tmp', 'w')
  if not f then
    M.write('ERROR', token .. ' cannot write ' .. name)
    return nil
  end
  f:write(text, '\n')
  f:close()
  os.remove(path)
  os.rename(path .. '.tmp', path)
  local old = n - REPLY_KEEP
  if old > 0 then os.remove(S.dir .. sep .. 'reply_' .. old .. '.json') end
  local kv = { n = n, file = name, bytes = #text }
  for k, v in pairs(extra or {}) do kv[k] = v end
  M.write(token, kv)
  return path
end

-- the layout diary
function M.note(fmt, ...)
  local s = select('#', ...) > 0 and string.format(fmt, ...) or tostring(fmt)
  log.info('layout %s', s)
  if log.selftest_armed() then log.selftest('LAYOUT ' .. s) end
  append('layout.txt', os.date('%H:%M:%S ') .. s)
  return s
end

-- replace the hud file: lines = { 'hud l t r b', 'monitor ...', 'work ...' }
function M.write_file(name, lines)
  if not ensure_dir() then return false end
  local f = io.open(S.dir .. sep .. name, 'w')
  if not f then return false end
  f:write(table.concat(lines, '\n'), '\n')
  f:close()
  return true
end

function M.clear_state()
  if not ensure_dir() then return false end
  local f = io.open(S.dir .. sep .. 'state', 'w')
  if f then f:close() end
  S.ring = {}
  return true
end

-- verbs -----------------------------------------------------------------------------------------------------------

function M.on(verb, fn)
  handlers[verb] = fn
end

function M.handler(verb)
  return handlers[verb]
end

function M.verbs()
  local out = {}
  for v in pairs(handlers) do out[#out + 1] = v end
  table.sort(out)
  return out
end

-- runs a command line; returns true when a handler took it
function M.dispatch(line, frame)
  line = tostring(line or ''):match('^%s*(.-)%s*$')
  if line == '' then return false end
  local verb, args = line:match('^(%S+)%s*(.*)$')
  S.last_cmd, S.last_cmd_t, S.last_cmd_frame = line, reaper.time_precise(), frame
  S.n_cmds = S.n_cmds + 1
  local fn = handlers[verb]
  if not fn then
    M.write('UNKNOWN', line)
    return false
  end
  local ok, err = pcall(fn, args, line)
  if not ok then
    log.error('ctl handler %s failed: %s', verb, tostring(err))
    M.write('ERROR', verb .. ' ' .. tostring(err))
    return false
  end
  return true
end

-- read and delete the cmd file; returns the line or nil
function M.read_cmd()
  local p = M.path('cmd')
  if not p then return nil end
  local f = io.open(p, 'r')
  if not f then return nil end
  local text = f:read('a') or ''
  f:close()
  os.remove(p)
  local line = text:match('^%s*(.-)%s*$'):match('^[^\r\n]*')
  if line == '' then return nil end
  return line
end

-- one poll: at most one command per call
function M.poll(frame)
  local line = M.read_cmd()
  if not line then return false end
  log.info('ctl < %s', line)
  return M.dispatch(line, frame)
end

function M.status()
  return S
end

function M.ring()
  return S.ring
end

return M
