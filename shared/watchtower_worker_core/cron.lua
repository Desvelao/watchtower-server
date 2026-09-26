-- Hand-rolled 5-field cron parser/evaluator (minute hour day-of-month month
-- day-of-week, day-of-week 0=Sunday) - no new Luarocks dependency, same
-- convention as shared/rule_engine/expr.lua's hand-rolled recursive-descent parser
-- and server/lib/zip_writer.lua/zip_reader.lua's hand-rolled zip handling.
--
-- Grammar (deliberately NOT full POSIX cron - no @yearly-style macros, no
-- "OR day-of-month/day-of-week when both restricted" special case - a time
-- matches only when ALL FIVE fields match, always):
--   field  := item ("," item)*
--   item   := range | range "/" step
--   range  := "*" | number | number "-" number
--   step   := number (>= 1)
--   number := digit+
--
-- Field bounds: minute 0-59, hour 0-23, day_of_month 1-31, month 1-12,
-- day_of_week 0-6 (0=Sunday, matching os.date's wday-1 mod 7 - see
-- next_after below).
--
-- All matching is done in UTC (os.date("!*t", ...)), matching this
-- codebase's existing convention of treating every stored TIMESTAMP as bare
-- UTC wall-clock (see lib/routes.lua's resolve_relative_date).
local M = {}

local FIELDS = {
  { name = "minute", min = 0, max = 59 },
  { name = "hour", min = 0, max = 23 },
  { name = "day_of_month", min = 1, max = 31 },
  { name = "month", min = 1, max = 12 },
  { name = "day_of_week", min = 0, max = 6 },
}

-- 4 years, in seconds - the upper bound next_after scans before giving up,
-- guarding against a pathological expression (e.g. "0 0 30 2 *", which
-- never matches - Feb never has a 30th) hanging the scheduler tick forever.
local MAX_SCAN_SECONDS = 4 * 366 * 24 * 3600

-- Parses one field string into (matcher(value) -> bool, nil) | (nil, err).
local function parse_field(str, min, max)
  if type(str) ~= "string" or str == "" then
    return nil, "field is required"
  end

  local set = {}
  for part in str:gmatch("[^,]+") do
    local range_part, step_str = part:match("^([^/]+)/(%d+)$")
    local step = 1
    if range_part then
      step = tonumber(step_str)
      if not step or step < 1 then
        return nil, "invalid step in '" .. part .. "'"
      end
    else
      range_part = part
    end

    local lo, hi
    if range_part == "*" then
      lo, hi = min, max
    else
      local lo_str, hi_str = range_part:match("^(%d+)-(%d+)$")
      if lo_str then
        lo, hi = tonumber(lo_str), tonumber(hi_str)
      else
        local n = tonumber(range_part)
        if not n then
          return nil, "invalid token '" .. range_part .. "'"
        end
        lo, hi = n, n
      end
    end

    if not lo or not hi or lo > hi or lo < min or hi > max then
      return nil, string.format("value out of range in '%s' (expected %d-%d)", part, min, max)
    end

    for v = lo, hi, step do
      set[v] = true
    end
  end

  return function(value)
    return set[value] == true
  end, nil
end

-- Splits "min hour dom month dow" into exactly 5 non-empty fields, or
-- (nil, err) on a shape mismatch.
local function split_fields(expr)
  local parts = {}
  for token in tostring(expr or ""):gmatch("%S+") do
    table.insert(parts, token)
  end
  if #parts ~= 5 then
    return nil, string.format("expected 5 space-separated fields, got %d", #parts)
  end
  return parts, nil
end

-- M.validate(expr) -> true, nil | false, err_string
function M.validate(expr)
  local parts, split_err = split_fields(expr)
  if not parts then
    return false, split_err
  end
  for i, part in ipairs(parts) do
    local _, err = parse_field(part, FIELDS[i].min, FIELDS[i].max)
    if err then
      return false, FIELDS[i].name .. ": " .. err
    end
  end
  return true, nil
end

-- M.next_after(expr, from_time) -> unix_time, nil | nil, err_string
-- Minute-by-minute scan strictly after from_time (unix seconds), bounded by
-- MAX_SCAN_SECONDS. `from_time` is a plain os.time()-shaped integer -
-- callers format the returned unix time into a DB-shaped string themselves
-- (os.date("!%Y-%m-%d %H:%M:%S", ts)).
function M.next_after(expr, from_time)
  local ok, err = M.validate(expr)
  if not ok then
    return nil, err
  end

  local parts = split_fields(expr)
  local matchers = {}
  for i, part in ipairs(parts) do
    matchers[i] = parse_field(part, FIELDS[i].min, FIELDS[i].max)
  end

  -- Next whole minute, strictly after from_time.
  local t = math.floor((from_time or os.time()) / 60 + 1) * 60
  local limit = t + MAX_SCAN_SECONDS

  while t <= limit do
    local d = os.date("!*t", t)
    -- os.date: wday 1=Sunday..7=Saturday -> cron 0=Sunday..6=Saturday.
    local dow = (d.wday - 1) % 7
    if matchers[1](d.min) and matchers[2](d.hour) and matchers[3](d.day)
      and matchers[4](d.month) and matchers[5](dow) then
      return t, nil
    end
    t = t + 60
  end

  return nil, "no matching time found within the scan bound"
end

return M
