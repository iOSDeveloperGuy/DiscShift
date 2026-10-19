#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Preserve the original automation variables for existing local setups.
SIGNING_IDENTITY="${DISCSHIFT_SIGNING_IDENTITY:-${DISCDOCK_SIGNING_IDENTITY:--}}"
export DISCSHIFT_VERSION="${DISCSHIFT_VERSION:-${DISCDOCK_VERSION:-}}"
export DISCSHIFT_BUILD_NUMBER="${DISCSHIFT_BUILD_NUMBER:-${DISCDOCK_BUILD_NUMBER:-}}"
if [[ "${DISCSHIFT_REQUIRE_DEVELOPER_ID:-${DISCDOCK_REQUIRE_DEVELOPER_ID:-0}}" == 1 && "$SIGNING_IDENTITY" != "Developer ID Application:"* ]]; then
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
BUILD_DIR="${DISCSHIFT_BUILD_DIR:-${DISCDOCK_BUILD_DIR:-${TMPDIR:-/tmp}/discshift-build-$UID}}"
swift test --scratch-path "$BUILD_DIR"
swift build -c release --scratch-path "$BUILD_DIR"
BIN_DIR="$(swift build -c release --scratch-path "$BUILD_DIR" --show-bin-path)"
APP="$BUILD_DIR/DiscShift.app"
mkdir -p "$APP/Contents/MacOS"
cp -X "$BIN_DIR/DiscShift" "$APP/Contents/MacOS/DiscShift"
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
<key>CFBundleExecutable</key><string>DiscShift</string>
<key>CFBundleIdentifier</key><string>com.iosdeveloperguy.discdock</string>
<key>CFBundleName</key><string>DiscShift</string>
<key>CFBundleDisplayName</key><string>DiscShift</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.8.1</string>
<key>CFBundleVersion</key><string>10</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
if [[ -n "${DISCSHIFT_VERSION:-}" ]]; then
    [[ "$DISCSHIFT_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { printf 'Use a numeric version such as 0.8.1.\n' >&2; exit 1; }
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $DISCSHIFT_VERSION" "$APP/Contents/Info.plist"
fi
if [[ -n "${DISCSHIFT_BUILD_NUMBER:-}" ]]; then
    [[ "$DISCSHIFT_BUILD_NUMBER" =~ ^[0-9]+$ ]] || { printf 'Use a numeric build number.\n' >&2; exit 1; }
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $DISCSHIFT_BUILD_NUMBER" "$APP/Contents/Info.plist"
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
ditto -c -k --norsrc --keepParent "$APP" "$PWD/dist/DiscShift.app.zip"
ditto --noextattr --norsrc "$APP" "$PWD/dist/DiscShift.app"
# File Provider may attach FinderInfo to the destination bundle during copy.
xattr -cr "$PWD/dist/DiscShift.app"
printf 'Built %s\nArchive: %s\n' "$PWD/dist/DiscShift.app" "$PWD/dist/DiscShift.app.zip"
