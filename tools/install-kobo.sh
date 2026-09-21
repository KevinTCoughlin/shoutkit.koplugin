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

find_kobo() {
    # Preferred: the partition label Kobo ships.
    local by_label="/dev/disk/by-label/KOBOeReader"
    if [ -e "$by_label" ]; then
        findmnt -n -o TARGET --source "$(readlink -f "$by_label")" 2>/dev/null && return 0
    fi
    # Fallback: an already-mounted filesystem that looks like one.
    findmnt -rn -o TARGET,LABEL 2>/dev/null \
        | awk '$2 == "KOBOeReader" { print $1; exit }'
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

# Worth knowing before you go looking for a Radio menu that cannot make sound.
model_file="$MOUNT/.kobo/version"
if [ -f "$model_file" ]; then
    echo "==> device: $(tr ',' ' ' < "$model_file" | awk '{print $NF, $(NF-1)}')"
fi

cat <<'MSG'

Next:
  1. Eject the Kobo properly (udisksctl unmount, or your file manager).
  2. KOReader -> Tools -> Radio.
  3. Expect "No audio backend on this device" -- the ALSA/BlueALSA backend is
     not written yet. Browsing by genre, country and name works over Wi-Fi.
MSG
