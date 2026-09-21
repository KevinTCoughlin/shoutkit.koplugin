local RadioBrowser = require("directory.radiobrowser")

--- Records every URL requested and replays scripted bodies. Matching is by
--- substring so tests can assert on a path without spelling out the mirror.
local function fake_transport(routes)
    return {
        requested = {},
        get = function(self, url)
            self.requested[#self.requested + 1] = url
            for pattern, body in pairs(routes) do
                if url:find(pattern, 1, true) then
                    if body == false then return nil, "simulated failure" end
                    return body
                end
            end
            return nil, "unrouted: " .. url
        end,
    }
end

local STATION_JSON = [[
[{"stationuuid":"a","name":"Alpha","url":"http://a/","url_resolved":"http://a/r",
  "tags":"jazz","countrycode":"US","codec":"MP3","bitrate":128,"lastcheckok":1,"hls":0},
 {"stationuuid":"b","name":"Broken","url":"","url_resolved":"",
  "tags":"","countrycode":"US","codec":"MP3","bitrate":64,"lastcheckok":0,"hls":0}]
]]

local function client(routes, opts)
    opts = opts or {}
    opts.transport = fake_transport(routes)
    opts.mirrors = opts.mirrors or { "mirror.test" }
    return RadioBrowser.new(opts), opts.transport
end

describe("RadioBrowser:mirrors", function()
    it("deduplicates the v4/v6 rows the discovery endpoint returns", function()
        local directory = RadioBrowser.new{
            transport = fake_transport{
                ["all.api.radio-browser.info"] =
                    '[{"ip":"1.2.3.4","name":"de1.api.radio-browser.info"},' ..
                    '{"ip":"::1","name":"de1.api.radio-browser.info"}]',
            },
        }
        assert_.len(1, directory:mirrors())
    end)

    it("falls back to known hosts when discovery fails", function()
        local directory = RadioBrowser.new{
            transport = fake_transport{ ["all.api"] = false },
        }
        local mirrors = directory:mirrors()
        assert_.truthy(#mirrors > 0)
        assert_.equal("all.api.radio-browser.info", mirrors[1])
    end)

    it("caches, so a browse session does not re-discover on every query", function()
        local directory, transport = client{
            ["/json/stations/search"] = STATION_JSON,
        }
        directory:search{}
        directory:search{}
        for _, url in ipairs(transport.requested) do
            assert_.falsy(url:find("all.api", 1, true), "should not rediscover mirrors")
        end
    end)
end)

describe("RadioBrowser:request", function()
    it("tries the next mirror when one fails", function()
        local directory, transport = client({
            ["down.test"] = false,
            ["up.test"] = STATION_JSON,
        }, { mirrors = { "down.test", "up.test" } })
        assert_.truthy(directory:search{})
        assert_.len(2, transport.requested)
    end)

    it("treats malformed JSON as a bad mirror, not a bad request", function()
        local directory, transport = client({
            ["first.test"] = "<html>502</html>",
            ["second.test"] = STATION_JSON,
        }, { mirrors = { "first.test", "second.test" } })
        assert_.len(1, directory:search{})
        assert_.len(2, transport.requested)
    end)

    it("reports every mirror's reason when all of them fail", function()
        local directory = client({ ["mirror.test"] = false })
        local stations, err = directory:search{}
        assert_.nil_(stations)
        assert_.contains(err, "all mirrors failed")
        assert_.contains(err, "mirror.test")
    end)

    it("builds a deterministic, sorted, percent-encoded query", function()
        local directory, transport = client{ ["/json/stations/search"] = STATION_JSON }
        directory:search{ name = "smooth jazz", countrycode = "US", limit = 5 }
        local url = transport.requested[1]
        assert_.contains(url, "countrycode=US")
        assert_.contains(url, "name=smooth%20jazz")
        assert_.contains(url, "hidebroken=true")
        -- Sorted: countrycode before hidebroken before limit before name.
        assert_.truthy(url:find("countrycode") < url:find("hidebroken"))
        assert_.truthy(url:find("limit") < url:find("name="))
    end)
end)

describe("RadioBrowser:search", function()
    it("drops directory rows with no playable URL", function()
        local directory = client{ ["/json/stations/search"] = STATION_JSON }
        local stations = directory:search{}
        assert_.len(1, stations)
        assert_.equal("Alpha", stations[1].name)
        assert_.equal("http://a/r", stations[1].url)
    end)

    it("defaults to most-clicked first", function()
        local directory, transport = client{ ["/json/stations/search"] = STATION_JSON }
        directory:search{}
        assert_.contains(transport.requested[1], "order=clickcount")
        assert_.contains(transport.requested[1], "reverse=true")
    end)

    it("rejects an unsupported sort instead of letting the API 400", function()
        local directory, transport = client{ ["/json/stations/search"] = STATION_JSON }
        local stations, err = directory:search{ order = "bogus" }
        assert_.nil_(stations)
        assert_.contains(err, "unsupported order")
        assert_.len(0, transport.requested)
    end)

    it("passes the facets through under the API's own parameter names", function()
        local directory, transport = client{ ["/json/stations/search"] = STATION_JSON }
        directory:search{ tag_list = { "jazz", "blues" }, bitrate_min = 128, codec = "MP3" }
        local url = transport.requested[1]
        assert_.contains(url, "tagList=jazz%2Cblues")
        assert_.contains(url, "bitrateMin=128")
        assert_.contains(url, "codec=MP3")
    end)

    it("can include broken stations when asked", function()
        local directory, transport = client{ ["/json/stations/search"] = STATION_JSON }
        directory:search{ include_broken = true }
        assert_.contains(transport.requested[1], "hidebroken=false")
    end)
end)

describe("RadioBrowser:click", function()
    it("reports the play and returns the URL the directory prefers", function()
        local directory, transport = client{
            ["/json/url/"] = '{"ok":true,"url":"http://preferred/"}',
        }
        assert_.equal("http://preferred/", directory:click("uuid-1"))
        assert_.contains(transport.requested[1], "/json/url/uuid-1")
    end)

    it("stays silent on failure -- a click must never block playback", function()
        local directory = client{ ["mirror.test"] = false }
        assert_.nil_(directory:click("uuid-1"))
        assert_.nil_(directory:click(nil))
    end)
end)

describe("RadioBrowser:tags and :countries", function()
    it("normalises the tag vocabulary", function()
        local directory = client{
            ["/json/tags"] = '[{"name":"jazz","stationcount":"120"},{"name":"","stationcount":"1"}]',
        }
        local tags = directory:tags()
        assert_.len(1, tags)
        assert_.equal("jazz", tags[1].name)
        assert_.equal(120, tags[1].count)
    end)

    it("normalises countries with their ISO code", function()
        local directory = client{
            ["/json/countries"] = '[{"name":"Germany","iso_3166_1":"DE","stationcount":"900"}]',
        }
        local countries = directory:countries()
        assert_.equal("DE", countries[1].code)
        assert_.equal(900, countries[1].count)
    end)
end)
