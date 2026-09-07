-- ui/imgui.lua - loads the ReaImGui API in one of two styles and returns a uniform table.
--
-- Preferred: the shim shipped with ReaImGui (`imgui.lua` next to the extension, present on ReaPack installs)
--   package.path = reaper.ImGui_GetBuiltinPath() .. '/?.lua'; local ImGui = require 'imgui' '0.10'
-- Fallback: a metatable over the reaper.ImGui_* functions (present when the binary was copied by hand, e.g. on
-- a test leg). Constants (Cond_*, Col_*, WindowFlags_* ...) are functions in the classic API; the fallback calls
-- them once and caches the number, so `ImGui.Cond_FirstUseEver` reads the same in both styles.
--
-- load() returns nil + a user-facing message when ReaImGui is missing or too old. Lua 5.4.

local M = {}

local MIN_MAJOR, MIN_MINOR = 0, 10

-- prefixes of the classic API names that denote enum constants (function taking no argument, returning a number)
local CONST_PREFIX = {
  ButtonFlags = true, ChildFlags = true, Col = true, ColorEditFlags = true, ComboFlags = true, Cond = true,
  ConfigFlags = true, ConfigVar = true, Dir = true, DockNodeFlags = true, DragDropFlags = true, DrawFlags = true,
  DrawListFlags = true, FocusedFlags = true, FontFlags = true, HoveredFlags = true, InputFlags = true,
  InputTextFlags = true, Key = true, Mod = true, MouseButton = true, MouseCursor = true, PopupFlags = true,
  SelectableFlags = true, SliderFlags = true, SortDirection = true, StyleVar = true, TabBarFlags = true,
  TabItemFlags = true, TableBgTarget = true, TableColumnFlags = true, TableFlags = true, TableRowFlags = true,
  TreeNodeFlags = true, WindowFlags = true,
}

local function file_exists(path)
  local f = io.open(path, 'r')
  if f then f:close(); return true end
  return false
end

local function classic_table()
  return setmetatable({}, {
    __index = function(t, key)
      local f = reaper['ImGui_' .. key]
      if not f then
        error('ReaImGui function missing: ImGui_' .. tostring(key), 2)
      end
      local value = f
      local prefix = key:match('^(%w-)_')
      if prefix and CONST_PREFIX[prefix] then value = f() end
      rawset(t, key, value)
      return value
    end,
  })
end

-- returns ImGui, info | nil, message
function M.load()
  if not reaper.ImGui_GetVersion then
    return nil, 'ReaImGui is not installed. Install "ReaImGui: ReaScript binding for Dear ImGui" through ReaPack '
      .. '(Extensions > ReaPack > Browse packages), then run Stagehand again.'
  end
  local imgui_version, imgui_version_num, reaimgui_version = reaper.ImGui_GetVersion()
  local major, minor = reaimgui_version:match('^(%d+)%.(%d+)')
  major, minor = tonumber(major) or 0, tonumber(minor) or 0
  if major < MIN_MAJOR or (major == MIN_MAJOR and minor < MIN_MINOR) then
    return nil, string.format('Stagehand needs ReaImGui %d.%d or newer; found %s. Update it through ReaPack.',
      MIN_MAJOR, MIN_MINOR, tostring(reaimgui_version))
  end
  local info = {
    imgui_version = imgui_version, imgui_version_num = imgui_version_num, reaimgui_version = reaimgui_version,
    builtin_path = reaper.ImGui_GetBuiltinPath and reaper.ImGui_GetBuiltinPath() or '',
    style = 'classic', shim_present = false,
  }
  info.shim_present = info.builtin_path ~= '' and file_exists(info.builtin_path .. '/imgui.lua')
  if info.shim_present then
    local ok, mod = pcall(function()
      package.path = info.builtin_path .. '/?.lua;' .. package.path
      return require('imgui')(string.format('%d.%d', MIN_MAJOR, MIN_MINOR))
    end)
    if ok and type(mod) == 'table' then
      info.style = 'modern'
      return mod, info
    end
    info.shim_error = tostring(mod)
  end
  return classic_table(), info
end

return M
