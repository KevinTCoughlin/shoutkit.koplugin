--[[--
Turns a directory link into something a player can actually open.

A meaningful share of Radio-Browser URLs are not streams but one-line playlist
files -- PLS or M3U -- wrapping the real stream. Some backends unwrap those
themselves (mpv and GStreamer do); the ALSA/decoder-daemon route does not. So
resolution happens here, once, above the backend seam, and every backend gets
handed a direct URL.

The trap this module exists to avoid: **.m3u8 is not an M3U playlist.** It is an
HLS manifest, and the player must be given the manifest URL, not the first
segment inside it. Unwrapping one yields a two-second audio chunk that plays and
then stops, which looks exactly like a flaky station. `is_hls` from the
directory, the `.m3u8` extension and the HLS content types are all checked.
]]

local Playlist = {}

Playlist.PLAYLIST_CONTENT_TYPES = {
    ["audio/x-scpls"] = "pls",
    ["application/pls+xml"] = "pls",
    ["audio/x-mpegurl"] = "m3u",
    ["audio/mpegurl"] = "m3u",
    ["application/x-mpegurl"] = "m3u",
    ["application/vnd.apple.mpegurl"] = "hls",
    ["application/x-mpegURL"] = "hls",
}

--- Strips the query string and fragment before looking at the extension, so
-- `...stream.m3u?token=abc` is still recognised.
local function extension_of(url)
    local path = tostring(url or ""):gsub("#.*$", ""):gsub("%?.*$", "")
    return (path:match("%.([%w]+)$") or ""):lower()
end

--- "pls", "m3u", "hls" or nil.
-- `content_type` wins over the extension when both are known, because servers
-- are more reliable about the former than URLs are about the latter.
function Playlist.classify(url, content_type)
    if content_type then
        local bare = tostring(content_type):gsub(";.*$", ""):gsub("%s", "")
        local kind = Playlist.PLAYLIST_CONTENT_TYPES[bare]
            or Playlist.PLAYLIST_CONTENT_TYPES[bare:lower()]
        if kind then return kind end
    end
    local ext = extension_of(url)
    if ext == "pls" then return "pls" end
    if ext == "m3u8" then return "hls" end
    if ext == "m3u" then return "m3u" end
    return nil
end

--- True when the URL should be fetched and unwrapped. HLS never should.
function Playlist.needs_resolution(url, content_type, is_hls)
    if is_hls then return false end
    local kind = Playlist.classify(url, content_type)
    return kind == "pls" or kind == "m3u"
end

local function looks_like_stream(candidate)
    if not candidate or candidate == "" then return false end
    return candidate:match("^https?://") ~= nil or candidate:match("^rtsp://") ~= nil
end

--- Extracts every stream URL from a PLS body, in FileN order.
local function parse_pls(body)
    local entries = {}
    for index, url in body:gmatch("[Ff]ile(%d+)%s*=%s*([^\r\n]+)") do
        url = url:gsub("^%s+", ""):gsub("%s+$", "")
        if looks_like_stream(url) then
            entries[#entries + 1] = { index = tonumber(index), url = url }
        end
    end
    table.sort(entries, function(a, b) return a.index < b.index end)
    local urls = {}
    for _, entry in ipairs(entries) do urls[#urls + 1] = entry.url end
    return urls
end

--- Extracts every stream URL from an M3U body, skipping #EXT directives and
-- comments. Relative entries are dropped rather than guessed at: a relative
-- path in a radio M3U is almost always a local-file playlist that leaked into
-- the directory, and resolving it would produce a URL that 404s.
local function parse_m3u(body)
    local urls = {}
    for line in body:gmatch("[^\r\n]+") do
        line = line:gsub("^%s+", ""):gsub("%s+$", "")
        if line ~= "" and line:sub(1, 1) ~= "#" and looks_like_stream(line) then
            urls[#urls + 1] = line
        end
    end
    return urls
end

--- Returns the list of stream URLs inside a playlist body.
function Playlist.parse(body, kind)
    if type(body) ~= "string" or body == "" then return {} end
    if kind == "pls" then return parse_pls(body) end
    if kind == "m3u" then return parse_m3u(body) end
    -- Unknown kind: sniff. A PLS always carries a [playlist] header.
    if body:find("%[playlist%]") then return parse_pls(body) end
    return parse_m3u(body)
end

--- Resolves `url` to a direct stream URL, fetching it if it is a playlist.
--
-- `opts.is_hls` should be the directory's own flag. `opts.depth` guards against
-- a playlist that points at itself, which exists in the wild.
--
-- Returns url, kind_or_nil. Never returns nil for the URL: an unresolvable
-- playlist falls back to the original, on the theory that the backend may well
-- unwrap it itself, and failing loudly here would hide stations that work.
function Playlist.resolve(url, transport, opts)
    opts = opts or {}
    if not Playlist.needs_resolution(url, opts.content_type, opts.is_hls) then
        return url, nil
    end

    local depth = opts.depth or 0
    if depth >= 2 then return url, nil end

    local body, err = transport:get(url, { timeout = opts.timeout or 10 })
    if not body then return url, err end

    local kind = Playlist.classify(url, opts.content_type)
    local entries = Playlist.parse(body, kind)
    if #entries == 0 then return url, "playlist contained no stream" end

    local first = entries[1]
    -- A playlist whose first entry is itself another playlist: one more hop.
    if Playlist.needs_resolution(first, nil, false) then
        return Playlist.resolve(first, transport, {
            depth = depth + 1,
            timeout = opts.timeout,
        })
    end
    return first, nil
end

return Playlist
