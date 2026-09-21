--[[--
The normalized station model.

Radio-Browser's JSON carries about thirty fields, half of them legacy or
bookkeeping. This flattens it to what a player and a list row actually need,
and -- more importantly -- makes the decisions that must not be made twice:

  * which URL to play (`url_resolved` when the server has followed the
    redirects for us, `url` otherwise);
  * whether the entry is an HLS manifest, which must *not* be unwrapped as a
    playlist even though it ends in .m3u8;
  * tags as a list rather than a comma-joined string.
]]

local Station = {}
Station.__index = Station

local function split_tags(tags)
    local out = {}
    if not tags or tags == "" then return out end
    for tag in tostring(tags):gmatch("[^,]+") do
        tag = tag:gsub("^%s+", ""):gsub("%s+$", "")
        if tag ~= "" then out[#out + 1] = tag end
    end
    return out
end

--- Builds a Station from one Radio-Browser search result.
-- Returns nil for a record with nothing playable, so callers can filter with
-- a single pass and never carry an unplayable row into the UI.
function Station.from_api(record)
    if type(record) ~= "table" then return nil end
    -- `url_resolved` is the server's already-followed version and is what the
    -- API docs tell clients to prefer; it is empty for stations never checked.
    local url = record.url_resolved
    if not url or url == "" then url = record.url end
    if not url or url == "" then return nil end

    return setmetatable({
        uuid = record.stationuuid,
        name = record.name or "(unnamed station)",
        url = url,
        homepage = record.homepage,
        favicon = record.favicon,
        tags = split_tags(record.tags),
        country = record.country,
        countrycode = record.countrycode,
        language = record.language,
        codec = record.codec,
        bitrate = tonumber(record.bitrate) or 0,
        votes = tonumber(record.votes) or 0,
        clickcount = tonumber(record.clickcount) or 0,
        -- 1 means the directory's own checker last reached it. A 0 here is the
        -- single best predictor of a station that will not play.
        working = record.lastcheckok == 1,
        is_hls = record.hls == 1,
    }, Station)
end

--- The subtitle for a list row: the few facts that help someone choose.
function Station:describe()
    local parts = {}
    if self.countrycode and self.countrycode ~= "" then parts[#parts + 1] = self.countrycode end
    if self.codec and self.codec ~= "" then
        local codec = self.codec
        if self.bitrate > 0 then codec = codec .. " " .. self.bitrate .. "k" end
        parts[#parts + 1] = codec
    end
    if #self.tags > 0 then
        parts[#parts + 1] = table.concat(self.tags, ", ", 1, math.min(#self.tags, 3))
    end
    return table.concat(parts, " \194\183 ")
end

--- The item to hand to a koaudio Player.
function Station:to_item()
    return {
        url = self.url,
        title = self.name,
        kind = "stream",
        station_uuid = self.uuid,
        is_hls = self.is_hls,
    }
end

--- Everything needed to rebuild this station from settings, with no API call.
function Station:serialize()
    return {
        uuid = self.uuid, name = self.name, url = self.url,
        homepage = self.homepage, favicon = self.favicon,
        tags = self.tags, country = self.country, countrycode = self.countrycode,
        language = self.language, codec = self.codec, bitrate = self.bitrate,
        votes = self.votes, clickcount = self.clickcount,
        working = self.working, is_hls = self.is_hls,
    }
end

function Station.deserialize(saved)
    if type(saved) ~= "table" or not saved.url then return nil end
    saved.tags = saved.tags or {}
    saved.bitrate = saved.bitrate or 0
    saved.votes = saved.votes or 0
    saved.clickcount = saved.clickcount or 0
    return setmetatable(saved, Station)
end

return Station
