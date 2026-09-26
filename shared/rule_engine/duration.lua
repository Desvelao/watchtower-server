-- Small, dependency-free duration-string parser used by rule_engine.expr's
-- `changed_within <duration>` operator (see that module's header comment).
-- Not a cron-schedule parser (that's shared/watchtower_worker_core/cron.lua, a different concept) -
-- this parses a single magnitude+unit string into a number of seconds.
--
-- Accepted formats: a magnitude followed by a unit - `ms` (milliseconds),
-- `s` (seconds), `m` (minutes), `h` (hours), `d` (days), `M` (months,
-- approximated as 30 days) - e.g. "500ms", "30s", "1m", "2h", "3d", "1M".
-- Note the deliberate case distinction between `m` (minutes) and `M`
-- (months), mirroring common duration-string conventions (Moment.js,
-- systemd). A bare "0" (no unit) is also accepted, since a zero-magnitude
-- duration is unambiguous regardless of unit. Any other magnitude with no
-- unit, an unrecognized unit, or a string that doesn't match the pattern at
-- all (including negative numbers, which the pattern simply never matches)
-- is rejected.
local M = {}

local UNIT_SECONDS = { ms = 0.001, s = 1, m = 60, h = 3600, d = 86400, M = 2592000 }

-- M.parse(str) -> seconds, err
-- Returns the duration in seconds on success, or (nil, "<message>") on
-- failure.
function M.parse(str)
  if type(str) ~= "string" then
    return nil, string.format("invalid duration: expected a string, got %s", type(str))
  end

  local magnitude, unit = str:match("^(%d+%.?%d*)(%a*)$")
  if not magnitude then
    return nil, string.format("invalid duration '%s': expected a magnitude and unit, e.g. 30s, 1m, 2h, 3d, 1M, 500ms, or bare 0", str)
  end

  if unit == "" then
    if tonumber(magnitude) == 0 then
      return 0, nil
    end
    return nil, string.format("invalid duration '%s': a magnitude without a unit is only valid for 0", str)
  end

  local unit_seconds = UNIT_SECONDS[unit]
  if not unit_seconds then
    return nil, string.format("invalid duration '%s': unrecognized unit '%s' (expected ms, s, m, h, d, or M)", str, unit)
  end

  return tonumber(magnitude) * unit_seconds, nil
end

return M
