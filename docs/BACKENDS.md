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
| `gstreamer` | Kindle | **written, untested on hardware** | `gst_control.sh` + `alsasink` |
| `alsa` | Kobo (i.MX6), PocketBook | stub | ALSA, + BlueALSA for A2DP, + a decoder |
| `gstreamer` | Kobo (MTK) | **written, blocked on A2DP** | `gst_control.sh` + `mtkbtmwrpcaudiosink` |
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

Two probe rounds on a real Clara Colour (`probe-clara-colour-1.txt`,
`probe-clara-colour-2.txt`) settled the shape of that pipeline, and it is not
the one this document assumed. What follows is measured, not inferred.

**There is no HTTP source element on the device.** Not `souphttpsrc`, not
`curlhttpsrc`; `giosrc` is built without the http backend and advertises only
`file` and `resource`; and `playbin` with an `http://` URI dies immediately with
*No URI handler implemented for "http"*. Of the 249 elements present, the only
network sources are `tcpclientsrc` and `socketsrc`, which speak TCP and know
nothing about HTTP. So this line, which earlier drafts of this file recommended,
cannot work on a Kobo:

    gst-launch-1.0 playbin uri=<url> audio-sink=mtkbtmwrpcaudiosink

**Something above GStreamer has to do the HTTP.** Both halves of that design are
confirmed working on the device:

    filesrc location=<file> ! mpegaudioparse ! mpg123audiodec \
        ! audioconvert ! audioresample ! <sink>          # exit 0

    cat <file> | gst-launch-1.0 fdsrc fd=0 ! mpegaudioparse ! mpg123audiodec \
        ! audioconvert ! audioresample ! <sink>          # exit 0

A file plays from `filesrc`, which is all a podcast needs. A stream plays from
`fdsrc` fed by a pipe, which is what radio needs, with the fetch done by
whatever we put on the other end of that pipe. `queue2` is present, so the
buffering belongs in the pipeline rather than in the fetcher.

Decoding is MP3-only: `mpg123audiodec` is the sole audio decoder on the device.
There is no `faad`, no `avdec_aac`, no libav at all, so an AAC station cannot be
played and the station picker has to filter on codec rather than fail at play
time.

**The sink lies about failure.** With nothing paired, `mtkbtmwrpcaudiosink`
tries the control socket four times, logs `skt_connect: failed to connect`, and
then reports `adev_open_output_stream: success` anyway. The pipeline prerolls,
runs to EOS and exits 0 — having made no sound and returned no error. Nothing a
backend can see in the exit status or the bus distinguishes "playing to a
speaker" from "playing to nowhere", so availability has to be decided *before*
the pipeline, by checking for the control socket directly.

That socket is `/tmp/audio.a2dp_ctrl`, an ordinary filesystem path, not the
abstract `@kobo:mtkbtmwrpc` socket earlier notes described — so orphan detection
is a `stat` and a `ps`, not a `/proc/net/unix` scan. After a full run,
`/proc/net/unix` held nothing.

**Nothing provides that socket while KOReader is running.** Under KOReader there
is no `bluetoothd`, no `mtkbtd`, no `/sys/class/bluetooth` and no hci interface
— the MediaTek Bluetooth middleware is Nickel's, and Nickel is stopped. Until
that is resolved, an MTK Kobo running KOReader has no audio path at all, and it
is the single open question this backend turns on. Round three has to answer it,
with a speaker paired from Nickel first:

  * does `/tmp/audio.a2dp_ctrl` exist while KOReader runs, after pairing?
  * if not, which Nickel-side process creates it, and can it be started alone?
  * with the socket live, does the file pipeline above actually make sound?

The remaining constraints stand as previously understood, and still need
confirming on hardware once there is sound at all:

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

1. **Settle the A2DP control socket**, because every step below it is blocked on
   there being an output at all;
2. **a local file on MTK**: `filesrc` through the decode chain to
   `mtkbtmwrpcaudiosink`, with the stale-pipeline cleanup and an availability
   check that does not trust the sink;
3. **then network streaming on MTK**, which is the same pipeline with `fdsrc`
   and a fetcher upstream of it — a different design from the file case, not a
   parameter change;
4. then i.MX6 via BlueALSA, the expensive one, which benefits from everything
   above it being settled first.

Detecting which generation you are on is a one-liner: KOReader exposes
**`Device:isMTK()`**, set per-model in `frontend/device/kobo/device.lua`. That
is what `koaudio/detect.lua` should branch on — not the product id, and not
crash.log.

`tools/probe-kobo.sh` (round one: what exists) and `tools/probe-kobo-2.sh`
(round two: what actually runs) execute on the device and report the framework,
the sink, the codec and source elements, the ALSA state and the Bluetooth stack.
Since a Kobo in USB mass storage mode has handed its disk to the host and is
running nothing, the device has to run them itself: `tools/2-probe-audio.lua`
and `tools/2-probe-audio-2.lua` are one-shot KOReader user patches that do
exactly that on next launch, write to `/mnt/onboard/probe-kobo-output*.txt`, and
rename themselves to `.done` so they never fire twice. Copy the pair to the
device, launch KOReader, reconnect USB, read the file. Results so far are kept
verbatim in `docs/probe-clara-colour-1.txt` and `-2.txt`.

That round trip costs a device reboot per question, which is why the next round
should be run over SSH instead: KOReader's SSH plugin is the same device, live,
with a shell.

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
