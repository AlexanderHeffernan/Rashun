import XCTest
@testable import Rashun

@MainActor
final class NotificationHistoryStoreTests: XCTestCase {
    private let store = NotificationHistoryStore.shared
    private let source = "TestSource"

    override func setUp() async throws {
        try await super.setUp()
        await MainActor.run {
            store.clearAllHistory()
        }
    }

    override func tearDown() async throws {
        await MainActor.run {
            store.clearAllHistory()
        }
        try await super.tearDown()
    }

    func testAppend_skipsDuplicateUsageState() {
        let usage = UsageResult(
            remaining: 80,
            limit: 100,
            resetDate: Date(timeIntervalSince1970: 1_700_000_000),
            cycleStartDate: Date(timeIntervalSince1970: 1_699_000_000)
        )

        store.append(sourceName: source, usage: usage)
        store.append(sourceName: source, usage: usage)

        XCTAssertEqual(store.history(for: source).count, 1)
    }

    func testAppend_keepsSnapshotWhenRemainingChanges() {
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
}
