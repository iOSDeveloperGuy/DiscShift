# Signing and notarizing a macOS release

The public 0.8 preview is ad hoc signed and is **not notarized**. Adding this workflow does not change that published download. A future release is ready for public distribution only after Apple accepts both submissions, ticket validation succeeds, and Gatekeeper accepts the artifacts.

## One-time account setup

1. Use an active Apple Developer Program membership. The account holder creates a **Developer ID Application** certificate in Xcode or the Apple Developer account. An Apple Development or Apple Distribution certificate cannot replace it for this workflow.
2. Install the signing identity, including its matching private key, in this Mac's Keychain. Confirm it appears in `security find-identity -v -p codesigning`. Keep the private key out of this repository and GitHub release assets.
3. Store notarization credentials in Keychain using an interactive prompt:

   ```sh
   DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
   xcrun notarytool store-credentials discdock-notary
   ```

   Supply the Apple Account, team ID, and app-specific password locally when prompted. Never paste passwords into chat, a commit, an environment file, or a release note. An App Store Connect API key is also supported by Apple's tool; keep its private key local.

Apple's account-holder requirement and credential guidance are documented in [Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/) and [Customizing the notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow).

## Build and verify

With the certificate and Keychain profile available:

```sh
DISCDOCK_SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' \
DISCDOCK_NOTARY_PROFILE=discdock-notary \
DISCDOCK_VERSION=0.8.1 \
DISCDOCK_BUILD_NUMBER=10 \
bash scripts/notarize-release.sh
```

The script validates notarization credentials, runs tests, builds Release, enables the hardened runtime, and signs with a secure timestamp. The app has no additional runtime exceptions or debug entitlements. It then:

1. Submits the signed app ZIP and requires Apple's `Accepted` result.
2. Staples and validates the app ticket, checks the signature, and asks Gatekeeper to assess the app.
3. Creates a drag-to-Applications disk image containing the stapled app, signs the image, and requires Apple's acceptance of the disk image.
4. Staples the disk image ticket, validates its signature and integrity, and asks Gatekeeper to assess it.
5. Verifies that the final ZIP retains the app's ticket after extraction, then writes versioned ZIP/DMG artifacts and SHA-256 checksums to `dist/`.

Submission reports stay in `dist/notarization-VERSION/`, which is ignored by Git. Temporary release work stays outside File Provider folders. A timeout or rejection stops the script and retains reports and the staging directory. If a submission is still processing, use `notarytool info` or `notarytool wait` with the reported ID and the same Keychain profile. Do not repeatedly upload the same pending submission. Fix any reported rejection before restarting the release.

The script does **not** publish to GitHub. Inspect the resulting artifacts before uploading them to a new release. Keep the existing preview download available until the signed replacement is verified. Build architecture follows the local Swift build; the current downloadable build is Apple Silicon. Notarization does not establish compatibility with Intel, older macOS releases, or every DVD/Jellyfin client.

## Local development

`bash scripts/build-app.sh` still creates an ad hoc signed local build when no identity is supplied. Both modes enable hardened runtime. To sign locally with Developer ID without submitting to Apple, set `DISCDOCK_SIGNING_IDENTITY` while running that build script. This alone does not notarize the app.

The reader and optional DVD libraries remain separately installed dependencies. No external reader code, signing certificate, or notarization credential is bundled in the app.
