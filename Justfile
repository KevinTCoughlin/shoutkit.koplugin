# shoutkit.koplugin — development tasks
# Requires: luajit, mpv. No luarocks, no KOReader checkout.

default: check test

# Run the test suite
test:
    luajit spec/run.lua

# Syntax-check every Lua file, including the mpv-side control script
check:
    #!/usr/bin/env bash
    set -euo pipefail
    failed=0
    while IFS= read -r file; do
        if ! luajit -bl "$file" /dev/null >/dev/null 2>&1; then
            echo "SYNTAX: $file"
            luajit -bl "$file" /dev/null 2>&1 | head -3
            failed=1
        fi
    done < <(find shoutkit.koplugin spec bin -name '*.lua' -o -path 'bin/shoutkit')
    [ "$failed" -eq 0 ] && echo "syntax ok"

# Run the dev harness, e.g. `just cli search --tag jazz`
cli *ARGS:
    ./bin/shoutkit {{ARGS}}

# Play something for 20 seconds as a smoke test against the live directory
smoke:
    ./bin/shoutkit play --tag jazz --order votes --seconds 20 --volume 40

# Copy the plugin into a local KOReader checkout or install
install KOREADER="../koreader":
    #!/usr/bin/env bash
    set -euo pipefail
    target="{{KOREADER}}/plugins"
    [ -d "$target" ] || { echo "no plugins dir at $target"; exit 1; }
    rm -rf "$target/shoutkit.koplugin"
    cp -r shoutkit.koplugin "$target/"
    echo "installed to $target/shoutkit.koplugin"

# Build a zip of just the plugin directory, for sideloading
package:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p dist
    rm -f dist/shoutkit.koplugin.zip
    zip -qr dist/shoutkit.koplugin.zip shoutkit.koplugin -x '*.log'
    echo "dist/shoutkit.koplugin.zip"

# Show which audio backend this machine would use
backends:
    ./bin/shoutkit backends
