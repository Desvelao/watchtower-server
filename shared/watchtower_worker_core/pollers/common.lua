-- The pieces every claim-based poller (observe/analyze/evaluate/notify) has
-- in common, so each poller module holds only what is genuinely its own:
-- claiming a batch (with the same warning on a failed claim), reporting its
-- final result (with the same warning on a failed report), and the
-- "N/M processed (K failed)" summary line for batches that process a list of
-- observables.
local M = {}

-- How many individual failures a batch summary spells out before collapsing
-- the rest into "+N more".
M.MAX_FAILURES_LISTED = 5

-- "<verb> S/T observables (F failed); observable ID (reason); ..." - `verb`
-- is the past-tense action ("Observed", "Analyzed"), `failed` an array of
-- {id, reason}.
function M.summarize(verb, succeeded, failed, total)
  local parts = { string.format("%s %d/%d observables (%d failed)", verb, succeeded, total, #failed) }
  for i, f in ipairs(failed) do
    if i > M.MAX_FAILURES_LISTED then
      table.insert(parts, string.format("+%d more", #failed - M.MAX_FAILURES_LISTED))
      break
    end
    table.insert(parts, string.format("observable %s (%s)", tostring(f.id), tostring(f.reason)))
  end
  return table.concat(parts, "; ")
end

-- deps.claim() -> batch | nil [, err]. Returns the batch, or nil after
-- logging the claim error (nothing pending is nil with no error, silently).
-- `name` prefixes the warning (the calling poller's own).
function M.claim(name, deps, logger)
  local batch, claim_err = deps.claim()
  if not batch and claim_err then
    logger.warn(name .. ": claim failed: " .. tostring(claim_err))
  end
  return batch
end

-- Logs a failed final report (`ok, err` as returned by a deps.report_*
-- call) and passes `ok` through. `what` names what was being reported.
function M.check_report(name, what, ok, err, logger)
  if not ok then
    logger.warn(name .. ": failed to report " .. what .. ": " .. tostring(err))
  end
  return ok
end

return M
