import XCTest
import Darwin
@testable import DiscDock

final class SetupTests: XCTestCase {
    private func fixture(script: String) throws -> (URL, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("reader")
        try Data(("#!/bin/sh\n" + script).utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        return (root, file)
    }
    private let valid = """
    if [ "$1" = "--version" ]; then printf 'HandBrake 1.11.2\\n'; else printf 'vt_h265\\nvt_h264\\n'; fi
    """
    @MainActor func testRequiresSuccessfulCheckAndPersistsCompletion() async throws {
        let (root, reader) = try fixture(script: valid)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = UserDefaults(suiteName: "DiscDockSetupTests-" + UUID().uuidString)!
        defaults.set(reader.path, forKey: "handbrake")
        let model = AppModel(defaults: defaults, discoverMountedDiscs: false)
        XCTAssertTrue(model.showingSetup)
        model.completeSetup(); XCTAssertTrue(model.showingSetup)
        model.setup.check(); await model.setup.task?.value
        XCTAssertTrue(model.setup.isReady); XCTAssertTrue(model.setup.supportsHEVC)
        XCTAssertEqual(model.setup.version, "HandBrake 1.11.2")
        model.automaticShowLookup = false
        model.completeSetup(); XCTAssertFalse(model.showingSetup)
        let restored = AppModel(defaults: defaults, discoverMountedDiscs: false)
        XCTAssertFalse(restored.showingSetup); XCTAssertFalse(restored.automaticShowLookup)
        XCTAssertEqual(restored.executable, reader.path)
        model.setup.libraryPath = root.path
        XCTAssertFalse(model.setup.isReady)
    }
    @MainActor func testBrokenAndUnsupportedReadersCannotComplete() async throws {
        for script in ["exit 2", "printf 'different tool\\n'", "printf 'HandBrake 1.0\\nx264\\n'"] {
            let (root, reader) = try fixture(script: script)
            defer { try? FileManager.default.removeItem(at: root) }
            let setup = DependencySetup(readerPath: reader.path, libraryPath: root.path)
            setup.check(); await setup.task?.value
            XCTAssertFalse(setup.isReady); XCTAssertNotNil(setup.message)
            XCTAssertFalse(setup.isWorking)
        }
    }
    @MainActor func testH264OnlyReaderSelectsAvailableCodec() async throws {
        let (root, reader) = try fixture(script: "printf 'HandBrake 1.11.2\\nvt_h264\\n'")
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = UserDefaults(suiteName: "DiscDockSetupTests-" + UUID().uuidString)!
        defaults.set(reader.path, forKey: "handbrake")
        let model = AppModel(defaults: defaults, discoverMountedDiscs: false)
        model.setup.check(); await model.setup.task?.value
        XCTAssertTrue(model.setup.isReady); XCTAssertFalse(model.setup.supportsHEVC)
        model.completeSetup(); XCTAssertEqual(model.encoder, .h264)
    }
    @MainActor func testInstallUsesFixedFormulaAndRechecksReader() async throws {
        let (root, reader) = try fixture(script: "exit 3")
        defer { try? FileManager.default.removeItem(at: root) }
        let brew = root.appendingPathComponent("brew")
        let installedReader = root.appendingPathComponent("HandBrakeCLI")
        try Data(("#!/bin/sh\n" + valid).utf8).write(to: installedReader)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installedReader.path)
        let script = """
        #!/bin/sh
        [ "$#" -eq 2 ] && [ "$1" = install ] && [ "$2" = handbrake ] || exit 4
        [ "$HOMEBREW_NO_AUTO_UPDATE" = 1 ] && [ "$HOMEBREW_NO_ANALYTICS" = 1 ] && [ "$NONINTERACTIVE" = 1 ] || exit 5
        printf 'Installed reader\\n'
        """
        try Data(script.utf8).write(to: brew)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: brew.path)
        let setup = DependencySetup(readerPath: reader.path, libraryPath: root.path)
        setup.install(brewPath: brew.path); await setup.task?.value
        XCTAssertTrue(setup.isReady); XCTAssertTrue(setup.diagnostics.contains("Installed reader"))
        XCTAssertEqual(setup.readerPath, installedReader.path)
        XCTAssertFalse(setup.isInstalling)
    }
    @MainActor func testInstallationFailureDoesNotReportReady() async throws {
        let (root, reader) = try fixture(script: "printf 'installation failed\\n' >&2; exit 9")
        defer { try? FileManager.default.removeItem(at: root) }
        let setup = DependencySetup(readerPath: reader.path, libraryPath: root.path)
        setup.install(brewPath: reader.path); await setup.task?.value
        XCTAssertFalse(setup.isReady); XCTAssertNotNil(setup.message)
        XCTAssertTrue(setup.diagnostics.contains("installation failed"))
    }
    @MainActor func testCancelInstallationTerminatesChildTasks() async throws {
        let (root, reader) = try fixture(script: """
        /bin/sleep 30 &
        printf '%s' "$!" > "$(dirname "$0")/child-pid"
        wait
        """)
        defer { try? FileManager.default.removeItem(at: root) }
        let setup = DependencySetup(readerPath: reader.path, libraryPath: root.path)
        setup.install(brewPath: reader.path)
        let pidFile = root.appendingPathComponent("child-pid")
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: pidFile.path) { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile)))
        setup.cancel(); await setup.task?.value
        XCTAssertFalse(setup.isWorking); XCTAssertFalse(setup.isReady)
        for _ in 0..<100 {
            if kill(pid, 0) != 0 { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNotEqual(kill(pid, 0), 0, "An installation child process was left running")
    }
}
