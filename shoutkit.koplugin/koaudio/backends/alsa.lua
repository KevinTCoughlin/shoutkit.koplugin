--[[--
Kobo / PocketBook backend — NOT YET IMPLEMENTED, and the most expensive of the four.

Kobo has no GStreamer and no media framework: there is ALSA and nothing else.
Worse, no current Kobo has a speaker or a headphone jack, so "audio" means
Bluetooth A2DP, which means BlueALSA bridging BlueZ to ALSA -- a binary that has
to be cross-compiled for the device. audiobook.koplugin does exactly this and
ships the build recipes (`cross-build-bluealsa.nix`), which is the prior art to
lean on rather than repeat.

Because ALSA only takes PCM, this backend needs a decoder in front of it: it
cannot stream an MP3 URL the way GStreamer or MediaPlayer can. That is the piece
KinAMP solves with a native daemon (miniaudio for decode, its own ICY client for
the HTTP), and the reason the status-file protocol in docs/PROTOCOL.md is shaped
the way it is -- so such a daemon drops straight in here.

Implementation order that avoids building everything at once:
  1. local files only, decoder -> `aplay`, no Bluetooth (works on PocketBook,
     which has a real speaker);
  2. Bluetooth A2DP via BlueALSA, pairing delegated to kobo.koplugin;
  3. network streaming, which needs the decoder daemon.
]]

local Util = require("koaudio.util")

local AlsaBackend = {}
AlsaBackend.__index = AlsaBackend

AlsaBackend.name = "alsa"
AlsaBackend.capabilities = { pause = false, seek = false, volume = true, metadata = false }

function AlsaBackend.is_available()
    if not Util.has_command("aplay") then
        return false, "no ALSA tools found"
    end
    return false, "ALSA backend not implemented yet (see koaudio/backends/alsa.lua)"
end

function AlsaBackend.new()
    return setmetatable({}, AlsaBackend)
end

function AlsaBackend:play() return false, "not implemented" end
function AlsaBackend:stop() return true end
function AlsaBackend:poll() return nil end
function AlsaBackend:is_running() return false end

return AlsaBackend
