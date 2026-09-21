--[[--
Small helpers shared by the koaudio backends.

Deliberately dependency-free: everything here has to work both inside KOReader
(LuaJIT, 5.1 semantics) and under a plain `lua`/`luajit` binary during
development and CI, where none of KOReader's frontend modules exist.
]]

local Util = {}

--- Quotes a string for safe use as a single POSIX shell word.
-- Every backend builds a command line, and station URLs are attacker-supplied
-- data from a public directory, so this is not optional.
function Util.shell_escape(s)
    if s == nil then return "''" end
    return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

--- Reads a whole file, returning nil rather than raising on any failure.
-- Status files are rewritten underneath us by another process, so a read can
-- fail mid-flight; on FAT-formatted Kindle storage an open handle can even stop
-- being readable partway through. Lua's line iterator turns that into a *raised*
-- error, which inside a UIManager task takes KOReader down with it.
function Util.read_file(path)
    local ok, content = pcall(function()
        local f = io.open(path, "r")
        if not f then return nil end
        local data = f:read("*a")
        f:close()
        return data
    end)
    if not ok then return nil end
    return content
end

--- Writes `content` to `path` atomically, via a sibling temp file and rename().
function Util.write_file_atomic(path, content)
    local tmp = path .. ".tmp"
    local f = io.open(tmp, "w")
    if not f then return false end
    f:write(content)
    f:close()
    return os.rename(tmp, path)
end

--- Parses the key=value status format described in docs/PROTOCOL.md.
-- Unknown keys are kept as strings; the caller coerces what it cares about.
function Util.parse_status(content)
    if not content or content == "" then return nil end
    local status = {}
    for line in content:gmatch("[^\r\n]+") do
        local key, value = line:match("^([%w_]+)=(.*)$")
        if key then status[key] = value end
    end
    if next(status) == nil then return nil end
    return status
end

function Util.tonum(value, default)
    return tonumber(value) or default
end

--- True if a command exists on PATH.
function Util.has_command(name)
    local f = io.popen("command -v " .. Util.shell_escape(name) .. " 2>/dev/null")
    if not f then return false end
    local out = f:read("*a") or ""
    f:close()
    return out:gsub("%s", "") ~= ""
end

--- True if the process is alive. Used as the liveness check for spawned
-- backends: a status file that has stopped being updated is ambiguous, a dead
-- pid is not.
function Util.pid_alive(pid)
    if not pid then return false end
    return os.execute("kill -0 " .. tonumber(pid) .. " 2>/dev/null") == true
        or os.execute("kill -0 " .. tonumber(pid) .. " 2>/dev/null") == 0
end

function Util.clamp(n, lo, hi)
    if n < lo then return lo end
    if n > hi then return hi end
    return n
end

--- A writable scratch directory for status files, FIFOs and logs.
function Util.runtime_dir()
    local candidates = {
        os.getenv("SHOUTKIT_RUNTIME_DIR"),
        os.getenv("XDG_RUNTIME_DIR"),
        os.getenv("TMPDIR"),
        "/tmp",
    }
    for _, dir in ipairs(candidates) do
        if dir and dir ~= "" then return (dir:gsub("/$", "")) end
    end
    return "."
end

return Util
