local function tobool_from_key(value)

    if value == "true" then
        return true
    elseif value == "false" then
        return false
    end

end

return {
    tobool_from_key = tobool_from_key
}