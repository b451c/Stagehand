-- lib/edits.lua - settle detection over GetProjectStateChangeCount. A region-edge drag or an item move bumps the
-- count on every mouse move; a module that rescans on every change re-reads the whole project at frame rate while
-- the user is still dragging (failure note B2). The owner table keeps `state_count` (the count its
-- caches were built from) and a rescan becomes due when the count has been stable for one frame, or every
-- `max_wait_s` during a long edit so the caches never lag more than that behind the project.
local M = {}

M.max_wait_s = 0.5

-- true when the owner must rescan now; the owner sets `state_count` when it did (M.taken)
function M.due(owner, now)
  local n = reaper.GetProjectStateChangeCount(0)
  if n == owner.state_count then
    owner.edit_pending, owner.edit_first_at = nil, nil
    return false
  end
  now = now or reaper.time_precise()
  if owner.edit_pending ~= n then
    -- still moving: wait one frame, unless the edit already runs longer than max_wait_s
    local first = owner.edit_first_at or now
    owner.edit_pending, owner.edit_first_at = n, first
    if now - first < M.max_wait_s then
      owner.edits_deferred = (owner.edits_deferred or 0) + 1
      return false
    end
  end
  owner.edit_pending, owner.edit_first_at = nil, nil
  owner.edits_rescanned = (owner.edits_rescanned or 0) + 1
  return true
end

-- the caches are fresh now
function M.taken(owner)
  owner.state_count = reaper.GetProjectStateChangeCount(0)
  owner.edit_pending, owner.edit_first_at = nil, nil
end

return M
