local function format_text_array(tbl)
    assert(type(tbl) == "table", "Expected a table")

    local escaped = {}
    for _, val in ipairs(tbl) do
        assert(type(val) == "string", "All values must be strings")
        -- Escape double quotes and backslashes
        local safe = val:gsub("\\", "\\\\"):gsub("\"", "\\\"")
        table.insert(escaped, '"' .. safe .. '"')
    end

    return "{" .. table.concat(escaped, ",") .. "}"
end

return {
  format_text_array = format_text_array
}