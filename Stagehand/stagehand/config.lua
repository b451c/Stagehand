-- config.lua - configuration layers: schema defaults <- global JSON file <- project overrides (ProjExtState).
--
-- get('navigator.jump.time_selection') reads the merged value. set(path, value, scope) writes to the 'global'
-- file (<resource>/Stagehand/config.json) or to the 'project' layer and rebuilds the merge. Lists (families,
-- marker classes, groups, profiles) are replaced whole by an override, scalars and nested tables merge key by key.
-- Every layer is validated against schema.lua when it is loaded or written: an invalid value stays in the file
-- (nothing is rewritten behind the user's back) but is left out of the effective merge and reported through
-- issues(); unknown keys are kept and reported once. Layers written by an older schema are migrated through the
-- schema's version chain, the global file after a backup copy. Modules that cache config subscribe with
-- on_change(fn) and are told which keys moved. preview()/commit() let a slider drag update the merge every frame
-- and write the file once. Lua 5.4; no globals.

local json = require('lib.json')
local log = require('lib.log')
local state = require('state')
local schema = require('schema')

local M = {}

M.SCHEMA = schema.VERSION

M.defaults = {
  schema = M.SCHEMA,
  ui = {
    theme = 'auto',                      -- auto | dark | light
    compact_below_px = 430,              -- window height under which every tab uses its compact layout
  },
  navigator = {
    families = {
      { name = 'Dialogue', color = '#4E9AF1', rule = '^DIALOG|^DIA|^DX|^VO|^VOICE', on = 'top' },
      { name = 'Music', color = '#F1A24E', rule = '^MUSIC|^MX|^MUS|^SCORE', on = 'top' },
      { name = 'Ambience', color = '#3FBFAE', rule = '^AMB|^ATMO|^BG', on = 'top' },
      { name = 'Foley', color = '#D96AC8', rule = '^FOL', on = 'top' },
      { name = 'SFX', color = '#A6B84E', rule = '^SFX|^FX|^EFFECT', on = 'top' },
      { name = 'Design', color = '#8F7BEF', rule = '^DESIGN|^DSG|^DSN', on = 'top' },
    },
    other_family = { name = 'Other', color = '#9AA3B5' },
    marker_classes = {
      { name = 'Cut', color = '#9AA3B5', rule = '^CUT|^SHOT' },
      { name = 'Dialogue', color = '#6FE39A', rule = '^VO|^DX|^DIAL|^LINE' },
      { name = 'Hit', color = '#FF5A5A', rule = 'HIT|IMPACT|STING|FLASH|BOOM' },
      { name = 'Todo', color = '#F5E663', rule = '^TODO|^FIX|^CHECK' },
      { name = 'Note', color = '#63C8FF', rule = '^NOTE' },
    },
    groups = {},                         -- { name, key ('1'..'9', '0'), t0, t1 }
    jump = {
      zoom_pad_min_s = 0.3, zoom_pad_frac = 0.06, marker_window_s = 2.5,
      time_selection = true, focus_tracks = false,
    },
    audition = {
      loop = false, last_marker_len_s = 5, track_default_len_s = 10, stop_margin_s = 0.015, start_grace_frames = 6,
    },
    search = { fuzzy = true },
    persist = { scope = 'project' },     -- project | global
  },
  director = {
    layout = { mode = 'focus', parents = 'none' },   -- focus | all ; none | bus | all
    timing = { lead_s = 0.40 },                       -- seconds before a shot at which the lanes switch
    view = {
      mode = 'page', pad_before_s = 0.60, pad_after_s = 0.50, anim_s = 0.30, easing = 'smoothstep',
      follow_len_s = 6.0, follow_cursor_frac = 0.333, follow_shot_frac = 0.6,
    },
    heights = {
      lane_min_px = 26, lane_max_px = 110, parent_px = 24, compact_px = 20, arrange_fallback_px = 760,
      env_lane_px = 26, verify_tries = 3, verify_wait_frames = 2,
    },
    pins = { enable = true, rows = {} },              -- rows: { rule = 'PICTURE', height_px = 76 }
    envelopes = { mode = 'story' },                   -- story | keep
    ruler = { mode = 'keep', lane_ids = { 1, 2 } },   -- keep | hide (blind toggles of 43507 + N, restored)
    scroll = { disable_continuous = true },          -- switch action 41817 off for the run (restored)
    validate = { caption_max_chars = 135 },
    persist = { scope = 'project' },
  },
  hud = {
    enable = true,                                   -- the caption bar window is available
    auto_show = true,                                -- open the bar when a Director run starts, close it when the run stops
    dock = 'bottom',                                 -- bottom | float | last (where the bar opens the first time)
    caption_lang = 'primary',                        -- primary | secondary (which caption text the bar shows)
    show_name = true, show_progress = true, show_time = true, show_hints = false,
    time_format = 'min_sec',                         -- min_sec | timecode | seconds
    loudness = {
      mode = 'live',                                 -- live (REAPER's master meter, approximate) | curve (t M S I file) | off
      curve_file = '',                               -- empty = <project dir>/Render/stagehand_ctl/lufs_curve.txt
      target_lufs = -14, target_tol_lu = 0.5,        -- the integrated value is highlighted inside this window
      bar_min_lufs = -30, bar_tick_lufs = -14,       -- momentary bar scale and tick
      block_ms = 100, gate_lu = -10, show_peak = true,
    },
    font = {                                         -- on-camera sizes (logical px; keep them readable after scaling to 1920)
      title_px = 24, caption_steps = { 19, 17, 15 }, caption_steps_compact = { 15, 14, 13, 12 },
      small_px = 13, mono_px = 24, mono_small_px = 12,
    },
    layout = { compact_below_px = 72, tall_above_px = 96, hints_above_px = 130 },
    colors = {                                       -- on-camera palette (dark neutral, amber and cyan accents)
      bg = '#0E1014', text = '#F2F4F7', muted = '#8D95A7', dim = '#4A5163', accent = '#3AD1FF', accent2 = '#FFB347',
      warn = '#F5E663', panel = '#1A1E26', line = '#2A2F3B', flash = '#FFFFFF',
    },
    progress = { height_px = 4, style = 'bar' },     -- bar | dots | off
    message_frames = 40,
    window = { w_px = 900, h_px = 84 },              -- floating size the first time
    flash = { frames = 3, gap_frames = 6, end_mode = 'last_shot', end_custom_s = 0, end_pad_s = 0.17 },   -- end_mode: last_shot | project_end | custom
    persist = { scope = 'project' },
  },
  glow = {
    enable = true, mode = 'meter', style = 'bar',    -- mode: meter | item | off ; style: bar | fill | edge
    color = '#FFFFFF', warm_color = '#FFD070', warm_amount = 0.55, outline_gain = 0.55,
    meter = {
      base_alpha = 0.03, tint_gain = 0.08, fill_gain = 0.36,
      release_db_s = 30, ref_decay_db_s = 3, ref_floor_dbfs = -42, window_db = 24, gamma = 1.6, tail_max_s = 2.5,
    },
    bar = { alpha_floor = 0.16, alpha_gain = 0.16 },
    spark = { style = 'beam', alpha = 0.75, width_px = 3, tail_px = 28, decay_s = 0.32, min_gap_s = 0.06, halo_px = 14, trail_max_px = 160 },   -- style: column | beam | trail
    detector = { onset_db = 6, release_db_s = 150 },
    profiles = {                                     -- per-family sensitivity; a track takes the first profile it matches
      { name = 'vocal', family = 'Dialogue', meter = { release_db_s = 40, window_db = 14, gamma = 1.0 }, detector = { onset_db = 5 }, spark = { min_gap_s = 0.09 } },
      { name = 'music', family = 'Music', meter = { release_db_s = 60, window_db = 12, gamma = 1.2, ref_decay_db_s = 6 }, detector = { onset_db = 5 }, spark = { min_gap_s = 0.10 } },
    },
    bus = { enable = true, alpha_floor = 0.10, alpha_gain = 0.14, max_frac = 0.35 },
    cut_flash = { enable = true, marker_class = 'Cut', color = '#FFFFFF', alpha = 0.35, width_px = 2, decay_s = 0.22 },
    render = { oversample = 2, body_only = false, label_px = 11 },
    item = { peak_alpha = 0.42, sustain_alpha = 0.14, long_item_s = 8.0, long_factor = 0.5, attack_s = 0.35, release_s = 0.30, edge_decay_s = 0.28 },
    perf = { budget_ms = 2.0, degrade_steps = { 'sparks_off', 'oversample_1', 'bus_off' }, over_frames = 30, recover_frames = 300 },
    debug = { fake_meter = false, log = false },
    persist = { scope = 'project' },
  },
  overview = {
    track_px = 34, env_lane_px = 26, env_min_points = 2,   -- uniform locked row height; open lanes' height; "used" = at least this many points (or an automation item)
    hide_rule = '', hide_empty = false,                    -- name rule of tracks left out of the picture; hide tracks without items
    uncollapse = 'all',                                    -- all | top | none: folders opened for the picture
    hide_mixer = true, hide_master = true, hide_video_window = true,
    range = { mode = 'picture', custom_end_s = 60, pad_end_s = 0.4 },   -- picture (last video item) | project | custom
    ctl = { reply_frames = 3 },                            -- frames between a scroll command and the SCROLL reply (the redraw happened)
    capture = { page_overlap_px = 0 },
    guided = { auto_s = 0 },                               -- guided mode: seconds per page (0 = advance by hand)
    output = { dir = '', half_copy = true, dpi_mode = 'auto' },   -- dir empty = <project>/Render/overview_<stamp>; dpi: auto | logical | native
  },
  recorder = {
    ctl = { dir = '', poll_frames = 3 },                   -- dir empty = <project>/Render/stagehand_ctl
    arm = { cursor_s = 0, start_director = true, show_hud = true },
    layout = {
      apply = false,                                       -- lay the screen out on arm
      monitor = 'current', monitor_index = 1,              -- current | largest | pick
      main_window = 'maximize', main_w = 1920, main_h = 1080,   -- keep | maximize | custom
      video = { show = false, place = 'top_right', w = 480, h = 270, dx = 0, dy = 0, title_px = 28 },   -- top_right | top_left | tcp | arrange | fit
      dock_window = { ident = '', command = '', position = 'top' },   -- a named window (its GetConfigWantsDock ident) sent to a docker and opened by an action
    },
    checklist = { min_w = 1280, min_h = 720 },
    export = { dir = '', time_format = 'seconds' },       -- dir empty = <project>/Render; seconds | timecode | min_sec
  },
  agent = {
    enable = true,          -- the agent verbs (hello, state, census, ...) answer
    allow_changes = true,   -- action verbs (nav, director, command, config set, arm, play, goto, overview apply, stems render)
    allow_render = true,    -- "stems render" and the recorder's arm (needs allow_changes too)
    discovery = true,       -- write <home>/.stagehand/agent.json so the MCP server finds the ctl folder without arguments
  },
  stems = {
    render = {
      format = 'wav24', srate = 0, channels = 2,           -- wav16 | wav24 | wav32f | flac | mp3 | project; 0 = the project rate
      bounds = 'stem', bounds_fallback = 'project',        -- stem = the stem's own range (a scene stem), else the fallback: project | time_selection | custom
      custom_start_s = 0, custom_end_s = 60, tail_ms = 0,
      normalize = 'off', normalize_target_db = -23,        -- off | lufs_i | lufs_m | lufs_s | peak | true_peak
      dither = false,
      pattern = '$project - $stem', dir = 'Render/stems',  -- $stem $stemnumber $scene $variant are Stagehand's; $project $date $time... are REAPER's
      overwrite = 'replace',                               -- replace | increment | skip (REAPER's own prompt would block an unattended batch)
    },
    variant = { default = 'master' },                      -- master | nofx (master FX bypassed) | dry (every send muted)
    bulk = { solo_mode = 'in_place', folder_children = 'parent' },   -- in_place | ignore_routing; parent | all
    membership = { write_tracks = true },                  -- stem membership into the tracks' extension state (track templates carry it)
    matrix = { show_hidden = false },
    run = { settle_frames = 3 },
    results = { reaper_stats = true, silent_below_db = -90 },   -- enable REAPER's render statistics for the batch (SWS) ; a stem whose peak is below this is flagged silent
    export = { results = 'both' },                         -- csv | md | both | none (stems_results.json is always written)
    persist = { scope = 'project' },
  },
}

-- raw = what the file / the project holds (invalid values included); clean = raw without the invalid values
local layers = { global = {}, project = {} }
local clean = { global = {}, project = {} }
local issues = { global = {}, project = {} }
local merged = nil
local errors = {}
local notes = {}
local listeners = {}
local path = nil
local dirty = { global = false, project = false }

M.sabotage = nil   -- self-test negative control: 'keep_invalid' merges the raw layers (invalid values included)

local function deep_copy(v)
  if type(v) ~= 'table' then return v end
  local out = {}
  for k, x in pairs(v) do out[k] = deep_copy(x) end
  return out
end

local function is_list(t)
  return type(t) == 'table' and #t > 0
end

-- an empty override table merges as "nothing to change"; a non-empty list replaces the list below it
local function merge(base, over)
  if type(over) ~= 'table' then return deep_copy(over) end
  if next(over) == nil then return deep_copy(base) end
  if is_list(over) or type(base) ~= 'table' then return deep_copy(over) end
  local out = deep_copy(base)
  for k, v in pairs(over) do
    if type(v) == 'table' and type(out[k]) == 'table' and not is_list(v) then
      out[k] = merge(out[k], v)
    else
      out[k] = deep_copy(v)
    end
  end
  return out
end

local function revalidate(scope)
  local list, cl = schema.validate(layers[scope])
  for _, it in ipairs(list) do it.scope = scope end
  issues[scope] = list
  clean[scope] = (M.sabotage == 'keep_invalid') and deep_copy(layers[scope]) or cl
end

local function rebuild()
  merged = merge(merge(M.defaults, clean.global), clean.project)
end

local function file_path()
  if not path then
    local dir = reaper.GetResourcePath() .. '/Stagehand'
    reaper.RecursiveCreateDirectory(dir, 0)
    path = dir .. '/config.json'
  end
  return path
end

local function read_file(p)
  local f = io.open(p, 'r')
  if not f then return nil end
  local s = f:read('a')
  f:close()
  return s
end

local function write_file(p, s)
  local f = io.open(p, 'w')
  if not f then return false end
  f:write(s)
  f:close()
  return true
end

local function split_path(p)
  local parts = {}
  for seg in tostring(p):gmatch('[^.]+') do parts[#parts + 1] = seg end
  return parts
end

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

-- remove a leaf and every table it leaves empty above it (the top-level module table stays)
local function prune(tbl, parts)
  local parent = get_in(tbl, { table.unpack(parts, 1, #parts - 1) })
  if type(parent) ~= 'table' then return end
  parent[parts[#parts]] = nil
  if next(parent) == nil and #parts > 1 then prune(tbl, { table.unpack(parts, 1, #parts - 1) }) end
end

-- persistence ---------------------------------------------------------------------------------------------------------

function M.save_global()
  layers.global.schema = M.SCHEMA
  local ok = write_file(file_path(), json.encode(layers.global, { pretty = true }) .. '\n')
  if not ok then log.error('could not write %s', file_path()) end
  dirty.global = false
  return ok
end

local function save_project()
  local body = deep_copy(layers.project)
  body.schema = nil
  if next(body) == nil then
    state.pset('config', '')
  else
    body.schema = M.SCHEMA
    state.pset('config', json.encode(body))
  end
  dirty.project = false
end

-- M.stats.saves counts every write (the self-tests prove a slider drag writes once, at the release)
M.stats = { saves = 0 }

local function save(scope)
  M.stats.saves = M.stats.saves + 1
  if scope == 'project' then save_project() else M.save_global() end
end

-- a layer of an older schema is migrated in place; the global file gets a backup copy first
local function migrate_layer(scope, layer)
  local from = math.floor(tonumber(layer.schema) or 1)
  if from >= M.SCHEMA then return layer, false end
  if scope == 'global' then
    local bak = file_path() .. '.schema' .. from .. '.bak'
    local raw = read_file(file_path())
    if raw then write_file(bak, raw) end
    notes[#notes + 1] = string.format('config.json migrated from schema %d to %d (backup: %s)', from, M.SCHEMA, bak)
  else
    notes[#notes + 1] = string.format('project config migrated from schema %d to %d', from, M.SCHEMA)
  end
  local _, _, changed = schema.migrate(layer)
  for _, n in ipairs(changed) do notes[#notes + 1] = n end
  log.info('config: %s layer migrated %d -> %d (%d changes)', scope, from, M.SCHEMA, #changed)
  return layer, true
end

local function load_project_layer()
  layers.project = {}
  local praw = state.pget('config')
  if praw then
    local v, err = json.decode(praw)
    if type(v) == 'table' then
      local migrated
      layers.project, migrated = migrate_layer('project', v)
      if migrated then save_project() end
    else
      errors[#errors + 1] = 'project config could not be read: ' .. tostring(err) .. ' (ignored)'
      log.warn(errors[#errors])
    end
  end
  revalidate('project')
end

function M.load()
  errors, notes = {}, {}
  layers.global, layers.project = {}, {}
  local raw = read_file(file_path())
  if raw and raw ~= '' then
    local v, err = json.decode(raw)
    if type(v) == 'table' then
      local migrated
      layers.global, migrated = migrate_layer('global', v)
      if migrated then M.save_global() end
    else
      errors[#errors + 1] = 'config.json could not be read: ' .. tostring(err) .. ' (defaults in use)'
      log.warn(errors[#errors])
    end
  end
  revalidate('global')
  load_project_layer()
  rebuild()
  for _, scope in ipairs({ 'global', 'project' }) do
    for _, it in ipairs(issues[scope]) do
      log.warn('config: %s %s = %s: %s', scope, it.key, json.encode(it.value), it.reason)
    end
  end
  return merged
end

function M.reload_project()
  load_project_layer()
  rebuild()
end

-- reading ----------------------------------------------------------------------------------------------------------------

function M.errors()
  return errors
end

-- migration notes of this load (shown once in the Settings tab)
function M.notes()
  return notes
end

-- every problem found in the layers: { key, value, reason, kind, scope } in layer order (global first)
function M.issues()
  local out = {}
  for _, scope in ipairs({ 'global', 'project' }) do
    for _, it in ipairs(issues[scope]) do out[#out + 1] = it end
  end
  return out
end

function M.get(p)
  if not merged then M.load() end
  return get_in(merged, split_path(p))
end

function M.default(p)
  return deep_copy(get_in(M.defaults, split_path(p)))
end

-- the raw value a layer holds for a key (nil = no override there), invalid values included
function M.raw(p, scope)
  return deep_copy(get_in(layers[scope], split_path(p)))
end

function M.has_override(p, scope)
  return get_in(layers[scope], split_path(p)) ~= nil
end

-- a deep copy of one layer as stored
function M.layer(scope)
  return deep_copy(layers[scope])
end

-- the overrides of a layer as a sorted list of { key, value }; list-typed schema keys count as one leaf
function M.overrides(scope)
  local out = {}
  local function walk(node, prefix)
    for k, v in pairs(node) do
      local p = prefix == '' and tostring(k) or (prefix .. '.' .. tostring(k))
      if p ~= 'schema' then
        if schema.entry(p) or type(v) ~= 'table' or is_list(v) then
          out[#out + 1] = { key = p, value = deep_copy(v) }
        else
          walk(v, p)
        end
      end
    end
  end
  walk(layers[scope], '')
  table.sort(out, function(a, b) return a.key < b.key end)
  return out
end

function M.path()
  return file_path()
end

-- change notification -----------------------------------------------------------------------------------------------------

-- fn(keys, scope) after every write; keys = list of dotted keys (a prefix for group / preset changes)
function M.on_change(fn)
  listeners[#listeners + 1] = fn
end

local function notify(keys, scope)
  for _, fn in ipairs(listeners) do
    local ok, err = pcall(fn, keys, scope)
    if not ok then log.error('config listener failed: %s', tostring(err)) end
  end
end

-- writing --------------------------------------------------------------------------------------------------------------------

local function put(p, value, scope)
  if not merged then M.load() end
  set_in(layers[scope], split_path(p), deep_copy(value))
  revalidate(scope)
  rebuild()
end

-- scope: 'global' (default) or 'project'
function M.set(p, value, scope)
  scope = scope == 'project' and 'project' or 'global'
  put(p, value, scope)
  save(scope)
  notify({ p }, scope)
end

-- a slider drag: the merge and the modules follow every frame, the file waits for commit()
function M.preview(p, value, scope)
  scope = scope == 'project' and 'project' or 'global'
  put(p, value, scope)
  dirty[scope] = true
  notify({ p }, scope)
end

function M.commit(scope)
  scope = scope == 'project' and 'project' or 'global'
  if dirty[scope] then save(scope) end
end

-- remove an override (falls back to the layer below)
function M.reset(p, scope)
  scope = scope == 'project' and 'project' or 'global'
  if not merged then M.load() end
  local parts = split_path(p)
  if get_in(layers[scope], parts) == nil then return false end
  prune(layers[scope], parts)
  revalidate(scope)
  rebuild()
  save(scope)
  notify({ p }, scope)
  return true
end

-- remove every override of a layer whose key starts with prefix ('glow.spark' or 'glow'); '' = everything
function M.reset_prefix(prefix, scope)
  scope = scope == 'project' and 'project' or 'global'
  if not merged then M.load() end
  local n = 0
  for _, o in ipairs(M.overrides(scope)) do
    if prefix == '' or o.key == prefix or o.key:sub(1, #prefix + 1) == prefix .. '.' then
      prune(layers[scope], split_path(o.key))
      n = n + 1
    end
  end
  if n == 0 then return 0 end
  revalidate(scope)
  rebuild()
  save(scope)
  notify({ prefix }, scope)
  return n
end

-- merge a partial tree (a preset's config) into a layer: lists replace, scalars overwrite; returns the keys written
function M.apply(tree, scope)
  scope = scope == 'project' and 'project' or 'global'
  if not merged then M.load() end
  local keys = {}
  local function walk(node, prefix)
    for k, v in pairs(node) do
      local p = prefix == '' and tostring(k) or (prefix .. '.' .. tostring(k))
      if p ~= 'schema' then
        if schema.entry(p) or type(v) ~= 'table' or is_list(v) then
          set_in(layers[scope], split_path(p), deep_copy(v))
          keys[#keys + 1] = p
        else
          walk(v, p)
        end
      end
    end
  end
  walk(tree or {}, '')
  table.sort(keys)
  revalidate(scope)
  rebuild()
  save(scope)
  notify(keys, scope)
  return keys
end

-- the user's answer to a reported problem: drop the offending value from its layer (the default applies)
function M.drop_issue(issue)
  return M.reset(issue.key, issue.scope)
end

return M
