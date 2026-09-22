#!/usr/bin/env bash
# Copy the plugin onto a Kobo that is mounted as USB mass storage.
#
# On Kobo, KOReader lives in `.adds/koreader/` on the user-visible partition
# (label KOBOeReader), so plugins go in `.adds/koreader/plugins/`. The device
# only exposes that partition after you tap "Connect" on its screen.
#
# Audio will not work on Kobo yet -- there is no ALSA backend -- but the
# directory browsing does, over the device's own Wi-Fi. The plugin says so
# rather than failing silently.
set -euo pipefail

PLUGIN_NAME="shoutkit.koplugin"
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The authoritative signal is a mounted filesystem containing .kobo/version --
# not the partition label. udev's by-label link can lag the mount by a second or
# two after plugging in, and findmnt reports an empty LABEL for this vfat on at
# least some setups, so neither is reliable on its own.
find_kobo() {
    local by_label="/dev/disk/by-label/KOBOeReader"
    if [ -e "$by_label" ]; then
        local target
        target="$(findmnt -n -o TARGET --source "$(readlink -f "$by_label")" 2>/dev/null || true)"
        if [ -n "$target" ] && [ -f "$target/.kobo/version" ]; then
            printf '%s\n' "$target"
            return 0
        fi
    fi
    # Any mounted removable filesystem that carries a Kobo's own marker file.
    findmnt -rn -t vfat,exfat,msdos -o TARGET 2>/dev/null | while read -r target; do
        if [ -f "$target/.kobo/version" ]; then
            printf '%s\n' "$target"
            return 0
        fi
    done
}

# Reports the model. KOReader itself has already detected it and written the
# answer to crash.log, which beats mapping product ids by hand -- the id is a
# three-digit tail that says nothing on its own (393 is a Clara Colour).
report_model() {
    local mount="$1"
    local detected
    detected="$(grep -ao 'Detected a Kobo [^)]*)' "$mount/.adds/koreader/crash.log" 2>/dev/null | tail -1 || true)"
    if [ -n "$detected" ]; then
        echo "==> device: ${detected#Detected a }"
        return
    fi
    if [ -f "$mount/.kobo/version" ]; then
        local version
        version="$(cat "$mount/.kobo/version")"
        echo "==> device: product id ${version##*-}, firmware $(echo "$version" | cut -d, -f3)"
    fi
}

MOUNT="${KOBO_MOUNT:-$(find_kobo || true)}"

if [ -z "${MOUNT:-}" ]; then
    cat >&2 <<'MSG'
No mounted Kobo found.

  1. Plug the Kobo in and tap "Connect" on its screen -- it exposes no storage
     until you do. If it is running KOReader, KOReader asks instead.
  2. Check it enumerated at all:  lsusb | grep -i kobo
  3. If your file manager has not auto-mounted it, mount it and re-run with
     KOBO_MOUNT=/path/to/mount tools/install-kobo.sh

A power-only USB-C cable is the most common cause of nothing appearing.
MSG
    exit 1
fi

echo "==> Kobo mounted at $MOUNT"

TARGET="$MOUNT/.adds/koreader/plugins"
if [ ! -d "$MOUNT/.adds/koreader" ]; then
    echo "KOReader is not installed on this Kobo ($MOUNT/.adds/koreader is missing)." >&2
    echo "Install KOReader first: https://github.com/koreader/koreader/wiki/Installation-on-Kobo-devices" >&2
    exit 1
fi

mkdir -p "$TARGET"
rm -rf "$TARGET/$PLUGIN_NAME"
cp -r "$REPO_DIR/$PLUGIN_NAME" "$TARGET/"
sync

echo "==> installed to $TARGET/$PLUGIN_NAME"

report_model "$MOUNT"

cat <<'MSG'

Next:
  1. Eject the Kobo properly (udisksctl unmount, or your file manager).
  2. KOReader -> Tools -> Radio.
  3. Expect "No audio backend on this device" -- the ALSA/BlueALSA backend is
     not written yet. Browsing by genre, country and name works over Wi-Fi.
MSG
