---
name: stagehand
description: Drive Stagehand for REAPER (session navigator, showcase director, glow / HUD, overview, recorder, stems) from a conversation through its MCP server. Use when the user asks about the open REAPER session (scenes, markers, tracks, families, shots, stems, loudness of a batch), wants to jump somewhere, solo or mute a scene, start or stop a showcase run, change a Stagehand setting, or render stems. Requires the "stagehand" MCP server (Stagehand's Agent tab shows how to install it), Stagehand running in REAPER with a saved project, and Agent access turned on by the user in the Agent tab (off by default).
---

# Stagehand for REAPER - the agent workflow

Stagehand is a ReaScript package. Its Agent tab lets an AI agent read the open session and drive the modules
through the `stagehand` MCP server. The user owns three switches in that tab, and all three are off until the user
turns them on: **Agent access** (any tool answers at all), **Allow changes** (jumps, solo / mute, runs, commands,
config set) and **Allow renders** (a stems batch; needs Allow changes too). A refused call says which one is off.
You can read the switches (`stagehand_status`, `stagehand_config` get) but never set them: only the user does, in the
Agent tab. Nothing you do saves the project, and every change you make is journaled by Stagehand and restored like the
user's own.

## Ground rules

1. **Read before you act.** Call `stagehand_status` first in a conversation: it tells you whether Stagehand runs, which
   project is open and saved, what is playing, what is soloed or muted, whether a Director run or a stems batch is
   active, and which switches are on. If it is refused because Agent access is off, ask the user to turn on "Agent
   access" in Stagehand's Agent tab and stop there. When the user asks for a change and Allow changes is off, say so
   and ask them to turn it on; do the same for renders and Allow renders.
2. **Reads are free, changes are asked.** `stagehand_status`, `stagehand_census`, `stagehand_shots`, `stagehand_stems`,
   `stagehand_results`, `stagehand_config` (get / list) and `stagehand_verbs` need no confirmation. A jump
   (`stagehand_jump`) is fine when the user asked to go somewhere. Before a scene solo / mute, a Director run, a
   command that shows or hides windows or starts playback, a `config set` / `reset`, or a render: say in one
   sentence what will happen and wait for the user's yes.
3. **Renders need an explicit yes.** `stagehand_stems_render` refuses without `confirm=true`. Tell the user which
   stems are enabled (from `stagehand_stems`), where the files land (`render.dir`, relative to the project folder) and
   in which format, then call with `confirm=true` only after a clear yes. Poll `stagehand_status`
   (`modules.stems.batch_active`) and report `stagehand_results` when the batch is done.
4. **Never save.** There is no tool for it and you must not ask the user to save on your behalf. When you changed
   something the user did not want, `stagehand_scene` with `action=restore` puts back everything Stagehand changed.
   Putting things back always works while Agent access is on, even with Allow changes off: `stagehand_scene` clear /
   restore, `stagehand_director` stop / validate, and the stop commands (`director_stop`, `overview_restore`,
   `recorder_stop`, `stems_stop`, `hud_cancel`).
5. **Report in the user's words.** Scenes are regions, families are the user's track groups (Dialogue, Music, ...),
   a shot is one entry of the Director's list. Quote names as the census gives them; times in seconds with three
   decimals, or minutes:seconds when the user talks that way.

## What to ask for what

| The user wants | Tool | Notes |
|---|---|---|
| "What is in this session?" | `stagehand_census` | one row per track; summarise by family and folder, list the scenes with lengths and item counts |
| "Where am I?" / "is it playing?" | `stagehand_status` | transport, active scene, solo / mute scenes, run state |
| "Go to the fight scene" | `stagehand_jump` `{scene: "fight"}` | part of a name works; a number picks the k-th scene of the census |
| "Go to marker HIT" / "go to 1:32" | `stagehand_jump` `{marker: "HIT"}` / `{time_s: 92}` | |
| "Solo scene 4 so I hear only it" | `stagehand_scene` `{action: "solo", scene: "4"}` | ask first; `clear` puts it back |
| "Mute everything in the intro" | `stagehand_scene` `{action: "mute", scene: "Intro"}` | ask first |
| "Put everything back" | `stagehand_scene` `{action: "clear"}` or `restore` | clear = scene solo / mute; restore = the whole journal |
| "What does the shot list look like, any problems?" | `stagehand_shots` | issues carry level error / warn / info and the shot number |
| "Make a shot per scene" / "add a shot for the fight, 40 to 52 s, caption ..." / "change shot 3's caption" | `stagehand_shots_set` `from_scenes` / `{action: "add", shot: {...}}` / `{action: "update", k: 3, shot: {caption: "..."}}` | ask before `set` or `clear` on a list the user built; then `stagehand_shots` shows the validator's verdict |
| "Play the showcase" / "stop it" | `stagehand_director` `start` / `stop` | ask first; the arrange follows the shots until stopped |
| "Show shot 3" | `stagehand_director` `{action: "goto", shot: 3}` | starts a run when none is active |
| "Turn the glow off" / "show the HUD" | `stagehand_command` `glow_off` / `hud_show` | |
| "What is the lead time?" | `stagehand_config` `{action: "get", key: "director.timing.lead_s"}` | |
| "Set the lead to half a second" | `stagehand_config` `{action: "set", key: "director.timing.lead_s", value: "0.5"}` | ask first; project layer by default, `scope: "global"` for the global file; `agent.*` keys are refused (the user's switches) |
| "Which stems are defined?" | `stagehand_stems` | cells: S solo in place, I solo ignore routing, M mute; a stem without cells is the full mix |
| "Render the stems" | `stagehand_stems_render` `{confirm: true}` | only after the user's yes; then `stagehand_results` |
| "How loud was the music stem?" | `stagehand_results` | peak_db, lufs_i, lufs_m_max, lufs_s_max, lra per row |
| Something without a tool | `stagehand_raw` `{line, token}` | the companions' verbs: `rect` -> RECT, `overview rect` -> RECT, `shots json` -> SHOTS; it never renders (`stems render` is refused: use `stagehand_stems_render`) and never sets the switches |

## Config keys worth knowing

`stagehand_config` with `action=list` and a prefix (`director`, `glow.spark`, `stems.render`) shows every key with its
type, range, default and value. Values are text: numbers, `on` / `off`, an enum word, a path, JSON for lists. A value
outside the range is refused with the reason and nothing changes. The full reference is `docs/config-reference.md`
in the Stagehand repository.

## When something fails

- "no Stagehand found" / "not running": Stagehand is not open in REAPER, or the project is not saved (an unsaved
  project has no control folder). Ask the user to open Stagehand (any tab) with a saved project.
- "refused: agent access is off / changes are off / renders are off": the user's switches in the Agent tab, off
  until the user turns them on. Tell the user which switch to turn on ("Agent access", "Allow changes", "Allow
  renders") and stop; do not work around it (no raw lines, no config set, no other tool).
- "the agent switches belong to the user": you tried to set or reset an `agent.*` key. Only the user changes them.
- "no PONG" / a timeout: REAPER may be busy (a render, a modal dialog). Wait and retry once, then tell the user.
- A tool answers but the numbers look stale: call `stagehand_status` again; Stagehand rescans the project once an
  edit settles (one frame after the last change).
