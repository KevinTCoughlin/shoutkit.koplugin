--[[--
A small, dependency-free JSON decoder.

KOReader ships `rapidjson` and this module prefers it when present, which is
the normal case on device. The pure-Lua fallback exists so the directory client
and its tests run under a bare `lua`/`luajit` during development and in CI,
where no KOReader modules are available. Radio-Browser responses are a few
hundred kilobytes at most, so the fallback's speed is not a concern.

Only decoding is implemented -- nothing here needs to produce JSON. Persistence
goes through KOReader's own LuaSettings.
]]

local Json = {}

--- Sentinel for JSON `null` inside arrays, where a nil would silently shorten
-- the table. As an *object* value, null is represented by the key simply being
-- absent, which is what every caller here wants.
Json.null = setmetatable({}, { __tostring = function() return "null" end })

local ESCAPES = {
    ['"'] = '"', ["\\"] = "\\", ["/"] = "/",
    b = "\b", f = "\f", n = "\n", r = "\r", t = "\t",
}

local function skip_whitespace(str, pos)
    local _, last = str:find("^[ \t\r\n]*", pos)
    return (last or pos - 1) + 1
end

--- Encodes a Unicode code point as UTF-8.
local function utf8_encode(code)
    if code < 0x80 then
        return string.char(code)
    elseif code < 0x800 then
        return string.char(0xC0 + math.floor(code / 0x40), 0x80 + code % 0x40)
    elseif code < 0x10000 then
        return string.char(
            0xE0 + math.floor(code / 0x1000),
            0x80 + math.floor(code / 0x40) % 0x40,
            0x80 + code % 0x40)
    end
    return string.char(
        0xF0 + math.floor(code / 0x40000),
        0x80 + math.floor(code / 0x1000) % 0x40,
        0x80 + math.floor(code / 0x40) % 0x40,
        0x80 + code % 0x40)
end

local parse_value

local function parse_string(str, pos)
    -- pos points at the opening quote.
    local out, i = {}, pos + 1
    while true do
        local stop = str:find('[\\"]', i)
        if not stop then return nil, pos, "unterminated string" end
        out[#out + 1] = str:sub(i, stop - 1)
        local char = str:sub(stop, stop)
        if char == '"' then
            return table.concat(out), stop + 1
        end
        -- An escape sequence.
        local code = str:sub(stop + 1, stop + 1)
        if code == "u" then
            local hex = tonumber(str:sub(stop + 2, stop + 5), 16)
            if not hex then return nil, pos, "bad \\u escape" end
            i = stop + 6
            -- A high surrogate must be joined with the low one that follows,
            -- or non-BMP characters (emoji in station names, and there are
            -- plenty) come out as mojibake.
            if hex >= 0xD800 and hex <= 0xDBFF and str:sub(i, i + 1) == "\\u" then
                local low = tonumber(str:sub(i + 2, i + 5), 16)
                if low and low >= 0xDC00 and low <= 0xDFFF then
                    hex = 0x10000 + (hex - 0xD800) * 0x400 + (low - 0xDC00)
                    i = i + 6
                end
            end
            out[#out + 1] = utf8_encode(hex)
        else
            out[#out + 1] = ESCAPES[code] or code
            i = stop + 2
        end
    end
end

local function parse_array(str, pos)
    local arr, i = {}, skip_whitespace(str, pos + 1)
    if str:sub(i, i) == "]" then return arr, i + 1 end
    while true do
        local value, next_pos, err = parse_value(str, i)
        if err then return nil, pos, err end
        arr[#arr + 1] = (value == nil) and Json.null or value
        i = skip_whitespace(str, next_pos)
        local char = str:sub(i, i)
        if char == "]" then return arr, i + 1 end
        if char ~= "," then return nil, pos, "expected , or ] in array" end
        i = skip_whitespace(str, i + 1)
    end
end

local function parse_object(str, pos)
    local obj, i = {}, skip_whitespace(str, pos + 1)
    if str:sub(i, i) == "}" then return obj, i + 1 end
    while true do
        if str:sub(i, i) ~= '"' then return nil, pos, "expected key in object" end
        local key, next_pos, err = parse_string(str, i)
        if err then return nil, pos, err end
        i = skip_whitespace(str, next_pos)
        if str:sub(i, i) ~= ":" then return nil, pos, "expected : after key" end
        local value
        value, next_pos, err = parse_value(str, skip_whitespace(str, i + 1))
        if err then return nil, pos, err end
        -- A null object value is left absent rather than stored as a sentinel:
        -- `station.geo_lat` being nil is exactly what the callers test for.
        if value ~= nil then obj[key] = value end
        i = skip_whitespace(str, next_pos)
        local char = str:sub(i, i)
        if char == "}" then return obj, i + 1 end
        if char ~= "," then return nil, pos, "expected , or } in object" end
        i = skip_whitespace(str, i + 1)
    end
end

parse_value = function(str, pos)
    local char = str:sub(pos, pos)
    if char == "{" then return parse_object(str, pos) end
    if char == "[" then return parse_array(str, pos) end
    if char == '"' then return parse_string(str, pos) end
    if str:sub(pos, pos + 3) == "true" then return true, pos + 4 end
    if str:sub(pos, pos + 4) == "false" then return false, pos + 5 end
    if str:sub(pos, pos + 3) == "null" then return nil, pos + 4 end
    local number, next_pos = str:match("^(%-?%d+%.?%d*[eE]?[-+]?%d*)()", pos)
    if number and tonumber(number) then return tonumber(number), next_pos end
    return nil, pos, "unexpected character " .. string.format("%q", char) .. " at " .. pos
end

--- Decodes a JSON document. Returns value, or nil plus an error message.
-- Never raises: a truncated or malformed response from a public API is an
-- expected condition, not a bug.
function Json.decode(str)
    if type(str) ~= "string" or str == "" then return nil, "empty input" end

    local ok, rapidjson = pcall(require, "rapidjson")
    if ok and rapidjson and rapidjson.decode then
        local decoded, err = pcall(rapidjson.decode, str)
        if decoded then return err end
        -- Fall through to the pure-Lua parser rather than failing outright;
        -- rapidjson is stricter about some things than the servers are.
    end

    local value, pos, err = parse_value(str, skip_whitespace(str, 1))
    if err then return nil, err end
    local trailing = skip_whitespace(str, pos)
    if trailing <= #str then
        return nil, "trailing content at " .. trailing
    end
    return value
end

return Json
