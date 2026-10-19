#!/bin/bash
# Builds and notarizes locally. Certificates stay in Keychain; this script never
# accepts passwords or API private keys as arguments and never publishes a release.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
if [[ "${DISCDOCK_SIGNING_IDENTITY:-}" != "Developer ID Application:"* ]]; then
    printf 'Set DISCDOCK_SIGNING_IDENTITY to your Developer ID Application certificate name.\n' >&2
    exit 1
fi
if [[ -z "${DISCDOCK_NOTARY_PROFILE:-}" ]]; then
    printf 'Set DISCDOCK_NOTARY_PROFILE to an existing notarytool Keychain profile.\n' >&2
    exit 1
fi
# Validate access before spending time building. No credential values are printed.
xcrun notarytool history --keychain-profile "$DISCDOCK_NOTARY_PROFILE" --output-format json >/dev/null
export DISCDOCK_REQUIRE_DEVELOPER_ID=1
bash scripts/build-app.sh

# Work outside File Provider directories so signing/stapling metadata is stable.
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/discdock-release.XXXXXX")"
printf 'Release work folder: %s\n' "$STAGING_DIR"
ditto -x -k dist/DiscDock.app.zip "$STAGING_DIR"
APP="$STAGING_DIR/DiscDock.app"
codesign --verify --deep --strict "$APP"
SIGNATURE="$(codesign --display --verbose=4 "$APP" 2>&1)"
[[ "$SIGNATURE" == *"Authority=Developer ID Application:"* && "$SIGNATURE" == *"(runtime)"* ]] || {
    printf 'The release must have a Developer ID signature and hardened runtime.\n' >&2
    exit 1
}
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
REPORT_DIR="$PWD/dist/notarization-$VERSION"
mkdir -p "$REPORT_DIR"

notarize() {
    local archive="$1" report="$2" result=0 status submission
    xcrun notarytool submit "$archive" --keychain-profile "$DISCDOCK_NOTARY_PROFILE" \
        --wait --timeout 30m --output-format json > "$report" || result=$?
    status="$(plutil -extract status raw -o - "$report" 2>/dev/null || true)"
    submission="$(plutil -extract id raw -o - "$report" 2>/dev/null || true)"
    if [[ "$result" != 0 || "$status" != Accepted ]]; then
        printf 'Notarization has not been accepted. Status: %s\nSubmission: %s\nReport: %s\n' "${status:-unknown}" "${submission:-see report}" "$report" >&2
        if [[ -n "$submission" ]]; then
            printf 'Resume/check this submission with notarytool info or wait; do not submit it again while it is processing.\n' >&2
        fi
        exit 1
    fi
    printf 'Apple accepted submission %s\n' "$submission"
}

ditto -c -k --norsrc --keepParent "$APP" "$STAGING_DIR/DiscDock-submit.zip"
notarize "$STAGING_DIR/DiscDock-submit.zip" "$REPORT_DIR/app.json"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
codesign --verify --deep --strict "$APP"
spctl --assess --type execute --verbose=2 "$APP"

# A simple drag-to-Applications disk image, containing the stapled app.
mkdir -p "$STAGING_DIR/image"
ditto "$APP" "$STAGING_DIR/image/DiscDock.app"
xcrun stapler validate "$STAGING_DIR/image/DiscDock.app"
codesign --verify --deep --strict "$STAGING_DIR/image/DiscDock.app"
ln -s /Applications "$STAGING_DIR/image/Applications"
DMG="$STAGING_DIR/DiscDock-$VERSION-macOS.dmg"
hdiutil create -volname DiscDock -srcfolder "$STAGING_DIR/image" -format UDZO -ov "$DMG"
codesign --force --timestamp --sign "$DISCDOCK_SIGNING_IDENTITY" "$DMG"
notarize "$DMG" "$REPORT_DIR/dmg.json"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"
codesign --verify --strict "$DMG"
hdiutil verify "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

# Publishable artifacts get their final names only after every check passes.
ditto -c -k --keepParent "$APP" "$STAGING_DIR/DiscDock-$VERSION-macOS.zip"
mkdir -p "$STAGING_DIR/zip-check"
ditto -x -k "$STAGING_DIR/DiscDock-$VERSION-macOS.zip" "$STAGING_DIR/zip-check"
xcrun stapler validate "$STAGING_DIR/zip-check/DiscDock.app"
codesign --verify --deep --strict "$STAGING_DIR/zip-check/DiscDock.app"
cp -X "$STAGING_DIR/DiscDock-$VERSION-macOS.zip" dist/
cp -X "$DMG" dist/
shasum -a 256 "dist/DiscDock-$VERSION-macOS.zip" "dist/DiscDock-$VERSION-macOS.dmg"
printf 'Signed, notarized, stapled, and Gatekeeper-verified artifacts are in dist/.\n'
