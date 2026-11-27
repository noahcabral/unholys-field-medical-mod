function read_settings()
    local sections, current = {}, nil
    for line in io.lines("gamedata/configs/field_medical/settings.ltx") do
        local section = line:match("^%[([%w_]+)%]")
        if section then
            current = {}
            sections[section] = current
        end
        local key, value = line:match("^([%w_]+)%s*=%s*(%S+)")
        if key then
            current[key] = tonumber(value) or value
        end
    end
    return sections
end

function addon_script(file)
    local source = assert(loadfile("gamedata/scripts/" .. file .. ".script"))
    local module = setmetatable({}, {__index = _G})
    setfenv(source, module)()
    return module
end

function near(actual, expected)
    assert(math.abs(actual - expected) < 0.000001, "expected " .. expected .. ", got " .. actual)
end
