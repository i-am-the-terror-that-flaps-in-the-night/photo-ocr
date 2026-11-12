#!/bin/bash
# Packages build/PhotoOCR.app into dist/Photo-OCR-<version>.dmg with a
# drag-to-Applications layout, and writes its SHA-256 next to it.
# Run ./build.sh first.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$DIR/VERSION")"
APP="$DIR/build/PhotoOCR.app"
DIST="$DIR/dist"
VOLNAME="Photo OCR"
DMG="$DIST/Photo-OCR-$VERSION.dmg"
TMP="$(mktemp -d)"
MOUNT=""

cleanup() {
    [ -n "$MOUNT" ] && hdiutil detach "$MOUNT" -quiet -force 2>/dev/null || true
    rm -rf "$TMP"
}
trap cleanup EXIT

[ -d "$APP" ] || { echo "build/PhotoOCR.app not found; run ./build.sh first" >&2; exit 2; }
mkdir -p "$DIST"
rm -f "$DMG" "$DMG.sha256"

# Stage the volume contents.
STAGE="$TMP/stage"
mkdir -p "$STAGE/.background"
cp -R "$APP" "$STAGE/Photo OCR.app"
ln -s /Applications "$STAGE/Applications"
sips -z 400 660 "$DIR/Resources/dmg-background@2x.png" --out "$TMP/background.png" >/dev/null
tiffutil -cathidpicheck "$TMP/background.png" "$DIR/Resources/dmg-background@2x.png" \
    -out "$STAGE/.background/background.tiff" >/dev/null 2>&1

# Writable image first, so Finder can store the window layout in it.
hdiutil create -quiet -volname "$VOLNAME" -srcfolder "$STAGE" -fs HFS+ \
    -format UDRW -ov "$TMP/rw.dmg"
MOUNT="$(hdiutil attach "$TMP/rw.dmg" -readwrite -noverify -noautoopen 2>/dev/null \
    | awk -F'\t' '/\/Volumes\//{print $NF}' | tail -1)"
[ -d "$MOUNT" ] || { echo "could not mount the disk image" >&2; exit 1; }

# Window layout. Needs permission to control Finder; without it the image
# still works, it just opens with Finder's default layout.
if ! osascript >/dev/null 2>&1 <<OSA
with timeout of 30 seconds
    tell application "Finder"
        tell disk "$(basename "$MOUNT")"
            open
            set current view of container window to icon view
            set toolbar visible of container window to false
            set statusbar visible of container window to false
            set bounds of container window to {200, 120, 860, 548}
            set opts to icon view options of container window
            set arrangement of opts to not arranged
            set icon size of opts to 112
            set text size of opts to 13
            set background picture of opts to file ".background:background.tiff"
            set position of item "Photo OCR.app" of container window to {180, 190}
            set position of item "Applications" of container window to {480, 190}
            update without registering applications
            delay 1
            close
        end tell
    end tell
end timeout
OSA
then
    echo "warning: could not set the Finder window layout (plain layout used)" >&2
fi

sync
hdiutil detach "$MOUNT" -quiet
MOUNT=""

# Compressed, read-only final image.
hdiutil convert -quiet "$TMP/rw.dmg" -format UDZO -imagekey zlib-level=9 -o "$DMG"
codesign --force --sign - "$DMG"
hdiutil verify -quiet "$DMG"

(cd "$DIST" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
echo "Built: $DMG"
cat "$DMG.sha256"
