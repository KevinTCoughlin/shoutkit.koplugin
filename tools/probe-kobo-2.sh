#!/bin/sh
# Second-round Kobo audio probe: what actually RUNS, not just what exists.
#
# Round one established that this device has GStreamer, the MTK Bluetooth sink
# and an MP3 decoder, but no HTTP source element. This round answers the
# questions that decide the backend's shape, and none of them need Bluetooth
# paired -- every pipeline ends in fakesink.
set -u

OUT_MP3=/mnt/onboard/test.mp3

section() { echo; echo "=== $1 ==="; }

# busybox `timeout` exists on Kobo, but guard anyway: a wedged pipeline must not
# hang the device with KOReader waiting on it.
run() {
    limit="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$limit" "$@" 2>&1
    else
        "$@" 2>&1 &
        pid=$!
        ( sleep "$limit"; kill -9 $pid 2>/dev/null ) &
        killer=$!
        wait $pid 2>/dev/null
        kill -9 $killer 2>/dev/null
    fi
}

echo "shoutkit.koplugin Kobo probe, round 2"
echo "date: $(date 2>/dev/null)"

section "every available GStreamer element"
# Recorded in full so no future question needs another round trip.
gst-inspect-1.0 2>/dev/null | sed -n 's/^\([a-z0-9]*\):  *\([a-z0-9_]*\):.*/\1 \2/p' | sort | head -200
echo "--- element count: $(gst-inspect-1.0 2>/dev/null | grep -c ':.*:')"

section "giosrc: can GIO fetch http at all?"
gst-inspect-1.0 giosrc 2>&1 | sed -n '1,6p'
echo "--- URI protocols giosrc claims:"
gst-inspect-1.0 giosrc 2>&1 | grep -iA3 "protocols"

section "TEST 1: local MP3 decode chain (no audio hardware needed)"
if [ -f "$OUT_MP3" ]; then
    run 20 gst-launch-1.0 -q \
        filesrc location="$OUT_MP3" ! mpegaudioparse ! mpg123audiodec \
        ! audioconvert ! audioresample ! fakesink
    echo "--- exit: $?"
else
    echo "SKIP: no $OUT_MP3"
fi

section "TEST 2: fdsrc from a pipe (the 'KOReader does the HTTP' design)"
if [ -f "$OUT_MP3" ]; then
    run 20 sh -c "cat $OUT_MP3 | gst-launch-1.0 -q fdsrc fd=0 ! mpegaudioparse ! mpg123audiodec ! audioconvert ! audioresample ! fakesink"
    echo "--- exit: $?"
else
    echo "SKIP: no $OUT_MP3"
fi

section "TEST 3: giosrc over http (does the device need KOReader to do the HTTP?)"
run 25 gst-launch-1.0 -q \
    giosrc location="http://stream.live.vc.bbcmedia.co.uk/bbc_world_service" \
    ! mpegaudioparse ! mpg123audiodec ! audioconvert ! audioresample \
    ! fakesink num-buffers=20
echo "--- exit: $?"

section "TEST 4: playbin with an http uri (expected to fail: no http source)"
run 25 gst-launch-1.0 -q \
    playbin uri="http://stream.live.vc.bbcmedia.co.uk/bbc_world_service" \
    audio-sink=fakesink
echo "--- exit: $?"

section "TEST 5: the MTK sink with nothing paired (capture the error shape)"
if [ -f "$OUT_MP3" ]; then
    GST_DEBUG=2 run 20 gst-launch-1.0 \
        filesrc location="$OUT_MP3" ! mpegaudioparse ! mpg123audiodec \
        ! audioconvert ! audioresample \
        ! "audio/x-raw,format=S16LE,rate=48000,channels=2" \
        ! mtkbtmwrpcaudiosink
    echo "--- exit: $?"
fi

section "TEST 6: the exclusive socket, after all that"
grep -a mtkbtmwrpc /proc/net/unix 2>/dev/null || echo "  (not held)"
ps 2>/dev/null | grep -E 'gst-launch|mtkbt' | grep -v grep || echo "  (no stray pipelines)"

section "bluetooth, in more detail"
ls /lib/gstreamer-1.0/ | grep -i bt
for f in /usr/bin/mtk* /bin/mtk* /usr/sbin/mtk*; do [ -e "$f" ] && echo "  $f"; done
echo "--- rfkill / hci:"
cat /proc/net/dev 2>/dev/null | awk '{print $1}' | grep -i bt
ls /sys/class/bluetooth 2>/dev/null || echo "  (no /sys/class/bluetooth)"

section "done"
