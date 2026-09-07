-- lib/search.lua - instant fuzzy search over short labels (scene, marker, track and item names).
--
-- prepare(query) -> q (nil when the query is blank). score(q, text) -> number (higher is better) or nil when the
-- text does not match. Every word of the query must match: as a substring (best) or as an in-order subsequence
-- (fuzzy) with bonuses for matches at word starts and for consecutive characters. Case-insensitive, byte based
-- (fast; accents match only exactly).

local M = {}

function M.prepare(query, fuzzy)
  local words = {}
  for w in tostring(query or ''):lower():gmatch('%S+') do words[#words + 1] = w end
  if #words == 0 then return nil end
  return { words = words, fuzzy = fuzzy ~= false, raw = tostring(query):lower() }
end

local function is_word_start(text, i)
  if i == 1 then return true end
  local p = text:byte(i - 1)
  return p == 32 or p == 45 or p == 95 or p == 46 or p == 47 or p == 58 or (p >= 48 and p <= 57) ~= (text:byte(i) >= 48 and text:byte(i) <= 57)
end

local function subsequence_score(word, text)
  local score, ti, last = 0, 1, nil
  for wi = 1, #word do
    local c = word:byte(wi)
    local found
    for k = ti, #text do
      if text:byte(k) == c then found = k; break end
    end
    if not found then return nil end
    local s = 1
    if is_word_start(text, found) then s = s + 3 end
    if last and found == last + 1 then s = s + 2 end
    if last then s = s - math.min(3, (found - last - 1) * 0.5) end
    score = score + s
    last = found
    ti = found + 1
  end
  return score
end

function M.score(q, text)
  if not q then return 0 end
  local t = tostring(text or ''):lower()
  if t == '' then return nil end
  local total = 0
  if q.raw and #q.words > 1 then
    local s = t:find(q.raw, 1, true)
    if s then total = total + 40 + (s == 1 and 10 or 0) end
  end
  for _, w in ipairs(q.words) do
    local s = t:find(w, 1, true)
    if s then
      total = total + 20 + (is_word_start(t, s) and 6 or 0) + (s == 1 and 4 or 0)
    elseif q.fuzzy then
      local fs = subsequence_score(w, t)
      if not fs then return nil end
      total = total + fs
    else
      return nil
    end
  end
  return total - #t * 0.01
end

-- filter a list: keep rows whose text (from get_text) matches, sorted by score desc (stable on ties)
function M.filter(q, rows, get_text)
  if not q then return rows end
  local out = {}
  for i, row in ipairs(rows) do
    local s = M.score(q, get_text(row))
    if s then out[#out + 1] = { row = row, score = s, i = i } end
  end
  table.sort(out, function(a, b)
    if a.score ~= b.score then return a.score > b.score end
    return a.i < b.i
  end)
  local rows_out = {}
  for k, e in ipairs(out) do rows_out[k] = e.row end
  return rows_out
end

return M
