#!/usr/bin/env luajit
-- Entry point for the test suite: `luajit spec/run.lua` from the repo root.

local here = arg[0]:match("^(.*)/[^/]+$") or "."
local root = here:match("^(.*)/spec$") or (here .. "/..")

package.path = table.concat({
    root .. "/shoutkit.koplugin/?.lua",
    root .. "/shoutkit.koplugin/?/init.lua",
    here .. "/?.lua",
    package.path,
}, ";")

local Runner = require("runner")

-- Exposed as globals so the spec files read like busted's.
describe = Runner.describe
it = Runner.it
assert_ = Runner.assert

local specs = {
    "json_spec",
    "station_spec",
    "playlist_spec",
    "radiobrowser_spec",
    "player_spec",
    "gstreamer_spec",
}

for _, spec in ipairs(specs) do
    io.write("\n", spec, " ")
    require(spec)
end

os.exit(Runner.report() and 0 or 1)
