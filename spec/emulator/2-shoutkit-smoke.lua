-- Smoke-tests shoutkit.koplugin's widgets inside real KOReader.
-- Priority 2 = runs after UIManager is ready. Not shipped; a dev harness.
local UIManager = require("ui/uimanager")
local logger = require("logger")

local PLUGIN_DIR = "plugins/shoutkit.koplugin"
package.path = PLUGIN_DIR .. "/?.lua;" .. package.path

local pass, fail, skipped = 0, 0, 0

-- Set SHOUTKIT_SMOKE_OFFLINE=1 to skip the steps that hit the public API. The
-- widget steps are deterministic and must never be allowed to fail quietly, so
-- CI runs this offline and hard-fails, and checks the live API separately.
local OFFLINE = os.getenv("SHOUTKIT_SMOKE_OFFLINE") == "1"

local function step(name, body, needs_network)
    if needs_network and OFFLINE then
        skipped = skipped + 1
        logger.warn("SMOKE SKIP: " .. name .. " (offline)")
        return
    end
    local ok, err = pcall(body)
    if ok then
        pass = pass + 1
        logger.warn("SMOKE PASS: " .. name)
    else
        fail = fail + 1
        logger.warn("SMOKE FAIL: " .. name .. " -- " .. tostring(err))
    end
end

UIManager:scheduleIn(1, function()
    local Config, Player, NullBackend, Browse, NowPlaying, Station

    step("require plugin modules", function()
        Config = require("config")
        Player = require("koaudio.player")
        NullBackend = require("koaudio.backends.null")
        Browse = require("ui/browse")
        NowPlaying = require("ui/nowplaying")
        Station = require("directory.station")
    end)

    step("require main.lua the way PluginLoader does", function()
        assert(require("main"), "main.lua returned nothing")
    end)

    local config, player, station
    step("Config uses real LuaSettings", function()
        config = Config.new()
        assert(config.store, "expected a LuaSettings store on device")
        config:set("volume", 42)
        assert(config:get("volume") == 42)
    end)

    step("Station from an API record", function()
        station = Station.from_api{
            stationuuid = "uuid-1", name = "Smoke FM",
            url = "http://x/s", url_resolved = "http://x/s",
            tags = "jazz", countrycode = "US", codec = "MP3",
            bitrate = 128, lastcheckok = 1, hls = 0,
        }
        assert(station and station.name == "Smoke FM")
    end)

    step("favourites round-trip through LuaSettings", function()
        assert(config:toggle_favourite(station) == true)
        assert(config:is_favourite(station) == true)
        assert(#config:favourites() == 1)
        assert(config:toggle_favourite(station) == false)
        assert(#config:favourites() == 0)
    end)

    step("Player with a null backend", function()
        player = Player.new{
            backend_instance = NullBackend.new{ scripted = {
                { state = "playing", title = "Smoke Track", codec = "mp3", bitrate = "128" },
            } },
        }
        assert(player:play(station:to_item()))
        assert(player:tick() == "playing")
    end)

    local now_playing
    step("NowPlaying:show builds a ButtonDialog", function()
        now_playing = NowPlaying.new{ player = player, config = config, station = station }
        now_playing:show()
        assert(now_playing.dialog, "no dialog was created")
    end)

    step("NowPlaying:refresh repaints without erroring", function()
        player.status.title = "Changed Track"
        now_playing:refresh()
        assert(now_playing.last_text:find("Changed Track"), "status text did not update")
    end)

    step("NowPlaying buttons are all callable", function()
        for _, row in ipairs(now_playing:_buttons()) do
            for _, button in ipairs(row) do
                assert(type(button.text) == "string" and #button.text > 0)
                assert(type(button.callback) == "function")
            end
        end
    end)

    step("NowPlaying:close unschedules and closes", function()
        now_playing:close()
        assert(now_playing.dialog == nil)
        assert(now_playing._poll == nil)
    end)

    step("Browse:_show_stations builds a Menu", function()
        local browse = Browse.new{
            directory = { transport = {} },
            config = config,
            on_play = function() end,
        }
        browse:_show_stations("Smoke", { station, station })
        assert(browse.menu, "no menu was created")
        assert(#browse.menu.item_table == 2)
        assert(browse.menu.item_table[1].text == "Smoke FM")
        browse:_close_menu()
        assert(browse.menu == nil)
    end)

    step("Browse:favourites with none shows a message, not a crash", function()
        local browse = Browse.new{ directory = {}, config = config, on_play = function() end }
        browse:favourites()
    end)

    step("plugin instantiates and registers a menu", function()
        local ShoutKit = require("main")
        local registered
        local plugin = ShoutKit:new{
            ui = { menu = { registerToMainMenu = function(_, p) registered = p end } },
        }
        assert(registered == plugin, "plugin did not register itself")

        local menu_items = {}
        plugin:addToMainMenu(menu_items)
        local entry = menu_items.shoutkit
        assert(entry, "no shoutkit menu entry")
        assert(entry.sorting_hint == "tools")
        assert(#entry.sub_item_table >= 7, "expected the full submenu")
        for _, sub in ipairs(entry.sub_item_table) do
            assert(sub.text or sub.text_func, "submenu entry with no label")
            if sub.text_func then assert(type(sub.text_func()) == "string") end
            if sub.enabled_func then sub.enabled_func() end
        end
    end)

    -- The paths that only exist on device: KOReader's own luasocket/luasec
    -- stack, and TLS through it. curl covers neither, so nothing above here
    -- has exercised what actually ships.
    step("Transport auto-selects KOReader's own HTTP stack", function()
        local Transport = require("directory.transport")
        local transport = Transport.new()
        assert(transport.kind == "koreader",
            "expected the koreader transport on device, got " .. tostring(transport.kind))
    end)

    step("HTTPS through luasec reaches the directory", function()
        local Transport = require("directory.transport")
        local body, err = Transport.new("koreader"):get(
            "https://all.api.radio-browser.info/json/servers", { timeout = 25 })
        assert(body, "luasec request failed: " .. tostring(err))
        assert(body:find("radio%-browser%.info"), "unexpected body: " .. body:sub(1, 120))
        logger.warn("SMOKE luasec got " .. #body .. " bytes")
    end, true)

    step("live faceted search over KOReader's HTTP stack", function()
        local RadioBrowser = require("directory.radiobrowser")
        local directory = RadioBrowser.new{ user_agent = "shoutkit.koplugin-smoke/0.1" }
        assert(directory.transport.kind == "koreader")
        local stations, err = directory:search{ tag = "jazz", limit = 3, order = "votes" }
        assert(stations, "search failed: " .. tostring(err))
        assert(#stations > 0, "search returned nothing")
        for _, found in ipairs(stations) do
            assert(found.url and found.url ~= "", "station with no URL survived")
            logger.warn("SMOKE   station: " .. found.name .. " -- " .. found:describe())
        end
    end, true)

    step("playlist resolution over KOReader's HTTP stack", function()
        local Playlist = require("playlist")
        local Transport = require("directory.transport")
        -- Direct URLs must not be fetched at all; that is the cheap half.
        local url = Playlist.resolve("http://example.org/stream", Transport.new("koreader"))
        assert(url == "http://example.org/stream")
    end, true)

    step("backend detection reports a reason on this device", function()
        local Detect = require("koaudio.detect")
        local _backend, name, rejections = Detect.select()
        logger.warn("SMOKE platform=" .. Detect.platform() .. " backend=" .. tostring(name))
        for backend, reason in pairs(rejections) do
            logger.warn("SMOKE   reject " .. backend .. ": " .. reason)
        end
    end)

    logger.warn(string.format("SMOKE RESULT: %d passed, %d failed, %d skipped",
        pass, fail, skipped))
    UIManager:scheduleIn(0.5, function() UIManager:quit() end)
end)
