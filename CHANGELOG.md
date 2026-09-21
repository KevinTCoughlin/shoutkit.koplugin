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
