#!/bin/bash
# Builds "Claude Multi-Accounts.app" and the claude-multi-accounts command into ./build,
# as universal binaries that run on both Apple silicon and Intel Macs.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="3.0.0"   # shown in Finder; raise it, and BUILD, for every release
BUILD="2"

# A stale SDKROOT (Command Line Tools removed after Xcode was installed) breaks swift build.
if [ -n "${SDKROOT:-}" ] && [ ! -d "$SDKROOT" ]; then unset SDKROOT; fi

ARCHS=(--arch arm64 --arch x86_64)
swift build -c release "${ARCHS[@]}" --product ClaudeMultiAccounts
swift build -c release "${ARCHS[@]}" --product claude-multi-accounts
BIN="$(swift build -c release "${ARCHS[@]}" --show-bin-path)"

APP="build/Claude Multi-Accounts.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN/ClaudeMultiAccounts" "$APP/Contents/MacOS/ClaudeMultiAccounts"
# The command ships inside the app too; Settings → Install links it into ~/.local/bin.
cp "$BIN/claude-multi-accounts" "$APP/Contents/MacOS/claude-multi-accounts"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp "$BIN/claude-multi-accounts" build/claude-multi-accounts

# The bundle identifier is the one from before version 3, when the app was called Claude Account
# Swap, so its settings and its login item carry over.
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Claude Multi-Accounts</string>
    <key>CFBundleDisplayName</key>
    <string>Claude Multi-Accounts</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleIdentifier</key>
    <string>local.claude-account-swap</string>
    <key>CFBundleExecutable</key>
    <string>ClaudeMultiAccounts</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

# Ad-hoc signatures, inner binary first, so macOS runs them on this Mac. They aren't notarized,
# so a downloaded copy gets a security warning the first time it opens (the README explains it).
codesign --force --sign - "$APP/Contents/MacOS/claude-multi-accounts"
codesign --force --sign - "$APP"
codesign --force --sign - build/claude-multi-accounts

echo "Built: $APP"
echo "Built: build/claude-multi-accounts"
