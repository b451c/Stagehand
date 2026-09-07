-- lib/families.lua - the user-defined track families (navigator.families in the config) as one shared service:
-- the Navigator's chips, the Director's "lanes by family" and the Stems module all read the same assignment.
--
-- compile() -> { list = { { name, rule, color, test, on } ... }, other = { name, color, other = true },
--                all = list + other } from the config. assign(families, tracks) sets entry.fam on every entry
-- of a lib/tracks.scan() list and returns the histogram { [name] = count }. Match scope `on`: top (the
-- top-level ancestor's name), own (the track's own name), any (the track or any parent). Lua 5.4; no globals.

local match = require('lib.match')
local tracks = require('lib.tracks')
local config = require('config')
local theme = require('ui.theme')

local M = {}

function M.compile()
  local fams = config.get('navigator.families') or {}
  local list = {}
  for i, f in ipairs(fams) do
    list[#list + 1] = {
      name = tostring(f.name or ('Family ' .. i)), rule = tostring(f.rule or ''),
      color = theme.parse_hex(f.color) or theme.family_palette[(i - 1) % #theme.family_palette + 1],
      test = match.compile(f.rule), on = f.on or 'top',
    }
  end
  local o = config.get('navigator.other_family') or {}
  local other = { name = tostring(o.name or 'Other'), color = theme.parse_hex(o.color) or 0x9AA3B5, other = true, rule = '' }
  local all = {}
  for _, f in ipairs(list) do all[#all + 1] = f end
  all[#all + 1] = other
  return { list = list, other = other, all = all }
end

local function family_of(fams, list, k)
  local e = list[k]
  for _, f in ipairs(fams.list) do
    if f.on == 'own' then
      if f.test(e.name) then return f.name end
    elseif f.on == 'any' then
      local x = e
      while x do
        if f.test(x.name) then return f.name end
        x = x.parent and list[x.parent] or nil
      end
    else
      if f.test(tracks.top(list, k).name) then return f.name end
    end
  end
  return fams.other.name
end

function M.assign(fams, list)
  local count = {}
  for k, e in ipairs(list) do
    e.fam = family_of(fams, list, k)
    count[e.fam] = (count[e.fam] or 0) + 1
  end
  return count
end

function M.color(fams, name)
  for _, f in ipairs(fams.all) do
    if f.name == name then return f.color end
  end
  return fams.other.color
end

function M.names(fams)
  local out = {}
  for _, f in ipairs(fams.all) do out[#out + 1] = f.name end
  return out
end

return M
