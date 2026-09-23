# Changelog

## Unreleased

### Added
- Radio-Browser directory client: mirror discovery with per-request failover,
  faceted search (genre, country, language, codec, bitrate), tag and country
  vocabularies, and click reporting back to the directory.
- `koaudio` playback core: a backend-agnostic state machine plus the
  status-file/command-file control protocol in `docs/PROTOCOL.md`.
- mpv backend, including live ICY track metadata, volume and seek.
- PLS/M3U playlist resolution that correctly refuses to unwrap HLS manifests.
- KOReader plugin UI: browse by genre/country/name, popular stations,
  favourites, and a now-playing screen. **Not yet run in the emulator.**
- `bin/shoutkit` development harness and a dependency-free test suite.
- GStreamer backend for Kindle and MTK Kobo, built to what two probe rounds on
  a real Clara Colour established rather than to `playbin uri=`, which no Kobo
  can do: `gst_control.sh` owns the pipeline and speaks the file protocol,
  since `gst-launch-1.0` has no control channel. A local file plays through
  `filesrc`; a stream is fetched by wget or curl and piped into `fdsrc`,
  because the firmware has no HTTP source element. Seeking is byte-offset
  arithmetic over a known duration, and `is_available()` checks the A2DP
  control socket rather than trusting a sink that reports success while playing
  to nothing. `just gst-smoke` drives the whole thing against a real GStreamer.
