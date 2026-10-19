# DiscDock validation

## Unreleased: Developer ID and notarization workflow

The build script now enables hardened runtime and accepts a Developer ID Application signing identity. The separate release workflow submits the app and disk image to Apple, requires an Accepted result, staples tickets, validates signatures/tickets, checks Gatekeeper, and checks that the final ZIP retains its app ticket. It does not publish to GitHub automatically.

- A local 0.8.1/build 10 preparation build passed 43 automated tests, with two opt-in tests skipped. Its ad hoc signature verified with the hardened-runtime flag. No additional runtime exceptions or debug entitlements were added.
- An isolated preview bundle successfully launched the installed HandBrakeCLI, scanned the existing generated six-second source, and advanced to Show. Production app preferences were not used. This checks that enabling hardened runtime retains the external-reader workflow.
- Both scripts pass shell syntax checking. The release workflow refuses to proceed without an explicit Developer ID Application identity and Keychain profile. The normal build refuses ad hoc signing when Developer ID is required.
- No Developer ID Application identity was available on the preparation Mac. No Apple notarization submission was made and no notarized artifact was produced. The complete certificate-backed signing/submission/stapling/Gatekeeper pipeline remains unverified until those credentials are available. The published 0.8 preview is unchanged and remains unnotarized.

## Version 0.8: app identity and guided setup

The app bundle now includes a full macOS icon family generated from the disc-to-video artwork in Assets. The first-run assistant introduces the workflow, checks the local reader, offers dependency installation or official download guidance, and explains online show lookup before saving setup completion. Setup can be deferred and reopened from Help or Settings.

- Final packaging passed 43 automated tests, with the two optional live metadata/reader tests skipped (45 tests total). The six setup tests cover verified completion and persistence, invalid readers, missing encoder support, H.264-only readers, fixed installation arguments and environment, preferring the newly installed reader over a broken custom path, installation failure, and canceling installer child processes.
- Live UI validation used a separate bundle identifier and isolated preferences. All three setup screens were exercised. Check My Mac successfully ran the installed HandBrakeCLI 1.11.2 and found advertised HEVC/H.264 VideoToolbox support plus the installed libdvdcss library. The assistant completed into Source, and relaunch preserved completion. Help and Settings both reopened the assistant.
- Entering an invalid reader produced installation/reselection actions and an active Check Again button. Returning to the working reader recovered successfully. The setup screens were visually inspected in light appearance, including the final icon and fixed footer actions.
- Reader verification uses version and capability checks, with a timeout; it does not read a disc or prove runtime hardware encoding. Every export still requires the actual hardware encoder identifier. Optional DVD support is reported as found, with compatibility deferred to a real scan.
- Installation code invokes an existing Homebrew executable with one fixed formula, no shell interpolation, no Homebrew bootstrap, and no administrator prompt. Installation success/failure/cancellation tests use simulated installers in temporary directories; no fresh Homebrew or dependency installation on a clean Mac was performed. The official-download route without Homebrew has not been exercised on a clean Mac.
- The final app ZIP was extracted outside Documents and its ad hoc signature and bundled icon were verified. This remains an Apple Silicon development preview, without Developer ID signing or notarization. Earlier encoding/container validation remains recorded below; this update does not establish a full physical-episode export or Jellyfin client playback.

## Version 0.7: MP4, M4V, MOV, and MKV options

The Export screen now separates File type from Video codec and File size. MP4 is the default; M4V, MOV, and MKV are selectable. Filename previews, destination previews, per-job settings, staging extensions, and completed filenames follow the chosen type. MOV retains the same hardware HEVC/H.264 settings and bitrate budget. The selected type persists. Review content scrolls while navigation stays visible.

- Final packaging passed 37 automated tests with no failures; the two opt-in metadata/reader tests were skipped in that run. New coverage checks real muxer identifiers, file extensions, per-container subtitle selection, saved file type, every container's queue publication, and explicit consent before leaving out incompatible picture subtitles. MP4 is included in the existing no-overwrite/cancel/failure tests.
- Five separate installed-reader integration runs passed: HEVC in MP4, M4V, MOV, and MKV, plus H.264 in MP4. Each required an actual matching Apple hardware encoder identifier. Independent probing found two audio tracks, one text subtitle, and two chapter entries in every output. HEVC Apple-container files use the hvc1 tag; H.264 MP4 uses avc1. MP4/M4V advertise mp42, while MOV advertises the QuickTime major brand, confirming MOV is a real container selection rather than just a renamed file.
- Apple's native AVFoundation framework loaded the MP4, M4V, MOV, and H.264 MP4 integration files as playable, and fully decoded video plus both audio tracks without reader failure. The original AC3 tracks worked in these native decode tests. Chapter entries were verified by independent media inspection; native chapter-menu behavior was not established by this test.
- In an isolated UI session, the picker offered all four file types. Changing MP4 → M4V → MOV immediately changed the preview extension and explanatory text. A MOV export completed at 100%, reported confirmed HEVC hardware use, and saved an 888 KB file with the expected name. That output also passed native video/audio decoding. Production preferences and destination were not used for these tests.
- MP4/M4V/MOV explicitly select text subtitle tracks, disable automatic burning, and limit audio passthrough to compatible codecs with AAC fallback. MKV preserves the broader original track handling. If selected titles contain picture or unknown subtitle formats, export is blocked until the user chooses MKV or explicitly approves leaving those tracks out. Adding another affected title invalidates the omission decision. No existing media is converted or overwritten automatically.
- Full physical-episode exports in the new containers, subjective synchronization over a full episode, and import/playback on the user's actual Jellyfin clients remain unverified. Prior physical-disc hardware encoding validation is below.

## Version 0.6: hardware encoding and file-size presets

Exports now use HEVC VideoToolbox by default, with H.264 VideoToolbox for compatibility. Both require Apple's hardware encoder. CPU x264/RF encoding is no longer selected. File-size choices use explicit average bitrates, scaled for larger source dimensions or bob motion. Review shows per-file and total estimates; progress reports confirmed hardware use after the actual Apple encoder identifier appears, and completed jobs show actual sizes.

- The final packaging run passed 33 automated tests, with two opt-in metadata/reader tests skipped. Coverage includes encoder arguments, bitrate/size ordering, audio accounting, larger sources/bob, codec-specific hardware evidence, saved preferences, rejecting unavailable hardware, and discarding output without hardware confirmation. Existing cancellation, cleanup, no-overwrite, and wizard checks passed.
- The installed-reader integration test separately passed for both HEVC and H.264. Both six-second outputs retained 720 × 480 / 4:3 / 29.97 fps, two AC3 tracks, a SubRip subtitle, and two chapters. HEVC output was 885,469 bytes and H.264 output was 1,482,443 bytes. Both decoded without reported video errors.
- A physical-DVD title 1 encode starting five minutes in and stopping after 30 seconds completed with the app's Balanced/adaptive HEVC arguments. The actual encoder log reported encvt_Init followed by com.apple.videotoolbox.videoencoder.ave.hevc, proving Apple's hardware HEVC encoder was used. MPEG-2 and AC3 decoding each reported zero decoder errors. Output was 4,503,271 bytes, duration 30.029 seconds, 720 × 480, 4:3, 29.97 fps, HEVC, AC3 stereo, and ASS captions. No chapter boundary occurred in this interior excerpt. A decoded frame was visually compared with the earlier x264 excerpt; full-episode subjective quality and synchronization are not established.
- A separate same-input 30-second re-encode comparison used the existing DVD excerpt. Old x264 RF19 produced 5,036,892 bytes; HEVC Balanced produced 4,481,122 bytes. These are sample-specific results, not a promised saving. Optical reading/seeking dominated the direct-disc test; hardware use does not imply the entire DVD job is GPU-bound.
- An isolated preview app completed the full wizard with the six-second multitrack source and Smaller files selected. The estimate changed from 912 KB at Balanced to 682 KB at Smaller files. Export reached 100%, showed confirmed HEVC hardware use, and reported 682 KB. Independent inspection found a 682,362-byte HEVC file with both audio tracks, subtitle, and both chapters intact; video decoded without errors. Test paths/preferences were isolated from production.
- HandBrakeCLI 1.11.2 explicitly requires a hardware VideoToolbox session for H.264/HEVC. DiscDock additionally checks advertised support and a matching actual encoder identifier. It does not silently switch to a CPU encoder. Hardware decoding is requested, while unsupported decoding, decomb, audio, and disc I/O can still use the CPU.
- The size budget targets compression, not lossless preservation. Existing exports are not modified. A complete physical episode, the user's Jellyfin import/playback clients, and subjective quality across an entire episode still require validation.

## Version 0.5: focused review and explicit actions

The former Library form was removed. The Episodes step now combines inclusion, DVD title/duration, season, and episode assignment in a native table. Its primary Confirm Order & Continue action both confirms the mapping and advances. Destination has a dedicated folder picker and folder/filename preview. The final Export step keeps filenames, episode names, settings, and the export action together. Manual show details have their own form. No confirmation switch is present, and a missing destination offers an active Choose TV Library action.

- The final packaging run passed 28 automated tests with no failures. The opt-in live metadata and reader tests were skipped in that run. The new state-transition test confirms that order can be approved before choosing a destination, that missing destinations block review, that subsequent assignment edits block export, and that duplicate numbers prevent confirmation.
- A separate preview bundle with isolated preferences was used for UI testing so validation destinations did not enter the production app's preferences. A fresh physical DVD scan returned four real titles: 50:49, 49:14, 47:47, and 0:31. The three long titles were included. Live lookup returned both show versions; choosing 1978 filled the show context and season 1 episode names.
- The episode table, season control, native pickers, inclusion checkboxes, numbering popover, destination chooser, folder preview, and final export review were exercised. A deliberately duplicated E02 assignment produced the inline unique-number explanation and prevented confirmation. Applying sequential numbers restored continuation.
- The manual route was tested with the existing generated six-second multitrack MKV. Enter Manually showed a separate form and required a show title. The short title was initially excluded. Including it and editing its episode number to 7 produced the S01E07 filename in Destination and Export review. Export completed at 100% through the new interface.
- Independent inspection of that output found H.264 video, two AC3 audio tracks, a SubRip subtitle track, two chapter markers, and duration 6.016 seconds. The output stayed under the isolated work/ux-validation destination; it is not bundled.
- Default 920 × 740 layout was inspected in the Mac's light appearance. The episode table and primary action were visible together without scrolling. Native views follow system appearance; this pass did not separately inspect dark appearance or another Mac.
- The packaged 0.5.0 ZIP was extracted outside Documents and passed strict ad hoc signature verification. The obsolete production preference pointing to the prior metadata-ui validation folder was cleared. Actual DVD episode identity/order and a full physical-episode export remain for the user to verify.

## Version 0.4: online show identification and confirmed episode order

The five-step wizard is Source → Show → Episodes → Library → Review. It searches TVMaze from a cleaned disc/file name, distinguishes same-name versions by year/network/country, fills the chosen show's title and premiere year, and offers season-specific episode names. These are sequential suggestions in broadcast order, not a verified identification of each DVD title. Continue and Export both require explicit season/order confirmation; a changed mapping invalidates it. Manual lookup, manual show entry, and manual episode numbering remain available. Automatic lookup can be disabled in Settings.

- The final packaging run passed 28 tests with no failures, including the opt-in live TVMaze lookup. One optional reader encode test was skipped. New coverage includes label cleanup, multiple show versions, encoded queries, malformed/service errors, offline fallback, unique-match suggestions, stale/canceled responses, source resets, and confirmation invalidation. Existing queue, failure, cancellation, naming, and settings checks passed.
- The live search for the mounted disc's cleaned label returned both 1978 and 2020 versions of All Creatures Great and Small. The 1978 show returned numbered episodes and seasons from TVMaze.
- The final Release app was exercised through the native UI using the previously encoded 30-second physical-disc excerpt, copied under the disc's label for the search-hint check. Source scanning led to Show with an automatically cleaned query; both versions appeared with neither selected. Choosing the 1978 version loaded the catalog and filled the Library fields. The episode picker offered Horse Sense, Dog Days, It Takes All Kinds, and the rest of season 1.
- With a temporary destination selected, Continue stayed disabled until order confirmation. Changing the picker from E01 to E02 cleared confirmation and disabled Continue again. Reconfirming allowed Review, which displayed the S01E02 filename and Title 1 → Dog Days. No export was started and this test did not establish the excerpt's actual episode identity. Settings showed the online lookup control and disclosure.
- Fresh scans of the mounted DVD root and VIDEO_TS folder stalled before returning titles during this update; both were canceled cleanly. The online lookup itself succeeded. Earlier physical-disc scan and excerpt results remain recorded below, but this update does not establish a successful fresh full-disc scan or the actual episode order. The app was reset to the mounted DVD with no selected show or confirmed order, and the temporary destination preference was cleared.
- The packaged 0.4.0 app ZIP was extracted outside Documents and passed strict ad hoc signature verification. No sample metadata or validation files are bundled. Full physical-episode export and Jellyfin import remain unverified.

## Version 0.3.1: real sources only

The shipped app no longer includes sample mode, hardcoded episode lists, a sample menu item, sample destinations, or a show-specific field prompt. Startup has no series, year, or titles until the user enters details and scans a source. Choosing a different source clears stale show details, scan results, completed queue display, and diagnostics. Next Disc explicitly keeps entered show details and the next episode number for one new source.

The packaging run passed 16 tests with no failures. The opt-in reader encode test was skipped for this update. Regression coverage includes empty startup, source-change reset, mandatory real destination selection, and preserving show details only through Next Disc. Tests use isolated fixtures that are not part of the shipping app.

The updated app was launched against the mounted physical DVD and scanned it successfully: actual titles were 50:49, 49:14, 47:47, and 0:31. The Library step showed blank series/year fields and required a real library folder, with no sample controls or prefilled show details. The app was left at this real-disc Library step without starting an export.


## Version 0.3: native macOS wizard

The interface was rebuilt as Source → Episodes → Library → Review, followed by export progress. It uses a standard title bar and toolbar, native title table, grouped forms, macOS Settings window, diagnostic sheet, and system appearance/accent color. The dark appearance was inspected live; a separate light-appearance visual pass has not been performed.

- All 16 automated tests passed with the installed-reader integration test enabled. Normal packaging runs 15 tests and skips the opt-in reader test. New tests cover forward/back navigation, selection and metadata gates, duplicate numbers, failed scans, safe sample review, and continuing numbering for the next disc.
- The complete wizard was exercised with a generated six-second interlaced source. Scanning advanced to title selection; no titles were selected by the duration heuristic. Continue remained disabled until a title was chosen. Library required the series title and destination. A manually entered episode number of 7 appeared as `DiscDock Wizard Test S01E07.mkv` on Review and in the completed output.
- The guided export reached 100% and Complete. Independent media inspection confirmed H.264 video, two AC3 audio tracks, one subtitle track, and two chapter markers.
- The final packaged sample was walked through to Review without a destination and could not export. Entering duplicate episode numbers disabled Continue and displayed the correction message; Renumber restored continuation. Native Settings and Activity opened and were inspected. The episode fields and completed-step buttons were checked through the accessibility tree.
- Default window size is 920 × 740 with scrollable forms; the main window no longer forces a light appearance or uses a custom sidebar.
- The reader engine and encoding command are unchanged from the physical-disc validation below. A complete physical episode and Jellyfin import remain unverified.

## Version 0.2: prior reader and physical-disc validation

Validated locally on October 18, 2026, on an Apple M4 Max Mac running macOS 27.0.1, Xcode 27.1 / Swift 6.4. Reader: Homebrew HandBrakeCLI 1.11.2 and libdvdcss 1.6.0, both arm64. Neither dependency is bundled.

## Passed

- Release build, local app launch, and ad hoc signature verification of the packaged app outside the iCloud/File Provider folder. The app ZIP preserves that verified bundle without Finder metadata.
- 12 automated tests passed with the reader integration test enabled. Normal packaging runs 11 tests and skips the one opt-in reader test. No failures.
- SwiftUI inspection: current disc, sample mode, queue, activity, settings, title selection, first episode changes, renumbering, accessible field labels, filename preview, and scrolling in the default 1180 × 820 window.
- Quitting the final packaged app during a live physical-disc scan terminated both DiscDock and HandBrakeCLI without leaving a running reader process.
- Sample mode cannot export. Duplicate selected episode numbers disable export with an explanation. Reader and encoding preferences round-trip.
- A six-second generated interlaced source completed scan → selection → export through the app UI, using a temporary validation library. Its output used the expected series/season/episode filename. A repeat export showed the existing-file warning and left the completed file intact.
- Installed-reader integration retained two AC3 audio tracks, a subtitle track, and two chapter markers from a generated MKV source. A separate forced-fallback check produced AAC using CoreAudio.
- Adaptive, off, and bob filter arguments were accepted by the installed CLI. The synthetic bob result contained approximately 59.94 frames/second, compared with 29.97 for off.
- Queue tests verified sequential completion, no overwrite, failure stopping later jobs, cancellation, partial-file cleanup, and concurrent draining of 200 KB of diagnostics.
- The physical USB DVD drive (HL-DT-ST SP80NB60) and mounted ALLCREATURESGREATANDSMALLDISC1 volume were detected. Both a command-line scan and an in-app scan completed successfully.

## Physical disc results

| Title | Duration | Chapters | Selection heuristic |
| --- | --- | --- | --- |
| 1 | 50:49 | 10 | Selected |
| 2 | 49:14 | 10 | Selected |
| 3 | 47:47 | 10 | Selected |
| 4 | 0:31 | 3 | Unselected, possible extra |

The scan reported 720 × 480, NTSC 29.97 fps, 8:9 pixel aspect, 4:3 display, English AC3 stereo, and one subtitle/caption entry per title. These are source properties, not proof of edition, region, or broadcast episode identity.

A 30-second excerpt of title 1, starting five minutes in, encoded with the same balanced/adaptive arguments used by DiscDock, plus a test-only start and duration limit. The MKV was 720 × 480 H.264, 4:3 with 8:9 pixel aspect, approximately 29.97 fps, English AC3 stereo, and an ASS subtitle/caption track. HandBrake reported zero MPEG-2 and AC3 decoder errors. The finished excerpt decoded without reported errors and played visibly in IINA. This short interior excerpt contained no chapter boundary; chapter retention was verified separately with the generated source.

Canceling a later physical-disc scan returned the app to an idle, usable state with no partial title selection. Later scans were slower than the initial scan. Diagnostics included failed raw-device attempts followed by successful filesystem-based DVD reading. The successful scan and excerpt establish readability of this mounted disc with this installation; they do not establish compatibility with other protected DVDs or region configurations.

## Still unverified

- A complete 48–51 minute episode and a multi-episode physical-disc queue.
- Subjective motion quality, audio sync, and subtitles across a whole episode; adaptive and bob need comparison on representative scenes by a viewer.
- Exact DVD edition/region and the mapping from title numbers to broadcast episode numbers.
- Jellyfin importing and playback on the user's actual clients and destination library.
- Disc removal during encoding, automatic ejection, network-share interruption, full destination disk, and power-loss recovery.
- Other Macs, Intel builds, macOS 14, notarization, and distribution outside this local development environment.

Quitting now requests cancellation and waits for the operation task to finish cleanup. Force quitting can still leave staging files. The queue remains in memory only.
