--[[--
shoutkit.koplugin -- internet radio for KOReader.

This file is only wiring: the menu, and the one decision that does not belong
in either the directory client or the playback core, which is what happens
between "the user picked a station" and "the backend gets a URL".

That sequence, in order and for a reason:
  1. report the click to the directory (courtesy, and it may hand back a
     better URL than the one in the search result);
  2. resolve a PLS/M3U wrapper to a direct stream, because not every backend
     can do that itself;
  3. remember the station, so it survives a restart;
  4. hand it to the Player.

Steps 1 and 2 are network calls, so the whole thing runs inside Trapper.
]]

local WidgetContainer = require("ui/widget/container/widgetcontainer")
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr = require("ui/network/manager")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")

-- Submodules, not the `koaudio` aggregate: KOReader's PluginLoader puts only
-- "<plugin>/?.lua" on package.path (pluginloader.lua), never "?/init.lua", so
-- `require("koaudio")` cannot resolve the directory from inside a plugin.
local Detect = require("koaudio.detect")
local Player = require("koaudio.player")
local Browse = require("ui/browse")
local Config = require("config")
local NowPlaying = require("ui/nowplaying")
local Playlist = require("playlist")
local RadioBrowser = require("directory.radiobrowser")

local ShoutKit = WidgetContainer:extend{
    name = "shoutkit",
    is_doc_only = false,
}

function ShoutKit:init()
    self.config = Config.new()
    self.directory = RadioBrowser.new{
        user_agent = "shoutkit.koplugin/0.1.0 (+https://github.com/KevinTCoughlin/shoutkit.koplugin)",
    }
    -- The player is created lazily: constructing it probes for backends, and
    -- there is no reason to do that for a user who never opens the menu.
    self.player = nil
    self.ui.menu:registerToMainMenu(self)
end

function ShoutKit:_get_player()
    if not self.player then
        self.player = Player.new{ volume = self.config:get("volume") }
    end
    return self.player
end

function ShoutKit:_browse()
    return Browse.new{
        directory = self.directory,
        config = self.config,
        on_play = function(station) self:play(station) end,
    }
end

--- Resolves and plays a station, then shows the now-playing screen.
function ShoutKit:play(station)
    local player = self:_get_player()
    if not player:is_usable() then
        UIManager:show(InfoMessage:new{
            text = _("No audio backend on this device.\n\n") .. player:unavailable_reason(),
        })
        return
    end

    NetworkMgr:runWhenOnline(function()
        Trapper:wrap(function()
            Trapper:info(_("Connecting to ") .. station.name .. "…")

            local item = station:to_item()

            -- Best-effort: a directory that is down must not stop playback.
            local preferred = self.directory:click(station.uuid)
            if preferred and preferred ~= "" then item.url = preferred end

            local resolved, err = Playlist.resolve(item.url, self.directory.transport, {
                is_hls = item.is_hls,
            })
            if err then logger.dbg("ShoutKit: playlist resolution:", err) end
            item.url = resolved

            Trapper:clear()

            local ok, play_err = player:play(item)
            if not ok then
                UIManager:show(InfoMessage:new{
                    text = _("Could not play this station.\n\n") .. tostring(play_err),
                })
                return
            end

            self.config:remember(station)
            NowPlaying.new{
                player = player,
                config = self.config,
                station = station,
            }:show()
        end)
    end)
end

--- Reopens the now-playing screen for whatever is already playing.
function ShoutKit:_show_now_playing()
    local player = self:_get_player()
    if player.state == "stopped" or not player.item then
        UIManager:show(InfoMessage:new{ text = _("Nothing is playing."), timeout = 3 })
        return
    end
    NowPlaying.new{
        player = player,
        config = self.config,
        station = self.config:last_station(),
    }:show()
end

function ShoutKit:addToMainMenu(menu_items)
    menu_items.shoutkit = {
        text = _("Radio"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Now playing"),
                enabled_func = function()
                    return self.player ~= nil and self.player.state ~= "stopped"
                end,
                callback = function() self:_show_now_playing() end,
            },
            {
                text = _("Favourites"),
                separator = true,
                callback = function() self:_browse():favourites() end,
            },
            {
                text = _("Popular stations"),
                callback = function() self:_browse():top_stations() end,
            },
            {
                text = _("Browse by genre"),
                callback = function() self:_browse():browse_by_tag() end,
            },
            {
                text = _("Browse by country"),
                callback = function() self:_browse():browse_by_country() end,
            },
            {
                text = _("Search by name"),
                separator = true,
                callback = function() self:_browse():search_by_name() end,
            },
            {
                text = _("Stop playback"),
                enabled_func = function()
                    return self.player ~= nil and self.player.state ~= "stopped"
                end,
                callback = function()
                    if self.player then self.player:stop() end
                end,
            },
            {
                text_func = function()
                    local _p, name = Detect.select()
                    return _("Audio backend: ") .. tostring(name or _("none"))
                end,
                keep_menu_open = true,
                callback = function()
                    local _p, name, rejections = Detect.select()
                    local lines = { _("Platform: ") .. Detect.platform() }
                    lines[#lines + 1] = _("Selected: ") .. tostring(name or _("none"))
                    for backend, reason in pairs(rejections) do
                        lines[#lines + 1] = backend .. ": " .. reason
                    end
                    UIManager:show(InfoMessage:new{ text = table.concat(lines, "\n") })
                end,
            },
        },
    }
end

--- Playback outlives the reader UI, so a closing document must not orphan the
-- backend process. KOReader calls this on teardown.
function ShoutKit:onCloseWidget()
    if self.player then self.player:stop() end
end

return ShoutKit
