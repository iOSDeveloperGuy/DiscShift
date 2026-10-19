# Automatic updates and publishing

DiscShift 0.9.0 introduces [Sparkle 2](https://sparkle-project.org/documentation/). Users of 0.8.2 must install this version once and move it to Applications. Subsequent releases can be installed from the app. The DiscShift menu includes **Check for Updates…**; Settings includes daily automatic checks and optional background downloads. Downloads do not silently restart the app. Checks and relaunches wait for disc operations and setup to finish. Updates installed on quit follow the existing operation cleanup behavior.

Update archives are Developer ID signed, notarized and stapled, then Ed25519 signed. The feed itself is signed, and the app requires archive verification before extraction. Sparkle system profiling is disabled. Update checks contact GitHub, which receives normal network request information; discs, media, and local paths are not uploaded. Sparkle is MIT licensed and its license is bundled in Resources.

The public feed lives at `https://raw.githubusercontent.com/iOSDeveloperGuy/DiscShift/updates/appcast.xml`. Only the `updates` branch is changed by feed publication. Avoid editing this file manually: any change invalidates its signature. The private update key is backed up in this Mac's login Keychain under the Sparkle account `com.iosdeveloperguy.discshift`. `release.json` contains only its public key. Back up the private key securely before erasing or replacing the Mac.

## Push to release

1. Change `version` and increment `build` in `release.json`. The build number must increase across every public release. Keep `prerelease: true` during previews.
2. Add `release-notes/VERSION.md` and push to `main`.
3. The **Release** workflow tests, builds, signs all nested Sparkle helpers, notarizes and staples the app and disk image, verifies Gatekeeper, signs the update feed, and publishes a GitHub release.
4. It downloads the published ZIP and compares its SHA-256 before updating the feed. Installed apps only see an update after that check passes.

Ordinary pushes and pull requests run **Checks** without signing credentials. Only a main-branch version-file change, or a manual **Release → Run workflow** on main, can release. Releases run sequentially. Re-running an already public version downloads its existing ZIP and repairs/re-publishes the feed without rebuilding or replacing its public archive. A failed run leaves the previous feed intact; release artifacts and notarization reports are retained for 30 days, including failed runs. Apple ticket delivery and Gatekeeper network checks retry up to five times; notarization submissions are not automatically repeated. A notarization timeout must be investigated using the retained submission ID before submitting again. The ZIP is the updater payload; the DMG is also retained as a workflow artifact.

## One-time GitHub credentials

These encrypted secrets are configured in the repository's **release** environment, restricted to deployments from `main`. Do not grant fork pull requests or `pull_request_target` access to these credentials. Use GitHub-hosted disposable macOS runners, not a public-repository runner on your personal Mac.

| Secret | Purpose |
| --- | --- |
| `DEVELOPER_ID_P12_BASE64` | Base64 of one Developer ID Application identity, including its private key, exported as a password-protected PKCS#12. Base64 is transport encoding, not encryption. |
| `DEVELOPER_ID_P12_PASSWORD` | Password protecting that PKCS#12. |
| `APPLE_API_KEY_P8` | A team App Store Connect API private key authorized for notarization. |
| `APPLE_API_KEY_ID` | Apple's API key ID. |
| `APPLE_API_ISSUER_ID` | Apple's API issuer ID. |
| `SPARKLE_ED_PRIVATE_KEY` | Sparkle Ed25519 private key exported for this application's Keychain account. |

Moving a local signing private key to GitHub requires the owner's explicit approval. No private keys are committed, placed in release assets, or embedded in the app. A dedicated Developer-role team API key is used for notarization and backed up in the local `discshift-ci-notary` Keychain profile. API keys and certificate files are written with restrictive permissions in the temporary runner directory, imported only after tests pass, and deleted in an always-run cleanup step. Release signing keys must be backed up in a secure location. Repository administrators and anyone able to change a main-branch workflow can potentially use its release secrets, so protect write access and review workflow changes.

See [GitHub's Xcode signing guide](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications) and [Apple's notarization authentication guidance](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow). The signing team is `UJ27S8B847`. Never paste passwords or private keys into chat.

## Local release alternative

Use the existing Xcode account and local Keychain without transferring any key to GitHub:

```sh
DISCSHIFT_SIGNING_IDENTITY='Developer ID Application: Your Name (TEAMID)' bash scripts/notarize-with-xcode.sh
python3 scripts/release.py prepare --tools /path/to/build/artifacts/sparkle/Sparkle/bin --archive dist/DiscShift-VERSION-macOS.zip
python3 scripts/release.py publish --commit HEAD
```

Commit and push the reviewed source before publishing so the release tag points to the exact source. `prepare` verifies the signature, ticket, Gatekeeper, bundle identity, version, public update key and feed URL before generating and verifying a signed feed. `publish` only accepts a prepared release, verifies the public ZIP, and atomically commits the signed feed using GitHub's API. The existing local Xcode notarization script prints a resume command if Apple's processing is still pending.

A complete update-install test needs an older signed build and a newer signed, notarized build. A successful compile or a no-update check alone does not prove archive replacement and relaunch. See `VALIDATION.md` for what has actually been exercised.
