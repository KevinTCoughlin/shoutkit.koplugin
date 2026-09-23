--[[--
Tests for the GStreamer backend.

Nothing here needs GStreamer installed: `is_available()` and the sink choice are
exercised through `KOAUDIO_PLATFORM` and `KOAUDIO_SINK`, and everything else is
file protocol and arithmetic. The parts that genuinely need a pipeline are in
`tools/gst-smoke.sh`, which is opt-in because CI has no audio device.
]]

local GstBackend = require("koaudio.backends.gstreamer")
local Util = require("koaudio.util")

local TMP = os.getenv("TMPDIR") or "/tmp"

local function scratch_dir()
    local dir = TMP .. "/koaudio-spec"
    os.execute("mkdir -p " .. Util.shell_escape(dir))
    return dir
end

local function backend()
    return GstBackend.new{ runtime_dir = scratch_dir() }
end

--- A file of exactly `bytes` bytes, so byte-rate arithmetic has something real
-- to measure rather than a mock that agrees with whatever we wrote.
local function file_of_size(name, bytes)
    local path = scratch_dir() .. "/" .. name
    local f = assert(io.open(path, "wb"))
    f:write(string.rep("x", bytes))
    f:close()
    return path
end

describe("GStreamer backend capabilities", function()
    it("does not claim live volume control, because gst-launch has no channel", function()
        assert_.falsy(GstBackend.capabilities.volume)
    end)

    it("does not claim metadata: no device here has an ICY source element", function()
        assert_.falsy(GstBackend.capabilities.metadata)
    end)

    it("claims pause and seek", function()
        assert_.truthy(GstBackend.capabilities.pause)
        assert_.truthy(GstBackend.capabilities.seek)
    end)
end)

describe("GStreamer seeking", function()
    it("refuses to seek a live stream", function()
        local b = backend()
        b.pid = 1
        b.item = { url = "http://x/s", kind = "stream" }
        local ok, why = b:seek(30)
        assert_.falsy(ok)
        assert_.equal("cannot seek a live stream", why)
    end)

    it("refuses to seek a file whose duration nobody knows", function()
        local b = backend()
        b.pid = 1
        b.item = { url = "/tmp/x.mp3", kind = "file" }
        b.byte_rate = 0
        local ok, why = b:seek(30)
        assert_.falsy(ok)
        assert_.truthy(why:match("duration"))
    end)

    it("seeks a file when the duration gives it a byte rate", function()
        local b = backend()
        b.pid = 1
        b.item = { url = "/tmp/x.mp3", kind = "file" }
        b.byte_rate = 16000
        os.remove(b.command_path)
        assert_.truthy(b:seek(-30))
        local written = Util.read_file(b.command_path) or ""
        assert_.truthy(written:match("1 seek %-30"))
    end)
end)

describe("GStreamer byte-rate arithmetic", function()
    it("divides the size on disk by the duration the caller knows", function()
        local path = file_of_size("rate.mp3", 160000)
        assert_.equal(16000, GstBackend._byte_rate{ url = path, kind = "file", duration = 10 })
        os.remove(path)
    end)

    it("gives up on a file with no duration, which disables seeking", function()
        local path = file_of_size("norate.mp3", 4096)
        assert_.equal(0, GstBackend._byte_rate{ url = path, kind = "file" })
        os.remove(path)
    end)

    it("gives up on a stream, where byte offsets mean nothing", function()
        assert_.equal(0, GstBackend._byte_rate{ url = "http://x/s", kind = "stream", duration = 60 })
    end)

    it("gives up on a file that is not there", function()
        assert_.equal(0, GstBackend._byte_rate{ url = "/nope/missing.mp3", kind = "file", duration = 60 })
    end)
end)

describe("GStreamer command protocol", function()
    it("numbers commands from one and increments", function()
        local b = backend()
        b.pid = 1
        os.remove(b.command_path)
        b:pause()
        b:resume()
        local written = Util.read_file(b.command_path) or ""
        assert_.truthy(written:match("1 pause"))
        assert_.truthy(written:match("2 resume"))
    end)

    it("refuses to queue a command with no player running", function()
        local b = backend()
        local ok, why = b:pause()
        assert_.falsy(ok)
        assert_.equal("no player running", why)
    end)

    it("records a volume change even though it cannot take effect at once", function()
        local b = backend()
        b.pid = 1
        os.remove(b.command_path)
        assert_.truthy(b:set_volume(35))
        assert_.equal(35, b.volume)
        assert_.truthy((Util.read_file(b.command_path) or ""):match("volume 35"))
    end)

    it("clamps a volume outside 0-100", function()
        local b = backend()
        b.pid = 1
        b:set_volume(400)
        assert_.equal(100, b.volume)
    end)
end)

describe("GStreamer polling", function()
    it("reports nothing when no player has been started", function()
        local b = backend()
        assert_.falsy(b:poll())
    end)

    it("calls a player that vanished without a terminal state an error", function()
        local b = backend()
        -- A pid that cannot be alive: we are not running as init.
        b.pid = 999999
        os.remove(b.status_path)
        local status = b:poll()
        assert_.equal("error", status.state)
        assert_.truthy(status.error:match("unexpectedly"))
    end)

    it("believes a terminal state the player did write", function()
        local b = backend()
        b.pid = 999999
        Util.write_file_atomic(b.status_path, "state=stopped\nseq=4\n")
        local status = b:poll()
        assert_.equal("stopped", status.state)
        os.remove(b.status_path)
    end)
end)

describe("GStreamer refusals", function()
    it("refuses an item with no URL", function()
        local ok, why = backend():play{ kind = "stream" }
        assert_.falsy(ok)
        assert_.equal("no URL", why)
    end)
end)

describe("GStreamer availability", function()
    it("reports why rather than just false", function()
        local available, why = GstBackend.is_available()
        if not available then
            -- Whatever the host is missing, the reason has to name it, because
            -- this string is what the UI shows a user with no sound.
            assert_.truthy(type(why) == "string" and #why > 0)
        end
    end)
end)
