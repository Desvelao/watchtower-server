-- A small, deliberately limited flat "key: value mapping" parser - NOT a
-- YAML parser. It supports exactly: one `key: value` per line, `#`-prefixed
-- comment lines, blank lines (ignored), quoted ("...", with \" / \\
-- escapes) or bare scalar values, bare integers, and bare true/false
-- booleans. It does NOT support nesting, lists, block scalars,
-- anchors/aliases, multi-document streams, type tags, or inline comments
-- after a value - a `#` is a comment ONLY when it's the very first
-- character of the whole line; the editor's YAML syntax highlighting
-- (CodeEditor.vue, language="yaml") invites the habit of trailing `#
-- comment` after a value, which this parser does NOT support - rather than
-- silently folding a trailing comment into the value (which would then
-- fail deep inside rule_expr.lua with a confusing token error), an
-- unquoted value containing a `#` preceded by whitespace is rejected with
-- a clear error - see `has_stray_comment_marker` below. Do not feed it
-- arbitrary YAML - it exists only for this project's flat rule-source
-- documents (see services/rules.lua).

local M = {}

local function trim(s)
  return s:match("^%s*(.-)%s*$")
end

-- True if `value_raw` has a `#` preceded by whitespace outside any
-- double-quoted substring - the shape of an accidental inline comment.
-- Tracks quote state (respecting \" escapes) so a legitimately quoted
-- value containing "#" (e.g. an `if:` line like `tags has "prod #1"`,
-- whose overall value isn't quote-wrapped as a whole) is never flagged.
local function has_stray_comment_marker(value_raw)
  local in_quotes, prev_was_space = false, false
  local i, len = 1, #value_raw
  while i <= len do
    local ch = value_raw:sub(i, i)
    if ch == "\\" and in_quotes and i < len then
      i = i + 2
      prev_was_space = false
    elseif ch == '"' then
      in_quotes = not in_quotes
      prev_was_space = false
      i = i + 1
    elseif ch == "#" and not in_quotes and prev_was_space then
      return true
    else
      prev_was_space = ch:match("%s") ~= nil
      i = i + 1
    end
  end
  return false
end

local function coerce_value(raw)
  if raw:sub(1, 1) == '"' and raw:sub(-1) == '"' and #raw >= 2 then
    local inner = raw:sub(2, -2)
    inner = inner:gsub('\\"', '"'):gsub("\\\\", "\\")
    return inner
  end
  if raw == "" then
    return ""
  end
  if raw == "true" then
    return true
  end
  if raw == "false" then
    return false
  end
  if raw:match("^%-?%d+$") then
    return tonumber(raw)
  end
  return raw
end

-- M.parse(source_text) -> fields_table, err
function M.parse(source_text)
  if type(source_text) ~= "string" then
    return nil, "source must be a string"
  end

  local fields = {}
  local line_no = 0

  for raw_line in (source_text .. "\n"):gmatch("(.-)\n") do
    line_no = line_no + 1
    local line = trim(raw_line)

    if line ~= "" and line:sub(1, 1) ~= "#" then
      local colon_pos = line:find(":", 1, true)
      if not colon_pos then
        return nil,
          string.format("line %d: expected 'key: value', no ':' found", line_no)
      end

      local key = trim(line:sub(1, colon_pos - 1))
      local value_raw = trim(line:sub(colon_pos + 1))

      if not key:match("^%a[%w_]*$") then
        return nil, string.format("line %d: invalid key '%s'", line_no, key)
      end

      if fields[key] ~= nil then
        return nil, string.format("line %d: duplicate key '%s'", line_no, key)
      end

      if has_stray_comment_marker(value_raw) then
        return nil, string.format(
          "line %d: inline comments are not supported - move the '#' comment to its own line",
          line_no
        )
      end

      fields[key] = coerce_value(value_raw)
    end
  end

  return fields, nil
end

return M
