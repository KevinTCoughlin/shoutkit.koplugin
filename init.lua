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

**This aggregate is not usable from inside a KOReader plugin.** PluginLoader
adds only "<plugin>/?.lua" to package.path (frontend/pluginloader.lua), never
"?/init.lua", so `require("koaudio")` cannot resolve this directory on device.
Plugin code must require the submodules directly:

    local Player = require("koaudio.player")   -- resolves to koaudio/player.lua

This file exists for the CLI harnesses and the test suite, which do put
"?/init.lua" on the path.

Canonical source: KevinTCoughlin/shoutkit.koplugin (shoutkit.koplugin/koaudio).
Vendored elsewhere via git subtree -- edit it there, not in the copy.
]]

return {
    Player = require("koaudio.player"),
    Detect = require("koaudio.detect"),
    Util = require("koaudio.util"),
    _VERSION = "0.1.0",
}
