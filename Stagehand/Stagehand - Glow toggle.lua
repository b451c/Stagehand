-- @noindex
-- Stagehand - Glow toggle: switches the glow overlay on or off in the running app (give it a shortcut);
-- when Stagehand is not running it opens the app on the Glow tab with the overlay as configured.
reaper.SetExtState('Stagehand', 'launch_tab', 'glow', false)
reaper.SetExtState('Stagehand', 'command', 'glow_toggle', false)
reaper.SetExtState('Stagehand', 'launch_from', 'launcher', false)
local source = debug.getinfo(1, 'S').source
local script_path = source:sub(1, 1) == '@' and source:sub(2) or source
local script_dir = script_path:match('^(.*)[/\\]') or '.'
dofile(script_dir .. package.config:sub(1, 1) .. 'Stagehand.lua')
