-- modules/agent/api.lua - what an agent reads: plain tables the ctl verbs serialise as JSON replies (lib/ctl.reply).
-- Every builder reads REAPER and the shared libs directly (tracks, regions, families, journal, config, schema);
-- the modules are looked up softly through the app registry (a module that is not loaded is reported as
-- loaded = false, never required). Nothing here changes the project. Lua 5.4; no globals.

local tracks = require('lib.tracks')
local regions = require('lib.regions')
local families = require('lib.families')
local journal = require('lib.journal')
local view = require('lib.view')
local config = require('config')
local schema = require('schema')
local state = require('state')
local log = require('lib.log')
local ctl = require('lib.ctl')
local json = require('lib.json')

local API = {}

local app

function API.init(app_)
  app = app_
end

local function mod(name)
  return app and app.by_name[name] or nil
end

local function round(v, places)
  if type(v) ~= 'number' then return v end
  local m = 10 ^ (places or 3)
  return math.floor(v * m + 0.5) / m
end

local function hex(native)
  if not native or native == 0 then return nil end
  local r, g, b = reaper.ColorFromNative(math.floor(native) & 0xFFFFFF)
  return string.format('#%02X%02X%02X', r, g, b)
end

-- project and transport ---------------------------------------------------------------------------------------------------

function API.project()
  local _, path = reaper.EnumProjects(-1, '')
  path = path or ''
  local _, n_markers, n_regions = reaper.CountProjectMarkers(0)
  return {
    name = state.project_name(), path = path, saved = path ~= '', dirty = reaper.IsProjectDirty(0) == 1,
    length_s = round(reaper.GetProjectLength(0)), tracks = reaper.CountTracks(0), items = reaper.CountMediaItems(0),
    regions = n_regions, markers = n_markers, state_count = reaper.GetProjectStateChangeCount(0),
    ctl_dir = ctl.dir(),
  }
end

function API.transport()
  local ps = reaper.GetPlayState()
  local ts0, ts1 = view.get_time_selection()
  local l0, l1 = view.get_loop_range()
  local v0, v1 = view.get()
  return {
    playing = ps & 1 == 1, paused = ps & 2 == 2, recording = ps & 4 == 4,
    position_s = round(view.position()), cursor_s = round(reaper.GetCursorPosition()),
    time_selection = { round(ts0), round(ts1) }, loop = { round(l0), round(l1) },
    ['repeat'] = reaper.GetSetRepeat(-1) == 1, view = { round(v0), round(v1) },
  }
end

-- the modules' live state ------------------------------------------------------------------------------------------------------

function API.modules()
  local out = {}
  local nav = mod('navigator')
  if nav and nav.D then
    local D, A, S = nav.D, nav.A, nav.S
    local scene = D.active_scene()
    out.navigator = {
      loaded = true, scenes = #D.scenes, markers = #D.markers, tracks = #D.tracks,
      active_scene = scene and scene.name or nil, solo_scene = A.solo_scene_name, mute_scene = A.mute_scene_name,
      focus = S.focus == true, families_off = (function()
        local off = {}
        for name, on in pairs(S.fam or {}) do if on == false then off[#off + 1] = name end end
        table.sort(off)
        return off
      end)(),
    }
  else
    out.navigator = { loaded = false }
  end
  local dir = mod('director')
  if dir and dir.E then
    local E, MD, S = dir.E, dir.MD, dir.S
    local k, s = E.current()
    out.director = {
      loaded = true, shots = #MD.shots, active = E.active == true, auto = E.auto == true,
      current_k = k, current_name = s and s.name or nil, issues = S.issue_counts,
    }
  else
    out.director = { loaded = false }
  end
  local hud = mod('hud')
  out.hud = hud and hud.H and { loaded = true, visible = hud.H.visible == true, tier = hud.H.tier } or { loaded = false }
  local glow = mod('glow')
  out.glow = glow and glow.E and { loaded = true, enabled = glow.E.enabled == true, mode = glow.E.mode, composited = glow.O and glow.O.bmp ~= nil } or { loaded = false }
  local ov = mod('overview')
  out.overview = ov and ov.L and { loaded = true, active = ov.L.active == true } or { loaded = false }
  local rec = mod('recorder')
  out.recorder = rec and rec.S and { loaded = true, armed = rec.S.armed == true, last_token = rec.S.last_token } or { loaded = false }
  local st = mod('stems')
  if st and st.MD then
    local r = st.E.results
    out.stems = {
      loaded = true, stems = #st.MD.stems, enabled = st.MD.enabled_count(), batch_active = st.E.active == true,
      results = r and { n = r.n, ok = r.ok, failed = r.failed, skipped = r.skipped, silent = r.silent, started = r.started, dir = r.dir } or nil,
    }
  else
    out.stems = { loaded = false }
  end
  return out
end

function API.journal()
  local by_owner, by_kind, n = {}, {}, 0
  for _, e in ipairs(journal.entries()) do
    n = n + 1
    by_owner[e.owner or '?'] = (by_owner[e.owner or '?'] or 0) + 1
    by_kind[e.kind or '?'] = (by_kind[e.kind or '?'] or 0) + 1
  end
  return { entries = n, by_owner = by_owner, by_kind = by_kind }
end

function API.state(agent)
  local issues = config.issues()
  return {
    stagehand = { version = app.version, reaper = reaper.GetAppVersion(), os = reaper.GetOS(), frame = app.frame,
      js = app.caps and app.caps.js_version or false, sws = app.caps and app.caps.sws_version or false },
    project = API.project(), transport = API.transport(), modules = API.modules(), journal = API.journal(),
    config = { path = config.path(), issues = #issues },
    agent = agent,
  }
end

-- the census: tracks with families, scenes, markers with classes, families and groups ------------------------------------

function API.census()
  local fams = families.compile()
  local list = tracks.scan()
  local hist = families.assign(fams, list)
  local classes = regions.compile_classes(config.get('navigator.marker_classes'))
  local last_len = config.get('navigator.audition.last_marker_len_s') or 5
  local scenes, markers = regions.scan(classes, last_len)
  regions.count_items(scenes)
  local out_tracks, folders, with_items, fx_total, env_total = {}, 0, 0, 0, 0
  for _, e in ipairs(list) do
    local fx = reaper.TrackFX_GetCount(e.tr)
    local envs = reaper.CountTrackEnvelopes(e.tr)
    fx_total, env_total = fx_total + fx, env_total + envs
    if e.folder then folders = folders + 1 end
    if e.items > 0 then with_items = with_items + 1 end
    out_tracks[#out_tracks + 1] = {
      n = e.n, guid = e.guid, name = e.name, depth = e.depth, folder = e.folder, parent = e.parent, items = e.items,
      family = e.fam, color = hex(e.color), fx = fx, envelopes = envs,
      solo = reaper.GetMediaTrackInfo_Value(e.tr, 'I_SOLO') > 0, mute = reaper.GetMediaTrackInfo_Value(e.tr, 'B_MUTE') == 1,
      visible = reaper.GetMediaTrackInfo_Value(e.tr, 'B_SHOWINTCP') == 1,
    }
  end
  local out_scenes = {}
  for k, s in ipairs(scenes) do
    out_scenes[k] = { k = k, idx = s.idx, name = s.name, t0 = round(s.t0), t1 = round(s.t1), length_s = round(s.t1 - s.t0), items = s.items, color = hex(s.color) }
  end
  local out_markers = {}
  for k, m in ipairs(markers) do
    out_markers[k] = { k = k, idx = m.idx, name = m.name, t0 = round(m.t0), class = m.class and m.class.name or nil, color = hex(m.color) }
  end
  local out_fams = {}
  for _, f in ipairs(fams.all) do
    out_fams[#out_fams + 1] = { name = f.name, rule = f.rule, color = f.color, other = f.other == true, tracks = hist[f.name] or 0 }
  end
  local groups = {}
  for _, g in ipairs(config.get('navigator.groups') or {}) do
    groups[#groups + 1] = { name = g.name, key = g.key, t0 = g.t0, t1 = g.t1 }
  end
  return {
    project = API.project(),
    summary = { tracks = #list, folders = folders, tracks_with_items = with_items, items = reaper.CountMediaItems(0),
      scenes = #scenes, markers = #markers, fx = fx_total, envelopes = env_total, length_s = round(reaper.GetProjectLength(0)) },
    families = out_fams, groups = groups, scenes = out_scenes, markers = out_markers, tracks = out_tracks,
  }
end

-- the Director's shot list with the validator's issues -----------------------------------------------------------------------

function API.shotlist()
  local dir = mod('director')
  if not dir or not dir.MD then return { loaded = false, shots = {} } end
  local MD, E, S, U = dir.MD, dir.E, dir.S, dir.U
  local issues = S.issues
  if (not issues or S.validate_request) and U and U.validate then
    local ok, res = pcall(U.validate)
    if ok then issues = res else log.warn('agent: validate failed: %s', tostring(res)) end
  end
  local shots = {}
  for k, s in ipairs(MD.shots) do
    shots[k] = MD.copy(s)
    shots[k].k = k
    shots[k].length_s = round(s.t1 - s.t0)
  end
  local out_issues = {}
  for _, i in ipairs(issues or {}) do out_issues[#out_issues + 1] = { level = i.level, k = i.k, text = i.text } end
  local k, cur = E.current()
  return {
    loaded = true, shots = shots, n = #MD.shots, length_s = round(MD.length()), issues = out_issues, counts = S.issue_counts,
    run = { active = E.active == true, auto = E.auto == true, current_k = k, current_name = cur and cur.name or nil },
  }
end

-- the stem set and the last batch ---------------------------------------------------------------------------------------------------

function API.stemset()
  local st = mod('stems')
  if not st or not st.MD then return { loaded = false, stems = {} } end
  local MD, E = st.MD, st.E
  local stems = {}
  for k, s in ipairs(MD.stems) do
    local cells = {}
    for guid, cell in pairs(s.cells or {}) do
      cells[#cells + 1] = { guid = guid, cell = cell, name = s.names and s.names[guid] or nil }
    end
    table.sort(cells, function(a, b) return (a.name or '') < (b.name or '') end)
    stems[k] = { k = k, id = s.id, name = s.name, enabled = s.enabled ~= false, variant = s.variant, source = s.source,
      range = s.range and { name = s.range.name, t0 = round(s.range.t0), t1 = round(s.range.t1) } or nil, cells = cells, n_cells = #cells }
  end
  local render = {}
  for _, key in ipairs({ 'format', 'srate', 'channels', 'bounds', 'tail_ms', 'normalize', 'normalize_target_db', 'pattern', 'dir', 'overwrite' }) do
    render[key] = config.get('stems.render.' .. key)
  end
  local r = E.results
  return {
    loaded = true, stems = stems, n = #MD.stems, enabled = MD.enabled_count(), batch_active = E.active == true,
    render = render, last_batch = r and { started = r.started, dir = r.dir, n = r.n, ok = r.ok, failed = r.failed, skipped = r.skipped, silent = r.silent } or nil,
  }
end

function API.results()
  local st = mod('stems')
  if not st or not st.E then return { loaded = false } end
  local r = st.E.results
  if not r then return { loaded = true, results = nil } end
  return { loaded = true, results = r }
end

-- configuration --------------------------------------------------------------------------------------------------------------------

local function describe(entry)
  return { key = entry.key, type = entry.type, module = entry.module, group = entry.group, range = schema.range_text(entry),
    values = entry.values, unit = entry.unit, value = config.get(entry.key), default = config.default(entry.key),
    override_project = config.has_override(entry.key, 'project'), override_global = config.has_override(entry.key, 'global') }
end

function API.config_get(key)
  local entry = schema.entry(key)
  if not entry then return nil, 'unknown key "' .. tostring(key) .. '"' end
  return describe(entry)
end

function API.config_list(prefix)
  prefix = prefix or ''
  local out = {}
  for _, entry in ipairs(schema.keys) do
    local k = entry.key
    if prefix == '' or k == prefix or k:sub(1, #prefix + 1) == prefix .. '.' then
      out[#out + 1] = { key = k, type = entry.type, value = config.get(k), default = config.default(k), range = schema.range_text(entry),
        override_project = config.has_override(k, 'project') or nil, override_global = config.has_override(k, 'global') or nil }
    end
  end
  return { prefix = prefix, n = #out, keys = out, issues = config.issues() }
end

-- text -> a value of the entry's type, checked against the schema (nil, reason when it does not fit)
function API.config_parse(entry, text)
  local ty = entry.type
  text = tostring(text or '')
  if ty == 'bool' then
    local s = text:lower()
    if s == 'on' or s == 'true' or s == '1' or s == 'yes' then return true end
    if s == 'off' or s == 'false' or s == '0' or s == 'no' then return false end
    return nil, 'not a boolean (on / off)'
  elseif ty == 'enum' or ty == 'str' or ty == 'path' then
    local ok, why = schema.check(entry, text)
    if not ok then return nil, why end
    return text
  elseif ty == 'list' or ty == 'table' then
    local v, err = json.decode(text)
    if v == nil then return nil, 'not JSON: ' .. tostring(err) end
    local ok, why = schema.check(entry, v)
    if not ok then return nil, why end
    return v
  end
  return schema.parse(entry, text)
end

function API.config_set(key, text, scope)
  local entry = schema.entry(key)
  if not entry then return nil, 'unknown key "' .. tostring(key) .. '"' end
  local v, why = API.config_parse(entry, text)
  if v == nil then return nil, string.format('%s: %s (%s)', key, why, schema.range_text(entry) or entry.type) end
  scope = scope == 'global' and 'global' or 'project'
  config.set(key, v, scope)
  local d = describe(entry)
  d.scope = scope
  return d
end

function API.config_reset(key, scope)
  local entry = schema.entry(key)
  if not entry then return nil, 'unknown key "' .. tostring(key) .. '"' end
  scope = scope == 'global' and 'global' or 'project'
  local removed = config.reset(key, scope)
  local d = describe(entry)
  d.scope, d.removed = scope, removed
  return d
end

return API
