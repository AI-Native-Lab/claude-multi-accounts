#!/bin/bash
# Builds and installs Claude Multi-Accounts into ~/Applications, links the claude-multi-accounts
# command into ~/.local/bin, then opens the app.
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build.sh

APP="$HOME/Applications/Claude Multi-Accounts.app"
mkdir -p "$HOME/Applications" "$HOME/.local/bin"

# Ask a running copy to quit, and wait until it has: opening the new copy while the old one is
# still shutting down fails (LaunchServices error -600). Never force-quit it. Before version 3
# the app was called Claude Account Swap; it has the same bundle identifier.
running() { pgrep -x -u "$(id -u)" 'ClaudeMultiAccounts|ClaudeAccountSwap' >/dev/null; }
if running; then
    osascript -e 'ignoring application responses' \
              -e 'tell application id "local.claude-account-swap" to quit' \
              -e 'end ignoring' 2>/dev/null || true
    for _ in {1..100}; do
        running || break
        sleep 0.2
    done
    if running; then
        echo "Claude Multi-Accounts hasn't quit (it may be showing a dialog). Quit it, then run this again." >&2
        exit 1
    fi
fi

rm -rf "$APP"
cp -R "build/Claude Multi-Accounts.app" "$HOME/Applications/"
ln -sf "$APP/Contents/MacOS/claude-multi-accounts" "$HOME/.local/bin/claude-multi-accounts"

# The app and command of versions 1 and 2. Their data folder, ~/.claude-desktop-swap, moves to
# ~/.claude-multi-accounts by itself once no account is open in its own window.
OLD_APP="$HOME/Applications/Claude Account Swap.app"
OLD_LINK="$HOME/.local/bin/claude-desktop-swap"
if [ -d "$OLD_APP" ]; then rm -rf "$OLD_APP" && echo "Removed:   $OLD_APP"; fi
if [ -L "$OLD_LINK" ] && [[ "$(readlink "$OLD_LINK")" == *"/Claude Account Swap.app/"* ]]; then
    rm "$OLD_LINK" && echo "Removed:   $OLD_LINK"
fi

open "$APP"
echo "Installed: $APP (its window opens now)"
echo "Command:   ~/.local/bin/claude-multi-accounts"
case ":$PATH:" in
  *":$HOME/.local/bin:"*) ;;
  *) echo "Note: ~/.local/bin is not on your PATH; add it to use the command by name." ;;
esac
