-- modules/stems/render.lua - the render settings Stagehand owns and how they reach the project.
--
-- Settings come from the config (stems.render.*): format, sample rate, channels, bounds, tail, normalisation,
-- the file pattern and a folder relative to the project, the overwrite policy. write(stem, k) journals every
-- RENDER_* value it changes (journal kinds render_num / render_str, owner 'stems') and writes the settings for
-- one stem through GetSetProjectInfo; targets() asks REAPER for the file names it would write (RENDER_TARGETS,
-- read-only) so the pre-flight knows the exact paths, and the stats() helper reads REAPER's render statistics
-- only when the preference that stores them is on (reading them while it is off raises a Yes/No dialog:
-- (failure note T1). Facts verified on both test machines on 2026-09-07 (a render probe):
-- 42230 renders synchronously from a script, a relative RENDER_FILE resolves against the project folder, the
-- "evaw" default depends on the machine's preferences (so the WAV bytes are always explicit), RENDER_ADDTOPROJ &2
-- (skip silent) and an empty range raise modal dialogs and are never used. Lua 5.4; no globals.

local config = require('config')
local journal = require('lib.journal')
local layout = require('lib.layout')
local log = require('lib.log')

local R = {}

local sep = package.config:sub(1, 1)

R.STATS_BIT = 1 << 21   -- renderclosewhendone: "save render statistics" (found on the test machine)

-- helpers --------------------------------------------------------------------------------------------------------------

local B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'

function R.b64(s)
  local out = {}
  for i = 1, #s, 3 do
    local a, b, c = s:byte(i, i + 2)
    local n = (a << 16) | ((b or 0) << 8) | (c or 0)
    out[#out + 1] = B64:sub(((n >> 18) & 63) + 1, ((n >> 18) & 63) + 1)
    out[#out + 1] = B64:sub(((n >> 12) & 63) + 1, ((n >> 12) & 63) + 1)
    out[#out + 1] = b and B64:sub(((n >> 6) & 63) + 1, ((n >> 6) & 63) + 1) or '='
    out[#out + 1] = c and B64:sub((n & 63) + 1, (n & 63) + 1) or '='
  end
  return table.concat(out)
end

function R.cfg(key)
  return config.get('stems.' .. key)
end

function R.project_dir()
  local _, name = reaper.EnumProjects(-1, '')
  name = name or ''
  local dir = name:match('^(.*)[/\\]')
  if not dir or dir == '' then return nil end
  return dir
end

function R.is_absolute(p)
  return p:sub(1, 1) == '/' or p:match('^%a:[/\\]') ~= nil or p:sub(1, 2) == '\\\\'
end

-- the output folder as REAPER will resolve it (absolute; nil when the project is unsaved and the folder relative)
function R.out_dir()
  local dir = tostring(R.cfg('render.dir') or '')
  if dir == '' then dir = 'Render' .. sep .. 'stems' end
  if R.is_absolute(dir) then return dir, dir end
  local pd = R.project_dir()
  if not pd then return nil, dir end
  return pd .. sep .. dir, dir
end

-- RENDER_FORMAT for the configured format: explicit WAV bytes ("evaw", bits, 0, 1: bits 16 / 24 / 32 = float),
-- the 4-byte defaults for FLAC and MP3, nil for "project" (the project's own format stays)
function R.format_string(fmt)
  fmt = fmt or R.cfg('render.format')
  if fmt == 'wav16' then return R.b64('evaw\16\0\1') end
  if fmt == 'wav24' then return R.b64('evaw\24\0\1') end
  if fmt == 'wav32f' then return R.b64('evaw\32\0\1') end
  if fmt == 'flac' then return 'calf' end
  if fmt == 'mp3' then return 'l3pm' end
  return nil
end

function R.format_ext(fmt)
  fmt = fmt or R.cfg('render.format')
  if fmt == 'flac' then return 'flac' end
  if fmt == 'mp3' then return 'mp3' end
  if fmt == 'project' then return nil end
  return 'wav'
end

function R.sanitize_name(name)
  local s = tostring(name or ''):gsub('[/\\:*?"<>|]', '_'):gsub('%s+$', ''):gsub('^%s+', '')
  if s == '' then s = 'stem' end
  return s
end

-- Stagehand's wildcards ($stem, $stemnumber, $scene, $variant); REAPER's own ($project, $date, $time...) stay
-- in the pattern for REAPER to expand
function R.expand(pattern, stem, k, variant)
  local s = tostring(pattern or '')
  local scene = stem and stem.range and stem.range.name or ''
  s = s:gsub('%$stemnumber', string.format('%02d', k or 0))
  s = s:gsub('%$stem', R.sanitize_name(stem and stem.name or 'stem'))
  s = s:gsub('%$scene', R.sanitize_name(scene))
  s = s:gsub('%$variant', tostring(variant or 'master'))
  return s
end

-- the render range of a stem: config bounds, or the stem's own range when it has one and bounds = 'stem'
-- returns { flag, t0, t1, desc } with flag = RENDER_BOUNDSFLAG (0 custom, 1 project, 2 time selection)
function R.bounds_of(stem)
  local mode = R.cfg('render.bounds') or 'stem'
  if mode == 'stem' then
    if stem and stem.range then return { flag = 0, t0 = stem.range.t0, t1 = stem.range.t1, desc = 'scene' } end
    mode = R.cfg('render.bounds_fallback') or 'project'
  end
  if mode == 'time_selection' then
    local a, b = reaper.GetSet_LoopTimeRange2(0, false, false, 0, 0, false)
    return { flag = 2, t0 = a, t1 = b, desc = 'time selection' }
  elseif mode == 'custom' then
    return { flag = 0, t0 = tonumber(R.cfg('render.custom_start_s')) or 0, t1 = tonumber(R.cfg('render.custom_end_s')) or 0, desc = 'custom' }
  end
  return { flag = 1, t0 = 0, t1 = reaper.GetProjectLength(0), desc = 'project' }
end

-- the effective settings (numbers REAPER wants), independent of any stem
function R.settings()
  local fmt = R.cfg('render.format') or 'wav24'
  local norm_mode = R.cfg('render.normalize') or 'off'
  local normalize = 0
  if norm_mode ~= 'off' then
    normalize = 1
    if norm_mode == 'peak' then normalize = normalize | 4
    elseif norm_mode == 'true_peak' then normalize = normalize | 6
    elseif norm_mode == 'lufs_m' then normalize = normalize | 8
    elseif norm_mode == 'lufs_s' then normalize = normalize | 10 end   -- lufs_i = 0 in bits 2..4
  end
  local target_db = tonumber(R.cfg('render.normalize_target_db')) or -23
  local tail_ms = math.floor(tonumber(R.cfg('render.tail_ms')) or 0)
  return {
    format = fmt, format_string = R.format_string(fmt), ext = R.format_ext(fmt),
    srate = math.floor(tonumber(R.cfg('render.srate')) or 0), channels = math.floor(tonumber(R.cfg('render.channels')) or 2),
    tail_ms = tail_ms, tailflag = tail_ms > 0 and (1 | 2 | 4) or 0,
    normalize = normalize, normalize_target = 10 ^ (target_db / 20),
    dither = R.cfg('render.dither') and 1 or 0,
    pattern = tostring(R.cfg('render.pattern') or '$stem'),
    overwrite = R.cfg('render.overwrite') or 'replace',
  }
end

-- journaled writes -----------------------------------------------------------------------------------------------------------

local function jnum(key, value)
  if not journal.has('render_num', key) then
    journal.add({ kind = 'render_num', key = key, was = reaper.GetSetProjectInfo(0, key, 0, false), owner = 'stems' })
  end
  reaper.GetSetProjectInfo(0, key, value, true)
end

local function jstr(key, value)
  if not journal.has('render_str', key) then
    local _, was = reaper.GetSetProjectInfo_String(0, key, '', false)
    journal.add({ kind = 'render_str', key = key, was = was or '', owner = 'stems' })
  end
  reaper.GetSetProjectInfo_String(0, key, value, true)
end

-- write the settings for one stem (k = its number in the batch); returns the bounds used
function R.write(stem, k, variant)
  local st = R.settings()
  local b = R.bounds_of(stem)
  local dir = R.out_dir()
  jnum('RENDER_SETTINGS', 0)                -- master mix: one solo state at a time (never stems mode, never the matrix)
  jnum('RENDER_BOUNDSFLAG', b.flag)
  if b.flag == 0 then
    jnum('RENDER_STARTPOS', b.t0)
    jnum('RENDER_ENDPOS', b.t1)
  end
  jnum('RENDER_CHANNELS', st.channels)
  jnum('RENDER_SRATE', st.srate)
  jnum('RENDER_TAILFLAG', st.tailflag)
  jnum('RENDER_TAILMS', st.tail_ms)
  jnum('RENDER_ADDTOPROJ', 0)               -- never &2 (skip silent): "Nothing to render!" would block the batch
  jnum('RENDER_DITHER', st.dither)
  jnum('RENDER_NORMALIZE', st.normalize)
  if st.normalize ~= 0 then jnum('RENDER_NORMALIZE_TARGET', st.normalize_target) end
  jstr('RENDER_FILE', dir or '')
  jstr('RENDER_PATTERN', R.expand(st.pattern, stem, k, variant))
  if st.format_string then jstr('RENDER_FORMAT', st.format_string) end
  jstr('RENDER_FORMAT2', '')
  return b
end

-- the files REAPER would write with the settings as they stand (semicolon separated list -> table)
function R.targets()
  local _, v = reaper.GetSetProjectInfo_String(0, 'RENDER_TARGETS', '', false)
  local out = {}
  for p in tostring(v or ''):gmatch('[^;]+') do out[#out + 1] = p end
  return out
end

-- the target of a stem without touching the project's settings: expand the pattern the way REAPER would for the
-- wildcards Stagehand knows, and leave REAPER's own untouched (the pre-flight compares these for collisions and
-- files that exist; the run reads RENDER_TARGETS for the truth after write())
function R.planned_target(stem, k, variant)
  local st = R.settings()
  local dir = R.out_dir()
  local name = R.expand(st.pattern, stem, k, variant)
  local ext = st.ext
  if not ext then
    local _, cur = reaper.GetSetProjectInfo_String(0, 'RENDER_FORMAT', '', false)
    ext = (cur or ''):sub(1, 4) == 'Y2Fs' and 'flac' or ((cur or ''):sub(1, 4) == 'bDNw' and 'mp3' or 'wav')
  end
  return (dir or '') .. sep .. name .. '.' .. ext, name
end

function R.restore_settings()
  return journal.restore(function(e) return e.owner == 'stems' and (e.kind == 'render_num' or e.kind == 'render_str') end)
end

-- REAPER's render statistics --------------------------------------------------------------------------------------------------

function R.stats_enabled()
  if not reaper.get_config_var_string then return false, 0 end
  local ok, v = reaper.get_config_var_string('renderclosewhendone')
  local n = math.floor(tonumber(v) or 0)
  return ok and (n & R.STATS_BIT) ~= 0, n
end

function R.can_enable_stats()
  return reaper.SNM_SetIntConfigVar ~= nil
end

-- turn the preference on for a batch (SWS); returns the previous value or nil
function R.enable_stats()
  local on, cur = R.stats_enabled()
  if on or not R.can_enable_stats() then return nil end
  reaper.SNM_SetIntConfigVar('renderclosewhendone', cur | R.STATS_BIT)
  log.info('stems: render statistics preference enabled for the batch (renderclosewhendone %d -> %d)', cur, cur | R.STATS_BIT)
  return cur
end

function R.restore_stats(prev)
  if prev == nil or not R.can_enable_stats() then return end
  reaper.SNM_SetIntConfigVar('renderclosewhendone', prev)
end

-- parse "FILE:x;LENGTH:0:06.000;PEAK:-3.469763;LUFSMMAX:..;LUFSSMAX:..;LUFSI:..;LRA:.." (a silent file has
-- FILE and LENGTH only); returns nil when the preference is off (the read is never attempted then)
function R.stats()
  if not R.stats_enabled() then return nil end
  local _, v = reaper.GetSetProjectInfo_String(0, 'RENDER_STATS', '', false)
  if not v or v == '' then return {} end
  local out = { raw = v }
  for field in v:gmatch('[^;]+') do
    local key, val = field:match('^(%u+):(.*)$')
    if key == 'FILE' then out.file = val
    elseif key == 'LENGTH' then
      local m, s = val:match('^(%d+):([%d.]+)$')
      out.length_s = m and (tonumber(m) * 60 + tonumber(s)) or tonumber(val)
    elseif key == 'PEAK' then out.peak_db = tonumber(val)
    elseif key == 'LUFSI' then out.lufs_i = tonumber(val)
    elseif key == 'LUFSMMAX' then out.lufs_m_max = tonumber(val)
    elseif key == 'LUFSSMAX' then out.lufs_s_max = tonumber(val)
    elseif key == 'LRA' then out.lra = tonumber(val)
    elseif key then out[key:lower()] = val end
  end
  return out
end

-- the dumped render fields (for the self-test's before / after comparison)
R.NUM_KEYS, R.STR_KEYS = layout.RENDER_NUM, layout.RENDER_STR

return R
