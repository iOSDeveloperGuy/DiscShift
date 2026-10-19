#!/bin/bash
# Uses the Apple Account already signed into Xcode. No app-specific password or
# API private key is read by this script. Publishing remains a separate action.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
export DISCSHIFT_SIGNING_IDENTITY="${DISCSHIFT_SIGNING_IDENTITY:-}"
[[ "$DISCSHIFT_SIGNING_IDENTITY" == "Developer ID Application:"* ]] || {
    printf 'Set DISCSHIFT_SIGNING_IDENTITY to an installed Developer ID Application certificate.\n' >&2
    exit 1
}
export DISCSHIFT_REQUIRE_DEVELOPER_ID=1
bash scripts/build-app.sh
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/discshift-xcode-release.XXXXXX")"
ARCHIVE="$STAGING_DIR/DiscShift.xcarchive"
mkdir -p "$ARCHIVE/Products/Applications"
ditto -x -k dist/DiscShift.app.zip "$ARCHIVE/Products/Applications"
APP="$ARCHIVE/Products/Applications/DiscShift.app"
codesign --verify --deep --strict "$APP"
TEAM="$(codesign --display --verbose=4 "$APP" 2>&1 | awk -F= '$1 == "TeamIdentifier" {print $2}')"
[[ -n "$TEAM" && "$TEAM" != 'not set' ]] || { printf 'The signed app has no developer team.\n' >&2; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
# Package the SwiftPM-built app as a standard single-application Xcode archive.
python3 - "$ARCHIVE" "$STAGING_DIR/export-options.plist" "$TEAM" "$DISCSHIFT_SIGNING_IDENTITY" <<'PY'
import datetime, plistlib, sys
from pathlib import Path
archive, options_path = Path(sys.argv[1]), Path(sys.argv[2])
team, identity = sys.argv[3:5]
app_info = plistlib.loads((archive/'Products/Applications/DiscShift.app/Contents/Info.plist').read_bytes())
info = {
    'ArchiveVersion': 2,
    'CreationDate': datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None),
    'Name': 'DiscShift', 'SchemeName': 'DiscShift',
    'ApplicationProperties': {
        'ApplicationPath': 'Applications/DiscShift.app',
        'CFBundleIdentifier': app_info['CFBundleIdentifier'],
        'CFBundleShortVersionString': app_info['CFBundleShortVersionString'],
        'CFBundleVersion': app_info['CFBundleVersion'],
        'SigningIdentity': identity, 'Team': team,
    },
}
(archive/'Info.plist').write_bytes(plistlib.dumps(info))
options_path.write_bytes(plistlib.dumps({
    'method': 'developer-id', 'destination': 'upload', 'signingStyle': 'manual',
    'signingCertificate': identity, 'teamID': team, 'stripSwiftSymbols': True,
}))
PY
printf 'Release archive: %s\n' "$ARCHIVE"
xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$STAGING_DIR/export-options.plist" \
    -exportPath "$STAGING_DIR/upload" -allowProvisioningUpdates
if ! xcodebuild -exportNotarizedApp -archivePath "$ARCHIVE" -exportPath "$STAGING_DIR/notarized"; then
    printf 'The notarized export is not ready. Keep this archive and retry only the export step:\n' >&2
    printf 'xcodebuild -exportNotarizedApp -archivePath "%s" -exportPath "%s"\n' "$ARCHIVE" "$STAGING_DIR/notarized" >&2
    exit 1
fi
APP="$STAGING_DIR/notarized/DiscShift.app"
xcrun stapler validate "$APP"
codesign --verify --deep --strict "$APP"
spctl --assess --type execute --verbose=2 "$APP"
ZIP="$STAGING_DIR/DiscShift-$VERSION-macOS.zip"
ditto -c -k --keepParent "$APP" "$ZIP"
mkdir -p "$STAGING_DIR/download-check"
ditto -x -k "$ZIP" "$STAGING_DIR/download-check"
xcrun stapler validate "$STAGING_DIR/download-check/DiscShift.app"
codesign --verify --deep --strict "$STAGING_DIR/download-check/DiscShift.app"
spctl --assess --type execute --verbose=2 "$STAGING_DIR/download-check/DiscShift.app"
cp -X "$ZIP" dist/
shasum -a 256 "dist/DiscShift-$VERSION-macOS.zip"
printf 'Notarized ZIP ready in dist/. No release has been published.\n'
