#!/bin/bash
# Makes the README images from synthetic data only; nothing here reads the real Claude data.
#   1. Builds the app and lets it draw its own windows from the demo accounts
#      (main-window.png, main-window-dark.png, settings.png).
#   2. Renders the illustrations in src/ with Google Chrome (menu-bar.png, side-by-side.png, how-it-works.png).
set -euo pipefail
cd "$(dirname "$0")"
HERE="$PWD"

../../macos/scripts/build.sh
# US English dates and sizes, whatever this Mac's own region is.
"../../macos/build/Claude Multi-Accounts.app/Contents/MacOS/ClaudeMultiAccounts" --render-screenshots "$HERE" \
    -AppleLocale en_US -AppleLanguages '(en)'

CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
render() {   # render <page> <width> <height>
    local profile
    profile="$(mktemp -d)"
    "$CHROME" --headless=new --disable-gpu --hide-scrollbars --user-data-dir="$profile" \
        --force-device-scale-factor=2 --window-size="$2,$3" --virtual-time-budget=6000 \
        --screenshot="$HERE/$1.png" "file://$HERE/src/$1.html" 2>/dev/null
    rm -rf "$profile"
    echo "Wrote $HERE/$1.png"
}
render menu-bar 1200 720
render side-by-side 1600 1000
render how-it-works 1400 1010
