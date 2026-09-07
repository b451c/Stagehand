-- modules/settings/selftest.lua - the scripted Settings scenario the test harness runs.
-- Oracles: the schema against config.defaults and the string table (coverage both ways), the
-- real config paths (a project layer written to ProjExtState and reloaded, a schema-1 global file written to
-- the clone's config.json and migrated with its backup), the four shipped presets parsed from disk, a preset
-- written and read back through the file, the tab's own row counter under a search, and lib/layout.dump()
-- before and after (Settings must not touch the project). Sabotage "keep_invalid" (negative control) merges
-- the raw layers, so the "invalid value falls back to the default" checks must go red. Lua 5.4; no globals.

local layout = require('lib.layout')
local config = require('config')
local schema = require('schema')
local json = require('lib.json')
local i18n = require('i18n')
local state = require('state')

local ST = {}

local app, S, U, P

function ST.init(app_, S_, U_, P_)
  app, S, U, P = app_, S_, U_, P_
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

local function file_exists(p)
  local f = io.open(p, 'r')
  if f then f:close(); return true end
  return false
end

local function count_issues(kind)
  local n = 0
  for _, it in ipairs(config.issues()) do
    if it.kind == kind then n = n + 1 end
  end
  return n
end

local function issue_for(key)
  for _, it in ipairs(config.issues()) do
    if it.key == key then return it end
  end
  return nil
end

local function set_project_layer(tbl)
  state.pset('config', json.encode(tbl))
  config.reload_project()
end

function ST.run(T)
  T.fact('variant', T.variant == '' and 'demo' or T.variant)
  T.fact('sabotage', T.sabotage == '' and 'none' or T.sabotage)
  if T.sabotage ~= '' then config.sabotage = T.sabotage end
  T.wait(2)
  local before = layout.dump()
  layout.write(T.out_path('layout_before.json'), before)
  local project_layer_before = config.layer('project')
  local global_text_before = read_file(config.path())

  -- 1. the schema covers the defaults and the strings cover the schema ------------------------------------------------
  local cov = schema.coverage(config.defaults)
  T.fact('schema_keys', #schema.keys)
  T.fact('schema_groups', #schema.groups)
  T.fact('schema_version', schema.VERSION)
  T.check('every default leaf has a schema entry', #cov.uncovered, 0)
  if #cov.uncovered > 0 then T.log('UNCOVERED ' .. table.concat(cov.uncovered, ' ')) end
  T.check('every schema entry has a default', #cov.missing, 0)
  if #cov.missing > 0 then T.log('MISSING ' .. table.concat(cov.missing, ' ')) end
  local no_label, no_tip, bad_default, no_val = {}, {}, {}, {}
  local seen_val = {}
  for _, e in ipairs(schema.keys) do
    if not i18n.has('cfg.' .. e.key) then no_label[#no_label + 1] = e.key end
    if not i18n.has('cfg.' .. e.key .. '.tip') then no_tip[#no_tip + 1] = e.key end
    local ok, why = schema.check(e, config.default(e.key))
    if not ok then bad_default[#bad_default + 1] = e.key .. ': ' .. tostring(why) end
    if e.type == 'enum' then
      for _, v in ipairs(e.values) do
        if not seen_val[v] then
          seen_val[v] = true
          if not i18n.has('cfg.val.' .. v) then no_val[#no_val + 1] = v end
        end
      end
    end
  end
  T.check('every key has a label string', #no_label, 0)
  if #no_label > 0 then T.log('NO_LABEL ' .. table.concat(no_label, ' ')) end
  T.check('every key has a tooltip string', #no_tip, 0)
  if #no_tip > 0 then T.log('NO_TIP ' .. table.concat(no_tip, ' ')) end
  T.check('every default passes its own check', #bad_default, 0)
  if #bad_default > 0 then T.log('BAD_DEFAULT ' .. table.concat(bad_default, '; ')) end
  T.check('every enum value has a label', #no_val, 0)
  if #no_val > 0 then T.log('NO_VAL ' .. table.concat(no_val, ' ')) end
  local no_group = {}
  for _, g in ipairs(schema.groups) do
    if not i18n.has('cfg.group.' .. g.id) then no_group[#no_group + 1] = g.id end
  end
  T.check('every group has a label', #no_group, 0)
  if #no_group > 0 then T.log('NO_GROUP ' .. table.concat(no_group, ' ')) end
  local no_mod = 0
  for _, m in ipairs(schema.MODULES) do if not i18n.has('cfg.module.' .. m) then no_mod = no_mod + 1 end end
  T.check('every module has a label', no_mod, 0)
  T.check('range text of a numeric key', schema.range_text(schema.entry('director.timing.lead_s')), '0 .. 2 s')
  T.check('format of a number drops trailing zeros', schema.format(schema.entry('glow.warm_amount'), 0.5), '0.5')
  T.check('parse of an int list', json.encode(schema.parse(schema.entry('hud.font.caption_steps'), '20, 18,16')), '[20,18,16]')
  local _, perr = schema.parse(schema.entry('hud.font.caption_steps'), '20, x')
  T.ok('parse of a bad int list reports the token', perr ~= nil and perr:find('"x"', 1, true) ~= nil, tostring(perr))

  -- 2. invalid values in a layer: reported, left out of the merge, never rewritten --------------------------------------
  set_project_layer({
    schema = schema.VERSION,
    director = { timing = { lead_s = 'fast' } },
    glow = { mode = 'rainbow', spark = { alpha = 7 } },
    hud = { colors = { bg = 'red' } },
    navigator = { groups = { { key = '1' } } },
    mystery = 1,
  })
  T.check('invalid values reported', count_issues('invalid'), 5)
  T.check('unknown key reported', count_issues('unknown'), 1)
  local it = issue_for('glow.spark.alpha')
  T.ok('reason names the range', it ~= nil and it.reason:find('above the maximum', 1, true) ~= nil, it and it.reason or 'no issue')
  T.check('invalid lead falls back to the default', config.get('director.timing.lead_s'), 0.4, 1e-9)
  T.check('invalid mode falls back to the default', config.get('glow.mode'), 'meter')
  T.check('out-of-range alpha falls back to the default', config.get('glow.spark.alpha'), 0.75, 1e-9)
  T.check('invalid colour falls back to the default', config.get('hud.colors.bg'), '#0E1014')
  T.check('invalid value stays in the layer (not rewritten)', config.raw('glow.spark.alpha', 'project'), 7)
  T.check('unknown key kept in the merge', config.get('mystery'), 1)
  config.drop_issue(issue_for('glow.mode'))
  T.check('dropping an issue removes the value', config.raw('glow.mode', 'project'), nil)
  T.check('issue count after the drop', count_issues('invalid'), 4)
  local praw = json.decode(state.pget('config') or '{}')
  T.check('drop written to the project record', praw.glow and praw.glow.mode, nil)
  T.check('other invalid values still in the project record', praw.glow and praw.glow.spark and praw.glow.spark.alpha, 7)

  -- 3. migration: a schema-1 project layer and a schema-1 global file ------------------------------------------------------
  set_project_layer({ schema = 1, navigator = { layout = { compact_below_px = 500 }, jump = { marker_window_s = 3 } } })
  T.check('migrated key read from the new place', config.get('ui.compact_below_px'), 500)
  T.check('old key gone after the migration', config.raw('navigator.layout', 'project'), nil)
  T.check('untouched key survives the migration', config.get('navigator.jump.marker_window_s'), 3, 1e-9)
  T.check('project layer stamped with the schema', config.layer('project').schema, schema.VERSION)
  local praw2 = json.decode(state.pget('config') or '{}')
  T.check('migrated project record written back', praw2.ui and praw2.ui.compact_below_px, 500)
  set_project_layer({})
  local old_global = '{\n  "schema": 1,\n  "navigator": { "layout": { "compact_below_px": 480 } },\n  "glow": { "warm_amount": 0.3 }\n}\n'
  local bak = config.path() .. '.schema1.bak'
  os.remove(bak)
  write_file(config.path(), old_global)
  config.load()
  T.check('global file migrated: value in the new place', config.get('ui.compact_below_px'), 480)
  T.check('global file migrated: other value kept', config.get('glow.warm_amount'), 0.3, 1e-9)
  T.check('global backup written before the rewrite', read_file(bak), old_global)
  local new_global = json.decode(read_file(config.path()) or '')
  T.check('global file rewritten with the new schema', new_global and new_global.schema, schema.VERSION)
  T.check('global file rewritten without the old key', new_global and new_global.navigator and new_global.navigator.layout, nil)
  local has_note = false
  for _, n in ipairs(config.notes()) do if n:find('migrated', 1, true) then has_note = true end end
  T.check('migration note for the Settings tab', has_note, true)
  os.remove(bak)
  if global_text_before then write_file(config.path(), global_text_before) else os.remove(config.path()) end
  config.load()
  T.check('global file restored after the test', read_file(config.path()), global_text_before)

  -- 4. presets: the shipped four, a round-trip through a file, apply, refuse an invalid one ---------------------------------
  local list = P.list()
  local builtin = {}
  for _, p in ipairs(list) do
    if p.source == 'builtin' then
      builtin[p.name] = p
      T.fact('preset_' .. p.name:lower():gsub('%s+', '_'), string.format('issues=%d unknown=%d broken=%s', #p.issues, p.unknown or 0, tostring(p.broken)))
    end
  end
  T.fact('presets_builtin_dir', P.builtin_dir())
  T.fact('presets_user_dir', P.user_dir())
  for _, name in ipairs({ 'Client showcase', 'Tutorial', 'Quick navigation', 'Minimal glow' }) do
    local p = builtin[name]
    T.ok('shipped preset "' .. name .. '" loads clean', p ~= nil and p.broken == nil and #p.issues == 0, p and (tostring(p.broken) .. ' ' .. #p.issues) or 'not found')
  end
  local keys = P.apply(builtin['Minimal glow'], 'project')
  T.ok('Minimal glow applied to the project', keys ~= nil and #keys > 0, keys and #keys or 'nil')
  T.check('Minimal glow sets the edge style', config.get('glow.style'), 'edge')
  T.check('Minimal glow is an override of this project', config.has_override('glow.style', 'project'), true)
  config.reset_prefix('', 'project')
  T.check('reset everything empties the project layer', #config.overrides('project'), 0)
  config.set('director.timing.lead_s', 0.55, 'project')
  config.set('hud.colors.accent', '#112233', 'project')
  config.set('hud.font.caption_steps', { 20, 18 }, 'project')
  config.set('glow.profiles', { { name = 'fx', family = 'SFX', detector = { onset_db = 4 } } }, 'project')
  T.check('overrides counted as leaves', #config.overrides('project'), 4)
  local built = P.build('roundtrip', 'self-test', 'project')
  local text = P.encode(built)
  local parsed, perr2 = P.parse(text)
  T.ok('exported preset parses', parsed ~= nil, tostring(perr2))
  T.check('exported preset carries the schema', built.stagehand_preset.schema, schema.VERSION)
  local layer_json = json.encode((function() local l = config.layer('project'); l.schema = nil; return l end)())
  T.check('round-trip config equals the layer', parsed and json.encode(parsed.config) or '', layer_json)
  config.reset_prefix('', 'project')
  local applied = P.apply(parsed, 'project')
  T.check('round-trip apply writes four keys', applied and #applied or 0, 4)
  T.check('round-trip value: number', config.get('director.timing.lead_s'), 0.55, 1e-9)
  T.check('round-trip value: colour', config.get('hud.colors.accent'), '#112233')
  T.check('round-trip value: int list', json.encode(config.get('hud.font.caption_steps')), '[20,18]')
  T.check('round-trip value: profiles', config.get('glow.profiles')[1].detector.onset_db, 4)
  local saved = P.save('Selftest preset', 'made by the self-test', 'project')
  T.ok('user preset saved', saved ~= nil and file_exists(saved), tostring(saved))
  local list2 = P.list()
  local mine = P.find(list2, 'Selftest preset', 'user')
  T.ok('user preset listed', mine ~= nil, mine and mine.path or 'not listed')
  local rt_path = T.out_path('preset_export.json')
  local exported = P.export('selftest-export', 'project', rt_path)
  T.check('export to a path', exported, rt_path)
  local imported, info = P.import(rt_path)
  T.ok('import reads the file back', imported ~= nil and #imported.issues == 0, tostring(info))
  if imported and imported.path ~= info and info and info:find('%.json$') then os.remove(info) end
  if saved then os.remove(saved) end
  local bad, berr = P.parse('{ "hello": 1 }')
  T.ok('a file without the header is refused', bad == nil and berr ~= nil, tostring(berr))
  local badp = P.parse('{ "stagehand_preset": { "name": "bad", "schema": 2 }, "config": { "glow": { "mode": "rainbow" } } }')
  T.check('a preset with an invalid value lists it', badp and #badp.issues or 0, 1)
  local r, why = P.apply(badp, 'project')
  T.ok('an invalid preset is not applied', r == nil and why ~= nil, tostring(why))
  local oldp = P.parse('{ "stagehand_preset": { "name": "old", "schema": 1 }, "config": { "navigator": { "layout": { "compact_below_px": 333 } } } }')
  T.check('a schema-1 preset is migrated on load', oldp and oldp.config.ui and oldp.config.ui.compact_below_px, 333)

  -- 5. writes: group reset, preview / commit, change notification ------------------------------------------------------------
  config.reset_prefix('', 'project')
  config.set('glow.spark.alpha', 0.5, 'project')
  config.set('glow.spark.width_px', 5, 'project')
  config.set('glow.warm_amount', 0.9, 'project')
  T.check('group reset removes the group only', config.reset_prefix('glow.spark', 'project'), 2)
  T.check('group reset leaves the neighbour', config.get('glow.warm_amount'), 0.9, 1e-9)
  T.check('group reset restores the defaults', config.get('glow.spark.alpha'), 0.75, 1e-9)
  local seen = {}
  config.on_change(function(keys, scope) for _, k in ipairs(keys) do seen[#seen + 1] = scope .. ':' .. k end end)
  config.preview('glow.warm_amount', 0.1, 'project')
  T.check('preview changes the merge', config.get('glow.warm_amount'), 0.1, 1e-9)
  local rec = json.decode(state.pget('config') or '{}')
  T.check('preview does not write the project record', rec.glow and rec.glow.warm_amount, 0.9, 1e-9)
  config.commit('project')
  rec = json.decode(state.pget('config') or '{}')
  T.check('commit writes the project record', rec.glow and rec.glow.warm_amount, 0.1, 1e-9)
  T.check('listener told about the preview', seen[1], 'project:glow.warm_amount')
  config.set('ui.theme', 'dark', 'project')
  T.check('listener told about a set', seen[#seen], 'project:ui.theme')
  config.reset('ui.theme', 'project')
  T.check('reset returns to the default', config.get('ui.theme'), 'auto')
  config.reset_prefix('', 'project')

  -- 6. the tab: search filters the rows, the scopes count their overrides -----------------------------------------------------
  app.set_tab('settings')
  for _, m in ipairs(schema.MODULES) do S.open[m] = true end
  S.search = ''
  T.wait(3)
  T.check('all rows drawn with an empty search', S.visible_rows, #schema.keys)
  S.search = 'director.timing.lead_s'
  T.wait(2)
  T.check('search by key shows one row', S.visible_rows, 1)
  S.search = 'spark'
  T.wait(2)
  T.fact('rows_for_spark', S.visible_rows)
  T.ok('search by word shows the spark rows', S.visible_rows >= 8, S.visible_rows)
  S.search = 'zzzznothing'
  T.wait(2)
  T.check('search with no hit shows nothing', S.visible_rows, 0)
  S.search = ''
  config.set('glow.warm_amount', 0.2, 'project')
  config.set('glow.warm_amount', 0.3, 'global')
  T.wait(2)
  T.check('project override visible', config.has_override('glow.warm_amount', 'project'), true)
  T.check('global override visible', config.has_override('glow.warm_amount', 'global'), true)
  T.check('project wins the merge', config.get('glow.warm_amount'), 0.2, 1e-9)
  local tip = U.tip_of(schema.entry('glow.warm_amount'))
  T.ok('tooltip carries the default and the key', tip:find('0.55', 1, true) ~= nil and tip:find('glow.warm_amount', 1, true) ~= nil, tip:gsub('\n', ' | '))
  config.reset('glow.warm_amount', 'global')
  config.reset('glow.warm_amount', 'project')
  T.check('global override gone', config.has_override('glow.warm_amount', 'global'), false)
  local frame_sum, n = 0, 0
  for _ = 1, 20 do
    T.wait(1)
    frame_sum = frame_sum + app.tick_ms_last
    n = n + 1
  end
  T.fact('settings_tab_frame_ms_avg', string.format('%.2f', frame_sum / n))

  -- 7. nothing in the project changed --------------------------------------------------------------------------------------------
  set_project_layer(project_layer_before)
  config.sabotage = nil
  config.load()
  local after = layout.dump()
  layout.write(T.out_path('layout_after.json'), after)
  local diff = layout.diff(before, after)
  for i, d in ipairs(diff) do
    if i <= 20 then T.log('DIFF ' .. d) end
  end
  T.log('RESTORE_DIFF ' .. #diff)
  T.check('restore diff', #diff, 0)
  T.check('project layer as before', json.encode(config.layer('project')), json.encode(project_layer_before))
  T.fact('frame', T.frame())
end

-- after DONE: one module expanded per screenshot, then a search
function ST.post(frames_since_done)
  local function only(mod)
    for _, m in ipairs(schema.MODULES) do S.open[m] = m == mod end
    S.search = ''
  end
  if frames_since_done == 1 then app.set_tab('settings'); only('navigator')
  elseif frames_since_done == 80 then only('director')
  elseif frames_since_done == 170 then only('hud')
  elseif frames_since_done == 260 then only('glow')
  elseif frames_since_done == 350 then only('ui')
  elseif frames_since_done == 440 then S.search = 'spark' end
end

return ST
