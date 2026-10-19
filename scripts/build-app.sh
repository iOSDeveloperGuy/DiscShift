#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
SIGNING_IDENTITY="${DISCDOCK_SIGNING_IDENTITY:--}"
if [[ "${DISCDOCK_REQUIRE_DEVELOPER_ID:-0}" == 1 && "$SIGNING_IDENTITY" != "Developer ID Application:"* ]]; then
    printf 'A Developer ID Application signing identity is required for a public release.\n' >&2
    exit 1
fi
# XCTest in Swift's Xcode build system requires the full Xcode developer tree.
# Select it for this script only; leave the Mac's xcode-select preference alone.
if [[ -z "${DEVELOPER_DIR:-}" && "$(xcode-select -p)" == */CommandLineTools && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
# Keep generated bundles outside iCloud/File Provider folders. Their Finder
# metadata can cause codesign to reject otherwise valid test and app bundles.
BUILD_DIR="${DISCDOCK_BUILD_DIR:-${TMPDIR:-/tmp}/discdock-build-$UID}"
swift test --scratch-path "$BUILD_DIR"
swift build -c release --scratch-path "$BUILD_DIR"
BIN_DIR="$(swift build -c release --scratch-path "$BUILD_DIR" --show-bin-path)"
APP="$BUILD_DIR/DiscDock.app"
mkdir -p "$APP/Contents/MacOS"
cp -X "$BIN_DIR/DiscDock" "$APP/Contents/MacOS/DiscDock"
ICONSET="$BUILD_DIR/AppIcon.iconset"
mkdir -p "$ICONSET" "$APP/Contents/Resources"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" Assets/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    doubled=$((size * 2))
    sips -z "$doubled" "$doubled" Assets/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>DiscDock</string>
<key>CFBundleIdentifier</key><string>com.iosdeveloperguy.discdock</string>
<key>CFBundleName</key><string>DiscDock</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.8.0</string>
<key>CFBundleVersion</key><string>9</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
if [[ -n "${DISCDOCK_VERSION:-}" ]]; then
    [[ "$DISCDOCK_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { printf 'Use a numeric version such as 0.8.1.\n' >&2; exit 1; }
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $DISCDOCK_VERSION" "$APP/Contents/Info.plist"
fi
if [[ -n "${DISCDOCK_BUILD_NUMBER:-}" ]]; then
    [[ "$DISCDOCK_BUILD_NUMBER" =~ ^[0-9]+$ ]] || { printf 'Use a numeric build number.\n' >&2; exit 1; }
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $DISCDOCK_BUILD_NUMBER" "$APP/Contents/Info.plist"
fi
if [[ "$SIGNING_IDENTITY" == - ]]; then
    codesign --force --options runtime --timestamp=none --sign - "$APP"
else
    codesign --force --options runtime --timestamp --sign "$SIGNING_IDENTITY" "$APP"
fi
codesign --verify --deep --strict "$APP"
mkdir -p "$PWD/dist"
# Archive the verified local bundle directly, before File Provider can attach
# Finder metadata. Use this ZIP when moving the app out of an iCloud folder.
ditto -c -k --norsrc --keepParent "$APP" "$PWD/dist/DiscDock.app.zip"
ditto --noextattr --norsrc "$APP" "$PWD/dist/DiscDock.app"
# File Provider may attach FinderInfo to the destination bundle during copy.
xattr -cr "$PWD/dist/DiscDock.app"
printf 'Built %s\nArchive: %s\n' "$PWD/dist/DiscDock.app" "$PWD/dist/DiscDock.app.zip"
