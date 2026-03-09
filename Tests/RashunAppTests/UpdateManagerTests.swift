import XCTest
@testable import Rashun
import RashunCore

@MainActor
final class UpdateManagerTests: XCTestCase {
    private var manager: UpdateManager { UpdateManager.shared }

    func testCheckForUpdateIfDue_skipsCallsBeforeIntervalElapses() async {
        manager.resetTestingState()
        defer { manager.resetTestingState() }
        manager.autoUpdateCheckEnabledOverride = true

        let start = Date(timeIntervalSince1970: 1_000)
        var now = start
        manager.nowProvider = { now }

        var callCount = 0
        manager.dueCheckRunner = { _ in
            callCount += 1
            return true
        }

        let first = await manager.checkForUpdateIfDue(notify: false)
        let second = await manager.checkForUpdateIfDue(notify: false)

        now = start.addingTimeInterval(manager.checkIntervalSecondsForTesting - 1)
        let third = await manager.checkForUpdateIfDue(notify: false)

        XCTAssertTrue(first)
        XCTAssertFalse(second)
        XCTAssertFalse(third)
        XCTAssertEqual(callCount, 1)
    }

    func testCheckForUpdateIfDue_runsAgainAfterIntervalElapses() async {
        manager.resetTestingState()
        defer { manager.resetTestingState() }
        manager.autoUpdateCheckEnabledOverride = true

        let start = Date(timeIntervalSince1970: 10_000)
        var now = start
        manager.nowProvider = { now }

        var callCount = 0
        manager.dueCheckRunner = { _ in
            callCount += 1
            return true
        }

        _ = await manager.checkForUpdateIfDue(notify: true)
        now = start.addingTimeInterval(manager.checkIntervalSecondsForTesting)
        let second = await manager.checkForUpdateIfDue(notify: true)

        XCTAssertTrue(second)
        XCTAssertEqual(callCount, 2)
    }

    func testStopPeriodicChecks_resetsDueWindow() async {
        manager.resetTestingState()
        defer { manager.resetTestingState() }
        manager.autoUpdateCheckEnabledOverride = true

        let now = Date(timeIntervalSince1970: 50_000)
        manager.nowProvider = { now }

        var callCount = 0
        manager.dueCheckRunner = { _ in
            callCount += 1
            return true
        }

        _ = await manager.checkForUpdateIfDue(notify: false)
        let skipped = await manager.checkForUpdateIfDue(notify: false)
        manager.stopPeriodicChecks()
        let postReset = await manager.checkForUpdateIfDue(notify: false)

        XCTAssertFalse(skipped)
        XCTAssertTrue(postReset)
        XCTAssertEqual(callCount, 2)
    }

    func testCheckForUpdateIfDue_returnsFalseWhenDisabled() async {
        manager.resetTestingState()
        defer { manager.resetTestingState() }
        manager.autoUpdateCheckEnabledOverride = false

        var callCount = 0
        manager.dueCheckRunner = { _ in
            callCount += 1
            return true
        }

        let result = await manager.checkForUpdateIfDue(notify: false)

        XCTAssertFalse(result)
        XCTAssertEqual(callCount, 0)
    }
}