local Station = require("directory.station")

local function record(overrides)
    local base = {
        stationuuid = "uuid-1",
        name = "Test FM",
        url = "http://example.org/original",
        url_resolved = "http://example.org/resolved",
        tags = "jazz, smooth jazz ,blues",
        countrycode = "US",
        codec = "MP3",
        bitrate = 128,
        votes = 10,
        clickcount = 5,
        lastcheckok = 1,
        hls = 0,
    }
    for key, value in pairs(overrides or {}) do base[key] = value end
    return base
end

describe("Station.from_api", function()
    it("prefers url_resolved, which is the URL the API tells clients to use", function()
        assert_.equal("http://example.org/resolved", Station.from_api(record()).url)
    end)

    it("falls back to url when the station has never been checked", function()
        local station = Station.from_api(record{ url_resolved = "" })
        assert_.equal("http://example.org/original", station.url)
    end)

    it("drops records with nothing playable", function()
        assert_.nil_(Station.from_api(record{ url = "", url_resolved = "" }))
        assert_.nil_(Station.from_api(nil))
        assert_.nil_(Station.from_api("not a table"))
    end)

    it("splits and trims tags into a list", function()
        assert_.deep_equal({ "jazz", "smooth jazz", "blues" }, Station.from_api(record()).tags)
        assert_.deep_equal({}, Station.from_api(record{ tags = "" }).tags)
    end)

    it("carries the flags that decide playability", function()
        assert_.equal(true, Station.from_api(record()).working)
        assert_.equal(false, Station.from_api(record{ lastcheckok = 0 }).working)
        assert_.equal(true, Station.from_api(record{ hls = 1 }).is_hls)
    end)
end)

describe("Station:describe", function()
    it("summarises country, codec and the leading tags", function()
        local text = Station.from_api(record()):describe()
        assert_.contains(text, "US")
        assert_.contains(text, "MP3 128k")
        assert_.contains(text, "jazz")
    end)

    it("omits what the directory does not know", function()
        local text = Station.from_api(record{ countrycode = "", codec = "", tags = "" }):describe()
        assert_.equal("", text)
    end)
end)

describe("Station round-tripping", function()
    it("survives serialize/deserialize so favourites need no API call", function()
        local original = Station.from_api(record())
        local restored = Station.deserialize(original:serialize())
        assert_.equal(original.url, restored.url)
        assert_.equal(original.name, restored.name)
        assert_.deep_equal(original.tags, restored.tags)
        assert_.contains(restored:describe(), "MP3 128k")
    end)

    it("rejects junk rather than producing a station that cannot play", function()
        assert_.nil_(Station.deserialize({}))
        assert_.nil_(Station.deserialize("nope"))
    end)
end)

describe("Station:to_item", function()
    it("produces a koaudio item tagged as a live stream", function()
        local item = Station.from_api(record()):to_item()
        assert_.equal("stream", item.kind)
        assert_.equal("http://example.org/resolved", item.url)
        assert_.equal("uuid-1", item.station_uuid)
    end)
end)
