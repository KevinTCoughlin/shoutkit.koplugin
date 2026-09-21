--[[--
The playback controller: one state machine, any backend.

Everything above this line (the radio UI, the podcast UI) talks only to a
Player. Everything below it (mpv, GStreamer, ALSA, MediaPlayer) implements the
backend interface. That split is the whole reason this directory is vendored
into podcast.koplugin rather than reimplemented there.

The Player does not own a timer. KOReader has no threads, so the host decides
how often to call `tick()` — from a UIManager task while the player UI is
visible, and rarely or never when it is not. That keeps a radio stream from
forcing a screen refresh on an e-ink display every second.
]]

local Detect = require("koaudio.detect")

local Player = {}
Player.__index = Player

--- Valid states. `buffering` exists because on a slow link the gap between
-- "we started" and "sound is coming out" is seconds long and the UI must say so.
Player.STATES = {
    stopped = true,
    opening = true,
    buffering = true,
    playing = true,
    paused = true,
    error = true,
}

function Player.new(opts)
    opts = opts or {}

    local backend_module, backend_name, rejections
    if opts.backend_instance then
        backend_module, backend_name = nil, opts.backend_instance.name or "injected"
    else
        backend_module, backend_name, rejections = Detect.select(opts)
    end

    local self = setmetatable({
        backend = opts.backend_instance,
        backend_module = backend_module,
        backend_name = backend_name,
        rejections = rejections or {},
        state = "stopped",
        item = nil,
        status = {},
        volume = opts.volume or 70,
        listeners = {},
    }, Player)

    if not self.backend and backend_module then
        self.backend = backend_module.new(opts)
    end
    return self
end

function Player:is_usable()
    return self.backend ~= nil
end

--- Why there is no backend, as a single human-readable line for the UI.
function Player:unavailable_reason()
    if self.backend then return nil end
    local parts = {}
    for name, reason in pairs(self.rejections) do
        parts[#parts + 1] = name .. ": " .. reason
    end
    table.sort(parts)
    if #parts == 0 then return "no audio backend available" end
    return "no audio backend available (" .. table.concat(parts, "; ") .. ")"
end

function Player:capabilities()
    if not self.backend then return {} end
    return self.backend.capabilities or (getmetatable(self.backend) or {}).capabilities or {}
end

--- Registers a callback invoked on every state or metadata change.
-- Returns an unsubscribe function.
function Player:subscribe(listener)
    self.listeners[#self.listeners + 1] = listener
    local index = #self.listeners
    return function() self.listeners[index] = nil end
end

function Player:_emit()
    for _, listener in pairs(self.listeners) do
        -- A listener that raises must not take the player -- or KOReader -- with
        -- it; a broken widget is a UI bug, not a reason to lose the stream.
        pcall(listener, self.state, self.status, self.item)
    end
end

function Player:_set_state(state, status)
    local changed = (state ~= self.state)
    self.state = state
    if status then self.status = status end
    if changed or status then self:_emit() end
end

--- `item` is { url =, title =, kind = "stream" | "file", ... }.
-- Anything else on the table is carried through untouched so callers can hang
-- their own metadata (station uuid, episode id) off it.
function Player:play(item)
    if not self.backend then
        self:_set_state("error", { error = self:unavailable_reason() })
        return false, self:unavailable_reason()
    end
    item = item or {}
    item.kind = item.kind or "stream"

    self.item = item
    self.status = {}
    self:_set_state("opening")

    local ok, err = self.backend:play(item, { volume = self.volume })
    if not ok then
        self:_set_state("error", { error = err or "playback failed" })
        return false, err
    end
    return true
end

function Player:stop()
    if self.backend then self.backend:stop() end
    self.item = nil
    self:_set_state("stopped", {})
    return true
end

function Player:pause()
    if not self.backend or self.state ~= "playing" then return false end
    local ok = self.backend:pause()
    if ok then self:_set_state("paused") end
    return ok
end

function Player:resume()
    if not self.backend or self.state ~= "paused" then return false end
    local ok = self.backend:resume()
    if ok then self:_set_state("playing") end
    return ok
end

function Player:toggle()
    if self.state == "paused" then return self:resume() end
    if self.state == "playing" then return self:pause() end
    if self.item then return self:play(self.item) end
    return false
end

function Player:set_volume(level)
    level = tonumber(level) or self.volume
    if level < 0 then level = 0 elseif level > 100 then level = 100 end
    self.volume = level
    if self.backend and self.backend.set_volume then
        self.backend:set_volume(level)
    end
    return level
end

--- Seeking a live stream is not a thing; refuse it here rather than in every UI.
function Player:seek(seconds)
    if not self.backend or not self.backend.seek then return false, "backend cannot seek" end
    if self.item and self.item.kind == "stream" then return false, "cannot seek a live stream" end
    return self.backend:seek(seconds)
end

--- Pulls one status snapshot from the backend and reconciles our state with it.
-- Safe to call when stopped, and safe to call far more often than the backend
-- updates.
function Player:tick()
    if not self.backend or self.state == "stopped" then return self.state end

    local status = self.backend:poll()
    if not status then
        -- No status yet: we are still between spawn and first write. Only treat
        -- that as an error once the backend admits the process is gone.
        if self.backend.is_running and not self.backend:is_running() and self.state ~= "error" then
            self:_set_state("error", { error = "player exited before it started" })
        end
        return self.state
    end

    local reported = status.state
    if reported == "error" then
        self:_set_state("error", status)
    elseif Player.STATES[reported] then
        self:_set_state(reported, status)
    end
    return self.state
end

--- Convenience accessor for the UI: the line to show as "now playing".
function Player:now_playing()
    local title = self.status.title
    if title and title ~= "" then return title end
    if self.item and self.item.title then return self.item.title end
    return nil
end

return Player
