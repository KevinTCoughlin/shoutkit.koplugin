# shoutkit.koplugin

Internet radio for [KOReader](https://github.com/koreader/koreader): browse the
[Radio-Browser](https://api.radio-browser.info/) directory by genre, country or
name, and play a station while you read.

A companion to [ShoutKit](https://github.com/cascadiacollections/shoutkit) (iOS)
and [radio-slate](https://github.com/KevinTCoughlin/radio-slate) (Linux
desktop) — same idea, same directory, a platform with 300 ms screen refreshes
and no speaker.

> **Status: early, but it runs.** The directory client, the playback core and
> the KOReader UI all work and are tested — the UI against a real KOReader build
> (`just emulator-smoke`, 18 checks including live HTTPS through KOReader's own
> luasec). The gap is **audio backends**: only mpv is implemented, so on an
> actual e-reader the menu loads and browsing works, but playing a station
> reports that there is no usable backend. See [ROADMAP.md](ROADMAP.md).

## What works today

```console
$ bin/shoutkit search --tag "smooth jazz" --country US --limit 3
3 stations
 1. 101 SMOOTH JAZZ
    US · MP3 192k · easy listening, jazz, smooth jazz
    http://jking.cdnstream1.com/b22139_128mp3
 ...

$ bin/shoutkit play --tag "smooth jazz" --country US --pick 3 --seconds 14
backend: mpv
playing:  SmoothJazz.com 64k aac+
[opening]
[buffering]
[playing]   (aac 60k)
[playing] dee Brown - Wes 8Mile   (aac 65k)
stopped
```

That is live directory search → click reporting → playlist resolution →
playback → live ICY track metadata, through the same modules the plugin uses.

## Design

```
main.lua                 menu wiring, and the play sequence
  ui/browse.lua          lists, Trapper-wrapped network calls, NetworkMgr gating
  ui/nowplaying.lua      transport controls; repaints only on change
  config.lua             LuaSettings; favourites stored whole, not by UUID

  directory/
    radiobrowser.lua     live API client: mirror discovery, facets, clicks
    station.lua          normalized model; decides which URL is playable
    transport.lua        HTTP behind a seam: luasocket on device, curl in CI
  playlist.lua           PLS/M3U unwrapping — and refusing to unwrap HLS
  lib/json.lua           rapidjson when present, pure-Lua fallback otherwise

  koaudio/               ← shared core, vendored into podcast.koplugin
    player.lua           the state machine; the only thing UIs talk to
    detect.lua           device → backend selection
    backends/            mpv (works), android · gstreamer · alsa (stubs), null
```

Two seams carry the weight. **`koaudio`** is the audio abstraction: one state
machine, many backends, defined by [docs/PROTOCOL.md](docs/PROTOCOL.md) and
[docs/BACKENDS.md](docs/BACKENDS.md). It is the canonical copy — `podcast.koplugin`
vendors this directory via `git subtree`, so edit it here, never in the copy.
After changing anything under `koaudio/`, run `just publish-koaudio` to
re-split it onto the `koaudio` branch that the other repo pulls from.
**`transport`** is the HTTP seam, which is why the directory client has tests
that never touch the network.

### Two decisions worth knowing about

**Live API, not a bundled dump.** KinAMP ships a frozen 3.4 MB JSON export of
Radio-Browser and greps it on device: no network needed, but no genres, no
countries, no codec filter, no vote counts, and it goes stale. Querying the live
API is what makes faceted browsing possible at all. The cost is needing a
connection at browse time — which is why favourites are stored as complete
stations and play with the network down.

**`.m3u8` is not an M3U.** It is an HLS manifest, and unwrapping it hands the
player a single two-second segment that plays and stops — indistinguishable
from a flaky station. `playlist.lua` checks the extension, the content types and
the directory's own `hls` flag, and there are tests pinning all three.

## Development

Needs `luajit` and `mpv`. No luarocks, no KOReader checkout — `just emulator`
downloads a real KOReader release build for you.

```sh
just test              # 65 unit tests, dependency-free runner
just check             # syntax-check every Lua file
just emulator-smoke    # load into real KOReader, assert 18 widget checks
just emulator          # launch real KOReader to click around (Tools -> Radio)
just cli search --tag jazz
just install-kobo      # copy onto a Kobo mounted as USB mass storage
                       # (reports the model; run tools/probe-kobo.sh on-device
                       #  to see which audio route that model needs)
```

`just emulator-smoke` is the one that matters. Unit tests cannot catch a wrong
KOReader API call, because they never load KOReader's frontend; the emulator
harness instantiates the real widgets and fails on exactly that. It found the
first one: `PluginLoader` puts only `<plugin>/?.lua` on `package.path` and never
`?/init.lua`, so `require("koaudio")` can never resolve from inside a plugin —
plugin code has to require the submodules directly.

## Installing on a device

Copy the inner `shoutkit.koplugin/` directory into KOReader's `plugins/`:

```sh
cp -r shoutkit.koplugin /path/to/koreader/plugins/
```

On Kobo that path is `.adds/koreader/plugins/` on the KOBOeReader partition,
and `just install-kobo` finds it for you. The device exposes no storage until
you tap **Connect** on its screen.

Then **Tools → Radio**. Browsing by genre, country and name works over the
device's Wi-Fi. Playing a station will report **"No audio backend on this
device"** — only the mpv backend exists today, so that is the honest current
state rather than a bug. [docs/BACKENDS.md](docs/BACKENDS.md) has the plan.

## Prior art

This is not the first audio plugin for KOReader, and the ones that came before
solved the hard parts:

- **[KinAMP](https://github.com/kbarni/KinAMP)** (kbarni, GPL-3.0) — a native
  Kindle music and internet radio player that since v3 ships as a KOReader
  plugin. Its ICY client, its `.kinamp_cmd`/`.kinamp_status` file protocol and
  its `.pls`/`.m3u` handling are the direct ancestors of what is here.
- **[audiobook.koplugin](https://github.com/stradichenko/audiobook.koplugin)**
  (stradichenko) — TTS and audiobooks across Kobo, Kindle, Android and
  PocketBook. The reference for *how to get sound out of an e-reader*, including
  cross-build recipes for BlueALSA.
- **[kobo.koplugin](https://github.com/OgKevin/kobo.koplugin)** — Bluetooth
  pairing and management on Kobo, which the ALSA backend will delegate to.

## Licence

AGPL-3.0, matching KOReader itself: a plugin runs inside KOReader's process and
`require`s its frontend modules, which makes it a derivative work.
