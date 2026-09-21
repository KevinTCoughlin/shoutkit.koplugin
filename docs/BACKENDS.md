# Audio backends

KOReader core ships **no audio at all** — there is no sound API in the frontend
to build on. Every plugin that makes noise brings its own pipeline and its own
per-device plumbing. `koaudio/` is that plumbing, and this is the state of it.

## The interface

A backend is a module with a constructor and these methods. `koaudio/backends/null.lua`
is the minimal complete example; `mpv.lua` is the reference one.

```lua
Backend.name               -- string
Backend.capabilities       -- { pause =, seek =, volume =, metadata = } booleans
Backend.is_available()     -- -> true | false, reason        (no instance needed)
Backend.new(opts)          -- -> instance

instance:play(item, opts)  -- item = { url =, title =, kind = "stream"|"file" }
instance:stop()
instance:pause() / :resume()
instance:seek(seconds) / :seek_to(seconds)
instance:set_volume(0..100)
instance:poll()            -- -> status table | nil. MUST NOT BLOCK.
instance:is_running()      -- -> boolean
```

Two hard rules:

1. **`poll()` never blocks.** It is called from a UIManager task; a blocking
   read there freezes the whole reader.
2. **`is_available()` must be honest.** It runs at plugin load on every device.
   Returning true and then failing to make sound is worse than returning false
   with a reason the UI can show — see the GStreamer note below.

## Status

| Backend | Platform | State | Route |
|---|---|---|---|
| `mpv` | desktop, KOReader emulator | **working** | mpv process + embedded Lua control script |
| `android` | Android e-ink (Boox, …) | stub | `android.media.MediaPlayer` via JNI |
| `gstreamer` | Kindle | stub | firmware `gst-launch-1.0 playbin` |
| `alsa` | Kobo, PocketBook | stub | ALSA, + BlueALSA for A2DP, + a decoder |
| `null` | anywhere | working | reports everything, plays nothing (tests) |

Probe order is `android → gstreamer → alsa → mpv`, set in `koaudio/detect.lua`.
`KOAUDIO_BACKEND=<name>` forces one and skips probing; `KOAUDIO_PLATFORM=<name>`
overrides platform detection. Both are how you test a backend you do not have
hardware for.

## Why the remaining three are in this order of difficulty

**Android — easiest.** `MediaPlayer` does HTTP(S), the codecs, the buffering and
seeking. Nothing to cross-compile, no status file needed (it is in-process).
It does *not* expose ICY metadata, so live track titles need a separate probe
or go without. Prior art: `androidplayer.lua` in stradichenko/audiobook.koplugin.

**Kindle — easy, with one trap.** The firmware ships GStreamer because Amazon
uses it for Audible and TTS, so `playbin` handles stream, decode and output in
one line. The trap: some firmware builds are *stripped* of `audioconvert` and
`audioresample`, and the pipeline then starts and produces silence —
audiobook.koplugin issue #81. `is_available()` has to check for the elements,
not the binary. `gst-launch-1.0` also has no control channel, which is fine for
radio (no seeking) and not fine for podcasts.

**Kobo — hardest, and the reason the protocol exists.** No GStreamer, no media
framework: ALSA and nothing else. ALSA takes PCM only, so streaming an MP3 URL
needs a decoder in front of it — there is no one-liner. And no current Kobo has
a speaker or a headphone jack, so output means Bluetooth A2DP via BlueALSA,
which must be cross-compiled for the device. audiobook.koplugin ships working
build recipes (`cross-build-bluealsa.nix`); lean on those rather than repeat
them. KinAMP solves the decode half with a native daemon (miniaudio) — which is
exactly the shape `docs/PROTOCOL.md` is designed to accept.

A sane order that avoids building everything at once:

1. local files → `aplay`, no Bluetooth (works on PocketBook, which has a real speaker);
2. Bluetooth A2DP via BlueALSA, pairing delegated to `kobo.koplugin`;
3. network streaming, which needs the decoder daemon.

## Hardware reality

This constrains the audience more than the software does. No current Kobo has a
speaker or a 3.5 mm jack; audio means Bluetooth, and only on Clara 2E, Sage,
Libra 2, Elipsa/2E, Libra Colour, Clara Colour and Clara BW. Kindle needs a
Bluetooth-audio model and a jailbreak. Android e-ink is the one platform where
this is unambiguous.

Streaming also runs the Wi-Fi radio, the Bluetooth radio and a decoder
continuously on a device budgeted for approximately none of that. KinAMP
measures 4–5 %/hour with the frontlight on. Design against that number.
