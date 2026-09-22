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
| `alsa` | Kobo (i.MX6), PocketBook | stub | ALSA, + BlueALSA for A2DP, + a decoder |
| `gstreamer` | Kobo (MTK) | stub | firmware GStreamer + `mtkbtmwrpcaudiosink` |
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

**Kobo — two different devices wearing the same name.** Which one you have
decides everything, and the split is by SoC generation, not model year.

*MTK Kobos* (Clara Colour, Clara BW, Libra Colour — Mark 12 and later) ship
**GStreamer**, including a proprietary sink element, `mtkbtmwrpcaudiosink`, that
talks to MediaTek's own Bluetooth stack. That puts them far closer to Kindle
than to an older Kobo: a pipeline, not a hand-built decoder.

    gst-launch-1.0 playbin uri=<url> audio-sink=mtkbtmwrpcaudiosink

Three constraints on that route are not optional:

  * **The `@kobo:mtkbtmwrpc` abstract socket is exclusive.** Exactly one
    pipeline may hold it. A backend has to find orphans from a previous session
    by reading `/proc/net/unix` and kill the stale `gst-launch-1.0` first.
  * **A2DP idles out in one to two seconds.** Between items, silence must keep
    flowing through a persistent pipeline, or the link drops and the next track
    loses its first second.
  * **Returning to Nickel after using Bluetooth can panic the kernel** and
    reboot the device. That is a MediaTek driver bug, not something a plugin can
    fix, and it belongs in a warning the first time a user enables audio.

*i.MX6 Kobos* (Libra 2, Sage, Clara 2E, Elipsa) run standard BlueZ and have no
media framework at all: ALSA and nothing else. ALSA takes PCM only, so streaming
an MP3 URL needs a decoder in front of it — there is no one-liner — and output
means A2DP via BlueALSA, which must be cross-compiled. audiobook.koplugin ships
working build recipes (`cross-build-bluealsa.nix`); lean on those rather than
repeat them. KinAMP solves the decode half with a native daemon (miniaudio) —
exactly the shape `docs/PROTOCOL.md` is designed to accept.

Neither generation has a speaker or a headphone jack. On every current Kobo,
audio means Bluetooth, with no exceptions.

A sane order that avoids building everything at once:

1. **MTK first**, because the pipeline already exists on the device: a local
   file through `playbin` to `mtkbtmwrpcaudiosink`, with the orphan cleanup;
2. then network streaming on MTK, which is the same pipeline with a URI —
   assuming `souphttpsrc` and the codec elements are present, which
   `tools/probe-kobo.sh` answers for a given device;
3. then i.MX6 via BlueALSA, the expensive one, which benefits from everything
   above it being settled first.

`tools/probe-kobo.sh` runs on the device and reports which of these applies:
the framework, the sink element, the codec elements a stream needs, the ALSA
state, and which Bluetooth daemon is running.

## Hardware reality

This constrains the audience more than the software does. No current Kobo has a
speaker or a 3.5 mm jack; audio means Bluetooth, and only on Clara 2E, Sage,
Libra 2, Elipsa/2E, Libra Colour, Clara Colour and Clara BW. Kindle needs a
Bluetooth-audio model and a jailbreak. Android e-ink is the one platform where
this is unambiguous.

Identifying a Kobo is worth doing properly, because the three-digit product id
in `.kobo/version` says nothing on its own. KOReader has already written the
answer to `.adds/koreader/crash.log` on any device it has run on -- for example
`Detected a Kobo Clara Colour (393 => Spa Colour @ Mark 12)`, where **Mark 12
is the part that matters**: it means MTK, and therefore the GStreamer route.
`tools/install-kobo.sh` reads and reports that line.

Streaming also runs the Wi-Fi radio, the Bluetooth radio and a decoder
continuously on a device budgeted for approximately none of that. KinAMP
measures 4–5 %/hour with the frontlight on. Design against that number.
