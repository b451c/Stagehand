# Changelog

All notable changes to Stagehand for REAPER. Format: Keep a Changelog; versions follow semantic versioning.

## 1.0.2 - 2026-10-02

- **Agent access** is off by default (Agent access, Allow changes, Allow renders), as the announcement said. The
  switches apply to AI agents: everything the MCP server sends. The companion tools you start yourself (recorder,
  overview capture, stems checker) are not affected. With Agent access on, the put-back verbs always work (nav clear /
  restore, director stop / validate, the stop commands); an agent can read but never change the switches; the raw tool
  never starts a render and refuses `config set agent.*`.
- **Stems**: a batch keeps the media online when REAPER is not the active app. With REAPER's preference "Set media items
  offline when application is not active" a batch started from another app (an agent in a terminal) rendered silence;
  the pre-flight now shows the preference, the batch switches it off (SWS) and puts it back after, and a silent result
  names offline media as the likely cause. Bulk add (one stem per family / folder / scene) no longer appends " 2" to
  every name. An aborted batch puts REAPER's render-statistics preference back.
- **macOS with more than one display**: the overview capture crop, the recorder's window layout and video placement and
  the stems matrix dialog used two different coordinate systems and went wrong with REAPER on a display above or below
  the main one; one conversion now covers them. Rect replies, the hud file and `vid` are screen pixels, y down.
- **Director**: Start run switches auto-follow on (a row preview still pauses it).
- **Overview**: Done on the last page of a guided capture restores the layout the capture applied.
- **Glow** reacts to edits of the family rules and marker classes; **HUD** honours `hud.show_progress`.
- **Control protocol**: values that contain spaces or quotes are written as `key="..."` (results paths with spaces broke
  the stems checker).
- ReaImGui: child windows are closed only when they opened (avoids an error in very small docked windows).
- The Navigator's and the Settings' search fields no longer share a text buffer.
- Documentation: the full list of MCP tools, the ReaImGui install note (it is not a declared dependency), Glow's Edge
  outline and slider counts, guided capture, the offline-media row, and a few stale notes.

## 1.0.1 - 2026-09-10

- Agent access: the shot list can be written through the protocol (`director shots set | add | update | remove | clear |
  from_scenes`) and the MCP tool `stagehand_shots_set`, so an agent can set up a whole showcase from a description.
- The About tab, the window title line and the log show the package version read from the ReaPack header (1.0.0 showed
  `0.1.0-dev`).
- GitHub Pages: the repository root redirects to the user guide.
- Demo video re-recorded (the closing narration, the About segment, the end card).

## 1.0.0 - 2026-09-07

First release. One ReaPack package (Lua + ReaImGui) for REAPER 7 on Windows, macOS and Linux.

- **Navigator**: scenes (regions), markers, tracks and items in a dockable window; fuzzy search, jump with the right
  zoom, audition in place with auto-stop and loop, scene solo / mute with an exact restore, track families by name
  rules, focus, groups, transport strip, per-project persistence.
- **Director**: shot list (from the scenes, editor, pinned rows, validator) and follow-play: the arrange shows the
  lanes of the current shot at locked heights, parents, envelope story mode, page or follow view with eased zoom,
  rehearsal controls; everything restored through the journal.
- **HUD**: dockable caption bar (shot name, caption, progress, time, loudness live or from a curve), font tiers by
  height, sync flashes with tokens for the recorder.
- **Glow**: overlay that lights the arrange with the sound: meter or item mode, bar / fill / edge styles, sparks from
  the take peaks (beam / column / trail), profiles per family, cut flash, bus band, performance guard.
- **Settings**: every knob drawn from one schema with search, tooltips, live preview, this project / global layers,
  reset per key / group / layer, four presets plus user presets; invalid values are reported and never repaired in
  silence; a generated configuration reference.
- **Overview**: one tall picture of the whole session with every used automation lane open; a companion that
  scrolls, captures and stitches, or a guided mode for any screenshot tool.
- **Recorder**: control protocol for the companion drivers (macOS, Windows, Linux, an OBS recipe), arm / play / stop,
  checklist with fixes, screen layout at start, shot-list export / import; the post finds the sync flashes and lays
  the mix under the picture.
- **Stems**: stem sets in bulk (families, top folders, selection, scenes), matrix editor, presets, membership in track
  extension state, Stagehand-owned render settings (formats, range, tail, normalisation, wildcards, folder, overwrite
  policy), a sequential renderer whose pre-flight defuses every dialog that would stall a batch, results with peak
  and loudness plus JSON / CSV / Markdown export and an independent checker.
- **Agent access**: the control protocol answers agent verbs with JSON; an MCP server and a skill ship in the package;
  three switches (access, changes, renders) gate every action; an agent never saves the project.
- Everything Stagehand changes is journaled and put back on Restore, on close, after a script error and at REAPER's
  exit. Verified on Linux, Windows and macOS test machines with a zero restore diff in every scenario.
