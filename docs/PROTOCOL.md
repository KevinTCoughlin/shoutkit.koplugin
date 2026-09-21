# The backend control protocol

Every spawning backend (mpv today; the Kindle GStreamer and Kobo decoder-daemon
backends later) is a **separate process that owns the audio pipeline**. KOReader
talks to it only through two files. This document is the contract.

Why files and not a socket: KOReader has no threads and no unix-socket library
on every platform, and the one existing precedent in this ecosystem — KinAMP's
`.kinamp_cmd` / `.kinamp_status` pair — already works this way on real devices.
Matching it means a native daemon written for one plugin can serve the other.

## Status file — `<base>.status`

Written **by the player**, read by KOReader. Rewritten atomically (write to
`<base>.status.tmp`, then `rename()`) on every state change and once a second
while playing.

```
state=playing
title=dee Brown - Wes 8Mile
artist=
name=SmoothJazz.com
codec=aac
bitrate=64
volume=60
elapsed=37
duration=0
seq=3
```

| Key | Meaning |
|---|---|
| `state` | `stopped` \| `opening` \| `buffering` \| `playing` \| `paused` \| `error` |
| `title` | ICY `StreamTitle` for radio, tag title for a file; empty when unknown |
| `artist` | Only when the source separates it from the title |
| `name` | ICY `icy-name`, i.e. the station's own name for itself |
| `codec` | Short codec name as the decoder reports it |
| `bitrate` | **Kilobits per second**, integer. Players reporting bits must divide. |
| `volume` | 0–100 |
| `elapsed` | Whole seconds into the item; meaningless for a live stream |
| `duration` | Whole seconds, `0` for a live stream |
| `error` | Present only when `state=error`; a short human-readable reason |
| `seq` | Highest command sequence number the player has applied |

Rules:

- **Atomic rename is mandatory.** On Kindle the status file lives on a FAT
  volume with no unlink-while-open semantics, and a reader can otherwise get a
  half-written file or a read error mid-stream.
- Unknown keys are ignored by the reader, so a backend may add its own.
- A missing status file means "nothing to report yet", not "stopped". The
  controller distinguishes the two by checking whether the process is alive.
- `state=error` must be written before exiting on a failure, and
  `state=stopped` before exiting on a requested quit. A player that dies
  without writing either is reported as an unexpected exit.

## Command file — `<base>.command`

Appended to **by KOReader**, polled by the player (4 Hz is what the mpv backend
uses). One command per line:

```
<seq> <verb> [argument]
```

`seq` is a monotonically increasing integer. The player tracks the highest it
has applied and ignores anything at or below it — which is what makes the file
append-only and safe to re-read from the start.

| Verb | Argument | Notes |
|---|---|---|
| `pause` | — | |
| `resume` | — | |
| `toggle` | — | |
| `stop` | — | Player writes `state=stopped` and exits |
| `volume` | 0–100 | |
| `seek` | seconds, signed | Relative. Refused above for live streams. |
| `seek_to` | seconds | Absolute |
| `loadfile` | URL | Replace the current item without respawning |

Rules:

- The controller **truncates** this file when it starts a player, because
  sequence numbers restart at 1 with each process. A leftover file would look
  like commands from the future.
- The argument may contain spaces; everything after the verb is the argument.
- A verb the player does not recognise is ignored, not an error.

## What a new backend must implement

Only these two files, plus exiting when told to. Everything above — the state
machine, the reconnect-on-error policy, the UI — is shared and lives in
`koaudio/player.lua`.
