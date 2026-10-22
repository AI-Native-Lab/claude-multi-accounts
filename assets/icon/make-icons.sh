#!/bin/bash
# Renders AppIcon.svg into the icon files the app uses. Run it again after editing the SVG.
#   assets/icon/AppIcon-1024.png    preview, used in the README
#   macos/Resources/AppIcon.icns    macOS, 16–1024 px
# Needs rsvg-convert (brew install librsvg); iconutil comes with macOS.
set -euo pipefail
cd "$(dirname "$0")"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

rsvg-convert -w 1024 -h 1024 AppIcon.svg -o AppIcon-1024.png

ICONSET="$TMP/AppIcon.iconset"
mkdir "$ICONSET"
for size in 16 32 128 256 512; do
    rsvg-convert -w $size -h $size AppIcon.svg -o "$ICONSET/icon_${size}x${size}.png"
    rsvg-convert -w $((size * 2)) -h $((size * 2)) AppIcon.svg -o "$ICONSET/icon_${size}x${size}@2x.png"
done
mkdir -p ../../macos/Resources
iconutil -c icns "$ICONSET" -o ../../macos/Resources/AppIcon.icns

echo "Rendered AppIcon-1024.png and macos/Resources/AppIcon.icns"
