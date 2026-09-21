--[[--
The now-playing surface.

Two things make this different from a phone's player UI, and both are e-ink
constraints rather than taste:

  * **Refreshes cost.** A full-screen update is ~300 ms of visible flashing. So
    the widget only repaints when the text actually changed, and the poll timer
    only runs while this widget is on screen -- a stream keeps playing with the
    UI closed, and costs nothing to do so.
  * **There is no scrubber for radio.** Seeking a live stream is meaningless,
    and the Player refuses it, so the controls here are transport-only.
]]

local ButtonDialog = require("ui/widget/buttondialog")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local _ = require("gettext")

local NowPlaying = {}
NowPlaying.__index = NowPlaying

--- How often to ask the backend for a status snapshot while visible.
-- One second matches what the backends write; anything faster only burns CPU.
local POLL_INTERVAL = 1

function NowPlaying.new(opts)
    return setmetatable({
        player = opts.player,
        config = opts.config,
        station = opts.station,
        on_toggle_favourite = opts.on_toggle_favourite,
        dialog = nil,
        last_text = nil,
    }, NowPlaying)
end

function NowPlaying:_status_text()
    local player = self.player
    local lines = { self.station and self.station.name or _("Radio") }

    local state = player.state
    if state == "opening" or state == "buffering" then
        lines[#lines + 1] = _("Connecting…")
    elseif state == "error" then
        lines[#lines + 1] = _("Error: ") .. tostring(player.status.error or "?")
    else
        local title = player.status.title
        if title and title ~= "" then
            lines[#lines + 1] = title
        elseif state == "paused" then
            lines[#lines + 1] = _("Paused")
        end
    end

    local codec = player.status.codec
    if codec and codec ~= "" then
        local bitrate = tonumber(player.status.bitrate) or 0
        lines[#lines + 1] = bitrate > 0
            and string.format("%s · %d kbps", codec, bitrate)
            or codec
    end
    return table.concat(lines, "\n")
end

function NowPlaying:_buttons()
    local player = self.player
    local is_favourite = self.config:is_favourite(self.station)

    return {
        {
            {
                text = (player.state == "paused") and _("Resume") or _("Pause"),
                -- A live stream cannot be resumed from where it paused; the
                -- backend reconnects. Say so rather than silently doing it.
                enabled = player:capabilities().pause and player.state ~= "error",
                callback = function()
                    player:toggle()
                    self:refresh()
                end,
            },
            {
                text = _("Stop"),
                callback = function()
                    player:stop()
                    self:close()
                end,
            },
        },
        {
            {
                text = _("Volume −"),
                callback = function()
                    self.config:set("volume", player:set_volume(player.volume - 10))
                    self:refresh()
                end,
            },
            {
                text = _("Volume +"),
                callback = function()
                    self.config:set("volume", player:set_volume(player.volume + 10))
                    self:refresh()
                end,
            },
        },
        {
            {
                text = is_favourite and _("Remove favourite") or _("Add favourite"),
                enabled = self.station ~= nil,
                callback = function()
                    self.config:toggle_favourite(self.station)
                    if self.on_toggle_favourite then self.on_toggle_favourite() end
                    self:refresh()
                end,
            },
            {
                text = _("Close"),
                -- Closing is not stopping: the stream keeps running and the
                -- poll timer stops, which is the cheap state to sit in.
                callback = function() self:close() end,
            },
        },
    }
end

function NowPlaying:show()
    self.dialog = ButtonDialog:new{
        title = self:_status_text(),
        title_align = "center",
        buttons = self:_buttons(),
    }
    UIManager:show(self.dialog)
    self:_schedule_poll()
    return self
end

--- Repaints only when the text changed, so an unchanging stream does not
-- flash the screen once a second.
function NowPlaying:refresh()
    if not self.dialog then return end
    local text = self:_status_text()
    if text == self.last_text then return end
    self.last_text = text

    UIManager:close(self.dialog)
    self.dialog = ButtonDialog:new{
        title = text,
        title_align = "center",
        buttons = self:_buttons(),
    }
    UIManager:show(self.dialog)
end

function NowPlaying:_schedule_poll()
    self._poll = function()
        if not self.dialog then return end
        local state = self.player:tick()
        self:refresh()
        if state == "error" then
            UIManager:show(InfoMessage:new{
                text = _("Playback stopped: ") .. tostring(self.player.status.error or "?"),
            })
            self:close()
            return
        end
        if state ~= "stopped" then
            UIManager:scheduleIn(POLL_INTERVAL, self._poll)
        end
    end
    UIManager:scheduleIn(POLL_INTERVAL, self._poll)
end

--- Closes the widget and stops polling. Does *not* stop playback.
function NowPlaying:close()
    if self._poll then
        UIManager:unschedule(self._poll)
        self._poll = nil
    end
    if self.dialog then
        UIManager:close(self.dialog)
        self.dialog = nil
    end
end

return NowPlaying
