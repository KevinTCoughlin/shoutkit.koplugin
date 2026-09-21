# Roadmap

Ordered by what unblocks the most. Nothing here has a date.

## v0.1 — the core, off-device ✅

- [x] Radio-Browser client: mirror discovery with failover, faceted search,
      tags, countries, click reporting
- [x] Station model that decides which URL is playable
- [x] PLS/M3U resolution, with HLS correctly left alone
- [x] `koaudio` playback core: state machine, backend seam, control protocol
- [x] mpv backend, with live ICY metadata
- [x] Dependency-free test suite (65 tests) and a CLI dev harness

## v0.2 — running inside KOReader

- [ ] Build the KOReader Linux emulator and actually run the plugin in it.
      **Everything in `ui/` and `main.lua` is unverified until this happens.**
- [ ] Fix whatever that reveals about `Menu`, `ButtonDialog` and `Trapper` usage
- [ ] Favourites round-trip through real `LuaSettings`
- [ ] Decide the e-ink refresh policy for the now-playing screen by looking at
      it, not by reasoning about it

## v0.3 — a device that makes sound

- [ ] Android backend (`MediaPlayer` via JNI) — the cheapest real hardware
- [ ] Wi-Fi lifecycle: keep the stream alive across KOReader's aggressive
      Wi-Fi power-down, and measure the battery cost honestly
- [ ] Sleep timer, because falling asleep with the radio on is the actual use case

## v0.4 — Kindle

- [ ] GStreamer backend, probing for `audioconvert`/`audioresample` rather than
      just the binary
- [ ] Decide whether to reuse KinAMP's daemon instead of writing another one

## v0.5 — Kobo

- [ ] ALSA backend, in the three stages in `docs/BACKENDS.md`
- [ ] Bluetooth pairing delegated to `kobo.koplugin` rather than reimplemented

## Later

- [ ] Station search history and a "recently played" list
- [ ] Vote from the now-playing screen (the API supports it; it is one call)
- [ ] Publish to the `koreader-plugin` GitHub topic so the community AppStore
      and plugin index pick it up — only once a device backend works
- [ ] Reconnect policy for a dropped stream, with backoff

## Explicitly not planned

- **Bundling a station dump.** The live API is the point. Favourites cover the
  offline case.
- **Our own ICY client in Lua.** Every backend's pipeline already parses ICY;
  re-doing it above the seam would mean two HTTP connections per station.
