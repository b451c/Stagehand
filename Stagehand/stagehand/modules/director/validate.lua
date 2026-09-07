-- modules/director/validate.lua - the in-app shot-list checker (the source job had it as an offline script).
--
-- run(shots, ctx) -> issues: list of { level = 'error' | 'warn' | 'info', k = shot index or nil, text }
-- ctx = { tracks (lib/tracks.scan with .fam), H (arrange height px), cfg = director config table,
--         pins = list, parents, mode }. Checks: coverage (gaps, overlaps, order), empty ranges, lane rules that
-- resolve to nothing, lanes without items in the shot, tracks that play but are not shown, caption length,
-- envelope rules that match nothing, lead vs page padding, and the height budget at H (lanes that will not
-- fit even at the minimum lane height). Lua 5.4; no globals.

local R = require('modules.director.resolve')
local text = require('lib.text')
local i18n = require('i18n')

local t = i18n.t

local V = {}

local function add(issues, level, k, s)
  issues[#issues + 1] = { level = level, k = k, text = s }
end

local function names_of(list, max)
  local out = {}
  for i, e in ipairs(list) do
    if i > max then out[#out + 1] = '...'; break end
    out[#out + 1] = e.name
  end
  return table.concat(out, ', ')
end

function V.run(shots, ctx)
  local issues = {}
  local cfg = ctx.cfg
  local H = ctx.H or 760
  if #shots == 0 then
    add(issues, 'info', nil, t('dir.val.no_shots'))
    return issues
  end
  local lead = tonumber(cfg.timing.lead_s) or 0.4
  local pad_before = tonumber(cfg.view.pad_before_s) or 0.6
  if lead > pad_before + 1e-6 then
    add(issues, 'warn', nil, string.format(t('dir.val.lead_gt_pad'), lead, pad_before))
  end
  local max_caption = tonumber(cfg.validate.caption_max_chars) or 135
  for k, s in ipairs(shots) do
    if s.t1 - s.t0 < 0.05 then
      add(issues, 'error', k, string.format(t('dir.val.empty_range'), text.fmt_time(s.t0), text.fmt_time(s.t1)))
    end
    if s.name == '' then add(issues, 'warn', k, t('dir.val.no_name')) end
    local prev = shots[k - 1]
    if prev then
      local gap = s.t0 - prev.t1
      if gap > 0.05 then
        add(issues, 'warn', k, string.format(t('dir.val.gap'), gap, k - 1))
      elseif gap < -0.05 then
        add(issues, 'warn', k, string.format(t('dir.val.overlap'), -gap, k - 1))
      end
    end
    if #s.caption > max_caption then
      add(issues, 'warn', k, string.format(t('dir.val.caption_long'), #s.caption, max_caption))
    end
    if #s.caption2 > max_caption then
      add(issues, 'warn', k, string.format(t('dir.val.caption2_long'), #s.caption2, max_caption))
    end
    if #s.lanes == 0 then add(issues, 'warn', k, t('dir.val.no_lanes')) end
    local role, keep_h, _, counts, lane_counts = R.roles(s, ctx.tracks, {
      pins = ctx.pins, parents = s.parents or ctx.parents, pin_enable = cfg.pins.enable ~= false,
    })
    for i, l in ipairs(s.lanes) do
      if (lane_counts[i] or 0) == 0 then
        add(issues, 'error', k, string.format(t('dir.val.lane_empty'), i, require('modules.director.model').lane_label(l)))
      end
    end
    if counts.lanes == 0 and #s.lanes > 0 then add(issues, 'error', k, t('dir.val.no_lane_tracks')) end
    -- lanes without items in the range
    local silent = {}
    for kk, r in pairs(role) do
      local e = ctx.tracks[kk]
      if r == 'lane' and not require('lib.tracks').has_items_in(e.tr, s.t0, s.t1) then silent[#silent + 1] = e end
    end
    table.sort(silent, function(a, b) return a.n < b.n end)
    if #silent > 0 then
      add(issues, 'warn', k, string.format(t('dir.val.lanes_silent'), #silent, names_of(silent, 5)))
    end
    local hidden = R.playing_hidden(s, ctx.tracks, role)
    if #hidden > 0 then
      add(issues, 'info', k, string.format(t('dir.val.playing_hidden'), #hidden, names_of(hidden, 5)))
    end
    -- envelope rules
    if #s.envelopes > 0 then
      local _, _, env_counts = R.envelopes(s, ctx.tracks)
      for i, r in ipairs(s.envelopes) do
        if (env_counts[i] or 0) == 0 then
          add(issues, 'warn', k, string.format(t('dir.val.env_empty'), i, r.track, r.env))
        end
      end
    end
    -- height budget at H
    local fixed = 0
    local env_lane = tonumber(cfg.heights.env_lane_px) or 26
    local shown_env = 0
    if cfg.envelopes.mode == 'story' and #s.envelopes > 0 then
      local want = R.envelopes(s, ctx.tracks)
      for kk, rows in pairs(want) do
        if role[kk] then
          for _, row in ipairs(rows) do if row.want then shown_env = shown_env + 1 end end
        end
      end
    end
    for kk, r in pairs(role) do
      if r == 'keep' then fixed = fixed + keep_h[kk]
      elseif r == 'parent' then fixed = fixed + (tonumber(cfg.heights.parent_px) or 24) end
    end
    fixed = fixed + shown_env * env_lane
    local lane_min = tonumber(cfg.heights.lane_min_px) or 26
    local need = fixed + counts.lanes * lane_min
    if counts.lanes > 0 and need > H then
      add(issues, 'warn', k, string.format(t('dir.val.wont_fit'), counts.lanes, need, H, lane_min))
    end
  end
  return issues
end

function V.counts(issues)
  local c = { error = 0, warn = 0, info = 0 }
  for _, i in ipairs(issues) do c[i.level] = (c[i.level] or 0) + 1 end
  return c
end

return V
