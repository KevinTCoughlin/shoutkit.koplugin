--[[--
A very small test runner.

busted is the KOReader convention, but it needs luarocks and a matching Lua
install, and this repo's whole point is that its core runs anywhere LuaJIT does.
So: no dependencies, one entry point, `luajit spec/run.lua`. If the suite ever
outgrows this, busted is a drop-in replacement -- the describe/it shape here is
deliberately the same.
]]

local Runner = {
    passed = 0,
    failed = 0,
    failures = {},
    _stack = {},
}

local function label()
    return table.concat(Runner._stack, " ")
end

function Runner.describe(name, body)
    Runner._stack[#Runner._stack + 1] = name
    body()
    Runner._stack[#Runner._stack] = nil
end

function Runner.it(name, body)
    Runner._stack[#Runner._stack + 1] = name
    local name_now = label()
    local ok, err = pcall(body)
    Runner._stack[#Runner._stack] = nil

    if ok then
        Runner.passed = Runner.passed + 1
        io.write(".")
    else
        Runner.failed = Runner.failed + 1
        Runner.failures[#Runner.failures + 1] = { name = name_now, err = tostring(err) }
        io.write("F")
    end
    io.flush()
end

local function fail(message, expected, actual)
    error(string.format("%s\n      expected: %s\n      actual:   %s",
        message, tostring(expected), tostring(actual)), 3)
end

Runner.assert = {}

function Runner.assert.equal(expected, actual, message)
    if expected ~= actual then
        fail(message or "values differ", expected, actual)
    end
end

function Runner.assert.truthy(value, message)
    if not value then fail(message or "expected truthy", "truthy", value) end
end

function Runner.assert.falsy(value, message)
    if value then fail(message or "expected falsy", "falsy", value) end
end

function Runner.assert.nil_(value, message)
    if value ~= nil then fail(message or "expected nil", "nil", value) end
end

function Runner.assert.contains(haystack, needle, message)
    if type(haystack) ~= "string" or not haystack:find(needle, 1, true) then
        fail(message or "substring not found", needle, haystack)
    end
end

function Runner.assert.len(expected, list, message)
    local actual = (type(list) == "table") and #list or -1
    if actual ~= expected then fail(message or "wrong length", expected, actual) end
end

function Runner.assert.deep_equal(expected, actual, message)
    local function same(a, b)
        if a == b then return true end
        if type(a) ~= "table" or type(b) ~= "table" then return false end
        for key, value in pairs(a) do if not same(value, b[key]) then return false end end
        for key in pairs(b) do if a[key] == nil then return false end end
        return true
    end
    if not same(expected, actual) then
        fail(message or "tables differ", "(table)", "(table)")
    end
end

function Runner.report()
    print()
    for _, failure in ipairs(Runner.failures) do
        print("\nFAIL: " .. failure.name)
        print("      " .. failure.err:gsub("\n", "\n      "))
    end
    print(string.format("\n%d passed, %d failed", Runner.passed, Runner.failed))
    return Runner.failed == 0
end

return Runner
