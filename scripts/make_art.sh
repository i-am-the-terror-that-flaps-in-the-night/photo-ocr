#!/bin/bash
# Regenerates Resources/AppIcon.icns and Resources/dmg-background@2x.png from
# scripts/make_icon.swift. Only needed when the artwork changes.
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

swiftc -O "$DIR/scripts/make_icon.swift" -o "$TMP/make_icon"
"$TMP/make_icon" "$TMP/icon_1024.png" "$DIR/Resources/dmg-background@2x.png"

ICONSET="$TMP/AppIcon.iconset"
mkdir "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$TMP/icon_1024.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$TMP/icon_1024.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$DIR/Resources/AppIcon.icns"
echo "Wrote Resources/AppIcon.icns and Resources/dmg-background@2x.png"
