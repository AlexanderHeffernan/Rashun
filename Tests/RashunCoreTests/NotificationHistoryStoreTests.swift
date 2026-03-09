import XCTest
@testable import RashunCore

@MainActor
final class NotificationHistoryStoreTests: XCTestCase {
    private let store = UsageHistoryStore.shared
    private let source = "TestSource"

    func testAppend_keepsFirstAndLatestWhenUsageStateIsUnchanged() {
        resetStore()
        let usage = UsageResult(
            remaining: 80,
            limit: 100,
            resetDate: Date(timeIntervalSince1970: 1_700_000_000),
            cycleStartDate: Date(timeIntervalSince1970: 1_699_000_000)
        )

        store.append(sourceName: source, usage: usage)
        store.append(sourceName: source, usage: usage)

        let history = store.history(for: source)
        XCTAssertEqual(history.count, 2)
        XCTAssertLessThan(history[0].timestamp, history[1].timestamp)
    }

    func testAppend_replacesLatestDuplicateSnapshotWhenStateRemainsUnchanged() {
        resetStore()
        let usage = baseUsage()

        store.append(sourceName: source, usage: usage)
        store.append(sourceName: source, usage: usage)
        let secondTimestamp = store.history(for: source)[1].timestamp

        Thread.sleep(forTimeInterval: 0.01)
        store.append(sourceName: source, usage: usage)

        let history = store.history(for: source)
        XCTAssertEqual(history.count, 2)
        XCTAssertGreaterThan(history[1].timestamp, secondTimestamp)
    }

    func testAppend_keepsSnapshotWhenRemainingChanges() {
        resetStore()
        let base = baseUsage()
        store.append(sourceName: source, usage: base)
        store.append(sourceName: source, usage: UsageResult(
            remaining: base.remaining - 1,
            limit: base.limit,
            resetDate: base.resetDate,
            cycleStartDate: base.cycleStartDate
        ))

        XCTAssertEqual(store.history(for: source).count, 2)
    }

    func testAppend_keepsSnapshotWhenLimitChanges() {
        resetStore()
        let base = baseUsage()
        store.append(sourceName: source, usage: base)
        store.append(sourceName: source, usage: UsageResult(
            remaining: base.remaining,
            limit: base.limit + 1,
            resetDate: base.resetDate,
            cycleStartDate: base.cycleStartDate
        ))

        XCTAssertEqual(store.history(for: source).count, 2)
    }

    func testAppend_keepsSnapshotWhenResetDateChanges() {
        resetStore()
        let base = baseUsage()
        store.append(sourceName: source, usage: base)
        store.append(sourceName: source, usage: UsageResult(
            remaining: base.remaining,
            limit: base.limit,
            resetDate: base.resetDate?.addingTimeInterval(60),
            cycleStartDate: base.cycleStartDate
        ))

        XCTAssertEqual(store.history(for: source).count, 2)
    }

    func testAppend_keepsSnapshotWhenCycleStartDateChanges() {
        resetStore()
        let base = baseUsage()
        store.append(sourceName: source, usage: base)
        store.append(sourceName: source, usage: UsageResult(
            remaining: base.remaining,
            limit: base.limit,
            resetDate: base.resetDate,
            cycleStartDate: base.cycleStartDate?.addingTimeInterval(60)
        ))

        XCTAssertEqual(store.history(for: source).count, 2)
    }

    func testDeleteSnapshotsOlderThan_removesOnlyOlderRows() {
        resetStore()
        let now = Date()
        store.replaceAllHistory([
            source: [
                UsageSnapshot(timestamp: now.addingTimeInterval(-3600), usage: baseUsage()),
                UsageSnapshot(timestamp: now.addingTimeInterval(-60), usage: baseUsage())
            ]
        ])

        let removed = store.deleteSnapshotsOlderThan(now.addingTimeInterval(-300), sourceName: source)

        XCTAssertEqual(removed, 1)
        XCTAssertEqual(store.history(for: source).count, 1)
    }

    private func baseUsage() -> UsageResult {
        UsageResult(
            remaining: 80,
            limit: 100,
            resetDate: Date(timeIntervalSince1970: 1_700_000_000),
            cycleStartDate: Date(timeIntervalSince1970: 1_699_000_000)
        )
    }

    private func resetStore() {
        store.clearAllHistory()
    }
}
