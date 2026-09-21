--[[--
Picks an audio backend for the device we are running on.

The order matters and is not arbitrary. Android is checked first because its
backend is in-process and always works when present. GStreamer comes before
ALSA because on Kindle the firmware ships it and it handles network streams
itself; ALSA backends need something else to do the HTTP and the decoding. mpv
is last as the desktop/emulator fallback, which is also what CI and the dev
harness get.

Nothing here fails hard: a device with no usable backend gets `nil` plus every
rejection reason, so the UI can tell the user *why* rather than silently
offering a player that cannot make sound.
]]

local Detect = {}

-- Listed in probe order.
Detect.BACKEND_NAMES = { "android", "gstreamer", "alsa", "mpv" }

--- KOReader's Device module, or nil when running outside KOReader.
local function koreader_device()
    local ok, device = pcall(require, "device")
    if ok then return device end
    return nil
end

function Detect.platform()
    local forced = os.getenv("KOAUDIO_PLATFORM")
    if forced and forced ~= "" then return forced end

    local device = koreader_device()
    if device then
        if device:isAndroid() then return "android" end
        if device:isKindle() then return "kindle" end
        if device:isKobo() then return "kobo" end
        if device:isPocketBook() then return "pocketbook" end
        if device:isRemarkable() then return "remarkable" end
        if device:isEmulator() then return "emulator" end
        return "unknown"
    end
    return "desktop"
end

local function load_backend(name)
    local ok, backend = pcall(require, "koaudio.backends." .. name)
    if ok then return backend end
    return nil, tostring(backend)
end

--- Returns backend_module, name, rejections.
-- `KOAUDIO_BACKEND` forces one and skips probing entirely, which is how the
-- test suite pins the null backend and how a user works around a bad probe.
function Detect.select(opts)
    opts = opts or {}
    local rejections = {}

    local forced = opts.backend or os.getenv("KOAUDIO_BACKEND")
    if forced and forced ~= "" then
        local backend, err = load_backend(forced)
        if not backend then
            return nil, nil, { [forced] = "not loadable: " .. tostring(err) }
        end
        return backend, forced, rejections
    end

    for _, name in ipairs(Detect.BACKEND_NAMES) do
        local backend, err = load_backend(name)
        if not backend then
            rejections[name] = "not loadable: " .. tostring(err)
        else
            local available, reason = backend.is_available()
            if available then
                return backend, name, rejections
            end
            rejections[name] = reason or "unavailable"
        end
    end

    return nil, nil, rejections
end

return Detect
