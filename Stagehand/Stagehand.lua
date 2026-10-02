-- @description Stagehand - session navigator, showcase director, stem delivery and session overview
-- @version 1.0.2
-- @author Bartosz Sroczynski (falami.studio)
-- @provides
--   [main] Stagehand.lua
--   [main] Stagehand - Navigator.lua
--   [main] Stagehand - Director.lua
--   [main] Stagehand - HUD.lua
--   [main] Stagehand - Glow toggle.lua
--   [main] Stagehand - Settings.lua
--   [main] Stagehand - Overview.lua
--   [main] Stagehand - Recorder.lua
--   [main] Stagehand - Stems.lua
--   [main] Stagehand - Agent.lua
--   stagehand/**/*.lua
--   stagehand/presets/*.json
--   agent/stagehand_mcp.py
--   agent/skills/stagehand/SKILL.md
-- @link falami.studio https://falami.studio
-- @link Repository https://github.com/b451c/Stagehand
-- @link User guide https://b451c.github.io/Stagehand/guide.html
-- @about
--   # Stagehand for REAPER
--
--   Session navigator, showcase director, stem delivery and session overview in one package. Navigate a large
--   session (scenes, markers, tracks, items, audition in place, scene solo/mute with exact restore), direct a
--   showcase recording (the arrange follows playback with the right lanes, zoom, glow and captions), deliver stems
--   (stem sets in bulk from the session structure, a matrix editor, render settings owned by Stagehand, a
--   sequential renderer with a pre-flight and a results page with peak and loudness) and capture a one-image
--   overview of the whole session. Everything is configurable in one Settings window with presets and per-project
--   overrides.
--
--   Requires ReaImGui (ReaTeam Extensions repository, install it through ReaPack). js_ReaScriptAPI unlocks the glow
--   overlay, the screen layout and the overview geometry. An AI agent (Claude and the like) can read the session
--   and drive Stagehand through the bundled MCP server once you switch agent access on in the Agent tab (off by
--   default). A falami.studio product, MIT licence. User guide: https://b451c.github.io/Stagehand/guide.html
--
--   Stagehand is free and open source. If it earns its place in your sessions, consider supporting its
--   development: Ko-fi https://ko-fi.com/quickmd - Buy Me a Coffee https://buymeacoffee.com/bsroczynskh -
--   PayPal https://paypal.me/b451c
-- @changelog
--   1.0.2 - agent access is off by default and the switches apply to AI agents only (everything the MCP server sends);
--   put-back verbs always work, an agent can no longer change the switches, the raw tool never renders. Stems: a batch
--   keeps the media online when REAPER is not the active app (renders were silent with REAPER's offline-when-inactive
--   preference), bulk add keeps the names (no " 2"). macOS: overview capture, recorder layout and the stems matrix
--   work with REAPER on any display. Director: Start run switches auto-follow on. Overview: Done in guided capture
--   restores the layout. Glow reacts to family rule edits; hud.show_progress works; protocol values with spaces are
--   quoted; ReaImGui child windows closed only when opened; documentation corrected.
--   1.0.1 - agent access: the shot list can be written through the protocol (director shots set / add / update / remove /
--   clear / from_scenes) and the MCP tool stagehand_shots_set; the About tab and the log show the package version (1.0.0
--   reported 0.1.0-dev); the Pages root redirects to the guide.
--   1.0.0 - first release. Navigator: scenes, markers, tracks, items, fuzzy search, jump, audition with auto-stop,
--   scene solo / mute with an exact restore, families, focus, groups. Director: shot list with validation, follow-play
--   (lanes at locked heights filling the arrange, pinned rows, parents, envelope story mode, page / follow view with
--   eased zoom), rehearsal controls, full restore. HUD: dockable caption bar with progress, time, loudness live or from
--   a curve, sync flashes for the recorder. Glow: overlay that lights the arrange with the sound (meter / item modes,
--   bar / fill / edge, sparks from take peaks, profiles per family, cut flash, bus band, performance guard). Settings:
--   every knob from one schema with search, tooltips, live preview, this project / global layers, presets, invalid
--   values reported and never repaired in silence. Overview: one tall picture of the session (journaled layout, a
--   companion that scrolls, captures and stitches, a guided mode for any screenshot tool). Recorder: control protocol
--   for the companion drivers, arm / play / stop, checklist, screen layout at start, shot-list export. Stems: stem
--   sets in bulk (families, folders, selection, scenes), matrix editor, presets, Stagehand-owned render settings with
--   wildcards and variants, a sequential renderer with a pre-flight that defuses every blocking dialog, results with
--   peak and loudness. Agent access: the control protocol answers agent verbs with JSON, an MCP server and a skill
--   ship in the package, three switches gate every change. Verified on Linux, Windows and macOS test machines.

-- Bootstrap: resolve the package folder from this file's own path, put the code folder on package.path and
-- hand over to stagehand/app.lua. Everything that can fail before ReaImGui is available reports through a plain
-- message box so the user always learns what is missing.
local source = debug.getinfo(1, 'S').source
local script_path = source:sub(1, 1) == '@' and source:sub(2) or source
local script_dir = script_path:match('^(.*)[/\\]') or '.'
local sep = package.config:sub(1, 1)
package.path = table.concat({
  script_dir .. sep .. 'stagehand' .. sep .. '?.lua',
  script_dir .. sep .. 'stagehand' .. sep .. '?' .. sep .. 'init.lua',
  package.path,
}, ';')

local ok, app = pcall(require, 'app')
if not ok then
  reaper.MB('Stagehand could not load its code from\n' .. script_dir .. sep .. 'stagehand\n\n' .. tostring(app),
    'Stagehand', 0)
  return
end

local from_launcher = reaper.GetExtState('Stagehand', 'launch_from') == 'launcher'
reaper.DeleteExtState('Stagehand', 'launch_from', false)
app.run({ script_dir = script_dir, from_launcher = from_launcher, modules = { 'modules.navigator', 'modules.director', 'modules.hud', 'modules.glow', 'modules.overview', 'modules.recorder', 'modules.stems', 'modules.agent', 'modules.settings' } })
