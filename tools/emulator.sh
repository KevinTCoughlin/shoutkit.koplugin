#!/usr/bin/env bash
# Fetch a real KOReader desktop build, install this plugin into it, and either
# run it interactively or drive the in-KOReader smoke test.
#
# Why a release build rather than building KOReader from source: the source
# build pulls a large toolchain and takes the better part of an hour, and
# nothing here needs to modify KOReader itself. The published Linux build is
# the same frontend the devices run.
#
#   tools/emulator.sh smoke   # headless, asserts every widget step passes
#   tools/emulator.sh run     # interactive window, click around
#
# The SDL "dummy" video driver is what makes `smoke` work with no display at
# all, which is also what makes it usable in CI and over SSH.
set -euo pipefail

KOREADER_VERSION="${KOREADER_VERSION:-v2026.07.1}"
MODE="${1:-smoke}"

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PLUGIN_NAME="shoutkit.koplugin"
WORK_DIR="${KOREADER_TEST_DIR:-$REPO_DIR/.koreader-test}"
KO_ROOT="$WORK_DIR/koreader/lib/koreader"
KO_DATA="$WORK_DIR/home"
TARBALL="$WORK_DIR/koreader-$KOREADER_VERSION.tar.xz"

mkdir -p "$WORK_DIR"

if [ ! -f "$TARBALL" ]; then
    echo "==> downloading KOReader $KOREADER_VERSION"
    if command -v gh >/dev/null 2>&1; then
        gh release download "$KOREADER_VERSION" -R koreader/koreader \
            -p 'koreader-linux-x86_64-*.tar.xz' -O "$TARBALL"
    else
        curl -fsSL -o "$TARBALL" \
            "https://github.com/koreader/koreader/releases/download/$KOREADER_VERSION/koreader-linux-x86_64-$KOREADER_VERSION.tar.xz"
    fi
fi

if [ ! -d "$KO_ROOT" ]; then
    echo "==> extracting"
    rm -rf "$WORK_DIR/koreader"
    mkdir -p "$WORK_DIR/koreader"
    tar -xJf "$TARBALL" -C "$WORK_DIR/koreader"
fi

echo "==> installing $PLUGIN_NAME"
rm -rf "$KO_ROOT/plugins/$PLUGIN_NAME"
cp -r "$REPO_DIR/$PLUGIN_NAME" "$KO_ROOT/plugins/"

# A document directory, so KOReader opens the file manager rather than prompting.
mkdir -p "$WORK_DIR/books"
[ -f "$WORK_DIR/books/README.txt" ] || echo "shoutkit emulator scratch" > "$WORK_DIR/books/README.txt"

case "$MODE" in
smoke)
    # A fresh data dir each run: a stale favourites file would make the
    # round-trip assertions pass for the wrong reason.
    rm -rf "$KO_DATA"
    mkdir -p "$KO_DATA/patches"
    cp "$REPO_DIR/spec/emulator/2-shoutkit-smoke.lua" "$KO_DATA/patches/"

    LOG="$WORK_DIR/smoke.log"
    if [ "${SHOUTKIT_SMOKE_OFFLINE:-0}" = "1" ]; then
        echo "==> running headless smoke test (offline: skipping live-API steps)"
    else
        echo "==> running headless smoke test"
    fi
    (
        cd "$KO_ROOT"
        timeout 120 env SDL_VIDEODRIVER=dummy KO_HOME="$KO_DATA" \
            SHOUTKIT_SMOKE_OFFLINE="${SHOUTKIT_SMOKE_OFFLINE:-0}" \
            ./reader.lua -d "$WORK_DIR/books" > "$LOG" 2>&1
    ) || true

    grep -a "SMOKE" "$LOG" | sed -e 's/^[0-9/:-]* *WARN *//' || true

    result="$(grep -a "SMOKE RESULT" "$LOG" | tail -1 || true)"
    if [ -z "$result" ]; then
        echo
        echo "FAILED: the smoke test never reported. Last lines of $LOG:"
        tail -25 "$LOG"
        exit 1
    fi
    # The patch reports its own tally; trust that over the exit code, since
    # KOReader exits 0 even when a scheduled task raised.
    if ! echo "$result" | grep -q "0 failed"; then
        echo
        echo "FAILED: $result"
        exit 1
    fi
    echo
    echo "OK: $result"
    ;;
run)
    mkdir -p "$KO_DATA"
    echo "==> launching KOReader (Tools -> Radio)"
    cd "$KO_ROOT"
    exec env KO_HOME="$KO_DATA" ./reader.lua "$WORK_DIR/books"
    ;;
*)
    echo "usage: tools/emulator.sh [smoke|run]" >&2
    exit 2
    ;;
esac
