--[[--
GStreamer backend — NOT YET IMPLEMENTED.

Covers **two** platforms, because both ship GStreamer in firmware and neither
needs an audio stack cross-compiled:

  * **Kindle**, where Amazon uses it for Audible and TTS. Output is `alsasink`.
    This is the route KinAMP takes.
  * **MTK Kobos** (Clara Colour, Clara BW, Libra Colour — "Mark 12" and later),
    where MediaTek ships a proprietary sink element, `mtkbtmwrpcaudiosink`,
    wrapping their own Bluetooth stack. Those devices have no speaker and no
    headphone jack, so that sink is the only output there is.

The intended pipelines, which stream Shoutcast/Icecast directly:

    gst-launch-1.0 playbin uri=<url> audio-sink=alsasink              # Kindle
    gst-launch-1.0 playbin uri=<url> audio-sink=mtkbtmwrpcaudiosink   # MTK Kobo

MTK adds three constraints Kindle does not have, all detailed in
docs/BACKENDS.md: the `@kobo:mtkbtmwrpc` abstract socket is exclusive, so
orphaned pipelines must be reaped via /proc/net/unix before starting; A2DP idles
out in one to two seconds, so silence has to keep flowing between items; and
returning to Nickel after using Bluetooth can panic the kernel, which the user
deserves to be warned about once.

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
  * Bluetooth pairing is a separate problem on both platforms. KinAMP's
    `kinamp_bt.lua` is the prior art for Kindle; for MTK Kobo it is
    audiobook.koplugin's `btmanager.lua`, which drives MediaTek's D-Bus
    interface at `com.kobo.mtk.bluedroid` rather than BlueZ's `org.bluez`.
  * `tools/probe-kobo.sh` reports, on a given device, whether the sink element
    and the codec elements a network stream needs are actually present. Run it
    before writing any of this.
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
