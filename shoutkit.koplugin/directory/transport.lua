--[[--
HTTP transport, behind a seam.

Two implementations of one interface:

  * `koreader` -- luasocket/luasec through KOReader's `socketutil`, which is
    what runs on device and what respects KOReader's own timeout and proxy
    settings;
  * `curl` -- `io.popen` around the curl binary, which is what runs during
    development and in CI, where none of KOReader's frontend exists. It is also
    a usable fallback on any device that has curl but a broken luasec.

Tests inject a third: a table with a `get` field. That is the only reason the
directory client is testable without the network.
]]

local Transport = {}
Transport.__index = Transport

local DEFAULT_TIMEOUT = 20

--- Quotes a string for safe use as a single POSIX shell word.
local function shell_escape(s)
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function tmp_path()
    return (os.getenv("TMPDIR") or "/tmp") .. "/shoutkit-http-" .. tostring(math.random(1e9))
end

local CurlTransport = {}
CurlTransport.__index = CurlTransport

function CurlTransport:get(url, opts)
    opts = opts or {}
    local body_file = tmp_path()
    local parts = {
        "curl", "-sS", "-L",
        "--max-time", tostring(opts.timeout or DEFAULT_TIMEOUT),
        "-A", shell_escape(opts.user_agent or self.user_agent),
        "-o", shell_escape(body_file),
        "-w", "'%{http_code}'",
    }
    for name, value in pairs(opts.headers or {}) do
        parts[#parts + 1] = "-H"
        parts[#parts + 1] = shell_escape(name .. ": " .. value)
    end
    parts[#parts + 1] = shell_escape(url)

    local pipe = io.popen(table.concat(parts, " ") .. " 2>/dev/null")
    if not pipe then
        os.remove(body_file)
        return nil, "cannot spawn curl"
    end
    local code = tonumber((pipe:read("*a") or ""):match("%d+"))
    pipe:close()

    local file = io.open(body_file, "r")
    local body = file and file:read("*a") or nil
    if file then file:close() end
    os.remove(body_file)

    if not code or code == 0 then return nil, "request failed (no response)" end
    if code < 200 or code >= 300 then
        return nil, "HTTP " .. code, code
    end
    return body, nil, code
end

local KoreaderTransport = {}
KoreaderTransport.__index = KoreaderTransport

function KoreaderTransport:get(url, opts)
    opts = opts or {}
    local ltn12 = require("ltn12")
    local socketutil = require("socketutil")
    local client = url:match("^https:") and require("ssl.https") or require("socket.http")

    local headers = { ["User-Agent"] = opts.user_agent or self.user_agent }
    for name, value in pairs(opts.headers or {}) do headers[name] = value end

    local sink = {}
    socketutil:set_timeout(opts.timeout or DEFAULT_TIMEOUT, opts.timeout or DEFAULT_TIMEOUT)
    local ok, code = client.request{
        url = url,
        method = "GET",
        headers = headers,
        sink = ltn12.sink.table(sink),
    }
    socketutil:reset_timeout()

    if not ok then return nil, tostring(code or "request failed") end
    code = tonumber(code)
    if not code or code < 200 or code >= 300 then
        return nil, "HTTP " .. tostring(code), code
    end
    return table.concat(sink), nil, code
end

--- `kind` is "auto", "curl", "koreader", or a table implementing `get`.
-- "auto" prefers KOReader's own stack when it is loadable, because that is the
-- one that honours the device's network settings.
function Transport.new(kind, opts)
    opts = opts or {}
    local user_agent = opts.user_agent or "shoutkit.koplugin/0.1.0"

    if type(kind) == "table" then return kind end

    if kind == nil or kind == "auto" then
        kind = pcall(require, "socketutil") and "koreader" or "curl"
    end

    if kind == "koreader" then
        return setmetatable({ user_agent = user_agent, kind = "koreader" }, KoreaderTransport)
    end
    return setmetatable({ user_agent = user_agent, kind = "curl" }, CurlTransport)
end

return Transport
