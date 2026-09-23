#!/bin/sh
# Third-round Kobo audio probe: who provides A2DP, and can KOReader reach it?
#
# Rounds one and two settled the pipeline: the decode chain works, there is no
# HTTP source element, and mtkbtmwrpcaudiosink reports success while playing to
# nothing because it cannot reach /tmp/audio.a2dp_ctrl. That socket is the whole
# remaining question. Under KOReader there is no bluetoothd, no mtkbtd and no
# /sys/class/bluetooth -- the MediaTek middleware belongs to Nickel, and
# KOReader stops Nickel.
#
# This round is READ-ONLY. It starts nothing and pairs nothing. Returning to
# Nickel after Bluetooth has been used can panic this SoC, so nothing here gets
# to be the thing that discovers that on a device nobody is watching.
set -u

section() { echo; echo "=== $1 ==="; }
have() { command -v "$1" >/dev/null 2>&1 && echo "  $1: $(command -v "$1")" || echo "  $1: NO"; }

echo "shoutkit.koplugin Kobo probe, round 3"
echo "date: $(date 2>/dev/null)"
echo "uptime: $(cat /proc/uptime 2>/dev/null)"

section "the socket itself"
# Round two saw four failed connects to this path. Does it ever exist?
for p in /tmp/audio.a2dp_ctrl /tmp/audio.a2dp_data /tmp/audio.a2dp_ctrl.sock; do
    [ -e "$p" ] && echo "  PRESENT: $(ls -la "$p")" || echo "  absent:  $p"
done
echo "--- everything socket-shaped in /tmp:"
ls -la /tmp 2>/dev/null | grep '^s' || echo "  (no sockets in /tmp)"
echo "--- abstract sockets mentioning bt/a2dp/mtk:"
grep -aiE 'a2dp|mtkbt|bluedroid|audio' /proc/net/unix 2>/dev/null || echo "  (none)"

section "what is actually running"
ps 2>/dev/null
echo "--- is Nickel alive?"
pidof nickel >/dev/null 2>&1 && echo "  nickel: RUNNING (pid $(pidof nickel))" || echo "  nickel: stopped (expected under KOReader)"
pidof hindenburg >/dev/null 2>&1 && echo "  hindenburg: running" || echo "  hindenburg: stopped"

section "who owns the string 'a2dp_ctrl'"
# The decisive question: which binary or library creates that socket. Whatever
# it is, is what KOReader would have to start.
for d in /bin /sbin /usr/bin /usr/sbin /usr/local/bin /lib /usr/lib; do
    [ -d "$d" ] || continue
    for f in "$d"/*; do
        [ -f "$f" ] || continue
        if grep -l "audio.a2dp_ctrl" "$f" >/dev/null 2>&1; then echo "  $f"; fi
    done
done
echo "--- (a2dp anywhere in those dirs, for context):"
for d in /bin /sbin /usr/bin /usr/sbin /lib /usr/lib; do
    [ -d "$d" ] || continue
    for f in "$d"/*; do
        [ -f "$f" ] || continue
        if grep -l "a2dp" "$f" >/dev/null 2>&1; then echo "  $f"; fi
    done
done

section "Bluetooth machinery on disk (running or not)"
for b in bluetoothd bluetoothctl mtkbtd btmwrpc bt_audio btconfig hciconfig hciattach rfkill dbus-daemon dbus-send; do have "$b"; done
echo "--- anything bt-ish in the usual bins:"
ls /usr/bin /bin /usr/sbin /sbin 2>/dev/null | grep -iE '^(bt|bluetooth|mtk)' | sort -u || echo "  (none)"
echo "--- /etc/bluetooth, /usr/libexec/bluetooth:"
ls -la /etc/bluetooth /usr/libexec/bluetooth 2>/dev/null || echo "  (neither)"
echo "--- kernel side:"
lsmod 2>/dev/null | grep -iE 'bt|blue' || echo "  (no bluetooth modules loaded)"
ls /sys/class/bluetooth /sys/class/rfkill 2>/dev/null || echo "  (no /sys/class/bluetooth or rfkill)"
ls /dev/ttyS* /dev/ttyHS* /dev/stpbt* 2>/dev/null || echo "  (no obvious BT tty)"

section "init: what starts it under Nickel"
ls /etc/init.d 2>/dev/null || echo "  (no /etc/init.d)"
echo "--- init scripts that mention bluetooth/bt/a2dp:"
grep -rliE 'bluetooth|bluedroid|a2dp|mtkbt' /etc/init.d /etc/rcS.d /etc/rc.d 2>/dev/null || echo "  (none)"
echo "--- KOReader's own startup, which is what stopped Nickel:"
ls -la /mnt/onboard/.adds/koreader/*.sh 2>/dev/null | head
grep -rn 'nickel' /mnt/onboard/.adds/koreader/koreader.sh 2>/dev/null | head -20

section "D-Bus: the pairing interface audiobook.koplugin drives"
# btmanager.lua talks to com.kobo.mtk.bluedroid rather than org.bluez. If that
# bus name can be reached from KOReader, pairing from the plugin is on the table.
if [ -e /var/run/dbus/system_bus_socket ]; then
    echo "  system bus socket: present"
else
    echo "  system bus socket: ABSENT"
fi
if command -v dbus-send >/dev/null 2>&1; then
    dbus-send --system --print-reply --dest=org.freedesktop.DBus \
        /org/freedesktop/DBus org.freedesktop.DBus.ListNames 2>&1 \
        | grep -iE 'kobo|mtk|blue|bt' || echo "  (no matching bus names, or the call failed)"
else
    echo "  dbus-send: NO (cannot list bus names)"
fi

section "HTTP clients, for the fetch that has to live above GStreamer"
for b in curl wget nc socat openssl; do have "$b"; done
echo "--- busybox applets, if any:"
busybox --list 2>/dev/null | tr '\n' ' ' | head -c 2000
echo

section "network (optional -- skipped when offline)"
echo "--- addresses (this is the IP to put in ~/.ssh/config if SSH is up):"
ip addr 2>/dev/null | grep -E 'inet |state ' || ifconfig 2>/dev/null | grep -E 'inet |^[a-z]'
echo "--- is KOReader's SSH server listening?"
netstat -ltn 2>/dev/null | grep 2222 || echo "  nothing on 2222"
if ip route 2>/dev/null | grep -q default || route -n 2>/dev/null | grep -q '^0\.0\.0\.0'; then
    echo "  default route present; testing the fdsrc streaming design end to end"
    URL="http://stream.live.vc.bbcmedia.co.uk/bbc_world_service"
    if command -v wget >/dev/null 2>&1; then
        timeout 25 sh -c "wget -q -O - '$URL' | gst-launch-1.0 -q fdsrc fd=0 ! queue2 ! mpegaudioparse ! mpg123audiodec ! audioconvert ! audioresample ! fakesink num-buffers=50" 2>&1
        echo "--- wget|fdsrc exit: $?"
    elif command -v curl >/dev/null 2>&1; then
        timeout 25 sh -c "curl -s '$URL' | gst-launch-1.0 -q fdsrc fd=0 ! queue2 ! mpegaudioparse ! mpg123audiodec ! audioconvert ! audioresample ! fakesink num-buffers=50" 2>&1
        echo "--- curl|fdsrc exit: $?"
    else
        echo "  no wget or curl: the fetch has to be KOReader's own luasocket"
    fi
else
    echo "  no default route -- offline. Re-run this section with Wi-Fi up."
fi

section "done"
