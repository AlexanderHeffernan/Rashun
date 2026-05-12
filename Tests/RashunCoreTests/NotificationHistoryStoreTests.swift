import XCTest
@testable import RashunCore

final class NotificationHistoryStoreTests: XCTestCase {
    private static let source = "TestSource"

    func testAppend_keepsFirstAndLatestWhenUsageStateIsUnchanged() {
        let usage = UsageResult(
            remaining: 80,
            limit: 100,
            resetDate: Date(timeIntervalSince1970: 1_700_000_000),
            cycleStartDate: Date(timeIntervalSince1970: 1_699_000_000)
        )

        MainActor.assumeIsolated {
            let store = Self.makeStore()
            store.append(sourceName: Self.source, usage: usage)
            store.append(sourceName: Self.source, usage: usage)

            let history = store.history(for: Self.source)
            XCTAssertEqual(history.count, 2)
            XCTAssertLessThan(history[0].timestamp, history[1].timestamp)
        }
    }

    func testAppend_replacesLatestDuplicateSnapshotWhenStateRemainsUnchanged() {
        let usage = Self.baseUsage()

        MainActor.assumeIsolated {
            let store = Self.makeStore()
            store.append(sourceName: Self.source, usage: usage)
            store.append(sourceName: Self.source, usage: usage)
            let secondTimestamp = store.history(for: Self.source)[1].timestamp

            Thread.sleep(forTimeInterval: 0.01)
            store.append(sourceName: Self.source, usage: usage)

            let history = store.history(for: Self.source)
            XCTAssertEqual(history.count, 2)
            XCTAssertGreaterThan(history[1].timestamp, secondTimestamp)
        }
    }

    func testAppend_keepsSnapshotWhenRemainingChanges() {
        let base = Self.baseUsage()
        MainActor.assumeIsolated {
            let store = Self.makeStore()
            store.append(sourceName: Self.source, usage: base)
            store.append(sourceName: Self.source, usage: UsageResult(
                remaining: base.remaining - 1,
                limit: base.limit,
                resetDate: base.resetDate,
                cycleStartDate: base.cycleStartDate
            ))

            XCTAssertEqual(store.history(for: Self.source).count, 2)
        }
    }

    func testAppend_keepsSnapshotWhenLimitChanges() {
        let base = Self.baseUsage()
        MainActor.assumeIsolated {
            let store = Self.makeStore()
            store.append(sourceName: Self.source, usage: base)
            store.append(sourceName: Self.source, usage: UsageResult(
                remaining: base.remaining,
                limit: base.limit + 1,
                resetDate: base.resetDate,
                cycleStartDate: base.cycleStartDate
            ))

            XCTAssertEqual(store.history(for: Self.source).count, 2)
        }
    }

    func testAppend_keepsSnapshotWhenResetDateChanges() {
        let base = Self.baseUsage()
        MainActor.assumeIsolated {
            let store = Self.makeStore()
            store.append(sourceName: Self.source, usage: base)
            store.append(sourceName: Self.source, usage: UsageResult(
                remaining: base.remaining,
                limit: base.limit,
                resetDate: base.resetDate?.addingTimeInterval(60),
                cycleStartDate: base.cycleStartDate
            ))

            XCTAssertEqual(store.history(for: Self.source).count, 2)
        }
    }

    func testAppend_keepsSnapshotWhenCycleStartDateChanges() {
        let base = Self.baseUsage()
        MainActor.assumeIsolated {
            let store = Self.makeStore()
            store.append(sourceName: Self.source, usage: base)
            store.append(sourceName: Self.source, usage: UsageResult(
                remaining: base.remaining,
                limit: base.limit,
                resetDate: base.resetDate,
                cycleStartDate: base.cycleStartDate?.addingTimeInterval(60)
            ))

            XCTAssertEqual(store.history(for: Self.source).count, 2)
        }
    }

    func testDeleteSnapshotsOlderThan_removesOnlyOlderRows() {
        let now = Date()
        MainActor.assumeIsolated {
            let store = Self.makeStore()
            store.replaceAllHistory([
                Self.source: [
                    UsageSnapshot(timestamp: now.addingTimeInterval(-3600), usage: Self.baseUsage()),
                    UsageSnapshot(timestamp: now.addingTimeInterval(-60), usage: Self.baseUsage())
                ]
            ])

            let removed = store.deleteSnapshotsOlderThan(now.addingTimeInterval(-300), sourceName: Self.source)

            XCTAssertEqual(removed, 1)
            XCTAssertEqual(store.history(for: Self.source).count, 1)
        }
    }

    @MainActor private static func makeStore() -> UsageHistoryStore {
        UsageHistoryStore(backend: InMemoryPersistenceBackend(), legacyBackends: [])
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
