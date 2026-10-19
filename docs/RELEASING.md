# Signing and notarizing a macOS release

DiscShift 0.8.2 is Developer ID signed and notarized, with a stapled ticket validated after extracting its ZIP. A future release is ready only after notarized export and ticket, signature, and Gatekeeper checks pass.

## One-time signing setup

1. Use an active Apple Developer Program membership. The account holder creates a **Developer ID Application** certificate in Xcode or the Apple Developer account. Apple Development and Apple Distribution certificates serve different distribution methods.
2. Keep the signing identity and matching private key in this Mac's Keychain. Confirm it appears in `security find-identity -v -p codesigning`. Never commit or publish the private key.
3. Sign into the matching team in Xcode → Settings → Apple Accounts. macOS may ask you locally to allow the signing tool to use the key.

See Apple's [Developer ID certificate requirements](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/) and [notarized app distribution instructions](https://help.apple.com/xcode/mac/current/en.lproj/dev88332a81e.html).

## Recommended: use the account signed into Xcode

This is the path used for 0.8.2. It does not require a separate app-specific password or API key:

```sh
DISCSHIFT_SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
DISCSHIFT_VERSION=0.8.2 \
DISCSHIFT_BUILD_NUMBER=11 \
bash scripts/notarize-with-xcode.sh
```

The script runs tests, builds Release with hardened runtime, and signs with a secure timestamp. It wraps the SwiftPM-built app in a standard single-app Xcode archive, uses the authenticated Xcode account to upload for notarization, and exports the notarized app. It validates the app ticket, strict signature, and Gatekeeper acceptance, then checks the same properties after extracting the final ZIP. Only then does it write `dist/DiscShift-VERSION-macOS.zip` and print its SHA-256 checksum.

If Apple is still processing, retain the printed archive path. Retry only `xcodebuild -exportNotarizedApp` against that archive. Do not upload the same pending build again. Nothing is published to GitHub automatically. This path produces a notarized app ZIP.

## Alternative: notarytool and a disk image

For automation or a notarized drag-to-Applications DMG, create a local Keychain profile interactively:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
xcrun notarytool store-credentials discshift-notary
```

Supply your Apple Account, team ID, and app-specific password locally when prompted. Never put passwords in chat, a commit, an environment file, or release notes. Apple's tool also supports App Store Connect API credentials; keep private keys local. See [Apple's credential guidance](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).

```sh
DISCSHIFT_SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
DISCSHIFT_NOTARY_PROFILE=discshift-notary \
DISCSHIFT_VERSION=0.8.2 \
DISCSHIFT_BUILD_NUMBER=11 \
bash scripts/notarize-release.sh
```

This route validates Keychain access, builds and signs, submits the app ZIP, and requires Apple's Accepted result before stapling and checking the app. It also creates a drag-to-Applications DMG, signs and submits that container, requires acceptance, and validates its ticket, signature, integrity, and Gatekeeper assessment. A final extraction check verifies the ZIP's app ticket. Versioned ZIP/DMG files and SHA-256 checksums appear in `dist/` only after all checks pass.

Submission reports stay in `dist/notarization-VERSION/`, ignored by Git. Temporary release work stays outside File Provider folders. A timeout or rejection retains the reports and staging directory. Use `notarytool info` or `notarytool wait` with the reported submission ID and the same Keychain profile if a submission is still processing. Fix rejections before making a new submission. This alternative DMG workflow was not used for the 0.8.2 release.

## Local builds and compatibility

`bash scripts/build-app.sh` creates an ad hoc signed local build by default. Both signing modes enable hardened runtime, without additional runtime exceptions or debug entitlements. Set `DISCSHIFT_SIGNING_IDENTITY` to sign locally with Developer ID; signing alone does not notarize the app.

Use `DISCSHIFT_*` environment variables for build, signing, and live tests. The app identifier is `com.iosdeveloperguy.discshift`. A first-launch importer copies only recognized workflow settings from one matching application in the same publisher namespace, without overwriting current settings or guessing between ambiguous sources.

Inspect and verify final artifacts before uploading a new GitHub release. Build architecture follows the local Swift build; the current release is Apple Silicon. Notarization does not establish Intel/older-macOS compatibility or every DVD/Jellyfin playback scenario. HandBrakeCLI and optional DVD libraries remain separate dependencies. Certificates and notarization credentials are never bundled with the app.
