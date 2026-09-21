--[[--
Kindle backend — NOT YET IMPLEMENTED.

Kindle firmware ships GStreamer (Amazon uses it for Audible and TTS), which
means no audio stack has to be cross-compiled: a `playbin` pipeline handles the
HTTP, the decode and the output. This is the route KinAMP takes.

The intended pipeline, which streams Shoutcast/Icecast directly:

    gst-launch-1.0 playbin uri=<url> audio-sink=alsasink

Implementation notes for whoever picks this up:
  * The known failure mode is a *stripped* firmware GStreamer with no
    `audioconvert`/`audioresample`, in which case the pipeline starts and
    produces silence. See audiobook.koplugin issue #81. `is_available()` must
    therefore check for the elements, not just the binary.
  * `gst-launch-1.0` has no control channel, so pause/seek/volume need either
    the `gst-launch` stdin hack or a small native helper. Spawning a fresh
    pipeline per station is acceptable for radio (where seek is meaningless)
    but not for podcasts.
  * ICY metadata is available via the `souphttpsrc` element's `iradio-mode`,
    but `gst-launch` cannot surface it -- which is exactly why KinAMP wrote its
    own ICY client instead.
  * Bluetooth pairing on Kindle is a separate problem; KinAMP's `kinamp_bt.lua`
    is the prior art.
]]

local Util = require("koaudio.util")

local GStreamerBackend = {}
GStreamerBackend.__index = GStreamerBackend

GStreamerBackend.name = "gstreamer"
GStreamerBackend.capabilities = { pause = false, seek = false, volume = true, metadata = false }

function GStreamerBackend.is_available()
    if not Util.has_command("gst-launch-1.0") then
        return false, "gst-launch-1.0 not found"
    end
    return false, "GStreamer backend not implemented yet (see koaudio/backends/gstreamer.lua)"
end

function GStreamerBackend.new()
    return setmetatable({}, GStreamerBackend)
end

function GStreamerBackend:play() return false, "not implemented" end
function GStreamerBackend:stop() return true end
function GStreamerBackend:poll() return nil end
function GStreamerBackend:is_running() return false end

return GStreamerBackend
