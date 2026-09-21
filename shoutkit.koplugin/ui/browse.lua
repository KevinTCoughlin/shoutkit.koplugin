--[[--
Station browsing: the lists, and the network calls behind them.

Every directory call here goes through Trapper, which is KOReader's way of
running something slow without freezing the UI and while letting the user
cancel. That matters more on an e-reader than it sounds: a Radio-Browser mirror
that has gone away takes the full timeout to fail, times the number of mirrors,
and without Trapper that is a frozen device.

NetworkMgr:runWhenOnline wraps the entry points because an e-reader's Wi-Fi is
usually *off*, and the honest place to ask about turning it on is when the user
asks to browse -- not at plugin load.
]]

local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Menu = require("ui/widget/menu")
local NetworkMgr = require("ui/network/manager")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local Screen = require("device").screen
local _ = require("gettext")

local Browse = {}
Browse.__index = Browse

function Browse.new(opts)
    return setmetatable({
        directory = opts.directory,
        config = opts.config,
        on_play = opts.on_play,
    }, Browse)
end

local function show_error(message)
    UIManager:show(InfoMessage:new{ text = tostring(message), timeout = 5 })
end

--- Runs `work` with a cancellable progress message, then hands the result to
--- `present`. Returns nothing; everything happens in the Trapper coroutine.
function Browse:_fetch(message, work, present)
    NetworkMgr:runWhenOnline(function()
        Trapper:wrap(function()
            Trapper:info(message)
            local result, err = work()
            Trapper:clear()
            if not result then
                show_error(err or _("Could not reach the station directory."))
                return
            end
            present(result)
        end)
    end)
end

function Browse:_close_menu()
    if self.menu then
        UIManager:close(self.menu)
        self.menu = nil
    end
end

function Browse:_show_menu(title, items, on_select)
    self:_close_menu()
    self.menu = Menu:new{
        title = title,
        item_table = items,
        is_borderless = true,
        is_popout = false,
        width = Screen:getWidth(),
        height = Screen:getHeight(),
        onMenuSelect = function(_menu, item)
            on_select(item)
            return true
        end,
        close_callback = function() self.menu = nil end,
    }
    UIManager:show(self.menu)
end

--- Turns Stations into menu rows. The subtitle is what makes an unfamiliar
-- station choosable at all, so it is never omitted.
function Browse:_station_items(stations)
    local items = {}
    for _, station in ipairs(stations) do
        items[#items + 1] = {
            text = station.name,
            mandatory = station.bitrate > 0 and (station.bitrate .. "k") or nil,
            help_text = station:describe(),
            station = station,
        }
    end
    return items
end

function Browse:_show_stations(title, stations)
    if #stations == 0 then
        show_error(_("No stations matched."))
        return
    end
    self:_show_menu(title, self:_station_items(stations), function(item)
        self:_close_menu()
        self.on_play(item.station)
    end)
end

function Browse:search_by_name()
    local dialog
    dialog = InputDialog:new{
        title = _("Search stations"),
        input_hint = _("Station name"),
        buttons = {{
            { text = _("Cancel"), id = "close", callback = function() UIManager:close(dialog) end },
            {
                text = _("Search"),
                is_enter_default = true,
                callback = function()
                    local query = dialog:getInputText()
                    UIManager:close(dialog)
                    if not query or query == "" then return end
                    self:_fetch(_("Searching…"), function()
                        return self.directory:search{
                            name = query,
                            limit = self.config:get("result_limit"),
                        }
                    end, function(stations)
                        self:_show_stations(query, stations)
                    end)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Browse:browse_by_tag()
    self:_fetch(_("Loading genres…"), function()
        return self.directory:tags(120)
    end, function(tags)
        local items = {}
        for _, tag in ipairs(tags) do
            items[#items + 1] = { text = tag.name, mandatory = tostring(tag.count), tag = tag.name }
        end
        self:_show_menu(_("Genres"), items, function(item)
            self:_fetch(_("Loading stations…"), function()
                return self.directory:search{
                    tag = item.tag,
                    order = "votes",
                    limit = self.config:get("result_limit"),
                }
            end, function(stations)
                self:_show_stations(item.tag, stations)
            end)
        end)
    end)
end

function Browse:browse_by_country()
    self:_fetch(_("Loading countries…"), function()
        return self.directory:countries()
    end, function(countries)
        local items = {}
        for _, country in ipairs(countries) do
            items[#items + 1] = {
                text = country.name,
                mandatory = tostring(country.count),
                code = country.code,
            }
        end
        self:_show_menu(_("Countries"), items, function(item)
            self:_fetch(_("Loading stations…"), function()
                return self.directory:search{
                    countrycode = item.code,
                    order = "votes",
                    limit = self.config:get("result_limit"),
                }
            end, function(stations)
                self:_show_stations(item.text, stations)
            end)
        end)
    end)
end

function Browse:top_stations()
    self:_fetch(_("Loading popular stations…"), function()
        return self.directory:top_clicked(self.config:get("result_limit"))
    end, function(stations)
        self:_show_stations(_("Popular stations"), stations)
    end)
end

--- Favourites need no network at all -- that is the whole point of storing the
-- full station rather than its UUID.
function Browse:favourites()
    local stations = self.config:favourites()
    if #stations == 0 then
        show_error(_("No favourites yet. Add one from the now-playing screen."))
        return
    end
    self:_show_stations(_("Favourites"), stations)
end

return Browse
