--[[--
mpv-side half of the mpv backend. **This file is loaded by mpv, not KOReader** —
it runs inside mpv's own embedded Lua interpreter and only has mpv's `mp` API
available.

It implements both sides of the contract in docs/PROTOCOL.md:

  * writes the key=value status file, atomically, on every state change and
    once a second while playing;
  * polls the command file and applies any line whose sequence number it has
    not seen yet.

Using mpv's own scripting here rather than mpv's JSON IPC socket is deliberate:
it needs no socket library on the KOReader side, and it makes mpv speak exactly
the same file protocol the native Kindle/Kobo backends will speak, so the
controller code is identical across every platform.

Paths come in via environment variables set by the spawning process.
]]

local status_path = os.getenv("KOAUDIO_STATUS")
local command_path = os.getenv("KOAUDIO_COMMAND")

local last_seq = 0

local function write_status()
    if not status_path then return end
    local metadata = mp.get_property_native("metadata") or {}
    local idle = mp.get_property_bool("core-idle")
    local paused = mp.get_property_bool("pause")

    local state
    if paused then
        state = "paused"
    elseif idle then
        state = "buffering"
    else
        state = "playing"
    end

    local lines = {
        "state=" .. state,
        "title=" .. (metadata["icy-title"] or metadata["title"] or ""),
        "artist=" .. (metadata["artist"] or ""),
        "name=" .. (metadata["icy-name"] or ""),
        "codec=" .. (mp.get_property("audio-codec-name") or ""),
        "bitrate=" .. tostring(math.floor((mp.get_property_number("audio-bitrate") or 0) / 1000)),
        "volume=" .. tostring(math.floor(mp.get_property_number("volume") or 0)),
        "elapsed=" .. tostring(math.floor(mp.get_property_number("time-pos") or 0)),
        "duration=" .. tostring(math.floor(mp.get_property_number("duration") or 0)),
        "seq=" .. tostring(last_seq),
    }

    local tmp = status_path .. ".tmp"
    local f = io.open(tmp, "w")
    if not f then return end
    f:write(table.concat(lines, "\n"), "\n")
    f:close()
    os.rename(tmp, status_path)
end

local function apply(verb, arg)
    if verb == "pause" then
        mp.set_property_bool("pause", true)
    elseif verb == "resume" then
        mp.set_property_bool("pause", false)
    elseif verb == "toggle" then
        mp.set_property_bool("pause", not mp.get_property_bool("pause"))
    elseif verb == "stop" then
        mp.commandv("quit")
    elseif verb == "volume" then
        local n = tonumber(arg)
        if n then mp.set_property_number("volume", n) end
    elseif verb == "seek" then
        local n = tonumber(arg)
        if n then mp.commandv("seek", tostring(n), "relative") end
    elseif verb == "seek_to" then
        local n = tonumber(arg)
        if n then mp.commandv("seek", tostring(n), "absolute") end
    elseif verb == "loadfile" and arg and arg ~= "" then
        mp.commandv("loadfile", arg, "replace")
    end
    write_status()
end

local function poll_commands()
    if not command_path then return end
    local f = io.open(command_path, "r")
    if not f then return end
    local content = f:read("*a") or ""
    f:close()
    for line in content:gmatch("[^\r\n]+") do
        -- "<seq> <verb> [argument]" — the argument may itself contain spaces.
        local seq, verb, arg = line:match("^(%d+)%s+(%S+)%s*(.*)$")
        seq = tonumber(seq)
        if seq and seq > last_seq then
            last_seq = seq
            apply(verb, arg)
        end
    end
end

mp.observe_property("metadata", "native", write_status)
mp.observe_property("core-idle", "bool", write_status)
mp.observe_property("pause", "bool", write_status)
mp.add_periodic_timer(1, write_status)
mp.add_periodic_timer(0.25, poll_commands)

mp.register_event("end-file", function(event)
    if not status_path then return end
    -- Distinguish "the stream dropped" from "we were told to quit": the former
    -- is an error the UI must surface, the latter is a normal teardown.
    local state = (event and event.reason == "quit") and "stopped" or "error"
    local reason = (event and event.error) or ""
    local f = io.open(status_path .. ".tmp", "w")
    if f then
        f:write("state=", state, "\nerror=", reason, "\nseq=", tostring(last_seq), "\n")
        f:close()
        os.rename(status_path .. ".tmp", status_path)
    end
end)

write_status()
