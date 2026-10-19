#!/bin/bash
# Builds and notarizes locally or in CI. Credentials are read only from an
# existing Keychain profile or a private API-key file. Never publishes a release.
set -euo pipefail
cd "$(dirname "$0")/.."
export DISCSHIFT_SIGNING_IDENTITY="${DISCSHIFT_SIGNING_IDENTITY:-}"
export DISCSHIFT_NOTARY_PROFILE="${DISCSHIFT_NOTARY_PROFILE:-}"
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
if [[ "${DISCSHIFT_SIGNING_IDENTITY:-}" != "Developer ID Application:"* ]]; then
    printf 'Set DISCSHIFT_SIGNING_IDENTITY to your Developer ID Application certificate name.\n' >&2
    exit 1
fi
NOTARY_AUTH=()
if [[ -n "$DISCSHIFT_NOTARY_PROFILE" ]]; then
    NOTARY_AUTH=(--keychain-profile "$DISCSHIFT_NOTARY_PROFILE")
elif [[ -n "${DISCSHIFT_NOTARY_KEY_PATH:-}" && -n "${DISCSHIFT_NOTARY_KEY_ID:-}" && -n "${DISCSHIFT_NOTARY_ISSUER:-}" ]]; then
    NOTARY_AUTH=(--key "$DISCSHIFT_NOTARY_KEY_PATH" --key-id "$DISCSHIFT_NOTARY_KEY_ID" --issuer "$DISCSHIFT_NOTARY_ISSUER")
else
    printf 'Set an existing notarytool profile or all three notarization API-key variables.\n' >&2
    exit 1
fi
xcrun notarytool history "${NOTARY_AUTH[@]}" --output-format json >/dev/null
export DISCSHIFT_REQUIRE_DEVELOPER_ID=1
bash scripts/build-app.sh

# Work outside File Provider directories so signing/stapling metadata is stable.
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/discshift-release.XXXXXX")"
printf 'Release work folder: %s\n' "$STAGING_DIR"
ditto -x -k dist/DiscShift.app.zip "$STAGING_DIR"
APP="$STAGING_DIR/DiscShift.app"
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
    xcrun notarytool submit "$archive" "${NOTARY_AUTH[@]}" \
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

# Apple's ticket delivery and Gatekeeper services can drop connections after
# accepting a submission. Retry validation, never the submission itself.
network_check() {
    local attempt
    for attempt in 1 2 3 4 5; do
        if "$@"; then return 0; fi
        if [[ "$attempt" == 5 ]]; then return 1; fi
        printf 'Network-dependent release check failed; retrying (%s/5).\n' "$attempt" >&2
        sleep 5
    done
}

ditto -c -k --norsrc --keepParent "$APP" "$STAGING_DIR/DiscShift-submit.zip"
notarize "$STAGING_DIR/DiscShift-submit.zip" "$REPORT_DIR/app.json"
network_check xcrun stapler staple "$APP"
network_check xcrun stapler validate "$APP"
codesign --verify --deep --strict "$APP"
network_check spctl --assess --type execute --verbose=2 "$APP"

# A simple drag-to-Applications disk image, containing the stapled app.
mkdir -p "$STAGING_DIR/image"
ditto "$APP" "$STAGING_DIR/image/DiscShift.app"
network_check xcrun stapler validate "$STAGING_DIR/image/DiscShift.app"
codesign --verify --deep --strict "$STAGING_DIR/image/DiscShift.app"
ln -s /Applications "$STAGING_DIR/image/Applications"
DMG="$STAGING_DIR/DiscShift-$VERSION-macOS.dmg"
hdiutil create -volname DiscShift -srcfolder "$STAGING_DIR/image" -format UDZO -ov "$DMG"
codesign --force --timestamp --sign "$DISCSHIFT_SIGNING_IDENTITY" "$DMG"
notarize "$DMG" "$REPORT_DIR/dmg.json"
network_check xcrun stapler staple "$DMG"
network_check xcrun stapler validate "$DMG"
codesign --verify --strict "$DMG"
hdiutil verify "$DMG"
network_check spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"

# Publishable artifacts get their final names only after every check passes.
ditto -c -k --keepParent "$APP" "$STAGING_DIR/DiscShift-$VERSION-macOS.zip"
mkdir -p "$STAGING_DIR/zip-check"
ditto -x -k "$STAGING_DIR/DiscShift-$VERSION-macOS.zip" "$STAGING_DIR/zip-check"
network_check xcrun stapler validate "$STAGING_DIR/zip-check/DiscShift.app"
codesign --verify --deep --strict "$STAGING_DIR/zip-check/DiscShift.app"
cp -X "$STAGING_DIR/DiscShift-$VERSION-macOS.zip" dist/
cp -X "$DMG" dist/
shasum -a 256 "dist/DiscShift-$VERSION-macOS.zip" "dist/DiscShift-$VERSION-macOS.dmg"
printf 'Signed, notarized, stapled, and Gatekeeper-verified artifacts are in dist/.\n'
