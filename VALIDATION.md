# DiscShift validation

## Version 0.8.2: app identity and settings import

- The app identifier is `com.iosdeveloperguy.discshift`. App names, executable, source modules, staging folder, build variables, documentation, and release artifacts use DiscShift. The working source and release bundle are checked for stale product-name references.
- The signed build passed 49 automated tests, with two optional live tests skipped (51 total). Six settings-import tests cover preserving setup completion and library preferences, importing once, preserving current values, copying only known settings, ignoring other publishers and nested preview domains, skipping ambiguous sources, rejecting invalid settings, and supporting settings saved before optional encoding fields existed.
- First launch can import recognized workflow settings from exactly one application at the same level in the publisher's preference namespace. It preserves current values and leaves the source preferences intact. No previous product identifier is embedded in the app. Ambiguous matches are not imported.
- Developer ID signing enables hardened runtime and a secure timestamp. The release app has no additional runtime exceptions or debug entitlements. Apple notarized version 0.8.2/build 11 with the new identifier. The stapled ticket validates, strict signature verification passes, and Gatekeeper accepts the app as Notarized Developer ID.
- The notarized app was launched with its new identifier on the development Mac. Its first-launch importer preserved all eight existing recognized settings, including reader paths, encoding preferences, lookup choice, ejection choice, and destination. The import marker was saved. The prior setup state was preserved.
- Case-insensitive checks of the current source and release bundle found no stale product-name references. Superseded release downloads were retired from the public release list.

## Prior encoding and interface checks

- HEVC and H.264 VideoToolbox encoding were verified with the installed reader. Separate six-second integration outputs covered HEVC in MP4, M4V, MOV, and MKV, plus H.264 in MP4. Actual Apple hardware encoder identifiers were required. Independent inspection found two audio tracks, a text subtitle, and chapter data.
- Apple's native media framework loaded and decoded the Apple-container test outputs, including both audio tracks. MOV was confirmed as a QuickTime container rather than a renamed MP4. Native chapter-menu behavior was not established.
- A short physical-DVD excerpt encoded with HEVC hardware acceleration, with zero reported MPEG-2 or AC3 decoder errors. This establishes a short excerpt, not a full episode or universal disc compatibility.
- Isolated UI checks exercised source scanning, show lookup, manual entry, episode matching, unique episode numbers, mandatory order confirmation, destination selection, file-type changes, and a completed MOV export. Existing-file protection, cancellation cleanup, and sequential queues are covered by automated tests.
- The first-run assistant has been exercised with an installed HandBrakeCLI, including invalid-reader recovery, saved completion, and reopening from Help and Settings. Installer success, failure, and cancellation use simulated installers in tests. A clean-Mac dependency installation has not been validated.

## Current limits

A full physical episode and multi-episode DVD queue, subjective audio synchronization over a full episode, actual Jellyfin client playback, Intel builds, and macOS 14 remain unverified. Disc removal, network-share interruption, full destinations, and power-loss recovery need further testing. Jobs are not persistent or resumable. Signing and notarization do not establish those playback or compatibility results.

## Automatic updates (0.9.0)

- Sparkle 2.10.0 is pinned in Package.resolved, embedded with preserved symlinks, and each nested helper is re-signed before the framework and app.
- An Apple-signed build with Sparkle has passed notarization, stapled-ticket validation, strict deep signature validation, and Gatekeeper assessment.
- Sparkle generated and verified both the signed appcast and ZIP enclosure signature using the app's update signing key. The generated feed restricts this Apple Silicon build to arm64 and macOS 14+.
- Native Settings shows the installed version, automatic checks, optional background downloads, and Check for Updates. Automatic checks start after the setup assistant is dismissed.
- Update tests cover postponing a relaunch until idle, running its callback once, cancellation, and preventing another disc operation once installation begins.
- GitHub workflow syntax passes actionlint. The release environment accepts only the main branch. The dedicated Apple notarization API credential has validated successfully.
- Full GitHub release execution and in-app archive replacement/relaunch are pending live verification.
