-- schema.lua - every configuration key Stagehand knows: type, range, unit, group, and how a value is checked,
-- parsed from text and shown. The defaults themselves stay in config.lua (one source of default values); this
-- file describes them. config.lua validates every layer against the schema on load (invalid values are
-- reported and left out of the effective merge, never rewritten silently), migrates old layers through the
-- version chain, and the Settings tab draws its controls from the entries here. Labels and tooltips are
-- strings in lang/en.lua under `cfg.<key>` and `cfg.<key>.tip`; the self-test checks that every entry has
-- both and that every leaf of config.defaults is covered. Lua 5.4; no globals.

local M = {}

M.VERSION = 2

-- module order in the Settings tab
M.MODULES = { 'navigator', 'director', 'hud', 'glow', 'overview', 'recorder', 'stems', 'agent', 'ui' }

local ENUM_SCOPE = { 'project', 'global' }

-- item schemas of the list-typed keys (fields checked one by one; `sub` maps an override table to a key prefix)
local ITEMS = {
  families = { fields = { name = 'str', color = 'color', rule = 'str', on = { enum = { 'top', 'own', 'any' } } }, required = { 'name' } },
  classes = { fields = { name = 'str', color = 'color', rule = 'str' }, required = { 'name' } },
  groups = { fields = { name = 'str', key = 'str', t0 = 'num', t1 = 'num' }, required = { 'name' } },
  pins = { fields = { rule = 'str', height_px = { int = true, min = 8, max = 400 } }, required = { 'rule' } },
  profiles = { fields = { name = 'str', family = 'str', rule = 'str', meter = 'table', detector = 'table', spark = 'table' },
    required = { 'name' }, sub = { meter = 'glow.meter', detector = 'glow.detector', spark = 'glow.spark' } },
}

-- e(key, type, opts): opts = min, max, step, values (enum / str_list), unit, group, editor, items, fmt
local function e(key, typ, o)
  o = o or {}
  o.key, o.type = key, typ
  return o
end

M.keys = {
  -- navigator ------------------------------------------------------------------------------------------------------
  e('navigator.families', 'list', { group = 'navigator.lists', editor = 'families', items = ITEMS.families }),
  e('navigator.other_family.name', 'str', { group = 'navigator.lists' }),
  e('navigator.other_family.color', 'color', { group = 'navigator.lists' }),
  e('navigator.marker_classes', 'list', { group = 'navigator.lists', editor = 'classes', items = ITEMS.classes }),
  e('navigator.groups', 'list', { group = 'navigator.lists', editor = 'groups', items = ITEMS.groups }),
  e('navigator.jump.zoom_pad_min_s', 'num', { min = 0, max = 5, unit = 's' }),
  e('navigator.jump.zoom_pad_frac', 'num', { min = 0, max = 0.5 }),
  e('navigator.jump.marker_window_s', 'num', { min = 0.1, max = 30, unit = 's' }),
  e('navigator.jump.time_selection', 'bool'),
  e('navigator.jump.focus_tracks', 'bool'),
  e('navigator.audition.loop', 'bool'),
  e('navigator.audition.last_marker_len_s', 'num', { min = 0.5, max = 60, unit = 's' }),
  e('navigator.audition.track_default_len_s', 'num', { min = 0.5, max = 120, unit = 's' }),
  e('navigator.audition.stop_margin_s', 'num', { min = 0, max = 0.2, unit = 's', fmt = '%.3f' }),
  e('navigator.audition.start_grace_frames', 'int', { min = 0, max = 30, unit = 'frames' }),
  e('navigator.search.fuzzy', 'bool'),
  e('navigator.persist.scope', 'enum', { values = ENUM_SCOPE }),

  -- director -------------------------------------------------------------------------------------------------------
  e('director.layout.mode', 'enum', { values = { 'focus', 'all' } }),
  e('director.layout.parents', 'enum', { values = { 'none', 'bus', 'all' } }),
  e('director.timing.lead_s', 'num', { min = 0, max = 2, unit = 's', group = 'director.view' }),
  e('director.view.mode', 'enum', { values = { 'page', 'follow' } }),
  e('director.view.pad_before_s', 'num', { min = 0, max = 5, unit = 's' }),
  e('director.view.pad_after_s', 'num', { min = 0, max = 5, unit = 's' }),
  e('director.view.anim_s', 'num', { min = 0, max = 2, unit = 's' }),
  e('director.view.easing', 'enum', { values = { 'smoothstep', 'linear', 'ease_out' } }),
  e('director.view.follow_len_s', 'num', { min = 2, max = 60, unit = 's' }),
  e('director.view.follow_cursor_frac', 'num', { min = 0.1, max = 0.9 }),
  e('director.view.follow_shot_frac', 'num', { min = 0.2, max = 1 }),
  e('director.heights.lane_min_px', 'int', { min = 20, max = 200, unit = 'px' }),
  e('director.heights.lane_max_px', 'int', { min = 40, max = 400, unit = 'px' }),
  e('director.heights.parent_px', 'int', { min = 16, max = 100, unit = 'px' }),
  e('director.heights.compact_px', 'int', { min = 16, max = 60, unit = 'px' }),
  e('director.heights.env_lane_px', 'int', { min = 16, max = 100, unit = 'px' }),
  e('director.heights.arrange_fallback_px', 'int', { min = 300, max = 3000, unit = 'px' }),
  e('director.heights.verify_tries', 'int', { min = 0, max = 5 }),
  e('director.heights.verify_wait_frames', 'int', { min = 1, max = 5, unit = 'frames' }),
  e('director.pins.enable', 'bool'),
  e('director.pins.rows', 'table', { editor = 'json', items = ITEMS.pins }),
  e('director.envelopes.mode', 'enum', { values = { 'story', 'keep' } }),
  e('director.ruler.mode', 'enum', { values = { 'keep', 'hide' } }),
  e('director.ruler.lane_ids', 'int_list', { min = 0, max = 7 }),
  e('director.scroll.disable_continuous', 'bool'),
  e('director.validate.caption_max_chars', 'int', { min = 20, max = 400 }),
  e('director.persist.scope', 'enum', { values = ENUM_SCOPE }),

  -- hud ------------------------------------------------------------------------------------------------------------
  e('hud.enable', 'bool'),
  e('hud.auto_show', 'bool'),
  e('hud.dock', 'enum', { values = { 'bottom', 'float', 'last' } }),
  e('hud.caption_lang', 'enum', { values = { 'primary', 'secondary' } }),
  e('hud.show_name', 'bool'),
  e('hud.show_progress', 'bool'),
  e('hud.show_time', 'bool'),
  e('hud.show_hints', 'bool'),
  e('hud.time_format', 'enum', { values = { 'min_sec', 'timecode', 'seconds' } }),
  e('hud.loudness.mode', 'enum', { values = { 'live', 'curve', 'off' } }),
  e('hud.loudness.curve_file', 'path'),
  e('hud.loudness.target_lufs', 'num', { min = -40, max = 0, unit = 'LUFS', fmt = '%.1f' }),
  e('hud.loudness.target_tol_lu', 'num', { min = 0, max = 5, unit = 'LU', fmt = '%.1f' }),
  e('hud.loudness.bar_min_lufs', 'num', { min = -60, max = -6, unit = 'LUFS', fmt = '%.0f' }),
  e('hud.loudness.bar_tick_lufs', 'num', { min = -40, max = 0, unit = 'LUFS', fmt = '%.0f' }),
  e('hud.loudness.block_ms', 'int', { min = 50, max = 1000, unit = 'ms' }),
  e('hud.loudness.gate_lu', 'num', { min = -20, max = 0, unit = 'LU', fmt = '%.0f' }),
  e('hud.loudness.show_peak', 'bool'),
  e('hud.font.title_px', 'int', { min = 10, max = 48, unit = 'px' }),
  e('hud.font.caption_steps', 'int_list', { min = 8, max = 48, unit = 'px' }),
  e('hud.font.caption_steps_compact', 'int_list', { min = 8, max = 48, unit = 'px' }),
  e('hud.font.small_px', 'int', { min = 8, max = 24, unit = 'px' }),
  e('hud.font.mono_px', 'int', { min = 10, max = 48, unit = 'px' }),
  e('hud.font.mono_small_px', 'int', { min = 8, max = 24, unit = 'px' }),
  e('hud.layout.compact_below_px', 'int', { min = 40, max = 200, unit = 'px' }),
  e('hud.layout.tall_above_px', 'int', { min = 60, max = 300, unit = 'px' }),
  e('hud.layout.hints_above_px', 'int', { min = 80, max = 400, unit = 'px' }),
  e('hud.colors.bg', 'color'),
  e('hud.colors.text', 'color'),
  e('hud.colors.muted', 'color'),
  e('hud.colors.dim', 'color'),
  e('hud.colors.accent', 'color'),
  e('hud.colors.accent2', 'color'),
  e('hud.colors.warn', 'color'),
  e('hud.colors.panel', 'color'),
  e('hud.colors.line', 'color'),
  e('hud.colors.flash', 'color'),
  e('hud.progress.style', 'enum', { values = { 'bar', 'dots', 'off' } }),
  e('hud.progress.height_px', 'int', { min = 1, max = 20, unit = 'px' }),
  e('hud.message_frames', 'int', { min = 10, max = 300, unit = 'frames', group = 'hud.window' }),
  e('hud.window.w_px', 'int', { min = 300, max = 3840, unit = 'px' }),
  e('hud.window.h_px', 'int', { min = 40, max = 600, unit = 'px' }),
  e('hud.flash.frames', 'int', { min = 1, max = 10, unit = 'frames' }),
  e('hud.flash.gap_frames', 'int', { min = 0, max = 30, unit = 'frames' }),
  e('hud.flash.end_mode', 'enum', { values = { 'last_shot', 'project_end', 'custom' } }),
  e('hud.flash.end_custom_s', 'num', { min = 0, max = 36000, unit = 's' }),
  e('hud.flash.end_pad_s', 'num', { min = 0, max = 5, unit = 's' }),
  e('hud.persist.scope', 'enum', { values = ENUM_SCOPE }),

  -- glow -----------------------------------------------------------------------------------------------------------
  e('glow.enable', 'bool'),
  e('glow.mode', 'enum', { values = { 'meter', 'item', 'off' } }),
  e('glow.style', 'enum', { values = { 'bar', 'fill', 'edge' } }),
  e('glow.color', 'color'),
  e('glow.warm_color', 'color'),
  e('glow.warm_amount', 'num', { min = 0, max = 1 }),
  e('glow.outline_gain', 'num', { min = 0, max = 1 }),
  e('glow.meter.base_alpha', 'num', { min = 0, max = 0.3 }),
  e('glow.meter.tint_gain', 'num', { min = 0, max = 1 }),
  e('glow.meter.fill_gain', 'num', { min = 0, max = 1 }),
  e('glow.meter.release_db_s', 'num', { min = 5, max = 200, unit = 'dB/s', fmt = '%.0f' }),
  e('glow.meter.ref_decay_db_s', 'num', { min = 0.5, max = 30, unit = 'dB/s', fmt = '%.1f' }),
  e('glow.meter.ref_floor_dbfs', 'num', { min = -80, max = -10, unit = 'dBFS', fmt = '%.0f' }),
  e('glow.meter.window_db', 'num', { min = 6, max = 40, unit = 'dB', fmt = '%.0f' }),
  e('glow.meter.gamma', 'num', { min = 0.5, max = 3 }),
  e('glow.meter.tail_max_s', 'num', { min = 0, max = 5, unit = 's' }),
  e('glow.bar.alpha_floor', 'num', { min = 0, max = 1 }),
  e('glow.bar.alpha_gain', 'num', { min = 0, max = 1 }),
  e('glow.spark.style', 'enum', { values = { 'beam', 'column', 'trail' } }),
  e('glow.spark.alpha', 'num', { min = 0, max = 1 }),
  e('glow.spark.width_px', 'int', { min = 1, max = 8, unit = 'px' }),
  e('glow.spark.tail_px', 'int', { min = 0, max = 80, unit = 'px' }),
  e('glow.spark.decay_s', 'num', { min = 0.05, max = 2, unit = 's' }),
  e('glow.spark.min_gap_s', 'num', { min = 0, max = 0.5, unit = 's' }),
  e('glow.spark.halo_px', 'int', { min = 0, max = 40, unit = 'px' }),
  e('glow.spark.trail_max_px', 'int', { min = 20, max = 600, unit = 'px' }),
  e('glow.detector.onset_db', 'num', { min = 1, max = 20, unit = 'dB', fmt = '%.1f' }),
  e('glow.detector.release_db_s', 'num', { min = 20, max = 500, unit = 'dB/s', fmt = '%.0f' }),
  e('glow.profiles', 'table', { editor = 'json', items = ITEMS.profiles }),
  e('glow.bus.enable', 'bool'),
  e('glow.bus.alpha_floor', 'num', { min = 0, max = 1 }),
  e('glow.bus.alpha_gain', 'num', { min = 0, max = 1 }),
  e('glow.bus.max_frac', 'num', { min = 0, max = 1 }),
  e('glow.cut_flash.enable', 'bool'),
  e('glow.cut_flash.marker_class', 'str'),
  e('glow.cut_flash.color', 'color'),
  e('glow.cut_flash.alpha', 'num', { min = 0, max = 1 }),
  e('glow.cut_flash.width_px', 'int', { min = 1, max = 8, unit = 'px' }),
  e('glow.cut_flash.decay_s', 'num', { min = 0.05, max = 2, unit = 's' }),
  e('glow.render.oversample', 'int', { min = 1, max = 2 }),
  e('glow.render.body_only', 'bool'),
  e('glow.render.label_px', 'int', { min = 0, max = 30, unit = 'px' }),
  e('glow.item.peak_alpha', 'num', { min = 0, max = 1 }),
  e('glow.item.sustain_alpha', 'num', { min = 0, max = 1 }),
  e('glow.item.long_item_s', 'num', { min = 0, max = 60, unit = 's' }),
  e('glow.item.long_factor', 'num', { min = 0, max = 1 }),
  e('glow.item.attack_s', 'num', { min = 0, max = 2, unit = 's' }),
  e('glow.item.release_s', 'num', { min = 0, max = 2, unit = 's' }),
  e('glow.item.edge_decay_s', 'num', { min = 0.05, max = 2, unit = 's' }),
  e('glow.perf.budget_ms', 'num', { min = 0.1, max = 10, unit = 'ms', fmt = '%.1f' }),
  e('glow.perf.degrade_steps', 'str_list', { values = { 'sparks_off', 'oversample_1', 'bus_off' } }),
  e('glow.perf.over_frames', 'int', { min = 5, max = 300, unit = 'frames' }),
  e('glow.perf.recover_frames', 'int', { min = 30, max = 3000, unit = 'frames' }),
  e('glow.debug.fake_meter', 'bool'),
  e('glow.debug.log', 'bool'),
  e('glow.persist.scope', 'enum', { values = ENUM_SCOPE }),

  -- overview (M5) --------------------------------------------------------------------------------------------------
  e('overview.track_px', 'int', { min = 20, max = 120, unit = 'px', group = 'overview.layout' }),
  e('overview.env_lane_px', 'int', { min = 16, max = 80, unit = 'px', group = 'overview.layout' }),
  e('overview.env_min_points', 'int', { min = 1, max = 50, group = 'overview.layout' }),
  e('overview.hide_rule', 'str', { group = 'overview.layout' }),
  e('overview.hide_empty', 'bool', { group = 'overview.layout' }),
  e('overview.uncollapse', 'enum', { values = { 'all', 'top', 'none' }, group = 'overview.layout' }),
  e('overview.hide_mixer', 'bool', { group = 'overview.windows' }),
  e('overview.hide_master', 'bool', { group = 'overview.windows' }),
  e('overview.hide_video_window', 'bool', { group = 'overview.windows' }),
  e('overview.range.mode', 'enum', { values = { 'picture', 'project', 'custom' } }),
  e('overview.range.custom_end_s', 'num', { min = 1, max = 36000, unit = 's', fmt = '%.1f' }),
  e('overview.range.pad_end_s', 'num', { min = 0, max = 30, unit = 's' }),
  e('overview.ctl.reply_frames', 'int', { min = 1, max = 10, unit = 'frames', group = 'overview.capture' }),
  e('overview.capture.page_overlap_px', 'int', { min = 0, max = 200, unit = 'px' }),
  e('overview.guided.auto_s', 'num', { min = 0, max = 30, unit = 's', group = 'overview.capture' }),
  e('overview.output.dir', 'path'),
  e('overview.output.half_copy', 'bool'),
  e('overview.output.dpi_mode', 'enum', { values = { 'auto', 'logical', 'native' } }),

  -- recorder (M5) --------------------------------------------------------------------------------------------------
  e('recorder.ctl.dir', 'path'),
  e('recorder.ctl.poll_frames', 'int', { min = 1, max = 10, unit = 'frames' }),
  e('recorder.arm.cursor_s', 'num', { min = 0, max = 36000, unit = 's' }),
  e('recorder.arm.start_director', 'bool'),
  e('recorder.arm.show_hud', 'bool'),
  e('recorder.layout.apply', 'bool'),
  e('recorder.layout.monitor', 'enum', { values = { 'current', 'largest', 'pick' } }),
  e('recorder.layout.monitor_index', 'int', { min = 1, max = 8 }),
  e('recorder.layout.main_window', 'enum', { values = { 'keep', 'maximize', 'custom' } }),
  e('recorder.layout.main_w', 'int', { min = 640, max = 7680, unit = 'px' }),
  e('recorder.layout.main_h', 'int', { min = 480, max = 4320, unit = 'px' }),
  e('recorder.layout.video.show', 'bool', { group = 'recorder.video' }),
  e('recorder.layout.video.place', 'enum', { values = { 'top_right', 'top_left', 'tcp', 'arrange', 'fit' }, group = 'recorder.video' }),
  e('recorder.layout.video.w', 'int', { min = 160, max = 3840, unit = 'px', group = 'recorder.video' }),
  e('recorder.layout.video.h', 'int', { min = 90, max = 2160, unit = 'px', group = 'recorder.video' }),
  e('recorder.layout.video.dx', 'int', { min = -2000, max = 2000, unit = 'px', group = 'recorder.video' }),
  e('recorder.layout.video.dy', 'int', { min = -2000, max = 2000, unit = 'px', group = 'recorder.video' }),
  e('recorder.layout.video.title_px', 'int', { min = 0, max = 60, unit = 'px', group = 'recorder.video' }),
  e('recorder.layout.dock_window.ident', 'str', { group = 'recorder.dock_window' }),
  e('recorder.layout.dock_window.command', 'str', { group = 'recorder.dock_window' }),
  e('recorder.layout.dock_window.position', 'enum', { values = { 'top', 'bottom', 'left', 'right' }, group = 'recorder.dock_window' }),
  e('recorder.checklist.min_w', 'int', { min = 640, max = 7680, unit = 'px' }),
  e('recorder.checklist.min_h', 'int', { min = 480, max = 4320, unit = 'px' }),
  e('recorder.export.dir', 'path'),
  e('recorder.export.time_format', 'enum', { values = { 'seconds', 'timecode', 'min_sec' } }),

  -- stems (M6) -----------------------------------------------------------------------------------------------------
  e('stems.render.format', 'enum', { values = { 'wav16', 'wav24', 'wav32f', 'flac', 'mp3', 'project' } }),
  e('stems.render.srate', 'int', { min = 0, max = 384000, unit = 'Hz' }),
  e('stems.render.channels', 'int', { min = 1, max = 64 }),
  e('stems.render.bounds', 'enum', { values = { 'stem', 'project', 'time_selection', 'custom' } }),
  e('stems.render.bounds_fallback', 'enum', { values = { 'project', 'time_selection', 'custom' } }),
  e('stems.render.custom_start_s', 'num', { min = 0, max = 36000, unit = 's', fmt = '%.3f' }),
  e('stems.render.custom_end_s', 'num', { min = 0, max = 36000, unit = 's', fmt = '%.3f' }),
  e('stems.render.tail_ms', 'int', { min = 0, max = 60000, unit = 'ms' }),
  e('stems.render.normalize', 'enum', { values = { 'off', 'lufs_i', 'lufs_m', 'lufs_s', 'peak', 'true_peak' } }),
  e('stems.render.normalize_target_db', 'num', { min = -60, max = 0, unit = 'dB', fmt = '%.1f' }),
  e('stems.render.dither', 'bool'),
  e('stems.render.pattern', 'str'),
  e('stems.render.dir', 'path'),
  e('stems.render.overwrite', 'enum', { values = { 'replace', 'increment', 'skip' } }),
  e('stems.variant.default', 'enum', { values = { 'master', 'nofx', 'dry' }, group = 'stems.general' }),
  e('stems.bulk.solo_mode', 'enum', { values = { 'in_place', 'ignore_routing' } }),
  e('stems.bulk.folder_children', 'enum', { values = { 'parent', 'all' } }),
  e('stems.membership.write_tracks', 'bool', { group = 'stems.bulk' }),
  e('stems.matrix.show_hidden', 'bool', { group = 'stems.bulk' }),
  e('stems.run.settle_frames', 'int', { min = 0, max = 120, unit = 'frames' }),
  e('stems.results.reaper_stats', 'bool', { group = 'stems.run' }),
  e('stems.results.silent_below_db', 'num', { min = -144, max = 0, unit = 'dBFS', fmt = '%.0f', group = 'stems.run' }),
  e('stems.export.results', 'enum', { values = { 'csv', 'md', 'both', 'none' }, group = 'stems.run' }),
  e('stems.persist.scope', 'enum', { values = ENUM_SCOPE, group = 'stems.general' }),

  -- agent (M7) -----------------------------------------------------------------------------------------------------
  e('agent.enable', 'bool', { group = 'agent.access' }),
  e('agent.allow_changes', 'bool', { group = 'agent.access' }),
  e('agent.allow_render', 'bool', { group = 'agent.access' }),
  e('agent.discovery', 'bool', { group = 'agent.access' }),

  -- ui -------------------------------------------------------------------------------------------------------------
  e('ui.theme', 'enum', { values = { 'auto', 'dark', 'light' }, group = 'ui.general' }),
  e('ui.compact_below_px', 'int', { min = 200, max = 800, unit = 'px', group = 'ui.general' }),
}

-- indexes -----------------------------------------------------------------------------------------------------------

M.by_key = {}
M.groups = {}        -- ordered { id, module, keys = { entry ... } }
local group_by_id = {}

local function module_of(key)
  return key:match('^([^.]+)')
end

local function default_group(key)
  local mod, rest = key:match('^([^.]+)%.(.+)$')
  if not rest then return mod .. '.general' end
  local second = rest:match('^([^.]+)%.')
  if not second then return mod .. '.general' end
  return mod .. '.' .. second
end

for i, entry in ipairs(M.keys) do
  entry.order = i
  entry.module = module_of(entry.key)
  entry.group = entry.group or default_group(entry.key)
  M.by_key[entry.key] = entry
  local g = group_by_id[entry.group]
  if not g then
    g = { id = entry.group, module = entry.module, keys = {} }
    group_by_id[entry.group] = g
    M.groups[#M.groups + 1] = g
  end
  g.keys[#g.keys + 1] = entry
end

function M.entry(key)
  return M.by_key[key]
end

function M.group(id)
  return group_by_id[id]
end

-- groups of one module in schema order
function M.groups_of(module)
  local out = {}
  for _, g in ipairs(M.groups) do
    if g.module == module then out[#out + 1] = g end
  end
  return out
end

-- value checks --------------------------------------------------------------------------------------------------------

local function is_color(v)
  return type(v) == 'string' and v:match('^#%x%x%x%x%x%x$') ~= nil
end

local function is_int(v)
  return type(v) == 'number' and v == math.floor(v)
end

local function in_range(entry, v)
  if entry.min and v < entry.min then return false, string.format('below the minimum %s', tostring(entry.min)) end
  if entry.max and v > entry.max then return false, string.format('above the maximum %s', tostring(entry.max)) end
  return true
end

local function in_values(values, v)
  for _, x in ipairs(values) do
    if x == v then return true end
  end
  return false
end

local function is_array(t)
  if type(t) ~= 'table' then return false end
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  return n == #t
end

local check_value

-- one item of a list-typed key against its item schema; returns ok, reason
local function check_item(items, item)
  if type(item) ~= 'table' then return false, 'an entry is not an object' end
  for _, r in ipairs(items.required or {}) do
    if item[r] == nil then return false, string.format('an entry lacks "%s"', r) end
  end
  for k, v in pairs(item) do
    local spec = items.fields[k]
    if not spec then return false, string.format('unknown field "%s" in an entry', tostring(k)) end
    local sub = items.sub and items.sub[k]
    if sub then
      if type(v) ~= 'table' then return false, string.format('"%s" of an entry is not an object', k) end
      for sk, sv in pairs(v) do
        local se = M.by_key[sub .. '.' .. tostring(sk)]
        if not se then return false, string.format('unknown override "%s.%s" in an entry', k, tostring(sk)) end
        local ok, why = check_value(se, sv)
        if not ok then return false, string.format('override %s.%s: %s', k, tostring(sk), why) end
      end
    elseif type(spec) == 'string' then
      local ok = (spec == 'str' and type(v) == 'string') or (spec == 'num' and type(v) == 'number')
        or (spec == 'color' and is_color(v)) or (spec == 'table' and type(v) == 'table')
      if not ok then return false, string.format('"%s" of an entry is not a %s', k, spec == 'color' and 'colour (#RRGGBB)' or spec) end
    else
      if spec.enum and not in_values(spec.enum, v) then return false, string.format('"%s" of an entry is not one of %s', k, table.concat(spec.enum, ', ')) end
      if spec.int then
        if not is_int(v) then return false, string.format('"%s" of an entry is not a whole number', k) end
        if (spec.min and v < spec.min) or (spec.max and v > spec.max) then return false, string.format('"%s" of an entry is outside %s..%s', k, tostring(spec.min), tostring(spec.max)) end
      end
    end
  end
  return true
end

-- check_value(entry, v) -> ok, reason
check_value = function(entry, v)
  local ty = entry.type
  if ty == 'bool' then
    if type(v) ~= 'boolean' then return false, 'not true or false' end
  elseif ty == 'int' then
    if not is_int(v) then return false, 'not a whole number' end
    return in_range(entry, v)
  elseif ty == 'num' then
    if type(v) ~= 'number' then return false, 'not a number' end
    return in_range(entry, v)
  elseif ty == 'enum' then
    if not in_values(entry.values, v) then return false, 'not one of ' .. table.concat(entry.values, ', ') end
  elseif ty == 'str' or ty == 'path' then
    if type(v) ~= 'string' then return false, 'not a text' end
  elseif ty == 'color' then
    if not is_color(v) then return false, 'not a colour (#RRGGBB)' end
  elseif ty == 'int_list' then
    if not is_array(v) then return false, 'not a list' end
    for i, x in ipairs(v) do
      if not is_int(x) then return false, string.format('entry %d is not a whole number', i) end
      local ok, why = in_range(entry, x)
      if not ok then return false, string.format('entry %d is %s', i, why) end
    end
  elseif ty == 'str_list' then
    if not is_array(v) then return false, 'not a list' end
    for i, x in ipairs(v) do
      if type(x) ~= 'string' then return false, string.format('entry %d is not a text', i) end
      if entry.values and not in_values(entry.values, x) then return false, string.format('entry %d is not one of %s', i, table.concat(entry.values, ', ')) end
    end
  elseif ty == 'list' or ty == 'table' then
    if not is_array(v) then return false, 'not a list' end
    if entry.items then
      for i, item in ipairs(v) do
        local ok, why = check_item(entry.items, item)
        if not ok then return false, string.format('entry %d: %s', i, why) end
      end
    end
  end
  return true
end

M.check = check_value

-- walk a layer (a partial config tree) and report every problem; returns issues, clean
-- issues: { { key, value, reason, kind = 'invalid' | 'unknown' } ... } in path order
-- clean: a deep copy of the layer without the invalid values (unknown keys are kept for forward compatibility)
function M.validate(layer)
  local issues = {}
  local function walk(node, prefix)
    if type(node) ~= 'table' then return node end
    local out = {}
    local keys = {}
    for k in pairs(node) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, k in ipairs(keys) do
      local v = node[k]
      local path = prefix == '' and tostring(k) or (prefix .. '.' .. tostring(k))
      local entry = M.by_key[path]
      if path == 'schema' then
        out[k] = v
      elseif entry then
        local ok, why = check_value(entry, v)
        if ok then
          out[k] = v
        else
          issues[#issues + 1] = { key = path, value = v, reason = why, kind = 'invalid' }
        end
      elseif type(v) == 'table' and not is_array(v) then
        out[k] = walk(v, path)
      else
        issues[#issues + 1] = { key = path, value = v, reason = 'unknown key (kept)', kind = 'unknown' }
        out[k] = v
      end
    end
    return out
  end
  local clean = walk(layer or {}, '')
  return issues, clean
end

-- migrations ------------------------------------------------------------------------------------------------------------

local function get_in(tbl, parts)
  local cur = tbl
  for _, seg in ipairs(parts) do
    if type(cur) ~= 'table' then return nil end
    cur = cur[seg]
  end
  return cur
end

local function set_in(tbl, parts, value)
  local cur = tbl
  for i = 1, #parts - 1 do
    local seg = parts[i]
    if type(cur[seg]) ~= 'table' then cur[seg] = {} end
    cur = cur[seg]
  end
  cur[parts[#parts]] = value
end

local function prune(tbl, parts)
  local parent = get_in(tbl, { table.unpack(parts, 1, #parts - 1) })
  if type(parent) == 'table' then
    parent[parts[#parts]] = nil
    if next(parent) == nil and #parts > 1 then prune(tbl, { table.unpack(parts, 1, #parts - 1) }) end
  end
end

-- move a dotted key inside a layer; returns true when something moved
local function move_key(layer, from, to)
  local fp, tp = {}, {}
  for seg in from:gmatch('[^.]+') do fp[#fp + 1] = seg end
  for seg in to:gmatch('[^.]+') do tp[#tp + 1] = seg end
  local v = get_in(layer, fp)
  if v == nil then return false end
  if get_in(layer, tp) == nil then set_in(layer, tp, v) end
  prune(layer, fp)
  return true
end

-- STEPS[n] takes a layer of schema n to schema n + 1; each returns a list of notes (what it changed)
M.STEPS = {
  [1] = function(layer)
    local notes = {}
    -- the compact-layout threshold applies to every tab of the main window, not only the Navigator
    if move_key(layer, 'navigator.layout.compact_below_px', 'ui.compact_below_px') then
      notes[#notes + 1] = 'navigator.layout.compact_below_px moved to ui.compact_below_px'
    end
    return notes
  end,
}

-- migrate(layer) -> layer, from_version, notes; the layer is changed in place and stamped with M.VERSION
function M.migrate(layer)
  layer = layer or {}
  local from = math.floor(tonumber(layer.schema) or 1)
  local notes = {}
  local v = from
  while v < M.VERSION do
    local step = M.STEPS[v]
    if step then
      for _, n in ipairs(step(layer) or {}) do notes[#notes + 1] = n end
    end
    v = v + 1
  end
  layer.schema = M.VERSION
  return layer, from, notes
end

-- coverage(defaults) -> { uncovered = { key ... }, missing = { key ... } }
-- uncovered: leaves of the defaults with no schema entry; missing: schema entries with no default
function M.coverage(defaults)
  local uncovered, missing = {}, {}
  local function walk(node, prefix)
    for k, v in pairs(node) do
      local path = prefix == '' and tostring(k) or (prefix .. '.' .. tostring(k))
      if path ~= 'schema' then
        if M.by_key[path] then
          -- covered
        elseif type(v) == 'table' and not is_array(v) then
          walk(v, path)
        else
          uncovered[#uncovered + 1] = path
        end
      end
    end
  end
  walk(defaults, '')
  for _, entry in ipairs(M.keys) do
    local parts = {}
    for seg in entry.key:gmatch('[^.]+') do parts[#parts + 1] = seg end
    if get_in(defaults, parts) == nil then missing[#missing + 1] = entry.key end
  end
  table.sort(uncovered)
  table.sort(missing)
  return { uncovered = uncovered, missing = missing }
end

-- text forms ---------------------------------------------------------------------------------------------------------------

-- a value as the Settings tab and the reference show it
function M.format(entry, v)
  if v == nil then return '' end
  local ty = entry and entry.type or type(v)
  if ty == 'bool' then return v and 'on' or 'off' end
  if ty == 'int' then return string.format('%d', v) end
  if ty == 'num' then
    local s = string.format(entry.fmt or '%.2f', v)
    s = s:gsub('(%..-)0+$', '%1'):gsub('%.$', '')
    return s
  end
  if ty == 'int_list' or ty == 'str_list' then
    local parts = {}
    for i, x in ipairs(v) do parts[i] = tostring(x) end
    return table.concat(parts, ', ')
  end
  if ty == 'list' or ty == 'table' then
    return string.format('%d entries', #v)
  end
  return tostring(v)
end

-- parse text typed by the user for the list types; returns value or nil, reason
function M.parse(entry, text)
  local ty = entry.type
  if ty == 'int_list' then
    local out = {}
    for tok in tostring(text):gmatch('[^,%s]+') do
      local n = tonumber(tok)
      if not n or n ~= math.floor(n) then return nil, string.format('"%s" is not a whole number', tok) end
      out[#out + 1] = math.floor(n)
    end
    local ok, why = check_value(entry, out)
    if not ok then return nil, why end
    return out
  elseif ty == 'str_list' then
    local out = {}
    for tok in tostring(text):gmatch('[^,%s]+') do out[#out + 1] = tok end
    local ok, why = check_value(entry, out)
    if not ok then return nil, why end
    return out
  elseif ty == 'int' then
    local n = tonumber(text)
    if not n then return nil, 'not a number' end
    n = math.floor(n + 0.5)
    local ok, why = check_value(entry, n)
    if not ok then return nil, why end
    return n
  elseif ty == 'num' then
    local n = tonumber(text)
    if not n then return nil, 'not a number' end
    local ok, why = check_value(entry, n)
    if not ok then return nil, why end
    return n
  elseif ty == 'color' then
    local s = tostring(text):upper()
    if not s:match('^#') then s = '#' .. s end
    local ok, why = check_value(entry, s)
    if not ok then return nil, why end
    return s
  end
  return tostring(text)
end

-- the range and unit in words, for tooltips and the reference ("0 .. 2 s", "one of focus, all")
function M.range_text(entry)
  local ty = entry.type
  if ty == 'enum' then return 'one of ' .. table.concat(entry.values, ', ') end
  if ty == 'str_list' and entry.values then return 'any of ' .. table.concat(entry.values, ', ') end
  if (ty == 'int' or ty == 'num' or ty == 'int_list') and entry.min then
    local s = string.format('%s .. %s', tostring(entry.min), tostring(entry.max))
    if entry.unit then s = s .. ' ' .. entry.unit end
    return s
  end
  if ty == 'bool' then return 'on / off' end
  if ty == 'color' then return '#RRGGBB' end
  if ty == 'path' then return 'a file path' end
  return nil
end

return M
