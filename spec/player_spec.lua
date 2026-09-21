local Player = require("koaudio.player")
local NullBackend = require("koaudio.backends.null")

local function player_with(scripted, opts)
    local backend = NullBackend.new{ scripted = scripted or {} }
    opts = opts or {}
    opts.backend_instance = backend
    return Player.new(opts), backend
end

describe("Player lifecycle", function()
    it("starts stopped and moves to opening on play", function()
        local player = player_with()
        assert_.equal("stopped", player.state)
        assert_.truthy(player:play{ url = "http://x/s", title = "S" })
        assert_.equal("opening", player.state)
    end)

    it("refuses an item with no URL", function()
        local player = player_with()
        local ok = player:play{ title = "nothing" }
        assert_.falsy(ok)
        assert_.equal("error", player.state)
    end)

    it("reconciles its state from what the backend reports", function()
        local player = player_with{
            { state = "buffering" },
            { state = "playing", title = "Track One" },
        }
        player:play{ url = "http://x/s" }
        assert_.equal("buffering", player:tick())
        assert_.equal("playing", player:tick())
        assert_.equal("Track One", player:now_playing())
    end)

    it("falls back to the item title until the stream names a track", function()
        local player = player_with{ { state = "playing", title = "" } }
        player:play{ url = "http://x/s", title = "Station Name" }
        player:tick()
        assert_.equal("Station Name", player:now_playing())
    end)

    it("surfaces a backend error state", function()
        local player = player_with{ { state = "error", error = "stream dropped" } }
        player:play{ url = "http://x/s" }
        assert_.equal("error", player:tick())
        assert_.equal("stream dropped", player.status.error)
    end)

    it("notices a backend that died before reporting anything", function()
        local player, backend = player_with{}
        player:play{ url = "http://x/s" }
        backend.running = false
        assert_.equal("error", player:tick())
    end)

    it("does not poll once stopped", function()
        local player, backend = player_with{ { state = "playing" } }
        player:play{ url = "http://x/s" }
        player:stop()
        local before = #backend.calls
        player:tick()
        assert_.equal(before, #backend.calls)
        assert_.equal("stopped", player.state)
    end)
end)

describe("Player transport controls", function()
    it("pauses only from playing, and resumes only from paused", function()
        local player = player_with{ { state = "playing" } }
        player:play{ url = "http://x/s" }
        player:tick()
        assert_.truthy(player:pause())
        assert_.equal("paused", player.state)
        assert_.falsy(player:pause())
        assert_.truthy(player:resume())
        assert_.equal("playing", player.state)
    end)

    it("toggle restarts the last item after a stop", function()
        local player = player_with{ { state = "playing" } }
        player:play{ url = "http://x/s" }
        player:tick()
        player:pause()
        player:toggle()
        assert_.equal("playing", player.state)
    end)

    it("clamps volume to 0-100 and forwards it", function()
        local player, backend = player_with()
        assert_.equal(100, player:set_volume(150))
        assert_.equal(0, player:set_volume(-5))
        assert_.equal(0, backend.volume)
    end)

    it("refuses to seek a live stream", function()
        local player = player_with()
        player:play{ url = "http://x/s", kind = "stream" }
        local ok, err = player:seek(30)
        assert_.falsy(ok)
        assert_.contains(err, "live stream")
    end)

    it("allows seeking a file, which is what podcasts need", function()
        local player = player_with()
        player:play{ url = "file:///ep.mp3", kind = "file" }
        assert_.truthy(player:seek(30))
    end)
end)

describe("Player subscribers", function()
    it("notifies on every state change", function()
        local player = player_with{ { state = "playing", title = "T" } }
        local seen = {}
        player:subscribe(function(state) seen[#seen + 1] = state end)
        player:play{ url = "http://x/s" }
        player:tick()
        assert_.equal("opening", seen[1])
        assert_.equal("playing", seen[2])
    end)

    it("survives a listener that raises", function()
        local player = player_with{ { state = "playing" } }
        player:subscribe(function() error("widget bug") end)
        local reached = false
        player:subscribe(function() reached = true end)
        player:play{ url = "http://x/s" }
        assert_.truthy(reached, "a broken listener must not stop the others")
    end)

    it("stops notifying after unsubscribe", function()
        local player = player_with{ { state = "playing" } }
        local count = 0
        local unsubscribe = player:subscribe(function() count = count + 1 end)
        player:play{ url = "http://x/s" }
        unsubscribe()
        player:tick()
        assert_.equal(1, count)
    end)
end)

describe("Player without a backend", function()
    it("explains why rather than pretending to play", function()
        local player = Player.new{ backend = "definitely-not-a-backend" }
        assert_.falsy(player:is_usable())
        assert_.contains(player:unavailable_reason(), "no audio backend available")
        local ok, err = player:play{ url = "http://x/s" }
        assert_.falsy(ok)
        assert_.truthy(err)
    end)
end)
