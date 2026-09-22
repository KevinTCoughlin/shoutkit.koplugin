#!/bin/sh
# Run this ON the Kobo (over SSH, or via KOReader's Terminal plugin) and send
# back the output. It only reads; it changes nothing and plays nothing.
#
# Everything the audio backend design needs to stop guessing: which media
# framework is present, whether the MTK Bluetooth sink exists, what ALSA sees,
# and which Bluetooth stack is running.
#
#   sh /mnt/onboard/.adds/koreader/plugins/shoutkit.koplugin/../../probe-kobo.sh
set -u

section() { echo; echo "=== $1 ==="; }
have() { command -v "$1" >/dev/null 2>&1 && echo "yes: $(command -v "$1")" || echo "NO"; }

echo "shoutkit.koplugin Kobo audio probe"
echo "date: $(date 2>/dev/null)"

section "device"
cat /mnt/onboard/.kobo/version 2>/dev/null || echo "(no version file)"
echo "PRODUCT=${PRODUCT:-unset}  MODEL_NUMBER=${MODEL_NUMBER:-unset}"
/bin/kobo_config.sh 2>/dev/null || echo "(no kobo_config.sh)"
uname -a

section "media frameworks"
printf 'gst-launch-1.0  '; have gst-launch-1.0
printf 'gst-inspect-1.0 '; have gst-inspect-1.0
printf 'ffmpeg          '; have ffmpeg
printf 'mpv             '; have mpv
printf 'madplay         '; have madplay
printf 'mpg123          '; have mpg123
printf 'aplay           '; have aplay
printf 'amixer          '; have amixer

section "the MTK Bluetooth audio sink"
if command -v gst-inspect-1.0 >/dev/null 2>&1; then
    gst-inspect-1.0 mtkbtmwrpcaudiosink 2>&1 | head -12
    echo "--- elements a network stream needs:"
    for e in playbin uridecodebin souphttpsrc curlhttpsrc mpegaudioparse \
             mpg123audiodec avdec_mp3 faad avdec_aac audioconvert audioresample \
             alsasink autoaudiosink; do
        if gst-inspect-1.0 "$e" >/dev/null 2>&1; then echo "  $e: yes"; else echo "  $e: NO"; fi
    done
else
    echo "(no gst-inspect-1.0)"
fi

section "GStreamer plugin files"
# Bounded on purpose: an unqualified `find /` also crawls /mnt/onboard, which is
# tens of thousands of files on slow flash.
GST_DIRS="/usr/lib /lib /usr/local/lib /usr/lib/gstreamer-1.0 /usr/local/lib/gstreamer-1.0"
for d in $GST_DIRS; do
    [ -d "$d" ] || continue
    find "$d" -maxdepth 2 -name 'libgst*.so*' 2>/dev/null
done | sort -u | head -60
echo "--- total: $(for d in $GST_DIRS; do [ -d "$d" ] && find "$d" -maxdepth 2 -name 'libgst*.so*' 2>/dev/null; done | sort -u | wc -l)"
echo "--- GST_PLUGIN_PATH=${GST_PLUGIN_PATH:-unset}"
echo "--- registry: $(ls /usr/lib/gstreamer-1.0 2>/dev/null | wc -l) entries in /usr/lib/gstreamer-1.0"

section "ALSA"
cat /proc/asound/cards 2>/dev/null || echo "(no /proc/asound/cards)"
ls /dev/snd 2>/dev/null || echo "(no /dev/snd)"
aplay -L 2>/dev/null | head -20

section "Bluetooth stack"
printf 'bluetoothd '; have bluetoothd
printf 'bluetoothctl '; have bluetoothctl
printf 'mtkbtd '; have mtkbtd
ps 2>/dev/null | grep -iE 'bluetooth|mtkbt|bluedroid|bsa' | grep -v grep
echo "--- the exclusive MTK socket (holder = whoever owns BT audio):"
grep -a mtkbtmwrpc /proc/net/unix 2>/dev/null || echo "  (not present -- nothing holding it)"
echo "--- hci devices:"
hciconfig -a 2>/dev/null | head -10 || echo "  (no hciconfig)"

section "paired devices / audio config"
ls /var/lib/bluetooth 2>/dev/null || echo "(no /var/lib/bluetooth)"
cat /etc/asound.conf 2>/dev/null || echo "(no /etc/asound.conf)"

section "libs that matter"
for l in libasound.so.2 libgstreamer-1.0.so.0 libssl.so libcrypto.so libsbc.so; do
    found=""
    for d in /usr/lib /lib /usr/local/lib; do
        [ -d "$d" ] || continue
        found=$(find "$d" -maxdepth 2 -name "$l*" 2>/dev/null | head -1)
        [ -n "$found" ] && break
    done
    echo "  $l: ${found:-NO}"
done

section "done"
echo "Send this whole output back."
