import XCTest
import DiscShiftCore
@testable import DiscShift

final class AppTests: XCTestCase {
    @MainActor private func fixture(script: String, advertisesHardware: Bool = true, confirmsHardware: Bool = true) throws -> (AppModel, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let reader = root.appendingPathComponent("test-reader")
        let capabilities = advertisesHardware ? "vt_h265\\nvt_h264" : "x264"
        let proof = confirmsHardware ? "printf '[test] encvt_Init: com.apple.videotoolbox.videoencoder.ave.hevc\\n' >&2\n" : ""
        let preamble = "if [ \"$1\" = \"--help\" ]; then printf '\(capabilities)\\n'; exit 0; fi\n"
        try Data(("#!/bin/sh\n" + preamble + proof + script).utf8).write(to: reader)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: reader.path)
        let defaults = UserDefaults(suiteName: "DiscShiftTests-" + UUID().uuidString)!
        defaults.set(false, forKey: "automaticShowLookup")
        let model = AppModel(defaults: defaults, discoverMountedDiscs: false)
        model.executable = reader.path
        model.setSource(root)
        model.destination = root.appendingPathComponent("Library")
        model.series = "Test / Series"; model.year = "1978"
        model.choices = [1, 2].map { EpisodeChoice(title: DiscTitle(index: $0, duration: 1800, chapters: 2), selected: true, episode: $0) }
        model.episodeOrderConfirmed = true
        return (model, root)
    }
    private let writer = """
    while [ "$#" -gt 0 ]; do
      if [ "$1" = "-o" ]; then shift; output="$1"; fi
      shift
    done
    printf 'Progress: {"State":"WORKING","Working":{"Progress":0.5,"ETASeconds":2}}\n'
    printf 'encoded test data' > "$output"
    """

    @MainActor func testQueuePublishesFilesAndNeverOverwrites() async throws {
        let (model, root) = try fixture(script: writer)
        defer { try? FileManager.default.removeItem(at: root) }
        model.export(); await model.operationTask?.value
        XCTAssertEqual(model.jobs.map(\.status), ["Complete", "Complete"])
        XCTAssertEqual(model.totalProgress, 1)
        XCTAssertFalse(model.busy)
        let first = try XCTUnwrap(model.jobs.first?.output)
        let original = try Data(contentsOf: first)
        XCTAssertTrue(first.path.hasSuffix("Test Series (1978)/Season 01/Test Series S01E01.mp4"))
        model.export(); await model.operationTask?.value
        XCTAssertEqual(model.jobs.map(\.status), ["Failed", "Canceled"])
        XCTAssertEqual(try Data(contentsOf: first), original)
        XCTAssertTrue(model.error?.contains("Nothing was overwritten") == true)
    }
    @MainActor func testFailureAndCancellationRemoveStagingAndStopQueue() async throws {
        for script in [writer + "\nexit 3", "exec /bin/sleep 30"] {
            let (model, root) = try fixture(script: script)
            defer { try? FileManager.default.removeItem(at: root) }
            model.export()
            let cancel = script.hasPrefix("exec")
            if cancel { try await Task.sleep(nanoseconds: 200_000_000); model.cancel() }
            await model.operationTask?.value
            XCTAssertEqual(model.jobs.first?.status, cancel ? "Canceled" : "Failed")
            XCTAssertEqual(model.jobs.last?.status, "Canceled")
            XCTAssertFalse(model.busy)
            for job in model.jobs { XCTAssertFalse(FileManager.default.fileExists(atPath: job.output.path)) }
            let staging = model.destination!.appendingPathComponent(".discshift-staging")
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: staging.path), [])
        }
    }
    @MainActor func testDuplicateNumbersCannotExport() throws {
        let (model, root) = try fixture(script: writer)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertTrue(model.canExport)
        model.choices[1].episode = 1
        XCTAssertFalse(model.canExport)
        XCTAssertTrue(model.exportHint?.contains("unique") == true)
        model.export(); XCTAssertTrue(model.jobs.isEmpty)
        model.renumber(); XCTAssertTrue(model.canExport)
    }
    @MainActor func testEngineDrainsVerboseDiagnosticsAndParsesScan() async throws {
        let (model, root) = try fixture(script: """
        /usr/bin/head -c 200000 /dev/zero | /usr/bin/tr '\\000' x >&2
        printf 'JSON Title Set: {"TitleList":[{"Index":1,"Duration":{"Hours":0,"Minutes":30,"Seconds":0},"Geometry":{"Width":720,"Height":480},"ChapterList":[{}]}]}\n'
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        model.scan(); await model.operationTask?.value
        XCTAssertNil(model.error)
        XCTAssertEqual(model.step, .identify)
        XCTAssertEqual(model.choices.count, 1)
        XCTAssertEqual(model.choices.first?.title.duration, 1800)
        XCTAssertEqual(model.activity.count, 120_000)
    }
    @MainActor func testWizardGatesSelectionAndLibraryDetails() throws {
        let (model, root) = try fixture(script: writer)
        defer { try? FileManager.default.removeItem(at: root) }
        model.step = .episodes
        model.continueWizard(); XCTAssertEqual(model.step, .library)
        model.series = ""
        XCTAssertFalse(model.canContinue)
        model.continueWizard(); XCTAssertEqual(model.step, .library)
        model.series = "Test Series"; model.destination = nil
        XCTAssertFalse(model.canContinue)
        model.navigate(to: .review); XCTAssertEqual(model.step, .library)
        model.destination = root.appendingPathComponent("Library")
        model.choices[1].episode = model.choices[0].episode
        XCTAssertFalse(model.canContinue)
        model.renumber(); model.episodeOrderConfirmed = true; XCTAssertTrue(model.canContinue)
        model.continueWizard(); XCTAssertEqual(model.step, .review)
        model.goBack(); XCTAssertEqual(model.step, .library)
        model.navigate(to: .episodes); XCTAssertEqual(model.step, .episodes)
        for index in model.choices.indices { model.choices[index].selected = false }
        XCTAssertFalse(model.canContinue)
        model.continueWizard(); XCTAssertEqual(model.step, .episodes)
    }
    @MainActor func testNewSessionContainsNoShowOrTitleData() {
        let defaults = UserDefaults(suiteName: "DiscShiftTests-" + UUID().uuidString)!
        defaults.set(false, forKey: "automaticShowLookup")
        let model = AppModel(defaults: defaults, discoverMountedDiscs: false)
        XCTAssertEqual(model.step, .source)
        XCTAssertTrue(model.series.isEmpty); XCTAssertTrue(model.year.isEmpty)
        XCTAssertTrue(model.choices.isEmpty); XCTAssertTrue(model.jobs.isEmpty)
        XCTAssertNil(model.source); XCTAssertNil(model.destination)
        XCTAssertFalse(model.canContinue); XCTAssertFalse(model.canExport)
    }
    @MainActor func testChangingSourceClearsPreviousShowAndScanData() throws {
        let (model, root) = try fixture(script: writer)
        defer { try? FileManager.default.removeItem(at: root) }
        let next = root.appendingPathComponent("different-show")
        try FileManager.default.createDirectory(at: next, withIntermediateDirectories: true)
        model.season = 4; model.firstEpisode = 12; model.step = .review
        model.setSource(next)
        XCTAssertEqual(model.source, next); XCTAssertEqual(model.step, .source)
        XCTAssertTrue(model.series.isEmpty); XCTAssertTrue(model.year.isEmpty)
        XCTAssertTrue(model.choices.isEmpty); XCTAssertTrue(model.jobs.isEmpty)
        XCTAssertEqual(model.season, 1); XCTAssertEqual(model.firstEpisode, 1)
        XCTAssertNotNil(model.destination)
        XCTAssertFalse(model.canExport)
    }
    @MainActor func testNextDiscContinuesAfterCompletedEpisodeNumbers() async throws {
        let (model, root) = try fixture(script: writer)
        defer { try? FileManager.default.removeItem(at: root) }
        model.export(); await model.operationTask?.value
        model.startNextDisc()
        XCTAssertEqual(model.step, .source); XCTAssertEqual(model.firstEpisode, 3)
        XCTAssertTrue(model.jobs.isEmpty); XCTAssertTrue(model.choices.isEmpty)
        XCTAssertEqual(model.series, "Test / Series")
        let next = root.appendingPathComponent("next-disc")
        try FileManager.default.createDirectory(at: next, withIntermediateDirectories: true)
        model.setSource(next)
        XCTAssertEqual(model.series, "Test / Series"); XCTAssertEqual(model.year, "1978")
        XCTAssertEqual(model.firstEpisode, 3); XCTAssertTrue(model.choices.isEmpty)
        // The explicit continuation applies to one new source only.
        model.setSource(root)
        XCTAssertTrue(model.series.isEmpty); XCTAssertEqual(model.firstEpisode, 1)
    }
    @MainActor func testOrderMustBeConfirmedAndEditsInvalidateIt() throws {
        let (model, root) = try fixture(script: writer)
        defer { try? FileManager.default.removeItem(at: root) }
        model.episodeOrderConfirmed = false
        XCTAssertFalse(model.canExport)
        model.export(); XCTAssertTrue(model.jobs.isEmpty)
        model.episodeOrderConfirmed = true; XCTAssertTrue(model.canExport)
        model.choices[0].episode = 8; XCTAssertFalse(model.episodeOrderConfirmed)
        model.episodeOrderConfirmed = true
        model.season = 2; XCTAssertFalse(model.canExport)
        model.episodeOrderConfirmed = true
        model.choices[1].selected = false; XCTAssertFalse(model.episodeOrderConfirmed)
    }
    @MainActor func testConfirmOrderActionAdvancesBeforeChoosingDestination() throws {
        let (model, root) = try fixture(script: writer)
        defer { try? FileManager.default.removeItem(at: root) }
        model.destination = nil; model.episodeOrderConfirmed = false; model.step = .episodes
        XCTAssertTrue(model.canContinue); XCTAssertFalse(model.canExport)
        model.continueWizard()
        XCTAssertEqual(model.step, .library); XCTAssertTrue(model.episodeOrderConfirmed)
        XCTAssertFalse(model.canContinue)
        model.destination = root.appendingPathComponent("Chosen Library")
        model.continueWizard(); XCTAssertEqual(model.step, .review)
        model.choices[0].episode = 9
        XCTAssertFalse(model.canExport)
        model.export(); XCTAssertTrue(model.jobs.isEmpty)
        model.step = .episodes; model.choices[0].episode = 2
        model.continueWizard(); XCTAssertEqual(model.step, .episodes)
        XCTAssertTrue(model.episodeValidationMessage?.contains("unique") == true)
        model.renumber(); model.continueWizard()
        XCTAssertEqual(model.step, .library); XCTAssertTrue(model.episodeOrderConfirmed)
    }
    @MainActor func testFailedScanDoesNotAdvanceWizard() async throws {
        let (model, root) = try fixture(script: "exit 3")
        defer { try? FileManager.default.removeItem(at: root) }
        model.scan(); await model.operationTask?.value
        XCTAssertEqual(model.step, .source)
        XCTAssertFalse(model.busy); XCTAssertFalse(model.scanning)
        XCTAssertTrue(model.choices.isEmpty); XCTAssertNotNil(model.error)
    }
    @MainActor func testSettingsRoundTrip() {
        let defaults = UserDefaults(suiteName: "DiscShiftTests-" + UUID().uuidString)!
        defaults.set(false, forKey: "automaticShowLookup")
        let model = AppModel(defaults: defaults, discoverMountedDiscs: false)
        model.filter = .bob; model.profile = .quality; model.encoder = .h264; model.container = .mov; model.ejectAfter = true
        model.saveSettings()
        let restored = AppModel(defaults: defaults, discoverMountedDiscs: false)
        XCTAssertEqual(restored.filter, .bob); XCTAssertEqual(restored.profile, .quality)
        XCTAssertEqual(restored.encoder, .h264)
        XCTAssertEqual(restored.container, .mov)
        XCTAssertTrue(restored.ejectAfter)
    }
    @MainActor func testUnavailableHardwareEncoderStopsBeforeCreatingOutputs() async throws {
        let (model, root) = try fixture(script: writer, advertisesHardware: false)
        defer { try? FileManager.default.removeItem(at: root) }
        model.export(); await model.operationTask?.value
        XCTAssertEqual(model.jobs.map(\.status), ["Failed", "Canceled"])
        XCTAssertTrue(model.error?.contains("hardware encoder") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: model.jobs[0].output.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: model.destination!.path))
    }
    @MainActor func testUnconfirmedHardwareOutputIsDiscarded() async throws {
        let (model, root) = try fixture(script: writer, confirmsHardware: false)
        defer { try? FileManager.default.removeItem(at: root) }
        model.export(); await model.operationTask?.value
        XCTAssertEqual(model.jobs.map(\.status), ["Failed", "Canceled"])
        XCTAssertTrue(model.error?.contains("did not confirm") == true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: model.jobs[0].output.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: model.destination!.appendingPathComponent(".discshift-staging").path), [])
    }
    @MainActor func testEveryContainerSetsPreviewStagingAndPublishedFilename() async throws {
        for container in ExportContainer.allCases {
            let (model, root) = try fixture(script: writer)
            defer { try? FileManager.default.removeItem(at: root) }
            model.container = container
            XCTAssertTrue(model.filenamePreview?.hasSuffix("." + container.fileExtension) == true)
            model.export(); await model.operationTask?.value
            XCTAssertEqual(model.jobs.map(\.status), ["Complete", "Complete"])
            XCTAssertEqual(model.jobs.first?.container, container)
            XCTAssertTrue(model.jobs.allSatisfy { $0.output.pathExtension == container.fileExtension })
        }
    }
    @MainActor func testPictureSubtitlesRequireExplicitDecisionForAppleContainers() throws {
        let (model, root) = try fixture(script: writer)
        defer { try? FileManager.default.removeItem(at: root) }
        model.choices[0] = EpisodeChoice(title: DiscTitle(index: 1, duration: 1800, chapters: 2, subtitleTracks: [SubtitleTrack(index: 1, isText: false)]), selected: true, episode: 1)
        model.episodeOrderConfirmed = true
        XCTAssertEqual(model.container, .mp4); XCTAssertTrue(model.needsSubtitleDecision); XCTAssertFalse(model.canExport)
        model.export(); XCTAssertTrue(model.jobs.isEmpty)
        model.leaveOutPictureSubtitles(); XCTAssertFalse(model.needsSubtitleDecision); XCTAssertTrue(model.canExport)
        model.choices[1] = EpisodeChoice(title: DiscTitle(index: 2, duration: 1800, chapters: 2, subtitleTracks: [SubtitleTrack(index: 1, isText: false)]), selected: true, episode: 2)
        XCTAssertTrue(model.needsSubtitleDecision) // Newly included picture tracks need a fresh choice.
        model.container = .mkv
        XCTAssertFalse(model.needsSubtitleDecision); XCTAssertTrue(model.canExport)
    }
}
