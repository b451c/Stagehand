-- @noindex
-- Stagehand - Recorder: opens Stagehand on the Recorder tab (or switches the running app to it).
reaper.SetExtState('Stagehand', 'launch_tab', 'recorder', false)
reaper.SetExtState('Stagehand', 'launch_from', 'launcher', false)
local source = debug.getinfo(1, 'S').source
local script_path = source:sub(1, 1) == '@' and source:sub(2) or source
local script_dir = script_path:match('^(.*)[/\\]') or '.'
dofile(script_dir .. package.config:sub(1, 1) .. 'Stagehand.lua')
