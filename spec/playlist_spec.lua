local Playlist = require("playlist")

--- A transport whose responses are scripted per URL.
local function fake_transport(responses)
    return {
        requested = {},
        get = function(self, url)
            self.requested[#self.requested + 1] = url
            local body = responses[url]
            if not body then return nil, "no such URL" end
            return body
        end,
    }
end

describe("Playlist.classify", function()
    it("recognises playlist extensions", function()
        assert_.equal("pls", Playlist.classify("http://x/s.pls"))
        assert_.equal("m3u", Playlist.classify("http://x/s.m3u"))
        assert_.nil_(Playlist.classify("http://x/stream"))
    end)

    it("ignores the query string when reading the extension", function()
        assert_.equal("m3u", Playlist.classify("http://x/s.m3u?token=1"))
        assert_.equal("pls", Playlist.classify("http://x/s.pls#frag"))
    end)

    it("classifies .m3u8 as HLS, not as M3U", function()
        assert_.equal("hls", Playlist.classify("http://x/s.m3u8"))
    end)

    it("lets content-type override a misleading URL", function()
        assert_.equal("pls", Playlist.classify("http://x/stream", "audio/x-scpls; charset=utf-8"))
    end)
end)

describe("Playlist.needs_resolution", function()
    it("unwraps PLS and M3U", function()
        assert_.truthy(Playlist.needs_resolution("http://x/s.pls"))
        assert_.truthy(Playlist.needs_resolution("http://x/s.m3u"))
    end)

    it("never unwraps HLS -- doing so yields one segment, not a stream", function()
        assert_.falsy(Playlist.needs_resolution("http://x/s.m3u8"))
        assert_.falsy(Playlist.needs_resolution("http://x/s.m3u", nil, true))
    end)

    it("leaves a direct stream alone", function()
        assert_.falsy(Playlist.needs_resolution("http://x/stream"))
    end)
end)

describe("Playlist.parse", function()
    it("reads PLS entries in FileN order, not file order", function()
        local urls = Playlist.parse(table.concat({
            "[playlist]",
            "NumberOfEntries=2",
            "File2=http://example.org/second",
            "Title2=Second",
            "File1=http://example.org/first",
        }, "\r\n"), "pls")
        assert_.len(2, urls)
        assert_.equal("http://example.org/first", urls[1])
        assert_.equal("http://example.org/second", urls[2])
    end)

    it("skips M3U directives and comments", function()
        local urls = Playlist.parse(table.concat({
            "#EXTM3U",
            "#EXTINF:-1,Some Station",
            "http://example.org/stream",
            "",
        }, "\n"), "m3u")
        assert_.len(1, urls)
        assert_.equal("http://example.org/stream", urls[1])
    end)

    it("drops relative entries instead of guessing a base URL", function()
        assert_.len(0, Playlist.parse("stream.mp3\n../other.mp3\n", "m3u"))
    end)

    it("sniffs the format when the kind is unknown", function()
        assert_.len(1, Playlist.parse("[playlist]\nFile1=http://example.org/a\n"))
    end)

    it("returns an empty list for junk rather than raising", function()
        assert_.len(0, Playlist.parse("", "pls"))
        assert_.len(0, Playlist.parse(nil, "pls"))
    end)
end)

describe("Playlist.resolve", function()
    it("returns a direct URL untouched and makes no request", function()
        local transport = fake_transport{}
        assert_.equal("http://x/stream", (Playlist.resolve("http://x/stream", transport)))
        assert_.len(0, transport.requested)
    end)

    it("unwraps a PLS to its first stream", function()
        local transport = fake_transport{
            ["http://x/s.pls"] = "[playlist]\nFile1=http://example.org/live\n",
        }
        assert_.equal("http://example.org/live", (Playlist.resolve("http://x/s.pls", transport)))
    end)

    it("follows one nested playlist hop", function()
        local transport = fake_transport{
            ["http://x/a.pls"] = "[playlist]\nFile1=http://x/b.m3u\n",
            ["http://x/b.m3u"] = "http://example.org/live\n",
        }
        assert_.equal("http://example.org/live", (Playlist.resolve("http://x/a.pls", transport)))
    end)

    it("stops rather than looping on a self-referencing playlist", function()
        local transport = fake_transport{
            ["http://x/loop.pls"] = "[playlist]\nFile1=http://x/loop.pls\n",
        }
        local url = Playlist.resolve("http://x/loop.pls", transport)
        assert_.equal("http://x/loop.pls", url)
        assert_.truthy(#transport.requested <= 3, "should not fetch unboundedly")
    end)

    it("falls back to the original URL when the fetch fails", function()
        local url, err = Playlist.resolve("http://x/missing.pls", fake_transport{})
        assert_.equal("http://x/missing.pls", url)
        assert_.truthy(err)
    end)

    it("never fetches an HLS manifest", function()
        local transport = fake_transport{}
        assert_.equal("http://x/s.m3u8", (Playlist.resolve("http://x/s.m3u8", transport)))
        assert_.len(0, transport.requested)
    end)
end)
