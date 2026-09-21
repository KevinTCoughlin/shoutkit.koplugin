--[[--
A backend that reports everything and plays nothing.

Used by the test suite to exercise the Player state machine without spawning a
process, and as the thing the UI falls back to on a device with no audio at all
so that browsing the directory still works.
]]

local NullBackend = {}
NullBackend.__index = NullBackend

NullBackend.name = "null"
NullBackend.capabilities = { pause = true, seek = true, volume = true, metadata = false }

function NullBackend.is_available() return true end

function NullBackend.new(opts)
    opts = opts or {}
    return setmetatable({
        -- Tests drive this directly to simulate what a real player would report.
        scripted = opts.scripted or {},
        calls = {},
        running = false,
        volume = opts.volume or 70,
    }, NullBackend)
end

function NullBackend:_record(verb, arg)
    self.calls[#self.calls + 1] = { verb = verb, arg = arg }
    return true
end

function NullBackend:play(item, opts)
    if not item or not item.url or item.url == "" then return false, "no URL" end
    if self.fail_play then return false, self.fail_play end
    self.running = true
    self.item = item
    if opts and opts.volume then self.volume = opts.volume end
    return self:_record("play", item.url)
end

function NullBackend:stop()
    self.running = false
    return self:_record("stop")
end

function NullBackend:pause() return self:_record("pause") end
function NullBackend:resume() return self:_record("resume") end
function NullBackend:seek(n) return self:_record("seek", n) end
function NullBackend:seek_to(n) return self:_record("seek_to", n) end

function NullBackend:set_volume(level)
    self.volume = level
    return self:_record("volume", level)
end

--- Returns the next scripted status, then repeats the last one forever.
function NullBackend:poll()
    if #self.scripted == 0 then return nil end
    if #self.scripted > 1 then
        return table.remove(self.scripted, 1)
    end
    return self.scripted[1]
end

function NullBackend:is_running() return self.running end

return NullBackend
