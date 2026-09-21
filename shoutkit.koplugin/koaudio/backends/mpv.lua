--[[--
mpv backend — the development and desktop target.

This is the reference implementation of the backend interface documented in
docs/BACKENDS.md. It is the one backend that needs nothing cross-compiled, so
it is where the UI and the directory client get built and debugged; the
Kindle (GStreamer), Kobo (ALSA/BlueALSA) and Android (MediaPlayer) backends
then implement the same protocol against the same controller code.

mpv owns the audio pipeline in its own process. We talk to it only through two
files, both created in the runtime directory:

  <base>.status   key=value, rewritten atomically by mpv_control.lua
  <base>.command  append-only "<seq> <verb> [arg]" lines we write

Nothing here blocks: the spawn returns as soon as the shell has backgrounded
mpv, and poll() is a single file read.
]]

local Util = require("koaudio.util")

local PLUGIN_DIR = debug.getinfo(1, "S").source:match("@?(.*/)") or "./"
local CONTROL_SCRIPT = PLUGIN_DIR .. "mpv_control.lua"

local MpvBackend = {}
MpvBackend.__index = MpvBackend

MpvBackend.name = "mpv"
MpvBackend.capabilities = {
    pause = true,
    seek = true,
    volume = true,
    metadata = true,
}

--- mpv is the only backend that can be probed this cheaply; the device ones
-- have to look at firmware paths instead.
function MpvBackend.is_available()
    if Util.has_command("mpv") then return true end
    return false, "mpv not found on PATH"
end

function MpvBackend.new(opts)
    opts = opts or {}
    local base = (opts.runtime_dir or Util.runtime_dir()) .. "/koaudio-mpv"
    return setmetatable({
        status_path = base .. ".status",
        command_path = base .. ".command",
        pid_path = base .. ".pid",
        log_path = base .. ".log",
        seq = 0,
        pid = nil,
        volume = opts.volume or 70,
    }, MpvBackend)
end

--- Appends a command for mpv_control.lua to pick up on its next poll.
-- Returns false when no player is running, which doubles as the liveness check.
function MpvBackend:send(verb, arg)
    if not self.pid then return false, "no player running" end
    self.seq = self.seq + 1
    local f = io.open(self.command_path, "a")
    if not f then return false, "cannot write command file" end
    f:write(self.seq, " ", verb, " ", tostring(arg or ""), "\n")
    f:close()
    return true
end

function MpvBackend:play(item, opts)
    if not item or not item.url or item.url == "" then
        return false, "no URL"
    end
    opts = opts or {}
    self:stop()

    -- Truncated, not appended: sequence numbers restart with each player, so a
    -- leftover file from the last run would look like commands from the future.
    local f = io.open(self.command_path, "w")
    if f then f:close() end
    os.remove(self.status_path)
    self.seq = 0

    local args = {
        "--no-video",
        "--really-quiet",
        "--no-terminal",
        "--idle=no",
        "--volume=" .. tostring(Util.clamp(opts.volume or self.volume, 0, 100)),
        -- A live stream that stalls should recover rather than end the file.
        "--stream-lavf-o=reconnect=1,reconnect_streamed=1,reconnect_delay_max=5",
        "--script=" .. Util.shell_escape(CONTROL_SCRIPT),
    }
    if item.kind == "stream" then
        -- Radio needs a real buffer on a slow link; a file does not, and
        -- caching a whole podcast episode into RAM would be hostile on a device
        -- with 256 MB.
        args[#args + 1] = "--cache=yes"
        args[#args + 1] = "--demuxer-readahead-secs=10"
    end

    local cmd = string.format(
        "KOAUDIO_STATUS=%s KOAUDIO_COMMAND=%s mpv %s %s >%s 2>&1 & echo $! >%s",
        Util.shell_escape(self.status_path),
        Util.shell_escape(self.command_path),
        table.concat(args, " "),
        Util.shell_escape(item.url),
        Util.shell_escape(self.log_path),
        Util.shell_escape(self.pid_path)
    )

    os.execute("sh -c " .. Util.shell_escape(cmd))

    local pid = tonumber((Util.read_file(self.pid_path) or ""):match("%d+"))
    if not pid then
        return false, "failed to start mpv (see " .. self.log_path .. ")"
    end
    self.pid = pid
    self.volume = opts.volume or self.volume
    return true
end

function MpvBackend:stop()
    if self.pid then
        self:send("stop")
        -- mpv_control.lua turns "stop" into a clean quit, but a wedged player
        -- that has stopped polling would never see it.
        os.execute("kill " .. self.pid .. " 2>/dev/null")
        self.pid = nil
    end
    os.remove(self.status_path)
    return true
end

function MpvBackend:pause() return self:send("pause") end
function MpvBackend:resume() return self:send("resume") end

function MpvBackend:set_volume(level)
    level = Util.clamp(tonumber(level) or self.volume, 0, 100)
    self.volume = level
    return self:send("volume", level)
end

--- Relative seek, in seconds. Meaningless on a live stream; the caller checks
-- capabilities and the item kind before offering it.
function MpvBackend:seek(seconds) return self:send("seek", tonumber(seconds) or 0) end
function MpvBackend:seek_to(seconds) return self:send("seek_to", tonumber(seconds) or 0) end

--- Non-blocking. Returns the parsed status table, or nil when there is nothing
-- to report yet (mpv still starting, or no player at all).
function MpvBackend:poll()
    if not self.pid then return nil end
    if not Util.pid_alive(self.pid) then
        self.pid = nil
        local status = Util.parse_status(Util.read_file(self.status_path))
        -- A player that exited without writing a terminal state died on us.
        if status and (status.state == "stopped" or status.state == "error") then
            return status
        end
        return { state = "error", error = "player exited unexpectedly" }
    end
    return Util.parse_status(Util.read_file(self.status_path))
end

function MpvBackend:is_running()
    return self.pid ~= nil and Util.pid_alive(self.pid)
end

return MpvBackend
