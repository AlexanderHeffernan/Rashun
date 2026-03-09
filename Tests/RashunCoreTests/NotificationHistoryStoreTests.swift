import XCTest
@testable import RashunCore

final class NotificationHistoryStoreTests: XCTestCase {
    private static let source = "TestSource"

    override func setUp() {
        super.setUp()
        MainActor.assumeIsolated {
            UsageHistoryStore.shared.clearAllHistory()
        }
    }

    override func tearDown() {
        MainActor.assumeIsolated {
            UsageHistoryStore.shared.clearAllHistory()
        }
        super.tearDown()
    }

    func testAppend_keepsFirstAndLatestWhenUsageStateIsUnchanged() {
        let usage = UsageResult(
            remaining: 80,
            limit: 100,
            resetDate: Date(timeIntervalSince1970: 1_700_000_000),
            cycleStartDate: Date(timeIntervalSince1970: 1_699_000_000)
        )

        MainActor.assumeIsolated {
            UsageHistoryStore.shared.append(sourceName: Self.source, usage: usage)
            UsageHistoryStore.shared.append(sourceName: Self.source, usage: usage)

            let history = UsageHistoryStore.shared.history(for: Self.source)
            XCTAssertEqual(history.count, 2)
            XCTAssertLessThan(history[0].timestamp, history[1].timestamp)
        }
    }

    func testAppend_replacesLatestDuplicateSnapshotWhenStateRemainsUnchanged() {
        let usage = Self.baseUsage()

        MainActor.assumeIsolated {
            UsageHistoryStore.shared.append(sourceName: Self.source, usage: usage)
            UsageHistoryStore.shared.append(sourceName: Self.source, usage: usage)
            let secondTimestamp = UsageHistoryStore.shared.history(for: Self.source)[1].timestamp

            Thread.sleep(forTimeInterval: 0.01)
            UsageHistoryStore.shared.append(sourceName: Self.source, usage: usage)

            let history = UsageHistoryStore.shared.history(for: Self.source)
            XCTAssertEqual(history.count, 2)
            XCTAssertGreaterThan(history[1].timestamp, secondTimestamp)
        }
    }

    func testAppend_keepsSnapshotWhenRemainingChanges() {
        let base = Self.baseUsage()
        MainActor.assumeIsolated {
            UsageHistoryStore.shared.append(sourceName: Self.source, usage: base)
            UsageHistoryStore.shared.append(sourceName: Self.source, usage: UsageResult(
                remaining: base.remaining - 1,
                limit: base.limit,
                resetDate: base.resetDate,
                cycleStartDate: base.cycleStartDate
            ))

            XCTAssertEqual(UsageHistoryStore.shared.history(for: Self.source).count, 2)
        }
    }

    func testAppend_keepsSnapshotWhenLimitChanges() {
        let base = Self.baseUsage()
        MainActor.assumeIsolated {
            UsageHistoryStore.shared.append(sourceName: Self.source, usage: base)
            UsageHistoryStore.shared.append(sourceName: Self.source, usage: UsageResult(
                remaining: base.remaining,
                limit: base.limit + 1,
                resetDate: base.resetDate,
                cycleStartDate: base.cycleStartDate
            ))

            XCTAssertEqual(UsageHistoryStore.shared.history(for: Self.source).count, 2)
        }
    }

    func testAppend_keepsSnapshotWhenResetDateChanges() {
        let base = Self.baseUsage()
        MainActor.assumeIsolated {
            UsageHistoryStore.shared.append(sourceName: Self.source, usage: base)
            UsageHistoryStore.shared.append(sourceName: Self.source, usage: UsageResult(
                remaining: base.remaining,
                limit: base.limit,
                resetDate: base.resetDate?.addingTimeInterval(60),
                cycleStartDate: base.cycleStartDate
            ))

            XCTAssertEqual(UsageHistoryStore.shared.history(for: Self.source).count, 2)
        }
    }

    func testAppend_keepsSnapshotWhenCycleStartDateChanges() {
        let base = Self.baseUsage()
        MainActor.assumeIsolated {
            UsageHistoryStore.shared.append(sourceName: Self.source, usage: base)
            UsageHistoryStore.shared.append(sourceName: Self.source, usage: UsageResult(
                remaining: base.remaining,
                limit: base.limit,
                resetDate: base.resetDate,
                cycleStartDate: base.cycleStartDate?.addingTimeInterval(60)
            ))

            XCTAssertEqual(UsageHistoryStore.shared.history(for: Self.source).count, 2)
        }
    }

    func testDeleteSnapshotsOlderThan_removesOnlyOlderRows() {
        let now = Date()
        MainActor.assumeIsolated {
            UsageHistoryStore.shared.replaceAllHistory([
                Self.source: [
                    UsageSnapshot(timestamp: now.addingTimeInterval(-3600), usage: Self.baseUsage()),
                    UsageSnapshot(timestamp: now.addingTimeInterval(-60), usage: Self.baseUsage())
                ]
            ])

            let removed = UsageHistoryStore.shared.deleteSnapshotsOlderThan(now.addingTimeInterval(-300), sourceName: Self.source)

            XCTAssertEqual(removed, 1)
            XCTAssertEqual(UsageHistoryStore.shared.history(for: Self.source).count, 1)
        }
    }

    private static func baseUsage() -> UsageResult {
        UsageResult(
            remaining: 80,
            limit: 100,
            resetDate: Date(timeIntervalSince1970: 1_700_000_000),
            cycleStartDate: Date(timeIntervalSince1970: 1_699_000_000)
        )
    }
}
