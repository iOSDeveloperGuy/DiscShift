import XCTest
@testable import DiscShift

final class UpdateTests: XCTestCase {
    @MainActor func testRelaunchWaitsForIdleAndRunsOnce() {
        let gate = UpdateActivityGate()
        var installs = 0
        XCTAssertTrue(gate.postpone { installs += 1 })
        gate.blocked = true
        XCTAssertEqual(installs, 0)
        gate.blocked = false
        XCTAssertEqual(installs, 1)
        gate.blocked = false
        XCTAssertEqual(installs, 1)
    }
    @MainActor func testIdleInstallationStaysWithSparkle() {
        let gate = UpdateActivityGate()
        gate.blocked = false
        XCTAssertFalse(gate.postpone { XCTFail("Sparkle owns immediate installation") })
        gate.blocked = true
        gate.blocked = false
    }
    @MainActor func testInstallationCannotStartAnotherDiscOperation() {
        let defaults = UserDefaults(suiteName: "DiscShiftUpdates-" + UUID().uuidString)!
        let model = AppModel(defaults: defaults, discoverMountedDiscs: false)
        model.source = URL(fileURLWithPath: "/private/tmp")
        model.executable = "/usr/bin/true"
        model.updateInstallationPending = true
        model.scan()
        XCTAssertFalse(model.busy)
        XCTAssertNil(model.operationTask)
        XCTAssertFalse(model.canContinue)
        XCTAssertFalse(model.canExport)
    }
    @MainActor func testCancelledUpdateDoesNotRelaunchWhenOperationFinishes() {
        let gate = UpdateActivityGate()
        XCTAssertTrue(gate.postpone { XCTFail("An aborted update must not relaunch") })
        gate.cancel()
        gate.blocked = false
    }
}
