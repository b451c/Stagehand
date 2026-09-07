-- lib/undo.lua - every project edit Stagehand makes runs inside an undo block named "Stagehand: <what>".
-- block(name, fn, ...) always closes the block, even when fn raises (the error is re-raised afterwards).

local M = {}

M.PREFIX = 'Stagehand: '

function M.block(name, fn, ...)
  reaper.Undo_BeginBlock2(0)
  local ok, a, b, c = pcall(fn, ...)
  reaper.Undo_EndBlock2(0, M.PREFIX .. tostring(name), -1)
  if not ok then error(a, 0) end
  return a, b, c
end

return M
