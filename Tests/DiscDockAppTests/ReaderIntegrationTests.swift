import XCTest
import DiscDockCore
@testable import DiscDock

final class ReaderIntegrationTests: XCTestCase {
    /// Opt in with DISCDOCK_TEST_SOURCE and DISCDOCK_TEST_OUTPUT. Never runs on a
    /// user's mounted disc or writes an output without those explicit settings.
    @MainActor func testInstalledReaderScanAndEncode() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let source = env["DISCDOCK_TEST_SOURCE"], let output = env["DISCDOCK_TEST_OUTPUT"] else {
            throw XCTSkip("Set DISCDOCK_TEST_SOURCE and DISCDOCK_TEST_OUTPUT for a real reader test")
        }
        guard !FileManager.default.fileExists(atPath: output) else {
            return XCTFail("Choose a new test output path; existing files are never overwritten by this test")
        }
        let engine = HandBrakeEngine()
        var titles: [DiscTitle] = [], log = "", progress = 0.0
        let cli = env["DISCDOCK_TEST_READER"] ?? "/opt/homebrew/bin/HandBrakeCLI"
        try await engine.run(executable: cli, arguments: ["--json", "-i", source, "-t", "0", "--scan"], libraryDirectory: "/opt/homebrew/lib", event: {
            if case .titles(let items) = $0 { titles = items }
        }, log: { log += $0 })
        XCTAssertFalse(titles.isEmpty, log)
        let encoder = VideoEncoder(rawValue: env["DISCDOCK_TEST_ENCODER"] ?? "") ?? .hevc
        let container = ExportContainer(rawValue: env["DISCDOCK_TEST_CONTAINER"] ?? "") ?? .mp4
        let title = try XCTUnwrap(titles.first)
        var args = EncodeCommand.arguments(source: source, title: title.index, output: output, profile: .balanced, filter: .adaptive, encoder: encoder, container: container, subtitles: title.subtitleTracks)
        args += ["--stop-at", "seconds:6"]
        try await engine.run(executable: cli, arguments: args, libraryDirectory: "/opt/homebrew/lib", event: {
            if case .progress(let value, _) = $0 { progress = max(progress, value) }
        }, log: { log += $0 })
        XCTAssertGreaterThan(try URL(fileURLWithPath: output).resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0, 1000)
        XCTAssertGreaterThan(progress, 0)
        XCTAssertNotNil(HardwareEncoderEvidence.identifier(in: log, for: encoder), log)
    }
}
