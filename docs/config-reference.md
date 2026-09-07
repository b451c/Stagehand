# Stagehand configuration reference

Generated from `stagehand/schema.lua` (schema version 2) by `tools/gen_config_reference.lua`; do not edit by hand.
Every key is a setting in the Settings tab (label, tooltip, range, default, reset per key and per group) and a key of the
JSON layers: the global file `<REAPER resource path>/Stagehand/config.json`, the per-project overrides stored with the
project, and preset files. Layers merge in that order: defaults <- global <- project. Lists (families, marker classes,
groups, pinned rows, profiles) are replaced whole by an override; everything else merges key by key. A value outside its
range or of the wrong type is reported in the Settings tab and left out of the merge (the default applies); the file is
not rewritten. Layers written by an older schema are migrated on load (schema 1 -> 2: `navigator.layout.compact_below_px`
became `ui.compact_below_px`).

221 keys in 53 groups.

## Navigator (`navigator.*`)

### Families, marker classes, groups

| Key | Setting | Type and range | Default | Meaning |
|---|---|---|---|---|
| `navigator.families` | Families | list (JSON) | `[{"color":"#4E9AF1","name":"Dialogue","on":"top","rule":"^DIALOG\|^DIA\|^DX\|^VO\|^VOICE"},{"color":"#F1A24E","name":"Music","on":"top","rule":"^MUSIC\|^MX\|^MUS\|^SCORE"},{"color":"#3FBFAE","name":"Ambience","on":"top","rule":"^AMB\|^ATMO\|^BG"},{"color":"#D96AC8","name":"Foley","on":"top","rule":"^FOL"},{"color":"#A6B84E","name":"SFX","on":"top","rule":"^SFX\|^FX\|^EFFECT"},{"color":"#8F7BEF","name":"Design","on":"top","rule":"^DESIGN\|^DSG\|^DSN"}]` | The track families: name, colour, a name rule and where it matches (top-level ancestor, own name, any parent). Chips in the Navigator, lanes by family in the Director, profiles in the Glow. |
| `navigator.other_family.name` | Other name | text | `Other` | Name of the family that takes every track no rule matched |
| `navigator.other_family.color` | Other colour | colour `#RRGGBB` | `#9AA3B5` | Colour of the "other" family chip and its tracks |
| `navigator.marker_classes` | Marker classes | list (JSON) | `[{"color":"#9AA3B5","name":"Cut","rule":"^CUT\|^SHOT"},{"color":"#6FE39A","name":"Dialogue","rule":"^VO\|^DX\|^DIAL\|^LINE"},{"color":"#FF5A5A","name":"Hit","rule":"HIT\|IMPACT\|STING\|FLASH\|BOOM"},{"color":"#F5E663","name":"Todo","rule":"^TODO\|^FIX\|^CHECK"},{"color":"#63C8FF","name":"Note","rule":"^NOTE"}]` | Marker colour classes by name rule (Cut, Dialogue, Hit, ...); the Glow's cut flash fires on one of them |
| `navigator.groups` | Groups | list (JSON) | empty | Named time ranges with a digit hotkey (acts, reels); jump and zoom with the key |

### Jump

| Key | Setting | Type and range | Default | Meaning |
|---|---|---|---|---|
| `navigator.jump.zoom_pad_min_s` | Zoom margin (min) | number, 0 .. 5 s | `0.3` | Smallest margin around a scene when the view zooms to it |
| `navigator.jump.zoom_pad_frac` | Zoom margin fraction | number, 0 .. 0.5 | `0.06` | Margin as a fraction of the scene length; the larger of the two margins applies |
| `navigator.jump.marker_window_s` | Marker window | number, 0.1 .. 30 s | `2.5` | Seconds shown on each side of a marker after a marker jump |
| `navigator.jump.time_selection` | Time selection | on / off | `on` | Set the time selection to the scene when jumping (initial state of the Time sel. toggle) |
| `navigator.jump.focus_tracks` | Focus tracks | on / off | `off` | Hide the tracks that have no items in the scene when jumping (initial state of Focus tracks; journaled and restored) |

### Audition

| Key | Setting | Type and range | Default | Meaning |
|---|---|---|---|---|
| `navigator.audition.loop` | Loop auditions | on / off | `off` | Initial state of the Loop toggle: auditions repeat until stopped |
| `navigator.audition.last_marker_len_s` | Last marker | number, 0.5 .. 60 s | `5` | How long an audition of the last marker plays (there is no next marker to stop at) |
| `navigator.audition.track_default_len_s` | Track audition | number, 0.5 .. 120 s | `10` | How long a track audition plays when no scene is active |
| `navigator.audition.stop_margin_s` | Auto-stop margin | number, 0 .. 0.2 s | `0.015` | The audition stops this much before its end so the next item is never heard |
| `navigator.audition.start_grace_frames` | Start grace | whole number, 0 .. 30 frames | `6` | Frames after play during which "not playing" is ignored (the transport needs a moment to start) |

### Search

| Key | Setting | Type and range | Default | Meaning |
|---|---|---|---|---|
| `navigator.search.fuzzy` | Fuzzy search | on / off | `on` | Match the typed letters in order with gaps (off = plain substring) |

### Persistence

| Key | Setting | Type and range | Default | Meaning |
|---|---|---|---|---|
| `navigator.persist.scope` | Remember tab state | one of project, global | `project` | Where the Navigator's tab, toggles, family filter and the window state are remembered: per project or once for all |

## Director (`director.*`)

### Layout

| Key | Setting | Type and range | Default | Meaning |
|---|---|---|---|---|
| `director.layout.mode` | Layout | one of focus, all | `focus` | Focus: only the shot's lanes (plus pins and parents) stay in the track panel. All: every track stays, non-lanes at the compact height |
| `director.layout.parents` | Parents | one of none, bus, all | `none` | Which folder ancestors of the lanes stay visible as rows: none, the top-level bus only, or all of them |

### View and timing

| Key | Setting | Type and range | Default | Meaning |
|---|---|---|---|---|
| `director.timing.lead_s` | Lead | number, 0 .. 2 s | `0.4` | Seconds before a shot's start at which the lanes switch, so the layout is in place when the shot begins |
| `director.view.mode` | View | one of page, follow | `page` | Page: the shot fits the window and the cursor sweeps across. Follow: the window slides with the cursor. A shot can override it |
| `director.view.pad_before_s` | Page margin before | number, 0 .. 5 s | `0.6` | Page view: seconds shown before the shot start |
| `director.view.pad_after_s` | Page margin after | number, 0 .. 5 s | `0.5` | Page view: seconds shown after the shot end |
| `director.view.anim_s` | Zoom animation | number, 0 .. 2 s | `0.3` | Length of the zoom animation between shots; 0 = instant |
| `director.view.easing` | Easing | one of smoothstep, linear, ease_out | `smoothstep` | Curve of the zoom animation |
| `director.view.follow_len_s` | Follow window | number, 2 .. 60 s | `6` | Follow view: seconds visible in the window (a long shot widens it to the shot fraction) |
| `director.view.follow_cursor_frac` | Follow cursor | number, 0.1 .. 0.9 | `0.33` | Follow view: where the play cursor sits, as a fraction of the window width |
| `director.view.follow_shot_frac` | Follow minimum | number, 0.2 .. 1 | `0.6` | Follow view: the window is at least this fraction of the shot length |

### Heights

| Key | Setting | Type and range | Default | Meaning |
|---|---|---|---|---|
| `director.heights.lane_min_px` | Lane height min | whole number, 20 .. 200 px | `26` | Smallest lane height; the theme's own minimum wins if it is larger. A shot that cannot fit is a validation warning |
| `director.heights.lane_max_px` | Lane height max | whole number, 40 .. 400 px | `110` | Largest lane height when few lanes share the arrange |
| `director.heights.parent_px` | Parent row height | whole number, 16 .. 100 px | `24` | Height of the folder rows kept by the Parents setting |
| `director.heights.compact_px` | Compact row height | whole number, 16 .. 60 px | `20` | All layout: height of the tracks outside the shot |
| `director.heights.env_lane_px` | Envelope lane | whole number, 16 .. 100 px | `26` | Estimated height of one visible envelope lane when the heights are budgeted; the verify pass measures the truth |
| `director.heights.arrange_fallback_px` | Arrange fallback | whole number, 300 .. 3000 px | `760` | Arrange height used when js_ReaScriptAPI cannot measure it |
| `director.heights.verify_tries` | Verify passes | whole number, 0 .. 5 | `3` | Correction passes after a layout push (the rows are measured and the lane height adjusted); 0 = trust the first push |
| `director.heights.verify_wait_frames` | Verify wait | whole number, 1 .. 5 frames | `2` | Frames to wait after a push before measuring the rows |

### Pinned rows

| Key | Setting | Type and range | Default | Meaning |
|---|---|---|---|---|
| `director.pins.enable` | Pin reference rows | on / off | `on` | Pin the reference rows (picture, guide) at the top of the arrange during a run (REAPER 7 track pinning) |
| `director.pins.rows` | Pinned rows | list (JSON) | empty | Rows that stay visible in every shot: a name rule (^PICTURE, =Guide) and a height in px. Also edited from the Director tab |

### Envelopes

| Key | Setting | Type and range | Default | Meaning |
|---|---|---|---|---|
| `director.envelopes.mode` | Envelope lanes | one of story, keep | `story` | Story: hide every track envelope lane and show only the ones a shot names. Keep: leave them as saved |

### Ruler lanes

| Key | Setting | Type and range | Default | Meaning |
|---|---|---|---|---|
| `director.ruler.mode` | Ruler lanes | one of keep, hide | `keep` | Hide: toggle the listed ruler lanes off for the run and back at the end (a blind toggle: it assumes they are visible now) |
| `director.ruler.lane_ids` | Ruler lane ids | list of whole numbers, each 0 .. 7 | `1, 2` | Which ruler lanes the Hide mode toggles (REAPER action 43507 + id) |

### Scrolling

| Key | Setting | Type and range | Default | Meaning |
|---|---|---|---|---|
| `director.scroll.disable_continuous` | Cont. scroll off | on / off | `on` | Switch REAPER's continuous scrolling off for the run and restore it after, so the page view holds still |

### Validation

| Key | Setting | Type and range | Default | Meaning |
|---|---|---|---|---|
| `director.validate.caption_max_chars` | Caption warning | whole number, 20 .. 400 | `135` | The validator warns about captions longer than this (they fall to the smallest font or get cut on the bar) |

### Persistence

| Key | Setting | Type and range | Default | Meaning |
|---|---|---|---|---|
| `director.persist.scope` | Remember tab state | one of project, global | `project` | Where the auto-follow flag and the validation panel state are remembered |

## HUD (`hud.*`)

### Bar

| Key | Setting | Type and range | Default | Meaning |
|---|---|---|---|---|
| `hud.enable` | Caption bar | on / off | `on` | The caption bar window is available (off = never shown, not even by a run) |
| `hud.auto_show` | Show with a run | on / off | `on` | Open the bar when a Director run starts and close it when the run stops |
| `hud.dock` | Opens | one of bottom, float, last | `bottom` | Where the bar opens the first time: the first bottom docker, floating, or where it was last |
| `hud.caption_lang` | Caption | one of primary, secondary | `primary` | Which caption text of each shot the bar shows (primary or the second language) |
| `hud.show_name` | Show the shot name | on / off | `on` | The shot number and name on the bar |
| `hud.show_progress` | Show progress | on / off | `on` | The shot progress bar or dots |
| `hud.show_time` | Show the time | on / off | `on` | The transport time on the bar |
| `hud.show_hints` | Show key hints | on / off | `off` | A line of key hints on the bar (rehearsal only; keep it off on camera) |
| `hud.time_format` | Time format | one of min_sec, timecode, seconds | `min_sec` | m:ss.cc, the project timecode (h:m:s:f) or plain seconds |

### Loudness

| Key | Setting | Type and range | Default | Meaning |
|---|---|---|---|---|
| `hud.loudness.mode` | Loudness source | one of live, curve, off | `live` | Live: REAPER's master meter (approximate). Curve: a "t M S I" file. Off: no loudness block |
| `hud.loudness.curve_file` | Curve file | file path | empty | Path of the loudness curve; empty = <project>/Render/stagehand_ctl/lufs_curve.txt |
| `hud.loudness.target_lufs` | Target | number, -40 .. 0 LUFS | `-14` | The integrated value is highlighted when it lands inside the target window |
| `hud.loudness.target_tol_lu` | Target tolerance | number, 0 .. 5 LU | `0.5` | Half-width of the target window |
| `hud.loudness.bar_min_lufs` | Bar minimum | number, -60 .. -6 LUFS | `-30` | Left end of the momentary bar scale (tall tier) |
| `hud.loudness.bar_tick_lufs` | Bar tick | number, -40 .. 0 LUFS | `-14` | Position of the tick mark on the momentary bar |
| `hud.loudness.block_ms` | Integration block | whole number, 50 .. 1000 ms | `100` | Block length of the live integration |
| `hud.loudness.gate_lu` | Relative gate | number, -20 .. 0 LU | `-10` | Blocks this far below the running mean are dropped from the integrated value |
| `hud.loudness.show_peak` | Show the peak | on / off | `on` | The PK column (sample peak) in the loudness block |

### Fonts

| Key | Setting | Type and range | Default | Meaning |
|---|---|---|---|---|
| `hud.font.title_px` | Title size | whole number, 10 .. 48 px | `24` | Font size of the shot name (logical px; keep it readable after scaling to 1920) |
| `hud.font.caption_steps` | Caption sizes | list of whole numbers, each 8 .. 48 px | `19, 17, 15` | Font sizes the caption steps through, largest first, until it fits the bar |
| `hud.font.caption_steps_compact` | Compact caption sizes | list of whole numbers, each 8 .. 48 px | `15, 14, 13, 12` | The same for the compact tier |
| `hud.font.small_px` | Small text size | whole number, 8 .. 24 px | `13` | Font size of the key hints and labels |
| `hud.font.mono_px` | Digits size | whole number, 10 .. 48 px | `24` | Font size of the loudness digits and the time |
| `hud.font.mono_small_px` | Digit labels size | whole number, 8 .. 24 px | `12` | Font size of the M / S / I / PK labels |

### Layout tiers

| Key | Setting | Type and range | Default | Meaning |
|---|---|---|---|---|
| `hud.layout.compact_below_px` | Compact below | whole number, 40 .. 200 px | `72` | Bar height under which the compact tier applies (one line, small fonts) |
| `hud.layout.tall_above_px` | Tall above | whole number, 60 .. 300 px | `96` | Bar height above which the tall tier applies (two-line captions, the momentary bar) |
| `hud.layout.hints_above_px` | Hints above | whole number, 80 .. 400 px | `130` | Bar height above which the key hints line has room |

### Colours

| Key | Setting | Type and range | Default | Meaning |
|---|---|---|---|---|
| `hud.colors.bg` | Background | colour `#RRGGBB` | `#0E1014` | Bar background (on camera: keep it dark and neutral) |
| `hud.colors.text` | Text | colour `#RRGGBB` | `#F2F4F7` | Shot name and caption |
| `hud.colors.muted` | Muted text | colour `#RRGGBB` | `#8D95A7` | Labels and the second caption line |
| `hud.colors.dim` | Dim | colour `#RRGGBB` | `#4A5163` | Inactive elements and the progress track |
| `hud.colors.accent` | Accent | colour `#RRGGBB` | `#3AD1FF` | Progress and the highlighted loudness value |
| `hud.colors.accent2` | Second accent | colour `#RRGGBB` | `#FFB347` | Time and the momentary bar |
| `hud.colors.warn` | Warning | colour `#RRGGBB` | `#F5E663` | Values outside the target window |
| `hud.colors.panel` | Panel | colour `#RRGGBB` | `#1A1E26` | The loudness block background |
| `hud.colors.line` | Line | colour `#RRGGBB` | `#2A2F3B` | Separator lines |
| `hud.colors.flash` | Flash | colour `#RRGGBB` | `#FFFFFF` | Colour of the sync flash frames (the recorder looks for white) |

### Progress

| Key | Setting | Type and range | Default | Meaning |
|---|---|---|---|---|
| `hud.progress.style` | Progress style | one of bar, dots, off | `bar` | A thin bar, one dot per shot, or nothing |
| `hud.progress.height_px` | Progress height | whole number, 1 .. 20 px | `4` | Height of the progress bar |

### Window

| Key | Setting | Type and range | Default | Meaning |
|---|---|---|---|---|
| `hud.message_frames` | Message time | whole number, 10 .. 300 frames | `40` | How long a status message stays on an idle bar |
| `hud.window.w_px` | Floating width | whole number, 300 .. 3840 px | `900` | Width of the bar the first time it floats |
| `hud.window.h_px` | Floating height | whole number, 40 .. 600 px | `84` | Height of the bar the first time it floats (84 = the medium tier) |

### Sync flash

| Key | Setting | Type and range | Default | Meaning |
|---|---|---|---|---|
| `hud.flash.frames` | Flash frames | whole number, 1 .. 10 frames | `3` | White frames painted at the start and at the end of a recording |
| `hud.flash.gap_frames` | Gap frames | whole number, 0 .. 30 frames | `6` | Dark frames between the start flash and the play command |
| `hud.flash.end_mode` | End flash at | one of last_shot, project_end, custom | `last_shot` | When the end flash fires: after the last shot, at the project end, or at a custom time |
| `hud.flash.end_custom_s` | Custom end time | number, 0 .. 36000 s | `0` | Project time of the end flash in the Custom mode |
| `hud.flash.end_pad_s` | End pad | number, 0 .. 5 s | `0.17` | Seconds added after the last shot or the project end before the end flash |

### Persistence

| Key | Setting | Type and range | Default | Meaning |
|---|---|---|---|---|
| `hud.persist.scope` | Remember bar state | one of project, global | `project` | Where the bar's dock, size and visibility are remembered |

## Glow (`glow.*`)

### Glow

| Key | Setting | Type and range | Default | Meaning |
|---|---|---|---|---|
| `glow.enable` | Glow | on / off | `on` | The overlay is drawn while something sounds (needs js_ReaScriptAPI) |
| `glow.mode` | Mode | one of meter, item, off | `meter` | Meter: the glow follows each track's meter. Item: a flash at the item start and a low glow from the item bounds. Off: released |
| `glow.style` | Style | one of bar, fill, edge | `bar` | Bar: a faint tint plus a level bar from the take peaks. Fill: a uniform tint that follows the meter. Edge: only the outline lights up |
| `glow.color` | Glow colour | colour `#RRGGBB` | `#FFFFFF` | Colour of the glow at quiet levels |
| `glow.warm_color` | Warm colour | colour `#RRGGBB` | `#FFD070` | Colour of the sparks and the warm end of the fill at loud levels |
| `glow.warm_amount` | Warming | number, 0 .. 1 | `0.55` | How far the level warms the colour: 0 = the glow colour always, 1 = fully warm at the loudest moment |
| `glow.outline_gain` | Outline | number, 0 .. 1 | `0.55` | Alpha of the 1 px outline relative to the fill |
| `glow.profiles` | Profiles | list (JSON) | `[{"detector":{"onset_db":5},"family":"Dialogue","meter":{"gamma":1,"release_db_s":40,"window_db":14},"name":"vocal","spark":{"min_gap_s":0.09}},{"detector":{"onset_db":5},"family":"Music","meter":{"gamma":1.2,"ref_decay_db_s":6,"release_db_s":60,"window_db":12},"name":"music","spark":{"min_gap_s":0.1}}]` | Per-family sensitivity: a name, a family (or a name rule) and overrides of the meter, detector and spark knobs. A track takes the first profile it matches |

### Meter

| Key | Setting | Type and range | Default | Meaning |
|---|---|---|---|---|
| `glow.meter.base_alpha` | Base alpha | number, 0 .. 0.3 | `0.03` | Alpha of an item under the play head while its track is silent |
| `glow.meter.tint_gain` | Tint gain | number, 0 .. 1 | `0.08` | Bar style: tint alpha at the track's own recent peak |
| `glow.meter.fill_gain` | Fill gain | number, 0 .. 1 | `0.36` | Fill style: alpha at the track's own recent peak |
| `glow.meter.release_db_s` | Release | number, 5 .. 200 dB/s | `30` | How fast the displayed level falls (the attack is instant) |
| `glow.meter.ref_decay_db_s` | Reference decay | number, 0.5 .. 30 dB/s | `3` | How fast the adaptive reference (the recent peak) sinks |
| `glow.meter.ref_floor_dbfs` | Reference floor | number, -80 .. -10 dBFS | `-42` | The reference never sinks below this, so quiet beds still pulse |
| `glow.meter.window_db` | Window | number, 6 .. 40 dB | `24` | dB below the reference that maps to dark |
| `glow.meter.gamma` | Gamma | number, 0.5 .. 3 | `1.6` | Brightness curve: above 1 the quieter moments are dimmer |
| `glow.meter.tail_max_s` | Tail | number, 0 .. 5 s | `2.5` | An ended item keeps glowing this long while its track still sounds |

### Level bar

| Key | Setting | Type and range | Default | Meaning |
|---|---|---|---|---|
| `glow.bar.alpha_floor` | Level bar alpha | number, 0 .. 1 | `0.16` | Alpha of the level bar at silence |
| `glow.bar.alpha_gain` | Level bar gain | number, 0 .. 1 | `0.16` | Alpha added to the level bar at the item's own peak |

### Sparks

| Key | Setting | Type and range | Default | Meaning |
|---|---|---|---|---|
| `glow.spark.style` | Spark look | one of beam, column, trail | `beam` | Beam: a bright core with a soft halo. Column: a hard column with a short tail. Trail: a gradient from the onset to the play head |
| `glow.spark.alpha` | Spark alpha | number, 0 .. 1 | `0.75` | Brightness of a spark at its onset |
| `glow.spark.width_px` | Spark width | whole number, 1 .. 8 px | `3` | Width of the spark core |
| `glow.spark.tail_px` | Spark tail | whole number, 0 .. 80 px | `28` | Column look: length of the gradient tail |
| `glow.spark.decay_s` | Spark decay | number, 0.05 .. 2 s | `0.32` | How long a spark takes to fade |
| `glow.spark.min_gap_s` | Spark gap | number, 0 .. 0.5 s | `0.06` | Shortest distance between two sparks on one track |
| `glow.spark.halo_px` | Beam halo | whole number, 0 .. 40 px | `14` | Beam look: width of the soft halo on each side of the core |
| `glow.spark.trail_max_px` | Trail length | whole number, 20 .. 600 px | `160` | Trail look: longest gradient behind the play head |

### Onset detector

| Key | Setting | Type and range | Default | Meaning |
|---|---|---|---|---|
| `glow.detector.onset_db` | Onset threshold | number, 1 .. 20 dB | `6` | A rise above the detector envelope by this much counts as an onset (a spark) |
| `glow.detector.release_db_s` | Detector release | number, 20 .. 500 dB/s | `150` | How fast the detector envelope falls after a peak |

### Bus band

| Key | Setting | Type and range | Default | Meaning |
|---|---|---|---|---|
| `glow.bus.enable` | Bus band | on / off | `on` | A level band on the rows without items (buses, returns) that sound |
| `glow.bus.alpha_floor` | Bus band alpha | number, 0 .. 1 | `0.1` | Alpha of the band at a low level |
| `glow.bus.alpha_gain` | Bus band gain | number, 0 .. 1 | `0.14` | Alpha added at the bus's own peak |
| `glow.bus.max_frac` | Bus band height | number, 0 .. 1 | `0.35` | Tallest band as a fraction of the row height |

### Cut flash

| Key | Setting | Type and range | Default | Meaning |
|---|---|---|---|---|
| `glow.cut_flash.enable` | Cut flash | on / off | `on` | A vertical flash across the arrange when the play head crosses a marker of the class below |
| `glow.cut_flash.marker_class` | Marker class | text | `Cut` | Name of the marker class (from the Navigator's marker classes) that fires the flash |
| `glow.cut_flash.color` | Cut flash colour | colour `#RRGGBB` | `#FFFFFF` | Colour of the flash line |
| `glow.cut_flash.alpha` | Cut flash alpha | number, 0 .. 1 | `0.35` | Brightness of the flash at the crossing |
| `glow.cut_flash.width_px` | Cut flash width | whole number, 1 .. 8 px | `2` | Width of the flash line |
| `glow.cut_flash.decay_s` | Cut flash decay | number, 0.05 .. 2 s | `0.22` | How long the flash takes to fade |

### Rendering

| Key | Setting | Type and range | Default | Meaning |
|---|---|---|---|---|
| `glow.render.oversample` | Oversampling | whole number, 1 .. 2 | `2` | The bitmap is drawn at this multiple of the arrange size (2 = crisp on Retina, twice the draw cost) |
| `glow.render.body_only` | Body only | on / off | `off` | Glow only the item body under the label bar (stored for a later version; not drawn yet) |
| `glow.render.label_px` | Label bar height | whole number, 0 .. 30 px | `11` | Height of the item label bar the Body only mode leaves out (theme dependent) |

### Item mode

| Key | Setting | Type and range | Default | Meaning |
|---|---|---|---|---|
| `glow.item.peak_alpha` | Item flash alpha | number, 0 .. 1 | `0.42` | Item mode: brightness of the flash at the item start |
| `glow.item.sustain_alpha` | Item sustain alpha | number, 0 .. 1 | `0.14` | Item mode: brightness while the item plays |
| `glow.item.long_item_s` | Long item | number, 0 .. 60 s | `8` | Item mode: items longer than this glow at the long factor |
| `glow.item.long_factor` | Long item factor | number, 0 .. 1 | `0.5` | Item mode: brightness factor for long items (beds and drones) |
| `glow.item.attack_s` | Item attack | number, 0 .. 2 s | `0.35` | Item mode: fade-in at the item start |
| `glow.item.release_s` | Item release | number, 0 .. 2 s | `0.3` | Item mode: fade-out after the item end |
| `glow.item.edge_decay_s` | Item edge decay | number, 0.05 .. 2 s | `0.28` | Item mode: how long the edge flash at the item start takes to fade |

### Performance guard

| Key | Setting | Type and range | Default | Meaning |
|---|---|---|---|---|
| `glow.perf.budget_ms` | Frame budget | number, 0.1 .. 10 ms | `2` | Draw time per frame the guard allows before it degrades the look |
| `glow.perf.degrade_steps` | Degrade steps | list of names, any of sparks_off, oversample_1, bus_off | `sparks_off, oversample_1, bus_off` | What the guard switches off, in order, while the draw time stays over budget |
| `glow.perf.over_frames` | Over budget for | whole number, 5 .. 300 frames | `30` | Frames over budget before the next degrade step |
| `glow.perf.recover_frames` | Recover after | whole number, 30 .. 3000 frames | `300` | Frames under budget before a step is taken back |

### Debug

| Key | Setting | Type and range | Default | Meaning |
|---|---|---|---|---|
| `glow.debug.fake_meter` | Fake meter | on / off | `off` | Drive the glow from the item bounds instead of the meters (headless tests, silent machines) |
| `glow.debug.log` | Evidence log | on / off | `off` | Write one line per lit track per frame while playing (next to the self-test log when the harness runs) |

### Persistence

| Key | Setting | Type and range | Default | Meaning |
|---|---|---|---|---|
| `glow.persist.scope` | Remember tab state | one of project, global | `project` | Where the Glow tab's settings are written by its own controls |

## Overview (`overview.*`)

### Rows and lanes

| Key | Setting | Type and range | Default | Meaning |
|---|---|---|---|---|
| `overview.track_px` | Row height | whole number, 20 .. 120 px | `34` | Uniform locked height of every track row in the picture |
| `overview.env_lane_px` | Lane height | whole number, 16 .. 80 px | `26` | Height of every open automation lane |
| `overview.env_min_points` | Lane min points | whole number, 1 .. 50 | `2` | An envelope lane opens when it has at least this many points; automation items count as used |
| `overview.hide_rule` | Hide rule | text | empty | Tracks whose name matches this rule are left out of the picture (TOKEN contains, ^TOKEN starts with, =TOKEN equals, \| separates) |
| `overview.hide_empty` | Hide empty tracks | on / off | `off` | Leave tracks without items out of the picture (folders stay) |
| `overview.uncollapse` | Open folders | one of all, top, none | `all` | Which collapsed folders are opened for the picture: all, only the top level, or none |

### Windows

| Key | Setting | Type and range | Default | Meaning |
|---|---|---|---|---|
| `overview.hide_mixer` | Hide the mixer | on / off | `on` | Close the mixer for the picture (toggled back on restore) |
| `overview.hide_master` | Hide the master row | on / off | `on` | Take the master track out of the track panel for the picture |
| `overview.hide_video_window` | Hide the video window | on / off | `on` | Close the video window for the picture (toggled back on restore) |

### View range

| Key | Setting | Type and range | Default | Meaning |
|---|---|---|---|---|
| `overview.range.mode` | View end | one of picture, project, custom | `picture` | Where the view ends: the last video item (picture), the project length, or a custom time |
| `overview.range.custom_end_s` | Custom end | number, 1 .. 36000 s | `60` | View end in seconds when the mode is custom |
| `overview.range.pad_end_s` | End padding | number, 0 .. 30 s | `0.4` | Seconds of empty arrange after the end |

### Capture

| Key | Setting | Type and range | Default | Meaning |
|---|---|---|---|---|
| `overview.ctl.reply_frames` | Reply frames | whole number, 1 .. 10 frames | `3` | Frames between a scroll command from the companion and the SCROLL reply, so the redraw happened before the capture |
| `overview.capture.page_overlap_px` | Page overlap | whole number, 0 .. 200 px | `0` | Pixels the pages overlap; the stitcher pastes each page at its real scroll offset anyway |
| `overview.guided.auto_s` | Guided auto-advance | number, 0 .. 30 s | `0` | Seconds per page in the guided mode (0 = advance by hand with Next) |

### Output

| Key | Setting | Type and range | Default | Meaning |
|---|---|---|---|---|
| `overview.output.dir` | Output folder | file path | empty | Where the pages and the stitched picture go; empty = <project>/Render/overview_<date> |
| `overview.output.half_copy` | Half-size copy | on / off | `on` | Also write Session_Overview_half.png at half the size |
| `overview.output.dpi_mode` | HiDPI output | one of auto, logical, native | `auto` | auto = keep what the capture delivered; logical = scale a Retina / HiDPI capture down to logical pixels; native = keep native pixels |

## Recorder (`recorder.*`)

### Control protocol

| Key | Setting | Type and range | Default | Meaning |
|---|---|---|---|---|
| `recorder.ctl.dir` | ctl folder | file path | empty | Folder of the control files (cmd, state, hud, layout.txt); empty = <project>/Render/stagehand_ctl |
| `recorder.ctl.poll_frames` | Poll every | whole number, 1 .. 10 frames | `3` | Frames between two reads of the cmd file |

### Arm

| Key | Setting | Type and range | Default | Meaning |
|---|---|---|---|---|
| `recorder.arm.cursor_s` | Arm cursor | number, 0 .. 36000 s | `0` | Where the edit cursor goes on arm (the recording starts there) |
| `recorder.arm.start_director` | Arm starts the run | on / off | `on` | Arm starts the Director run (the first shot is laid out before the flash) |
| `recorder.arm.show_hud` | Arm shows the bar | on / off | `on` | Arm shows the HUD bar and writes its rect to the hud file |

### Screen layout

| Key | Setting | Type and range | Default | Meaning |
|---|---|---|---|---|
| `recorder.layout.apply` | Layout on arm | on / off | `off` | Apply the screen layout (monitor, main window, video window, docker) when arming |
| `recorder.layout.monitor` | Monitor | one of current, largest, pick | `current` | Which monitor the layout uses: the one holding the main window, the largest, or a number |
| `recorder.layout.monitor_index` | Monitor number | whole number, 1 .. 8 | `1` | The monitor to use when Monitor = pick (1 = the one holding the main window, then in scan order) |
| `recorder.layout.main_window` | Main window | one of keep, maximize, custom | `maximize` | keep = leave it; maximize = fill the monitor work area; custom = the size below, centred |
| `recorder.layout.main_w` | Main width | whole number, 640 .. 7680 px | `1920` | Main window width for the custom mode |
| `recorder.layout.main_h` | Main height | whole number, 480 .. 4320 px | `1080` | Main window height for the custom mode |

### Video window

| Key | Setting | Type and range | Default | Meaning |
|---|---|---|---|---|
| `recorder.layout.video.show` | Show video window | on / off | `off` | Show and place the video window with the layout |
| `recorder.layout.video.place` | Video place | one of top_right, top_left, tcp, arrange, fit | `top_right` | top_right / top_left = monitor corner; tcp = over the track panel top; arrange = arrange top-right; fit = 16:9 sized to the space above the tracks |
| `recorder.layout.video.w` | Video width | whole number, 160 .. 3840 px | `480` | Video window width (ignored by fit) |
| `recorder.layout.video.h` | Video height | whole number, 90 .. 2160 px | `270` | Video window height (ignored by fit) |
| `recorder.layout.video.dx` | Video x offset | whole number, -2000 .. 2000 px | `0` | Horizontal nudge of the video window |
| `recorder.layout.video.dy` | Video y offset | whole number, -2000 .. 2000 px | `0` | Vertical nudge of the video window |
| `recorder.layout.video.title_px` | Video title bar | whole number, 0 .. 60 px | `28` | Title bar height counted by the fit mode |

### Window to a docker

| Key | Setting | Type and range | Default | Meaning |
|---|---|---|---|---|
| `recorder.layout.dock_window.ident` | Window ident | text | empty | The dock identifier of a script window to send to a docker (what its script passes to gfx.dock / ImGui docking; empty = none) |
| `recorder.layout.dock_window.command` | Open with | text | empty | The action that opens that window: a named command (_RS...) or an id; toggled only when its state reads off |
| `recorder.layout.dock_window.position` | Docker position | one of top, bottom, left, right | `top` | Which docker takes the window (the first docker with that position; a script cannot create one) |

### Checklist

| Key | Setting | Type and range | Default | Meaning |
|---|---|---|---|---|
| `recorder.checklist.min_w` | Min window width | whole number, 640 .. 7680 px | `1280` | The checklist warns when the main window is narrower |
| `recorder.checklist.min_h` | Min window height | whole number, 480 .. 4320 px | `720` | The checklist warns when the main window is lower |

### Shot-list export

| Key | Setting | Type and range | Default | Meaning |
|---|---|---|---|---|
| `recorder.export.dir` | Export folder | file path | empty | Where the shot-list exports go; empty = <project>/Render |
| `recorder.export.time_format` | CSV times | one of seconds, timecode, min_sec | `seconds` | How the start / end / duration columns of the CSV are written (timecode columns are always added) |

## Stems (`stems.*`)

### Render settings

| Key | Setting | Type and range | Default | Meaning |
|---|---|---|---|---|
| `stems.render.format` | Format | one of wav16, wav24, wav32f, flac, mp3, project | `wav24` | File format of the stems: WAV 16 / 24-bit / 32-bit float, FLAC or MP3 with REAPER defaults, or the project render format as it is |
| `stems.render.srate` | Sample rate | whole number, 0 .. 384000 Hz | `0` | Sample rate of the stems; 0 = the project sample rate |
| `stems.render.channels` | Channels | whole number, 1 .. 64 | `2` | Channels in every stem file (2 = stereo) |
| `stems.render.bounds` | Range | one of stem, project, time_selection, custom | `stem` | What each stem covers: stem = its own range when it has one (a scene stem), else the fallback below; or the whole project, the time selection, a custom range |
| `stems.render.bounds_fallback` | Range fallback | one of project, time_selection, custom | `project` | The range of stems without one of their own when Range = stem |
| `stems.render.custom_start_s` | Custom start | number, 0 .. 36000 s | `0` | Start of the custom range (seconds) |
| `stems.render.custom_end_s` | Custom end | number, 0 .. 36000 s | `60` | End of the custom range (seconds); an empty range is refused by the pre-flight (REAPER would show a dialog) |
| `stems.render.tail_ms` | Tail | whole number, 0 .. 60000 ms | `0` | Milliseconds added after the range so reverb and delay tails end inside the file (0 = none) |
| `stems.render.normalize` | Normalize | one of off, lufs_i, lufs_m, lufs_s, peak, true_peak | `off` | REAPER render normalization of every file to the target: off, integrated / momentary max / short-term max loudness, sample peak or true peak |
| `stems.render.normalize_target_db` | Normalize target | number, -60 .. 0 dB | `-23` | Target of the normalization in dB (LUFS or dBFS by the mode) |
| `stems.render.dither` | Dither | on / off | `off` | Dither the files (16-bit deliveries) |
| `stems.render.pattern` | File name | text | `$project - $stem` | Name of every stem file: $stem, $stemnumber (01, 02...), $scene, $variant are filled in by Stagehand; $project, $date, $time and the other REAPER wildcards by REAPER. With more than one stem the name must contain $stem, $stemnumber or $scene. |
| `stems.render.dir` | Folder | file path | `Render/stems` | Where the stems go: a folder relative to the project (Render/stems) or an absolute path |
| `stems.render.overwrite` | Existing files | one of replace, increment, skip | `replace` | What happens when a stem file exists: replace it, write a numbered copy (name_2), or skip that stem. REAPER's own overwrite prompt would block an unattended batch, so Stagehand decides before the render. |

### General

| Key | Setting | Type and range | Default | Meaning |
|---|---|---|---|---|
| `stems.variant.default` | Default variant | one of master, nofx, dry | `master` | How stems without a variant of their own render: through the master (as the mix), with the master FX bypassed, or dry (every send muted). Journaled toggles, restored after each stem. |
| `stems.persist.scope` | Tab state scope | one of project, global | `project` | Where the tab remembers its toggles: per project or globally |

### Bulk creation and membership

| Key | Setting | Type and range | Default | Meaning |
|---|---|---|---|---|
| `stems.bulk.solo_mode` | Bulk solo | one of in_place, ignore_routing | `in_place` | The solo cell bulk creation writes: solo in place (sends and returns follow, as in the Navigator) or solo ignore routing |
| `stems.bulk.folder_children` | Folder stems | one of parent, all | `parent` | A stem per top folder marks the folder track only (soloed in place it plays its children) or every child as well |
| `stems.membership.write_tracks` | Write membership to tracks | on / off | `on` | Store each track's stem cells in its extension state, so a track template carries its stems and a track inserted from one joins them again |
| `stems.matrix.show_hidden` | Matrix shows hidden tracks | on / off | `off` | Rows for tracks hidden in the track panel |

### Batch and results

| Key | Setting | Type and range | Default | Meaning |
|---|---|---|---|---|
| `stems.run.settle_frames` | Settle between stems | whole number, 0 .. 120 frames | `3` | Frames waited after a stem is restored before the next one is applied |
| `stems.results.reaper_stats` | REAPER statistics | on / off | `on` | Read REAPER's render statistics (peak, LUFS-I, LUFS-M max, LUFS-S max, LRA) into the results page; the preference that stores them is switched on for the batch when SWS is installed and put back after |
| `stems.results.silent_below_db` | Silent below | number, -144 .. 0 dBFS | `-90` | A stem whose sample peak is at or below this level is flagged silent |
| `stems.export.results` | Results files | one of csv, md, both, none | `both` | Which tables are written next to the stems after a batch (stems_results.json is always written) |

## Agent (`agent.*`)

### Access

| Key | Setting | Type and range | Default | Meaning |
|---|---|---|---|---|
| `agent.enable` | Agent access | on / off | `on` | Answer the agent verbs of the control protocol (hello, state, census, shot list, stems, config) |
| `agent.allow_changes` | Allow changes | on / off | `on` | Let an external driver change the project (jumps, solo / mute, runs, commands, config set, arm, play, overview apply, renders); off = reads only |
| `agent.allow_render` | Allow renders | on / off | `on` | Let "stems render" start a batch from outside (needs Allow changes too) |
| `agent.discovery` | Discovery file | on / off | `on` | Write <home>/.stagehand/agent.json with the ctl folder of the open project so the MCP server needs no arguments |

## Window (`ui.*`)

### Window

| Key | Setting | Type and range | Default | Meaning |
|---|---|---|---|---|
| `ui.theme` | Theme | one of auto, dark, light | `auto` | Auto follows the brightness of the REAPER theme; Dark and Light force a palette |
| `ui.compact_below_px` | Compact below | whole number, 200 .. 800 px | `430` | Window height under which every tab switches to its compact layout (smaller rows, fewer controls) |

## Preset file format

```json
{
  "stagehand_preset": { "name": "My preset", "description": "...", "stagehand_version": "0.1.0", "schema": 2, "created": "2026-09-07" },
  "config": { "glow": { "style": "edge", "spark": { "alpha": 0.4 } } }
}
```

`config` is a partial tree of the keys above; a preset written by an older schema is migrated when it is read. The four
shipped presets live in `Stagehand/stagehand/presets/`, the user's own in `<REAPER resource path>/Stagehand/presets/`.
