# Stagehand tools - companions and checkers

Scripts that run outside REAPER: the recorder and overview companions (Python 3, standard library; Pillow and
ffmpeg widen what they can do), and the checkers that run before any Lua ships.

## Companions (M5)

All of them talk to a running Stagehand through the control protocol: a `cmd` file Stagehand reads every few
frames and a `state` file it appends replies to, in `<project folder>/Render/stagehand_ctl/` (or the folder in
`recorder.ctl.dir`). The Recorder and Overview tabs show the exact command line for the open project and copy it
to the clipboard. Stagehand must be running with the project open; nothing is saved by the companions.

| Script | What it does | Needs |
|---|---|---|
| `overview_capture.py --ctl <folder>` (or `--project <file.RPP>`) | One tall picture of the session: asks Stagehand to apply the overview layout (mixer, master row and video window hidden, uniform locked rows, every used automation lane open, the whole picture in view; Stagehand's own window hides), reads the screen crop, scrolls page by page, captures each page, restores the session and stitches the pages. Output: `Session_Overview.png` + a half-size copy in `Render/overview_<stamp>/` | a screen grab: macOS `screencapture` (Retina aware), Pillow, Linux `scrot` / ImageMagick `import`, Windows PowerShell. Pillow speeds the stitch up |
| `overview_stitch.py <folder>` | Stitches captured pages by their real scroll offsets (`pages.txt` + `geometry.txt`); also for the **guided mode** where you capture the REAPER window yourself with any screenshot tool (`--window` when the auto-detection is unsure) | Pillow, or the pure-Python PNG path for 8-bit PNGs |
| `record_showcase.py --ctl <folder> --mix <mix.wav>` | Records a showcase: arms Stagehand (cursor, Director run, HUD bar, screen layout, the `hud` file), starts the screen capture, plays with the sync flashes, stops, restores, then runs the post | macOS `screencapture -v` (Screen Recording permission for the terminal), or `ffmpeg` (x11grab / gdigrab), or the `frames` backend (Pillow; sync check only) |
| `showcase_post.py <recording> --state --hud --out [--mix]` | Finds the two HUD flashes in the recording, anchors mix time 0 (end anchor by default, start and moving anchors reported), lays the mix under the picture, writes native + 1920 px outputs and `report.json` / `report.md` | `ffprobe` / `ffmpeg` for video (report only without them); Pillow for a frame folder |
| `make_lufs_curve.py <mix.wav> <out.txt>` | The `t M S I` loudness curve the HUD shows in curve mode (written by `record_showcase.py --mix` into the ctl folder) | `ffmpeg` (ebur128 filter) |
| `stems_check.py --ctl <folder>` (or `--results <stems folder>/stems_results.json`) | The independent measurement of a stems batch (M6): asks Stagehand to render its enabled stems (ctl verb `stems render`, token `STEMS_DONE`) or reads a finished batch, then measures every WAV with numpy (exact sample peak, length, BS.1770-4 integrated loudness with K-weighting and gates; ffmpeg ebur128 as a third opinion when present) and compares with what Stagehand wrote; verdict in `stems_check.json`, exit 1 when a file is off by more than 0.1 dB / 1 ms / 1 LU | numpy (scipy speeds the filters up); ffmpeg optional |
| `stagehand_ctl.py`, `pngio.py` | The protocol client and the image helpers the drivers import | - |
| `../Stagehand/agent/stagehand_mcp.py` (in the package, not here) | The MCP server for AI agents (M7): the agent verbs of the protocol as typed tools over stdio; finds the open project through `<home>/.stagehand/agent.json`; `--selftest --ctl <folder> --out <json>` runs the protocol in-process against a running Stagehand | Python 3, standard library |

## Agent example and the Pages guide

| Tool | What it does | Needs |
|---|---|---|
| `agent_demo.py --ctl <folder> [--pace 3]` | A minimal agent on the control protocol, the one shown in the demo video: hello, census, a scene jump, the Director on a shot, stop, one verb per `--pace` seconds (the agent switches must be on). A starting point for your own driver | Python 3 |
| `gen_guide.py [--check]` | `docs/guide.html` for GitHub Pages from `docs/user-guide.md`: one self-contained page in Stagehand's design tokens (dark, IBM Plex from Google Fonts, sidebar from the chapters, figures from `![caption](images/x.png)`); `--check` fails when the HTML is older than the Markdown | Python 3 |

### The sync method (why the post can trust the flashes)

Stagehand's HUD paints the whole bar white for 3 frames, stays dark for 6 frames, then presses play; when the play
position passes the end it paints white again for 3 frames and stops. Every phase edge is written to the `state`
file with the wall clock and the play position: `PLAY_REQUEST`, `FLASH_START` (the first dark frame), `PLAY_CMD`,
`PLAY_POS` (the first playing frame), `PLAY_MOVING` (the first frame whose position advanced: the engine really
runs), `FLASH_END` (the first white frame of the end flash), `END`. The post measures the brightness of the bar's
crop per frame, finds the white runs and offers three anchors for mix time 0 in recording time:

- **start**: end of the first white run + 1 frame + (`PLAY_POS` wall - its position - `FLASH_START` wall). Naive:
  REAPER reports position 0.000 for 40-165 ms before the engine moves (measured over several takes).
- **moving**: the same with the `PLAY_MOVING` frame (engine start latency included).
- **end** (default): first white frame of the end flash - 1.5 frames (paint + capture latency) - the position of
  `FLASH_END`. Verified against the picture's own flash and a hard cut to within one output frame on the
  reference project; `--t0` overrides after a picture check.

`report.md` lists all three and the engine start latency (the drift between the start anchor and the end flash).
The video is trimmed inside the filter graph (never an output `-ss` with a second input), the mix is delayed by
the pre-roll, `apad` + `atrim` fix the length; the desktop strip and the title bar above REAPER can be cropped
automatically (`--crop-top auto2`).

### OBS as the zero-dependency route

See the Recorder chapter of `docs/user-guide.md` ("OBS recipe"): a Display Capture source of the monitor Stagehand
laid out, 60 fps, a CQP / CRF encoder, no audio; after the take run `showcase_post.py <take.mkv> --state
<ctl>/state --hud <ctl>/hud --mix <mix.wav> --out <folder>`.

## Checkers

- `check_lua_order.py <files>` - a `local function` used above its definition is a nil call REAPER reports only at
  runtime; every test run and release runs this first.
- `check_i18n.py <package dir>` - every `t('key')` in the code exists in `stagehand/lang/en.lua` (the `cfg.` keys are
  built at runtime from the schema and proven by the settings self-test).
- `gen_config_reference.lua` - writes `docs/config-reference.md` from `stagehand/schema.lua` (`--check` for the gate).
