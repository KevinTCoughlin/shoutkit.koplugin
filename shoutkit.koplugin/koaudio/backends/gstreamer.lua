--[[--
GStreamer backend — Kindle and MTK Kobo.

Covers **two** platforms, because both ship GStreamer in firmware and neither
needs an audio stack cross-compiled:

  * **Kindle**, where Amazon uses it for Audible and TTS. Output is `alsasink`.
    This is the route KinAMP takes.
  * **MTK Kobos** (Clara Colour, Clara BW, Libra Colour — "Mark 12" and later),
    where MediaTek ships a proprietary sink element, `mtkbtmwrpcaudiosink`,
    wrapping their own Bluetooth stack. Those devices have no speaker and no
    headphone jack, so that sink is the only output there is.

Two probe rounds on a real Clara Colour (`docs/probe-clara-colour-*.txt`) shaped
everything below, and they ruled out the design this file used to describe.

**There is no HTTP source element on a Kobo.** No `souphttpsrc`, no
`curlhttpsrc`; `giosrc` is built without the http backend; `playbin` refuses an
`http://` URI outright. So `playbin uri=<url>` — the one-liner this project was
built around — does not work there, and the two kinds of item need genuinely
different pipelines rather than one with a different argument:

    filesrc location=<path> ! mpegaudioparse ! mpg123audiodec
        ! audioconvert ! audioresample ! volume ! <sink>

    wget -O - <url> | gst-launch-1.0 fdsrc fd=0 ! queue2 ! <the same chain>

Both are verified working on the device. `mpg123audiodec` is the only audio
decoder present, so this backend plays MP3 and nothing else, and says so.

**`gst-launch-1.0` has no control channel**, unlike mpv: it parses a pipeline,
runs it and exits. The status file, the command file and the state machine all
live in `gst_control.sh`, which owns the pipeline and is what we actually spawn.
That is also why `capabilities.volume` is false — the volume is baked into the
pipeline at start and cannot be changed without rebuilding it. On MTK Kobo that
matters less than it sounds, since A2DP volume lives on the speaker.

**Seeking is approximate and file-only.** With no control channel the seek
happens upstream of GStreamer: skip bytes with `dd`, feed the rest down a pipe.
That needs a bytes-per-second figure, which the caller supplies as
`item.duration` alongside the file — podcast.koplugin has both from the feed.
Without a duration there is no seeking, and `seek()` says so rather than
quietly doing nothing.

**The sink cannot be trusted to report failure.** With nothing paired,
`mtkbtmwrpcaudiosink` fails to reach `/tmp/audio.a2dp_ctrl` four times, logs it,
then reports success, prerolls, runs to EOS and exits 0 — having made no sound.
Nothing after the fact distinguishes that from real playback, so
`is_available()` checks for the control socket itself. That check is currently
the reason this backend reports unavailable on every MTK Kobo: under KOReader
nothing provides that socket, because the MediaTek middleware belongs to Nickel
and KOReader stops Nickel. See ROADMAP v0.4.
]]

local Util = require("koaudio.util")

local BACKEND_DIR = debug.getinfo(1, "S").source:match("@?(.*/)") or "./"
local CONTROL_SCRIPT = BACKEND_DIR .. "gst_control.sh"

-- The A2DP control socket the MTK sink connects to. A plain filesystem path,
-- not the abstract socket earlier notes described -- round two watched it try.
local MTK_A2DP_SOCKET = "/tmp/audio.a2dp_ctrl"

local GstBackend = {}
GstBackend.__index = GstBackend

GstBackend.name = "gstreamer"
GstBackend.capabilities = {
    pause = true,
    seek = true,      -- files with a known duration only; seek() enforces it
    volume = false,   -- no control channel: see the note above
    metadata = false, -- no ICY source element exists on these devices
}

--- Elements without which nothing can play. Deliberately not `decodebin`: an
-- explicit chain fails loudly on a format it cannot handle, where decodebin
-- would negotiate its way to silence.
local REQUIRED_ELEMENTS = {
    "mpegaudioparse", "mpg123audiodec", "audioconvert", "audioresample",
    "fdsrc", "filesrc", "queue2", "volume",
}

local function platform()
    local forced = os.getenv("KOAUDIO_PLATFORM")
    if forced and forced ~= "" then return forced end
    local ok, device = pcall(require, "device")
    if not ok or not device then return "desktop" end
    if device.isKindle and device:isKindle() then return "kindle" end
    if device.isKobo and device:isKobo() then return "kobo" end
    return "desktop"
end

--- True when this Kobo is an MTK one, which decides the sink. `Device:isMTK()`
-- is KOReader's own per-model answer and beats parsing product ids or crash.log.
local function is_mtk()
    local ok, device = pcall(require, "device")
    if not ok or not device or not device.isMTK then return false end
    local called_ok, value = pcall(device.isMTK, device)
    return called_ok and value or false
end

--- Which elements `gst-inspect-1.0` can see, as a set. One call, not one per
-- element: on a device this slow the difference is seconds at plugin load.
local function available_elements()
    local f = io.popen("gst-inspect-1.0 2>/dev/null")
    if not f then return {} end
    local elements = {}
    for line in f:lines() do
        -- "plugin:  element: Description"
        local name = line:match("^[%w_%-]+:%s+([%w_%-]+):")
        if name then elements[name] = true end
    end
    f:close()
    return elements
end

--- The sink this platform outputs through, or nil plus why not.
local function choose_sink(elements)
    local forced = os.getenv("KOAUDIO_SINK")
    if forced and forced ~= "" then return forced end

    local plat = platform()
    if plat == "kobo" then
        if not is_mtk() then
            -- i.MX6 Kobos have no media framework at all; that is the ALSA
            -- backend's problem, not this one's.
            return nil, "this Kobo is not an MTK device (no GStreamer route)"
        end
        if not elements.mtkbtmwrpcaudiosink then
            return nil, "mtkbtmwrpcaudiosink missing"
        end
        -- The sink will happily "succeed" with nothing on the other end, so
        -- the socket is the only honest availability signal there is.
        local socket = io.open(MTK_A2DP_SOCKET, "r")
        if socket then
            socket:close()
        else
            return nil, "no Bluetooth audio: " .. MTK_A2DP_SOCKET
                .. " is absent (pair a speaker, and see ROADMAP v0.4)"
        end
        return "mtkbtmwrpcaudiosink"
    end

    if elements.alsasink then return "alsasink" end
    if elements.autoaudiosink then return "autoaudiosink" end
    return nil, "no usable sink element (tried alsasink, autoaudiosink)"
end

--- How a stream's bytes get fetched, since GStreamer cannot do it itself.
local function choose_fetcher()
    if Util.has_command("wget") then return "wget" end
    if Util.has_command("curl") then return "curl" end
    return nil
end

--- Runs at plugin load on every device, so it has to be both cheap and honest.
function GstBackend.is_available()
    if not Util.has_command("gst-launch-1.0") then
        return false, "gst-launch-1.0 not found"
    end

    local elements = available_elements()
    local missing = {}
    for _, name in ipairs(REQUIRED_ELEMENTS) do
        if not elements[name] then missing[#missing + 1] = name end
    end
    if #missing > 0 then
        -- The Kindle trap from audiobook.koplugin #81: some firmware builds are
        -- stripped of audioconvert/audioresample, and the pipeline then starts
        -- and produces silence. Checking the binary alone is not enough.
        return false, "GStreamer is missing " .. table.concat(missing, ", ")
    end

    local sink, why = choose_sink(elements)
    if not sink then return false, why end

    return true
end

function GstBackend.new(opts)
    opts = opts or {}
    local base = (opts.runtime_dir or Util.runtime_dir()) .. "/koaudio-gst"
    return setmetatable({
        status_path = base .. ".status",
        command_path = base .. ".command",
        pid_path = base .. ".pid",
        log_path = base .. ".log",
        sink = opts.sink,
        seq = 0,
        pid = nil,
        volume = opts.volume or 70,
        item = nil,
    }, GstBackend)
end

function GstBackend:send(verb, arg)
    if not self.pid then return false, "no player running" end
    self.seq = self.seq + 1
    local f = io.open(self.command_path, "a")
    if not f then return false, "cannot write command file" end
    f:write(self.seq, " ", verb, " ", tostring(arg or ""), "\n")
    f:close()
    return true
end

--- Bytes per second for a file, from the size on disk and the duration the
-- caller knows. Constant-bitrate arithmetic: good enough to land within a frame
-- on a podcast, and the only arithmetic available without decoding the file.
local function byte_rate(item)
    if not item or item.kind ~= "file" then return 0 end
    local duration = tonumber(item.duration or 0) or 0
    if duration <= 0 then return 0 end
    local f = io.open(item.url, "rb")
    if not f then return 0 end
    local size = f:seek("end")
    f:close()
    if not size or size <= 0 then return 0 end
    return math.floor(size / duration)
end

--- Kills a pipeline left behind by a previous session. On MTK Kobo this is not
-- housekeeping: the A2DP socket takes exactly one holder, so an orphan from a
-- crashed KOReader makes every later attempt fail silently, and the user has no
-- way to see why.
-- Exposed for the test suite: the arithmetic is the whole of seeking on this
-- backend, and it deserves to be checked against a real file rather than only
-- through a spawn.
GstBackend._byte_rate = byte_rate

function GstBackend:reap_orphans()
    local pid = tonumber((Util.read_file(self.pid_path) or ""):match("%d+"))
    if pid and pid ~= self.pid and Util.pid_alive(pid) then
        os.execute("kill -TERM -" .. pid .. " 2>/dev/null; kill -TERM " .. pid .. " 2>/dev/null")
    end
    -- Belt and braces: anything still holding the pipeline that we did not
    -- start, for instance after KOReader itself was killed.
    os.execute("pkill -f 'gst-launch-1.0 .*koaudio' 2>/dev/null")
end

function GstBackend:play(item, opts)
    if not item or not item.url or item.url == "" then
        return false, "no URL"
    end
    opts = opts or {}
    self:stop()
    self:reap_orphans()

    local kind = item.kind == "file" and "file" or "stream"

    local sink = self.sink
    if not sink then
        local chosen, why = choose_sink(available_elements())
        if not chosen then return false, why end
        sink = chosen
        self.sink = sink
    end

    local fetch = "none"
    if kind == "stream" then
        fetch = choose_fetcher()
        if not fetch then
            -- Worth stating plainly: GStreamer on these devices cannot fetch,
            -- so with no HTTP client there is no radio at all.
            return false, "no wget or curl to fetch the stream"
        end
    end

    -- Truncated, not appended: sequence numbers restart with each player, so a
    -- leftover file would look like commands from the future.
    local f = io.open(self.command_path, "w")
    if f then f:close() end
    os.remove(self.status_path)
    self.seq = 0

    local volume = Util.clamp(tonumber(opts.volume or self.volume) or 70, 0, 100)
    local start_at = math.floor(tonumber(item.position or 0) or 0)

    local cmd = string.format(
        "KOAUDIO_STATUS=%s KOAUDIO_COMMAND=%s KOAUDIO_LOG=%s KOAUDIO_URL=%s "
        .. "KOAUDIO_KIND=%s KOAUDIO_SINK=%s KOAUDIO_VOLUME=%d KOAUDIO_FETCH=%s "
        .. "KOAUDIO_START=%d KOAUDIO_BYTE_RATE=%d sh %s >>%s 2>&1 & echo $! >%s",
        Util.shell_escape(self.status_path),
        Util.shell_escape(self.command_path),
        Util.shell_escape(self.log_path),
        Util.shell_escape(item.url),
        kind,
        Util.shell_escape(sink),
        volume,
        fetch,
        start_at,
        byte_rate(item),
        Util.shell_escape(CONTROL_SCRIPT),
        Util.shell_escape(self.log_path),
        Util.shell_escape(self.pid_path)
    )

    os.execute("sh -c " .. Util.shell_escape(cmd))

    local pid = tonumber((Util.read_file(self.pid_path) or ""):match("%d+"))
    if not pid then
        return false, "failed to start the pipeline (see " .. self.log_path .. ")"
    end
    self.pid = pid
    self.item = item
    self.volume = volume
    self.byte_rate = byte_rate(item)
    return true
end

function GstBackend:stop()
    if self.pid then
        self:send("stop")
        -- The control script turns "stop" into a clean shutdown, but one that
        -- has wedged would never read it -- and a wedged pipeline on MTK keeps
        -- the socket. Signal the group too.
        os.execute("kill -TERM -" .. self.pid .. " 2>/dev/null; kill -TERM " .. self.pid .. " 2>/dev/null")
        self.pid = nil
    end
    os.remove(self.status_path)
    return true
end

function GstBackend:pause() return self:send("pause") end
function GstBackend:resume() return self:send("resume") end

--- Accepted and recorded, but it cannot take effect until the pipeline is next
-- built. Saying so beats a silent no-op.
function GstBackend:set_volume(level)
    level = Util.clamp(tonumber(level) or self.volume, 0, 100)
    self.volume = level
    return self:send("volume", level)
end

local function seek_refusal(self)
    if not self.item or self.item.kind ~= "file" then
        return "cannot seek a live stream"
    end
    if (self.byte_rate or 0) <= 0 then
        return "cannot seek without a known duration for this file"
    end
    return nil
end

function GstBackend:seek(seconds)
    local why = seek_refusal(self)
    if why then return false, why end
    return self:send("seek", math.floor(tonumber(seconds) or 0))
end

function GstBackend:seek_to(seconds)
    local why = seek_refusal(self)
    if why then return false, why end
    return self:send("seek_to", math.floor(tonumber(seconds) or 0))
end

--- Non-blocking: one file read, as the interface requires.
function GstBackend:poll()
    if not self.pid then return nil end
    if not Util.pid_alive(self.pid) then
        self.pid = nil
        local status = Util.parse_status(Util.read_file(self.status_path))
        if status and (status.state == "stopped" or status.state == "error") then
            return status
        end
        return { state = "error", error = "the pipeline exited unexpectedly" }
    end
    return Util.parse_status(Util.read_file(self.status_path))
end

function GstBackend:is_running()
    return self.pid ~= nil and Util.pid_alive(self.pid)
end

return GstBackend
