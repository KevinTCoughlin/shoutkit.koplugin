--[[--
koaudio — a small, backend-agnostic audio playback core for KOReader plugins.

KOReader core ships no audio at all, so every plugin that makes sound has to
bring its own pipeline and its own per-device plumbing. This module is that
plumbing, factored out so the radio plugin and the podcast plugin share one
implementation rather than forking the hard, device-specific part.

    local koaudio = require("koaudio")
    local player = koaudio.Player.new()
    player:play{ url = station.url, title = station.name, kind = "stream" }
    -- ... then call player:tick() from a UIManager task while the UI is up.

Canonical source: KevinTCoughlin/shoutkit.koplugin (shoutkit.koplugin/koaudio).
Vendored elsewhere via git subtree -- edit it there, not in the copy.
]]

return {
    Player = require("koaudio.player"),
    Detect = require("koaudio.detect"),
    Util = require("koaudio.util"),
    _VERSION = "0.1.0",
}
