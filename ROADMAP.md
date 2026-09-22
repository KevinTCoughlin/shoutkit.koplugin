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

## v0.4 — GStreamer: MTK Kobo and Kindle

One backend, two platforms. MTK Kobos (Clara Colour, Clara BW, Libra Colour)
ship GStreamer with a proprietary `mtkbtmwrpcaudiosink`, which makes them much
closer to Kindle than to an older Kobo — and much cheaper than the ALSA route
this roadmap used to assume for all Kobos.

- [ ] Run `tools/probe-kobo.sh` on a device and settle which elements exist
- [ ] Local file → `playbin` → `mtkbtmwrpcaudiosink`, with orphaned-pipeline
      cleanup via `/proc/net/unix` (the socket is exclusive)
- [ ] Keepalive silence between items, or A2DP drops and eats the first second
- [ ] Warn once about the MediaTek driver bug that can panic the kernel on
      return to Nickel
- [ ] Network streaming: the same pipeline with a URI
- [ ] Kindle: the same backend with `alsasink`, probing for
      `audioconvert`/`audioresample` rather than just the binary
- [ ] Decide whether to reuse KinAMP's daemon instead of writing another one

## v0.5 — i.MX6 Kobo

The expensive one, and now clearly last: BlueZ devices (Libra 2, Sage, Clara 2E,
Elipsa) have no media framework at all.

- [ ] ALSA backend, in the stages in `docs/BACKENDS.md`
- [ ] BlueALSA cross-build, leaning on audiobook.koplugin's recipes
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
