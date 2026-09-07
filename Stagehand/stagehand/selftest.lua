-- selftest.lua - the scripted-scenario runner used by the test harness.
--
-- Armed when ExtState Stagehand/selftest holds a log path. ExtState Stagehand/selftest_module names the module
-- whose selftest(T) scenario runs (empty = facts only); selftest_variant / selftest_sabotage are passed to the
-- scenario through T. ExtState Stagehand/selftest_scenario names a scenario FILE instead (a chunk returning
-- function(T, app)) for scenarios that span modules and live in tests/. The scenario is a coroutine resumed once per frame: T.wait(n) and T.wait_until(fn) yield
-- between frames so transport and layout can settle. Every assertion writes one line: PASS name got=... or
-- FAIL name expected=... got=...; an error ends the run with ERROR + SELFTEST ABORTED (written by app.lua);
-- otherwise SELFTEST SUMMARY and SELFTEST DONE close the log. Lua 5.4; no globals.

local log = require('lib.log')

local M = {}

local START_FRAME = 8

local R = { armed = false, module_name = '', variant = '', sabotage = '', co = nil, started = false, done = false,
  done_frame = nil, checks = 0, failures = 0, log_dir = '', app = nil }

local T = {}

function T.log(s)
  log.selftest(s)
end

function T.fact(key, value)
  log.selftest('FACT ' .. tostring(key) .. '=' .. tostring(value))
end

local function same(got, expected, tol)
  if type(got) == 'number' and type(expected) == 'number' then
    return math.abs(got - expected) <= (tol or 1e-9)
  end
  return got == expected
end

-- check(name, got, expected [, tol]) -> boolean
function T.check(name, got, expected, tol)
  R.checks = R.checks + 1
  if same(got, expected, tol) then
    log.selftest(string.format('PASS %s got=%s', name, tostring(got)))
    return true
  end
  R.failures = R.failures + 1
  log.selftest(string.format('FAIL %s expected=%s got=%s', name, tostring(expected), tostring(got)))
  return false
end

function T.ok(name, cond, detail)
  R.checks = R.checks + 1
  if cond then
    log.selftest(string.format('PASS %s%s', name, detail and (' ' .. tostring(detail)) or ''))
    return true
  end
  R.failures = R.failures + 1
  log.selftest(string.format('FAIL %s%s', name, detail and (' ' .. tostring(detail)) or ''))
  return false
end

function T.wait(n)
  for _ = 1, n or 1 do coroutine.yield() end
end

-- returns true when fn() became true within max_frames
function T.wait_until(fn, max_frames, name)
  for _ = 1, max_frames or 300 do
    if fn() then return true end
    coroutine.yield()
  end
  if name then T.ok(name, false, 'timeout after ' .. tostring(max_frames) .. ' frames') end
  return false
end

function T.out_path(name)
  local sep = package.config:sub(1, 1)
  return R.log_dir .. sep .. name
end

function T.frame()
  return R.app and R.app.frame or 0
end

function T.app()
  return R.app
end

function T.failures()
  return R.failures
end

function M.init(app)
  R.app = app
  R.armed = log.selftest_armed()
  if not R.armed then return end
  R.module_name = reaper.GetExtState('Stagehand', 'selftest_module') or ''
  R.variant = reaper.GetExtState('Stagehand', 'selftest_variant') or ''
  R.sabotage = reaper.GetExtState('Stagehand', 'selftest_sabotage') or ''
  local p = reaper.GetExtState('Stagehand', 'selftest')
  R.log_dir = p:match('^(.*)[/\\]') or '.'
  T.variant, T.sabotage = R.variant, R.sabotage
  log.info('selftest armed: module=%s variant=%s sabotage=%s', R.module_name, R.variant, R.sabotage)
end

function M.armed()
  return R.armed
end

function M.done()
  return R.done
end

-- a scenario FILE (ExtState Stagehand/selftest_scenario = path): a Lua chunk returning function(T, app), used by
-- cross-module scenarios that live outside the package (the demo tour); the module named by
-- selftest_module still owns the screenshots after DONE (selftest_post)
local function scenario_from_file(app, path)
  local chunk, err = loadfile(path)
  if not chunk then
    return function(t) t.ok('scenario file loads', false, tostring(err)) end
  end
  local ok, fn = pcall(chunk)
  if not ok or type(fn) ~= 'function' then
    return function(t) t.ok('scenario file returns a function', false, tostring(ok and fn or fn)) end
  end
  return function(t)
    fn(t, app)
    app.selftest_facts(t)
  end
end

local function scenario_for(app)
  local file = reaper.GetExtState('Stagehand', 'selftest_scenario') or ''
  if file ~= '' then
    log.info('selftest scenario file: %s', file)
    return scenario_from_file(app, file)
  end
  if R.module_name == '' then
    return function(t) app.selftest_facts(t) end
  end
  local m = app.by_name[R.module_name]
  if m and m.selftest then
    return function(t)
      m.selftest(t)
      app.selftest_facts(t)
    end
  end
  return function(t)
    t.ok('selftest module known', false, 'no module named ' .. tostring(R.module_name))
  end
end

function M.tick(app)
  if not R.armed or R.done then return end
  if not R.started then
    if app.frame < START_FRAME then return end
    R.started = true
    R.co = coroutine.create(scenario_for(app))
  end
  local ok, err = coroutine.resume(R.co, T)
  if not ok then
    R.done = true   -- the scenario is dead: the app reports the error once, never resumes it again
    R.done_frame = app.frame
    error(debug.traceback(R.co, tostring(err)), 0)
  end
  if coroutine.status(R.co) == 'dead' then
    R.done = true
    R.done_frame = app.frame
    log.selftest(string.format('SELFTEST SUMMARY checks=%d failures=%d', R.checks, R.failures))
    log.selftest('SELFTEST DONE')
  end
end

-- after DONE: let the module drive the window for the harness screenshots
function M.post(app)
  if not R.done then return end
  local m = app.by_name[R.module_name]
  if m and m.selftest_post then m.selftest_post(app.frame - R.done_frame) end
end

return M
