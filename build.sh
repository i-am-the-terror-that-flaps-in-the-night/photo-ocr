#!/bin/bash
# Builds build/PhotoOCR.app (universal: Apple Silicon + Intel) and the
# build/ocr_cli test harness with swiftc.
# Needs only the Xcode Command Line Tools (no Xcode).
# The filtered linker warning is harmless: the Command Line Tools ship one
# back-deployment library without an Intel slice, and the app does not use it.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERSION="$(tr -d '[:space:]' < "$DIR/VERSION")"
BUILD="$DIR/build"
APP="$BUILD/PhotoOCR.app"
CONTENTS="$APP/Contents"
MIN_MACOS=13.0
SWIFT_FLAGS=(-swift-version 5 -O)
TMP="$BUILD/tmp"

# Never leave a stale or half-built product behind after a failed build.
cleanup() {
    local status=$?
    rm -rf "$TMP"
    if [ "$status" -ne 0 ]; then
        rm -rf "$APP"
        rm -f "$BUILD/ocr_cli"
    fi
}
trap cleanup EXIT

rm -rf "$APP" "$TMP"
rm -f "$BUILD/ocr_cli"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources" "$TMP/cli"

echo "Compiling Photo OCR $VERSION..."
for arch in arm64 x86_64; do
    swiftc "${SWIFT_FLAGS[@]}" -parse-as-library \
        -target "$arch-apple-macos$MIN_MACOS" \
        "$DIR"/Sources/*.swift \
        -o "$TMP/PhotoOCR-$arch" \
        2> >(grep -v 'libswiftCompatibilityPacks' >&2)
done
lipo -create "$TMP/PhotoOCR-arm64" "$TMP/PhotoOCR-x86_64" -output "$CONTENTS/MacOS/PhotoOCR"

cp "$DIR/Resources/AppIcon.icns" "$CONTENTS/Resources/AppIcon.icns"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>io.github.i-am-the-terror-that-flaps-in-the-night.photo-ocr</string>
    <key>CFBundleName</key>
    <string>Photo OCR</string>
    <key>CFBundleDisplayName</key>
    <string>Photo OCR</string>
    <key>CFBundleExecutable</key>
    <string>PhotoOCR</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>LSMinimumSystemVersion</key>
    <string>$MIN_MACOS</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.productivity</string>
    <key>NSHumanReadableCopyright</key>
    <string>Open source under the Apache License 2.0.</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key>
            <string>Image</string>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>LSHandlerRank</key>
            <string>Alternate</string>
            <key>LSItemContentTypes</key>
            <array>
                <string>public.image</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
PLIST
plutil -lint "$CONTENTS/Info.plist"

echo "Signing (ad hoc)..."
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"

# The harness uses top-level code. In a multi-file compile swiftc allows that
# only in a file named main.swift, so compile a copy under that name.
echo "Compiling ocr_cli..."
cp "$DIR/Tests/ocr_cli.swift" "$TMP/cli/main.swift"
swiftc "${SWIFT_FLAGS[@]}" \
    "$DIR/Sources/OCRCore.swift" "$TMP/cli/main.swift" \
    -o "$BUILD/ocr_cli"

echo "Built: $APP"
echo "Built: $BUILD/ocr_cli"
