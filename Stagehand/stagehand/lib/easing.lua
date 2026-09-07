-- lib/easing.lua - easing curves for the arrange zoom animation (docs/architecture.md, motion tokens).
-- Every function maps progress p in [0, 1] to [0, 1]; get(name) returns a curve by its settings name
-- (smoothstep | linear | ease_out), smoothstep when the name is unknown. Lua 5.4; no globals.

local M = {}

function M.clamp01(p)
  if p < 0 then return 0 elseif p > 1 then return 1 end
  return p
end

function M.linear(p)
  return M.clamp01(p)
end

function M.smoothstep(p)
  p = M.clamp01(p)
  return p * p * (3 - 2 * p)
end

function M.ease_out(p)
  p = M.clamp01(p)
  local q = 1 - p
  return 1 - q * q * q
end

M.NAMES = { 'smoothstep', 'linear', 'ease_out' }

function M.get(name)
  local f = M[name]
  if type(f) == 'function' and name ~= 'get' and name ~= 'clamp01' then return f end
  return M.smoothstep
end

-- a + (b - a) * eased(p)
function M.lerp(a, b, p, curve)
  return a + (b - a) * (curve or M.smoothstep)(p)
end

return M
