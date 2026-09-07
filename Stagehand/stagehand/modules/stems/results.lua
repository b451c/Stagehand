-- modules/stems/results.lua - the results of a batch as files next to the stems: stems_results.json (always: the
-- companion checker tools/stems_check.py reads it), .csv and .md by stems.export.results. One row per stem:
-- file, action (new / replaced / incremented / skipped), duration, sample peak (Stagehand's own scan of a WAV),
-- REAPER's statistics when its preference is on (peak, LUFS-I, LUFS-M max, LUFS-S max, LRA), the silent flag,
-- the render time and any error. Lua 5.4; no globals.

local json = require('lib.json')
local config = require('config')

local RS = {}

local sep = package.config:sub(1, 1)

local function fmt_db(v)
  if v == nil then return '' end
  if v <= -144 then return '-inf' end
  return string.format('%.2f', v)
end

local function fmt_s(v)
  if v == nil then return '' end
  return string.format('%.3f', v)
end

local function csv_cell(v)
  local s = tostring(v == nil and '' or v)
  if s:find('[",\r\n]') then s = '"' .. s:gsub('"', '""') .. '"' end
  return s
end

function RS.status_of(row)
  if row.error then return 'error' end
  if row.skipped then return 'skipped' end
  if row.silent then return 'silent' end
  if row.ok then return 'ok' end
  return 'pending'
end

function RS.to_csv(results)
  local lines = { 'index,stem,status,file,action,variant,bounds,start_s,end_s,duration_s,peak_dbfs,reaper_peak_dbfs,lufs_i,lufs_m_max,lufs_s_max,lra,silent,render_s,bytes,error' }
  for _, r in ipairs(results.rows or {}) do
    local row = { r.i, r.name, RS.status_of(r), r.file or '', r.action or '', r.variant or '', r.bounds or '', fmt_s(r.t0), fmt_s(r.t1), fmt_s(r.duration_s),
      fmt_db(r.peak_db), fmt_db(r.reaper_peak_db), fmt_db(r.lufs_i), fmt_db(r.lufs_m_max), fmt_db(r.lufs_s_max), r.lra and string.format('%.1f', r.lra) or '',
      r.silent and 'yes' or 'no', fmt_s(r.render_s), r.bytes or '', r.error or '' }
    for k, v in ipairs(row) do row[k] = csv_cell(v) end
    lines[#lines + 1] = table.concat(row, ',')
  end
  return table.concat(lines, '\n') .. '\n'
end

function RS.to_md(results)
  local out = {}
  out[#out + 1] = string.format('# Stems: %s', tostring(results.project or ''))
  out[#out + 1] = ''
  out[#out + 1] = string.format('%d stems, %d rendered, %d failed, %d skipped, %d silent; %s to %s (%.1f s); folder `%s`; format %s%s',
    results.n or #(results.rows or {}), results.ok or 0, results.failed or 0, results.skipped or 0, results.silent or 0,
    tostring(results.started), tostring(results.finished), results.seconds or 0, tostring(results.dir), tostring(results.format),
    results.stopped and '; STOPPED before the end' or '')
  out[#out + 1] = ''
  out[#out + 1] = '| # | Stem | Status | File | Length | Peak dBFS | LUFS-I | LUFS-M max | LRA | Render s |'
  out[#out + 1] = '|---|---|---|---|---|---|---|---|---|---|'
  for _, r in ipairs(results.rows or {}) do
    local file = r.file and (r.file:match('[^/\\]+$') or r.file) or ''
    out[#out + 1] = string.format('| %d | %s | %s | %s | %s | %s | %s | %s | %s | %s |', r.i, r.name, RS.status_of(r) .. (r.action and r.action ~= 'new' and (' (' .. r.action .. ')') or ''),
      file, fmt_s(r.duration_s), fmt_db(r.peak_db or r.reaper_peak_db), fmt_db(r.lufs_i), fmt_db(r.lufs_m_max), r.lra and string.format('%.1f', r.lra) or '', fmt_s(r.render_s))
    if r.error then out[#out + 1] = string.format('|   |   | error: %s |  |  |  |  |  |  |  |', r.error) end
  end
  out[#out + 1] = ''
  out[#out + 1] = 'Peak dBFS = sample peak scanned by Stagehand (WAV) or REAPER\'s statistic; LUFS columns come from REAPER\'s render statistics when that preference is on.'
  return table.concat(out, '\n') .. '\n'
end

local function write(path, text)
  local dir = path:match('^(.*)[/\\]')
  if dir then reaper.RecursiveCreateDirectory(dir, 0) end
  local f = io.open(path, 'w')
  if not f then return false end
  f:write(text)
  f:close()
  return true
end

-- writes the files next to the stems; returns { json, csv, md } paths that were written
function RS.write_all(results)
  local dir = results.dir
  if not dir then return {} end
  local base = dir .. sep .. 'stems_results'
  local files = {}
  local copy = {}
  for k, v in pairs(results) do
    if k ~= 'files' then copy[k] = v end
  end
  if write(base .. '.json', json.encode(copy, { pretty = true }) .. '\n') then files.json = base .. '.json' end
  local mode = config.get('stems.export.results') or 'both'
  if (mode == 'csv' or mode == 'both') and write(base .. '.csv', RS.to_csv(results)) then files.csv = base .. '.csv' end
  if (mode == 'md' or mode == 'both') and write(base .. '.md', RS.to_md(results)) then files.md = base .. '.md' end
  return files
end

return RS
