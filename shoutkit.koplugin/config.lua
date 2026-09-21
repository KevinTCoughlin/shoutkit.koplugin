--[[--
Persisted settings and favourites.

Backed by KOReader's LuaSettings when running on device, and by an in-memory
table otherwise so the directory and playback code stay testable off-device.
Favourites are stored as serialized Stations rather than UUIDs: a favourite has
to be playable with the network down and the directory unreachable, which a
UUID alone is not.
]]

local Station = require("directory.station")

local Config = {}
Config.__index = Config

local DEFAULTS = {
    volume = 60,
    last_station = nil,
    -- Wi-Fi on an e-ink device is the dominant battery cost of streaming, so
    -- this is opt-in per session rather than something the plugin assumes.
    auto_connect = false,
    result_limit = 60,
}

local function open_store()
    local ok, LuaSettings = pcall(require, "luasettings")
    if not ok then return nil end
    local ok_storage, DataStorage = pcall(require, "datastorage")
    if not ok_storage then return nil end
    return LuaSettings:open(DataStorage:getSettingsDir() .. "/shoutkit.lua")
end

function Config.new()
    local self = setmetatable({ store = open_store(), memory = {} }, Config)
    return self
end

function Config:get(key)
    if self.store then
        local value = self.store:readSetting(key)
        if value ~= nil then return value end
    elseif self.memory[key] ~= nil then
        return self.memory[key]
    end
    return DEFAULTS[key]
end

function Config:set(key, value)
    if self.store then
        self.store:saveSetting(key, value)
        self.store:flush()
    else
        self.memory[key] = value
    end
end

--- Favourites, newest first, as Station objects.
function Config:favourites()
    local saved = self:get("favourites") or {}
    local stations = {}
    for _, record in ipairs(saved) do
        local station = Station.deserialize(record)
        if station then stations[#stations + 1] = station end
    end
    return stations
end

function Config:is_favourite(station)
    if not station or not station.uuid then return false end
    for _, saved in ipairs(self:get("favourites") or {}) do
        if saved.uuid == station.uuid then return true end
    end
    return false
end

--- Adds or removes; returns true when the station is a favourite afterwards.
function Config:toggle_favourite(station)
    if not station then return false end
    local saved = self:get("favourites") or {}
    for index, entry in ipairs(saved) do
        if entry.uuid == station.uuid or entry.url == station.url then
            table.remove(saved, index)
            self:set("favourites", saved)
            return false
        end
    end
    table.insert(saved, 1, station:serialize())
    self:set("favourites", saved)
    return true
end

--- The last thing played, so the plugin can offer to resume it.
function Config:remember(station)
    if station and station.serialize then
        self:set("last_station", station:serialize())
    end
end

function Config:last_station()
    return Station.deserialize(self:get("last_station") or {})
end

return Config
