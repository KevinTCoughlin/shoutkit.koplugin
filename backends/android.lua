--[[--
Android backend — NOT YET IMPLEMENTED.

Android is the easiest target of the four: `android.media.MediaPlayer` does the
HTTP(S), the codecs, the buffering and the seeking itself, so this backend is
almost pure JNI glue and needs nothing cross-compiled and no status file. On
Boox and other Android e-ink devices it is the only sane route.

Reference implementation to follow: audiobook.koplugin's `androidplayer.lua`
(stradichenko/audiobook.koplugin), which already drives MediaPlayer from a
KOReader plugin through `android-luajit-launcher`'s JNI bridge.

Implementation notes for whoever picks this up:
  * `require("android")` is present only in KOReader's Android build; the
    `pcall` below is what keeps this file loadable everywhere else.
  * MediaPlayer is asynchronous -- prepareAsync() plus listeners -- so `poll()`
    reads a state table this module keeps up to date from callbacks, rather than
    parsing a file as the spawning backends do.
  * ICY metadata is *not* exposed by MediaPlayer. Live titles need either a
    separate lightweight HTTP probe of the stream headers or going without.
]]

local AndroidBackend = {}
AndroidBackend.__index = AndroidBackend

AndroidBackend.name = "android"
AndroidBackend.capabilities = { pause = true, seek = true, volume = true, metadata = false }

function AndroidBackend.is_available()
    local ok = pcall(require, "android")
    if not ok then return false, "not an Android build of KOReader" end
    return false, "Android backend not implemented yet (see koaudio/backends/android.lua)"
end

function AndroidBackend.new()
    return setmetatable({}, AndroidBackend)
end

function AndroidBackend:play() return false, "not implemented" end
function AndroidBackend:stop() return true end
function AndroidBackend:poll() return nil end
function AndroidBackend:is_running() return false end

return AndroidBackend
