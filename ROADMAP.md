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

- [x] Run `tools/probe-kobo.sh` on a device and settle which elements exist
- [x] Round two: settle which pipelines actually run. Local file and `fdsrc`
      both decode; there is **no HTTP source element at all**, so `playbin
      uri=http://…` is off the table and the fetch happens above GStreamer.
      MP3 is the only codec. Results in `docs/probe-clara-colour-2.txt`.
- [ ] **Round three, over SSH: the A2DP control socket.** With a speaker paired
      from Nickel, does `/tmp/audio.a2dp_ctrl` exist while KOReader runs? If
      not, which process provides it and can it be started alone? Everything
      below is blocked on this: under KOReader there is currently no Bluetooth
      daemon, and `mtkbtmwrpcaudiosink` reports success while playing to
      nothing.
- [x] Local file → decode chain → sink, with stale-pipeline cleanup. Written as
      `gst_control.sh` (the pipeline owner, since `gst-launch-1.0` has no
      control channel) plus `koaudio/backends/gstreamer.lua`, and driven end to
      end by `just gst-smoke` against a real GStreamer: play, pause, resume,
      seek, stop, and no orphaned pipeline afterwards. **Unverified on the
      device**, which needs the A2DP question answered first.
- [x] `is_available()` that checks the control socket rather than the sink,
      since the sink never reports failure
- [ ] Keepalive silence between items, or A2DP drops and eats the first second
- [ ] Warn once about the MediaTek driver bug that can panic the kernel on
      return to Nickel
- [x] Network streaming: fetch above GStreamer, bytes into `fdsrc`, `queue2`
      for buffering — a different design from the file case. Smoke-tested
      against a local HTTP server; not yet against a real station on a device.
- [ ] Decide what the UI does with a backend that cannot change volume live and
      reports no track metadata — both are consequences of `gst-launch` having
      no control channel, and the now-playing screen currently assumes neither
- [ ] Filter the station list to MP3: there is no AAC decoder on the device
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
