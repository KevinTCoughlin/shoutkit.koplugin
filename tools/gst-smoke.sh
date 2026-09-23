#!/usr/bin/env bash
# Drives gst_control.sh end to end against a real GStreamer.
#
# Opt-in rather than part of `just test`, because it needs GStreamer installed
# and takes the better part of a minute. What it proves is the half the unit
# tests cannot reach: that the pipeline actually starts, that the status file
# reaches `playing`, that a stop leaves nothing behind, and that the stream path
# -- the one the Kobo forces, with the fetch happening outside GStreamer -- works
# against a real HTTP server.
#
# Output is fakesink throughout, so this makes no noise and needs no audio
# device; the decode chain is exactly the one an MTK Kobo runs. `sync=true`
# matters more than it looks: without it the sink consumes as fast as the CPU
# can decode, a 30-second file is over in under a second, and every timing
# assertion below passes against a pipeline that has already exited.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONTROL="$REPO/shoutkit.koplugin/koaudio/backends/gst_control.sh"
WORK="${TMPDIR:-/tmp}/koaudio-gst-smoke"
BASE="$WORK/player"
MP3="$WORK/tone.mp3"
DURATION=30

pass=0
fail=0
ok()   { echo "  ok   — $1"; pass=$((pass + 1)); }
bad()  { echo "  FAIL — $1"; fail=$((fail + 1)); }
check() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (expected $1, got $2)"; fi; }

status_field() { sed -n "s/^$1=//p" "$BASE.status" 2>/dev/null | tail -1; }

# Polls until the status file reports `want`, or gives up. Never a bare sleep:
# on a loaded machine the pipeline can take a second to preroll, and a fixed
# wait would make this flaky in exactly the way a smoke test must not be.
await_state() {
    want="$1"; limit="${2:-15}"
    i=0
    while [ "$i" -lt "$((limit * 4))" ]; do
        [ "$(status_field state)" = "$want" ] && return 0
        sleep 0.25
        i=$((i + 1))
    done
    return 1
}

send() {
    seq=$1; shift
    echo "$seq $*" >> "$BASE.command"
}

start_player() {
    rm -f "$BASE.status" "$BASE.command" "$BASE.log"
    : > "$BASE.command"
    env KOAUDIO_STATUS="$BASE.status" \
        KOAUDIO_COMMAND="$BASE.command" \
        KOAUDIO_LOG="$BASE.log" \
        KOAUDIO_SINK="fakesink sync=true" \
        "$@" sh "$CONTROL" &
    CONTROL_PID=$!
}

stop_player() {
    kill -TERM "$CONTROL_PID" 2>/dev/null
    wait "$CONTROL_PID" 2>/dev/null
}

rm -rf "$WORK"; mkdir -p "$WORK"

echo "== generating a ${DURATION}s constant-bitrate MP3 =="
# Constant bitrate on purpose: the seek arithmetic assumes it, so testing
# against a VBR file would be testing something the backend never claimed.
gst-launch-1.0 -q audiotestsrc num-buffers=$((DURATION * 43)) \
    ! audioconvert ! lamemp3enc target=bitrate bitrate=128 cbr=true \
    ! filesink location="$MP3" 2>/dev/null
if [ ! -s "$MP3" ]; then echo "could not generate $MP3"; exit 1; fi
SIZE=$(wc -c < "$MP3")
echo "   $MP3, $SIZE bytes, ~$((SIZE / DURATION)) bytes/s"

echo
echo "== a local file =="
start_player KOAUDIO_URL="$MP3" KOAUDIO_KIND=file KOAUDIO_VOLUME=60 \
             KOAUDIO_BYTE_RATE=$((SIZE / DURATION))
if await_state playing; then ok "reaches playing"; else bad "never reached playing"; fi
check "60" "$(status_field volume)" "reports the volume it was given"
check "0" "$(status_field seq)" "no commands applied yet"

echo
echo "== pause and resume =="
send 1 pause
if await_state paused 5; then ok "pauses"; else bad "did not pause"; fi
before=$(status_field elapsed)
sleep 2
check "$before" "$(status_field elapsed)" "elapsed does not advance while paused"
send 2 resume
if await_state playing 5; then ok "resumes"; else bad "did not resume"; fi

echo
echo "== seeking =="
send 3 seek_to 20
# A seek rebuilds the pipeline, so wait for the announced buffering and then for
# playback to resume. Sleeping a fixed two seconds here reads the *old*
# pipeline's status and calls a working seek a failure.
await_state buffering 5 || bad "a seek should announce itself as buffering"
await_state playing 10
sleep 1
elapsed=$(status_field elapsed)
if [ "${elapsed:-0}" -ge 19 ] && [ "${elapsed:-0}" -le 26 ]; then
    ok "seek_to 20 lands at ${elapsed}s"
else
    bad "seek_to 20 reported ${elapsed}s"
fi
check "3" "$(status_field seq)" "tracks the applied sequence number"

echo
echo "== stop leaves nothing behind =="
orphans_before=$(pgrep -f 'gst-launch-1.0 .*fakesink' 2>/dev/null | wc -l)
send 4 stop
wait "$CONTROL_PID" 2>/dev/null
sleep 1
check "stopped" "$(status_field state)" "writes a terminal state"
orphans_after=$(pgrep -f 'gst-launch-1.0 .*fakesink' 2>/dev/null | wc -l)
if [ "$orphans_after" -lt "$orphans_before" ] || [ "$orphans_after" = 0 ]; then
    ok "no orphaned pipeline (this is the one that holds the A2DP socket)"
else
    bad "$orphans_after gst-launch processes still running"
fi

echo
echo "== a stream, fetched outside GStreamer =="
# A local HTTP server, because the point is the fetch|fdsrc design rather than
# any particular station, and a smoke test should not depend on the internet.
python3 -m http.server 8731 --directory "$WORK" >/dev/null 2>&1 &
HTTP_PID=$!
sleep 1
start_player KOAUDIO_URL="http://127.0.0.1:8731/tone.mp3" KOAUDIO_KIND=stream \
             KOAUDIO_VOLUME=70 KOAUDIO_FETCH=wget
if await_state playing; then ok "streams through wget | fdsrc"; else bad "stream never played"; fi
check "0" "$(status_field elapsed)" "reports no position for a stream"
send 1 stop
wait "$CONTROL_PID" 2>/dev/null
kill "$HTTP_PID" 2>/dev/null

echo
echo "== a stream with no fetcher =="
start_player KOAUDIO_URL="http://127.0.0.1:8731/tone.mp3" KOAUDIO_KIND=stream \
             KOAUDIO_FETCH=none
sleep 1
check "error" "$(status_field state)" "refuses rather than playing silence"
stop_player

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
