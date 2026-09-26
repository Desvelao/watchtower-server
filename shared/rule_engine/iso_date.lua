-- Dependency-free ISO 8601 date/datetime string -> Unix epoch seconds
-- parser, used by rule_engine.expr's `older_than`/`newer_than` operators to
-- compare a `date`-typed payload field (see server/lib/property_schema.lua)
-- against `now`. Not a general ISO 8601 parser - handles exactly the shapes
-- property_schema.lua's own validation guarantees a "date" property looks
-- like: a bare date (`YYYY-MM-DD`) or a full date-time, optionally with
-- fractional seconds and a `Z`/`+HH:MM`/`-HH:MM` offset
-- (`YYYY-MM-DD[T ]HH:MM[:SS][.fff](Z|+HH:MM|-HH:MM)`).
--
-- Always treats a bare date, or a date-time with no explicit offset, as
-- UTC (never the server process's local timezone) - the only way to get a
-- deterministic, restart-safe result regardless of where the server/worker
-- happens to run. Deliberately does not use `os.time`/`os.date` (both are
-- locale/timezone-dependent and DST-sensitive) - instead computes
-- days-since-epoch directly via a well-known proleptic-Gregorian
-- civil-to-days algorithm (Howard Hinnant's `days_from_civil`), which is
-- exact on both sides of 1970 and needs no calendar library.
local M = {}

-- Days from the Unix epoch (1970-01-01) for civil date (y, m, d), per
-- http://howardhinnant.github.io/date_algorithms.html#days_from_civil.
-- Uses true floor division throughout (`math.floor(a / b)`, not `%`/C-style
-- truncation), which is what lets this formulation skip that page's
-- truncating-division adjustment for negative years.
local function days_from_civil(y, m, d)
  local yy = (m <= 2) and (y - 1) or y
  local era = math.floor(yy / 400)
  local yoe = yy - era * 400 -- [0, 399]
  local doy = math.floor((153 * (m + (m > 2 and -3 or 9)) + 2) / 5) + d - 1 -- [0, 365]
  local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy -- [0, 146096]
  return era * 146097 + doe - 719468
end

-- M.parse(str) -> epoch_seconds, err
-- Returns the UTC epoch seconds on success, or (nil, "<message>") on
-- failure.
function M.parse(str)
  if type(str) ~= "string" then
    return nil, string.format("invalid date: expected a string, got %s", type(str))
  end

  local y, mo, d = str:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)")
  if not y then
    return nil, string.format("invalid date '%s': expected an ISO 8601 date/datetime string", str)
  end
  y, mo, d = tonumber(y), tonumber(mo), tonumber(d)

  local h, mi, s = 0, 0, 0
  local offset_seconds = 0
  local rest = str:sub(11)

  if rest ~= "" then
    local hh, mm, ss, tz = rest:match("^[T ](%d%d):(%d%d):?(%d?%d?)(.*)$")
    if not hh then
      return nil, string.format("invalid date '%s': expected an ISO 8601 date/datetime string", str)
    end
    h, mi = tonumber(hh), tonumber(mm)
    s = tonumber(ss) or 0

    tz = tz:gsub("^%.%d+", "") -- drop fractional seconds, if any, before reading the offset
    if tz ~= "" and tz ~= "Z" and tz ~= "z" then
      local sign, oh, om = tz:match("^([%+%-])(%d%d):?(%d%d)$")
      if not sign then
        return nil, string.format("invalid date '%s': unrecognized timezone offset '%s'", str, tz)
      end
      offset_seconds = (tonumber(oh) * 3600 + tonumber(om) * 60) * (sign == "-" and -1 or 1)
    end
  end

  local epoch = days_from_civil(y, mo, d) * 86400 + h * 3600 + mi * 60 + s - offset_seconds
  return epoch, nil
end

return M
