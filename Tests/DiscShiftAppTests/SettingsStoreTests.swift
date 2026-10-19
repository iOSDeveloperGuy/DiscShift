import XCTest
import DiscShiftCore
@testable import DiscShift

final class SettingsStoreTests: XCTestCase {
    private func compatibleSettings() -> [String: Any] {
        ["handbrake": "/custom/HandBrakeCLI", "dvdcss": "/custom/lib", "automaticShowLookup": false,
         "profile": VideoProfile.quality.rawValue, "encoder": VideoEncoder.h264.rawValue,
         "container": ExportContainer.mov.rawValue, "filter": MotionFilter.bob.rawValue,
         "ejectAfter": true, "destination": "/chosen/TV", "setupCompleted": true]
    }
    private func domains() -> (UserDefaults, String, String) {
        let prefix = "com.discshift-test." + UUID().uuidString
        let current = prefix + ".current", previous = prefix + ".previous"
        return (UserDefaults(suiteName: current)!, current, previous)
    }
    func testImportsSettingsAndSetupCompletionOnce() {
        let (defaults, current, previous) = domains()
        defer { defaults.removePersistentDomain(forName: current); defaults.removePersistentDomain(forName: previous) }
        defaults.setPersistentDomain(compatibleSettings(), forName: previous)
        XCTAssertTrue(SettingsStore.importOnce(defaults: defaults, applicationID: current, domains: [previous]))
        XCTAssertEqual(defaults.string(forKey: "destination"), "/chosen/TV")
        XCTAssertEqual(defaults.string(forKey: "handbrake"), "/custom/HandBrakeCLI")
        XCTAssertEqual(defaults.string(forKey: "container"), "mov")
        XCTAssertTrue(defaults.bool(forKey: "setupCompleted"))
        XCTAssertFalse(defaults.bool(forKey: "automaticShowLookup"))
        defaults.set("/new/TV", forKey: "destination")
        XCTAssertFalse(SettingsStore.importOnce(defaults: defaults, applicationID: current, domains: [previous]))
        XCTAssertEqual(defaults.string(forKey: "destination"), "/new/TV")
        XCTAssertNotNil(defaults.persistentDomain(forName: previous))
    }
    func testPreservesCurrentValuesAndCopiesOnlyKnownKeys() {
        let (defaults, current, previous) = domains()
        defer { defaults.removePersistentDomain(forName: current); defaults.removePersistentDomain(forName: previous) }
        var settings = compatibleSettings(); settings["unrelatedValue"] = "leave behind"
        defaults.setPersistentDomain(settings, forName: previous)
        defaults.set(false, forKey: "setupCompleted"); defaults.set("mp4", forKey: "container")
        SettingsStore.importOnce(defaults: defaults, applicationID: current, domains: [previous, previous])
        XCTAssertFalse(defaults.bool(forKey: "setupCompleted"))
        XCTAssertEqual(defaults.string(forKey: "container"), "mp4")
        XCTAssertNil(defaults.object(forKey: "unrelatedValue"))
        XCTAssertTrue(defaults.bool(forKey: SettingsStore.importMarker))
    }
    func testIgnoresOtherPublishersAndNestedPreviewDomains() {
        let (defaults, current, previous) = domains()
        let other = "org.discshift-test." + UUID().uuidString + ".previous", nested = previous + ".preview"
        defer { for id in [current, other, nested] { defaults.removePersistentDomain(forName: id) } }
        for id in [other, nested] { defaults.setPersistentDomain(compatibleSettings(), forName: id) }
        XCTAssertFalse(SettingsStore.importOnce(defaults: defaults, applicationID: current, domains: [other, nested]))
        XCTAssertNil(defaults.object(forKey: "destination"))
    }
    func testAmbiguousSourcesAreNotImported() {
        let (defaults, current, previous) = domains()
        let second = previous.replacingOccurrences(of: ".previous", with: ".another")
        defer { for id in [current, previous, second] { defaults.removePersistentDomain(forName: id) } }
        for id in [previous, second] { defaults.setPersistentDomain(compatibleSettings(), forName: id) }
        XCTAssertFalse(SettingsStore.importOnce(defaults: defaults, applicationID: current, domains: [previous, second]))
        XCTAssertNil(defaults.object(forKey: "destination"))
    }
    func testInvalidOrUnrelatedSettingsAreNotImported() {
        let (defaults, current, previous) = domains()
        defer { defaults.removePersistentDomain(forName: current); defaults.removePersistentDomain(forName: previous) }
        var settings = compatibleSettings(); settings["encoder"] = "unknown"
        defaults.setPersistentDomain(settings, forName: previous)
        XCTAssertFalse(SettingsStore.importOnce(defaults: defaults, applicationID: current, domains: [previous]))
        XCTAssertNil(defaults.object(forKey: "handbrake"))
    }
    func testImportsSettingsSavedBeforeOptionalEncodingFieldsExisted() {
        let (defaults, current, previous) = domains()
        defer { defaults.removePersistentDomain(forName: current); defaults.removePersistentDomain(forName: previous) }
        var settings = compatibleSettings()
        settings.removeValue(forKey: "encoder"); settings.removeValue(forKey: "container")
        defaults.setPersistentDomain(settings, forName: previous)
        XCTAssertTrue(SettingsStore.importOnce(defaults: defaults, applicationID: current, domains: [previous]))
        XCTAssertEqual(defaults.string(forKey: "destination"), "/chosen/TV")
        XCTAssertNil(defaults.object(forKey: "container"))
        XCTAssertTrue(defaults.bool(forKey: "setupCompleted"))
    }
}
