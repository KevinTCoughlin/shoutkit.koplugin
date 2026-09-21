--[[--
Radio-Browser directory client.

Radio-Browser is the community station directory Radio-Browser-backed clients
use (including ShoutKit's own `RadioDirectory`): free, no API key, ~50k
stations. It is also a volunteer-run cluster of mirrors, and the docs are
explicit that "any of them may go down in the future", so a client that hardcodes
one host is a client that breaks.

This differs from KinAMP's approach on purpose. KinAMP ships a frozen 3.4 MB
JSON dump of the directory and greps it on device: no network needed, but no
tags, no countries, no codec filter, no vote counts, and it goes stale. This
queries the live API instead, which is what makes faceted browsing possible at
all -- at the cost of needing a working connection at browse time.

Etiquette the API asks of clients, all implemented here:
  * send a real, identifying User-Agent (enforced: see `new`);
  * report a click to /json/url/<uuid> whenever the user actually plays a
    station, which is how the directory's popularity ranking stays meaningful;
  * use the UUID fields, never the legacy integer ids.
]]

local Json = require("lib.json")
local Station = require("directory.station")
local Transport = require("directory.transport")

local RadioBrowser = {}
RadioBrowser.__index = RadioBrowser

RadioBrowser.DISCOVERY_URL = "https://all.api.radio-browser.info/json/servers"

--- Used when discovery itself fails. `all.api` is round-robin DNS across the
-- live mirrors, so it is the best single guess; the named hosts are there for
-- the case where that record is the thing that is broken.
RadioBrowser.FALLBACK_MIRRORS = {
    "all.api.radio-browser.info",
    "de1.api.radio-browser.info",
    "de2.api.radio-browser.info",
    "at1.api.radio-browser.info",
}

local RESERVED = {
    [" "] = "%20",
}

local function urlencode(value)
    return (tostring(value):gsub("[^%w%-%._~]", function(char)
        return RESERVED[char] or string.format("%%%02X", char:byte())
    end))
end

local function build_query(params)
    if not params or next(params) == nil then return "" end
    local keys = {}
    for key in pairs(params) do keys[#keys + 1] = key end
    -- Sorted so a given request produces a byte-identical URL every time,
    -- which makes caching and test assertions possible.
    table.sort(keys)
    local parts = {}
    for _, key in ipairs(keys) do
        local value = params[key]
        if type(value) == "boolean" then value = value and "true" or "false" end
        parts[#parts + 1] = urlencode(key) .. "=" .. urlencode(value)
    end
    return "?" .. table.concat(parts, "&")
end

local function shuffle(list)
    for i = #list, 2, -1 do
        local j = math.random(i)
        list[i], list[j] = list[j], list[i]
    end
    return list
end

function RadioBrowser.new(opts)
    opts = opts or {}
    local user_agent = opts.user_agent or "shoutkit.koplugin/0.1.0"
    return setmetatable({
        user_agent = user_agent,
        transport = Transport.new(opts.transport, { user_agent = user_agent }),
        timeout = opts.timeout or 20,
        _mirrors = opts.mirrors,
        -- Mirrors are rediscovered at most this often; the cluster membership
        -- changes on the order of months, not minutes.
        _mirrors_fetched_at = opts.mirrors and os.time() or nil,
        mirror_ttl = opts.mirror_ttl or 24 * 60 * 60,
    }, RadioBrowser)
end

--- The mirror list, in the order this client will try them.
-- Discovery failure is not an error: we fall back and carry on.
function RadioBrowser:mirrors()
    local fresh = self._mirrors_fetched_at
        and (os.time() - self._mirrors_fetched_at) < self.mirror_ttl
    if self._mirrors and fresh then return self._mirrors end

    local body = self.transport:get(RadioBrowser.DISCOVERY_URL, {
        timeout = self.timeout,
        user_agent = self.user_agent,
    })
    local servers = body and Json.decode(body)

    local names, seen = {}, {}
    if type(servers) == "table" then
        for _, server in ipairs(servers) do
            -- Each mirror appears once per address family; we want hostnames.
            local name = type(server) == "table" and server.name
            if name and not seen[name] then
                seen[name] = true
                names[#names + 1] = name
            end
        end
    end

    if #names == 0 then
        names = {}
        for _, name in ipairs(RadioBrowser.FALLBACK_MIRRORS) do names[#names + 1] = name end
    else
        shuffle(names)
    end

    self._mirrors = names
    self._mirrors_fetched_at = os.time()
    return names
end

--- Issues `path` against each mirror in turn until one answers.
-- Returns decoded, err. A mirror that returns malformed JSON is treated as a
-- failed mirror, not a failed request, because that is what it is.
function RadioBrowser:request(path, params)
    local query = build_query(params)
    local errors = {}

    for _, mirror in ipairs(self:mirrors()) do
        local url = "https://" .. mirror .. path .. query
        local body, err = self.transport:get(url, {
            timeout = self.timeout,
            user_agent = self.user_agent,
        })
        if body then
            local decoded, decode_err = Json.decode(body)
            if decoded then return decoded end
            errors[#errors + 1] = mirror .. ": " .. tostring(decode_err)
        else
            errors[#errors + 1] = mirror .. ": " .. tostring(err)
        end
    end

    return nil, "all mirrors failed (" .. table.concat(errors, "; ") .. ")"
end

local ORDER_FIELDS = {
    name = true, votes = true, clickcount = true, clicktrend = true,
    bitrate = true, random = true, lastcheckok = true, country = true,
}

--- Faceted station search. Every field is optional.
--
--   name, country, countrycode, state, language, tag  -- substring match
--   tag_list                                          -- table, ANDed
--   codec                                             -- "MP3", "AAC", ...
--   bitrate_min, bitrate_max
--   order        -- one of ORDER_FIELDS, default "clickcount"
--   reverse      -- default true, i.e. most popular first
--   limit, offset
--   include_broken -- default false; see Station.working
--
-- Returns a list of Station, or nil plus an error.
function RadioBrowser:search(opts)
    opts = opts or {}
    local params = {
        limit = opts.limit or 60,
        offset = opts.offset or 0,
        hidebroken = not opts.include_broken,
    }

    local order = opts.order or "clickcount"
    if not ORDER_FIELDS[order] then
        return nil, "unsupported order: " .. tostring(order)
    end
    params.order = order
    params.reverse = (opts.reverse == nil) and true or opts.reverse

    if opts.name and opts.name ~= "" then params.name = opts.name end
    if opts.country and opts.country ~= "" then params.country = opts.country end
    if opts.countrycode and opts.countrycode ~= "" then params.countrycode = opts.countrycode end
    if opts.state and opts.state ~= "" then params.state = opts.state end
    if opts.language and opts.language ~= "" then params.language = opts.language end
    if opts.tag and opts.tag ~= "" then params.tag = opts.tag end
    if opts.tag_list and #opts.tag_list > 0 then
        params.tagList = table.concat(opts.tag_list, ",")
    end
    if opts.codec and opts.codec ~= "" then params.codec = opts.codec end
    if opts.bitrate_min then params.bitrateMin = opts.bitrate_min end
    if opts.bitrate_max then params.bitrateMax = opts.bitrate_max end

    local records, err = self:request("/json/stations/search", params)
    if not records then return nil, err end
    if type(records) ~= "table" then return nil, "unexpected response shape" end

    local stations = {}
    for _, record in ipairs(records) do
        local station = Station.from_api(record)
        -- from_api drops records with no playable URL; a directory entry that
        -- cannot be played is noise in a list someone has to scroll.
        if station then stations[#stations + 1] = station end
    end
    return stations
end

function RadioBrowser:top_clicked(limit)
    return self:search{ order = "clickcount", reverse = true, limit = limit }
end

function RadioBrowser:top_voted(limit)
    return self:search{ order = "votes", reverse = true, limit = limit }
end

--- The directory's tag vocabulary, most-used first, as { name =, count = }.
function RadioBrowser:tags(limit)
    local records, err = self:request("/json/tags", {
        order = "stationcount", reverse = true, limit = limit or 100, hidebroken = true,
    })
    if not records then return nil, err end
    local tags = {}
    for _, record in ipairs(records) do
        if record.name and record.name ~= "" then
            tags[#tags + 1] = { name = record.name, count = tonumber(record.stationcount) or 0 }
        end
    end
    return tags
end

--- Countries, as { name =, code =, count = }.
function RadioBrowser:countries()
    local records, err = self:request("/json/countries", {
        order = "stationcount", reverse = true, hidebroken = true,
    })
    if not records then return nil, err end
    local countries = {}
    for _, record in ipairs(records) do
        if record.name and record.name ~= "" then
            countries[#countries + 1] = {
                name = record.name,
                code = record.iso_3166_1,
                count = tonumber(record.stationcount) or 0,
            }
        end
    end
    return countries
end

--- Reports that the user played this station, and returns the URL the directory
-- wants us to use. Best-effort by design: the click is courtesy to the
-- directory, never a precondition for playing, so a failure here is swallowed.
function RadioBrowser:click(uuid)
    if not uuid or uuid == "" then return nil end
    local response = self:request("/json/url/" .. urlencode(uuid))
    if type(response) == "table" and response.url and response.url ~= "" then
        return response.url
    end
    return nil
end

--- Upvotes a station. The API rate-limits this per IP per station.
function RadioBrowser:vote(uuid)
    if not uuid or uuid == "" then return false, "no uuid" end
    local response, err = self:request("/json/vote/" .. urlencode(uuid))
    if not response then return false, err end
    if response.ok == true or response.ok == "true" then return true end
    return false, response.message or "vote rejected"
end

return RadioBrowser
