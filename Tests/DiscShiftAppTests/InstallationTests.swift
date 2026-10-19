import XCTest
@testable import DiscShift

final class InstallationTests: XCTestCase {
    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("DiscShiftInstallTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func app(_ url: URL, build: String, id: String = AppBundleInstaller.applicationID) throws {
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let info = ["CFBundleIdentifier": id, "CFBundleExecutable": "DiscShift", "CFBundleVersion": build]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: url.appendingPathComponent("Contents/Info.plist"))
        try Data(build.utf8).write(to: url.appendingPathComponent("Contents/MacOS/DiscShift"))
    }
    func testOnlyActualApplicationsRootsCountAsInstalled() {
        let directories = [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: "/Users/example/Applications")]
        for path in ["/Applications/DiscShift.app", "/Applications/Video/DiscShift.app", "/Users/example/Applications/DiscShift.app"] {
            XCTAssertTrue(AppBundleInstaller.isInstalled(URL(fileURLWithPath: path), in: directories))
        }
        for path in ["/Applications-Old/DiscShift.app", "/Users/example/Downloads/DiscShift.app", "/Volumes/Installer/Applications/DiscShift.app"] {
            XCTAssertFalse(AppBundleInstaller.isInstalled(URL(fileURLWithPath: path), in: directories))
        }
    }
    func testFreshInstallKeepsSourceAndFrameworkSymlinks() throws {
        let root = try fixture(), source = root.appendingPathComponent("Download.app"), destination = root.appendingPathComponent("DiscShift.app")
        try app(source, build: "13")
        try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("Current").path, withDestinationPath: "Contents")
        let backup = try AppBundleInstaller.install(source: source, destination: destination, validate: { _ in })
        XCTAssertNil(backup)
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertEqual(AppBundleInstaller.info(at: destination)?["CFBundleVersion"] as? String, "13")
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: destination.appendingPathComponent("Current").path), "Contents")
    }
    func testSourceAliasCopiesTheAppInsteadOfInstallingADanglingLink() throws {
        let root = try fixture(), source = root.appendingPathComponent("Original.app"), alias = root.appendingPathComponent("Download.app"), destination = root.appendingPathComponent("DiscShift.app")
        try app(source, build: "13")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: source)
        _ = try AppBundleInstaller.install(source: alias, destination: destination, validate: { _ in })
        let type = try FileManager.default.attributesOfItem(atPath: destination.path)[.type] as? FileAttributeType
        XCTAssertEqual(type, .typeDirectory)
        XCTAssertEqual(AppBundleInstaller.info(at: destination)?["CFBundleVersion"] as? String, "13")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }
    func testExistingAppRequiresExplicitReplacement() throws {
        let root = try fixture(), source = root.appendingPathComponent("Download.app"), destination = root.appendingPathComponent("DiscShift.app")
        try app(source, build: "13"); try app(destination, build: "12")
        XCTAssertThrowsError(try AppBundleInstaller.install(source: source, destination: destination, validate: { _ in }))
        XCTAssertEqual(AppBundleInstaller.info(at: destination)?["CFBundleVersion"] as? String, "12")
        let backup = try XCTUnwrap(AppBundleInstaller.install(source: source, destination: destination, replace: true, validate: { _ in }))
        XCTAssertEqual(AppBundleInstaller.info(at: destination)?["CFBundleVersion"] as? String, "13")
        XCTAssertEqual(AppBundleInstaller.info(at: backup)?["CFBundleVersion"] as? String, "12")
    }
    func testInvalidSignatureDoesNotTouchExistingAppOrSource() throws {
        let root = try fixture(), source = root.appendingPathComponent("Download.app"), destination = root.appendingPathComponent("DiscShift.app")
        try app(source, build: "13"); try app(destination, build: "12")
        XCTAssertThrowsError(try AppBundleInstaller.install(source: source, destination: destination, replace: true))
        XCTAssertEqual(AppBundleInstaller.info(at: destination)?["CFBundleVersion"] as? String, "12")
        XCTAssertEqual(AppBundleInstaller.info(at: source)?["CFBundleVersion"] as? String, "13")
    }
    func testPlacementFailureRollsBackThePreviousCopy() throws {
        let root = try fixture(), source = root.appendingPathComponent("Download.app"), destination = root.appendingPathComponent("DiscShift.app")
        try app(source, build: "13"); try app(destination, build: "12")
        XCTAssertThrowsError(try AppBundleInstaller.install(source: source, destination: destination, replace: true,
            validate: { _ in }, place: { _, _ in throw CocoaError(.fileWriteNoPermission) }))
        XCTAssertEqual(AppBundleInstaller.info(at: destination)?["CFBundleVersion"] as? String, "12")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: root.path).contains { $0.hasPrefix(".DiscShift-Install-") })
    }
    func testRunningCopyDiscoveredDuringStagingStopsReplacement() throws {
        let root = try fixture(), source = root.appendingPathComponent("Download.app"), destination = root.appendingPathComponent("DiscShift.app")
        try app(source, build: "13"); try app(destination, build: "12")
        XCTAssertThrowsError(try AppBundleInstaller.install(source: source, destination: destination, replace: true,
            validate: { _ in }, beforePlacement: { throw AppBundleInstaller.InstallationError.runningCopy }))
        XCTAssertEqual(AppBundleInstaller.info(at: destination)?["CFBundleVersion"] as? String, "12")
    }
    func testUnrelatedAppAndSymbolicLinkCannotBeReplaced() throws {
        let root = try fixture(), source = root.appendingPathComponent("Download.app"), destination = root.appendingPathComponent("DiscShift.app")
        try app(source, build: "13"); try app(destination, build: "1", id: "com.example.other")
        XCTAssertThrowsError(try AppBundleInstaller.install(source: source, destination: destination, replace: true, validate: { _ in }))
        XCTAssertEqual(AppBundleInstaller.info(at: destination)?["CFBundleIdentifier"] as? String, "com.example.other")
        try FileManager.default.removeItem(at: destination)
        try FileManager.default.createSymbolicLink(at: destination, withDestinationURL: source)
        XCTAssertThrowsError(try AppBundleInstaller.install(source: source, destination: destination, replace: true, validate: { _ in }))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }
    func testNumericBuildComparisonAvoidsAccidentalDowngrades() throws {
        let root = try fixture(), source = root.appendingPathComponent("Download.app"), destination = root.appendingPathComponent("DiscShift.app")
        try app(source, build: "13"); try app(destination, build: "9")
        XCTAssertTrue(AppBundleInstaller.isNewer(source, than: destination))
        try app(destination, build: "13")
        XCTAssertFalse(AppBundleInstaller.isNewer(source, than: destination))
        try app(destination, build: "14")
        XCTAssertFalse(AppBundleInstaller.isNewer(source, than: destination))
    }
}
