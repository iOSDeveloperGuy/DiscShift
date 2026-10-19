#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
SIGNING_IDENTITY="${DISCSHIFT_SIGNING_IDENTITY:--}"
export DISCSHIFT_VERSION="${DISCSHIFT_VERSION:-}"
export DISCSHIFT_BUILD_NUMBER="${DISCSHIFT_BUILD_NUMBER:-}"
if [[ "${DISCSHIFT_REQUIRE_DEVELOPER_ID:-0}" == 1 && "$SIGNING_IDENTITY" != "Developer ID Application:"* ]]; then
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
BUILD_DIR="${DISCSHIFT_BUILD_DIR:-${TMPDIR:-/tmp}/discshift-build-$UID}"
if [[ "${DISCSHIFT_SKIP_TESTS:-0}" != 1 ]]; then
    swift test --scratch-path "$BUILD_DIR"
fi
swift build -c release --scratch-path "$BUILD_DIR"
BIN_DIR="$(swift build -c release --scratch-path "$BUILD_DIR" --show-bin-path)"
APP="$BUILD_DIR/DiscShift.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp -X "$BIN_DIR/DiscShift" "$APP/Contents/MacOS/DiscShift"
# Preserve framework symlinks; re-sign every nested helper inside-out below.
SPARKLE_ROOT="$BUILD_DIR/artifacts/sparkle/Sparkle"
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
mkdir -p "$APP/Contents/Frameworks"
ditto --noextattr --norsrc "$SPARKLE_ROOT/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework" "$FRAMEWORK"
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
<key>CFBundleIdentifier</key><string>com.iosdeveloperguy.discshift</string>
<key>CFBundleName</key><string>DiscShift</string>
<key>CFBundleDisplayName</key><string>DiscShift</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.0.0</string>
<key>CFBundleVersion</key><string>0</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
python3 - "$APP/Contents/Info.plist" <<'PYCONFIG'
import base64, json, os, plistlib, re, sys
from pathlib import Path
config = json.loads(Path('release.json').read_text())
version = os.environ.get('DISCSHIFT_VERSION') or config['version']
build = os.environ.get('DISCSHIFT_BUILD_NUMBER') or str(config['build'])
assert re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', version), 'Expected numeric semantic version'
assert re.fullmatch(r'[1-9][0-9]*', build), 'Expected positive build number'
assert len(base64.b64decode(config['publicEDKey'], validate=True)) == 32
assert config['feedURL'].startswith('https://')
path = Path(sys.argv[1]); info = plistlib.loads(path.read_bytes())
info.update(CFBundleShortVersionString=version, CFBundleVersion=build,
    DSInstallOnLaunch=True, SUFeedURL=config['feedURL'], SUPublicEDKey=config['publicEDKey'],
    SUEnableAutomaticChecks=True, SUAutomaticallyUpdate=False,
    SUEnableSystemProfiling=False, SUVerifyUpdateBeforeExtraction=True,
    SURequireSignedFeed=True)
path.write_bytes(plistlib.dumps(info))
PYCONFIG
cp -X "$SPARKLE_ROOT/LICENSE" "$APP/Contents/Resources/Sparkle-LICENSE.txt"
SIGN_FLAGS=(--force --options runtime --sign "$SIGNING_IDENTITY")
if [[ "$SIGNING_IDENTITY" == - ]]; then
    SIGN_FLAGS+=(--timestamp=none)
else
    SIGN_FLAGS+=(--timestamp)
fi
codesign "${SIGN_FLAGS[@]}" "$FRAMEWORK/Versions/B/XPCServices/Installer.xpc"
codesign "${SIGN_FLAGS[@]}" --preserve-metadata=entitlements "$FRAMEWORK/Versions/B/XPCServices/Downloader.xpc"
codesign "${SIGN_FLAGS[@]}" "$FRAMEWORK/Versions/B/Autoupdate"
codesign "${SIGN_FLAGS[@]}" "$FRAMEWORK/Versions/B/Updater.app"
codesign "${SIGN_FLAGS[@]}" "$FRAMEWORK"
codesign "${SIGN_FLAGS[@]}" "$APP"
codesign --verify --deep --strict "$APP"
mkdir -p "$PWD/dist"
# Archive the verified local bundle directly, before File Provider can attach
# Finder metadata. Use this ZIP when moving the app out of an iCloud folder.
ditto -c -k --norsrc --keepParent "$APP" "$PWD/dist/DiscShift.app.zip"
ditto --noextattr --norsrc "$APP" "$PWD/dist/DiscShift.app"
# File Provider may attach FinderInfo to the destination bundle during copy.
xattr -cr "$PWD/dist/DiscShift.app"
printf 'Built %s\nArchive: %s\n' "$PWD/dist/DiscShift.app" "$PWD/dist/DiscShift.app.zip"
