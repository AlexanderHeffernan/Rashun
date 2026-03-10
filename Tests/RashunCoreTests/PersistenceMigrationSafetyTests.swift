import Foundation
import XCTest
@testable import RashunCore

#if !os(Linux) && !os(Windows)
final class PersistenceMigrationSafetyTests: XCTestCase {
    func testUsageHistoryMigration_prefersLegacyWhenSharedEmpty() {
        MainActor.assumeIsolated {
            let backend = InMemoryPersistenceBackend()
            let legacy = InMemoryPersistenceBackend()

            let snapshots = Self.makeSnapshots(count: 5)
            let payload = try! JSONEncoder().encode(["AMP": snapshots])
            legacy.set(payload, forKey: "ai.notificationHistory.v1")

            let store = UsageHistoryStore(backend: backend, legacyBackends: [legacy])
            XCTAssertEqual(store.countSnapshots(), 5)

            let reloaded = UsageHistoryStore(backend: backend, legacyBackends: [legacy])
            XCTAssertEqual(reloaded.countSnapshots(), 5)
        }
    }

    func testUsageHistoryReplaceAllHistory_blocksLargeDataLossWithoutForce() {
        MainActor.assumeIsolated {
            let backend = InMemoryPersistenceBackend()
            let store = UsageHistoryStore(backend: backend)

            let large = ["AMP": Self.makeSnapshots(count: 100)]
            XCTAssertTrue(store.replaceAllHistory(large, force: true))
            XCTAssertEqual(store.countSnapshots(), 100)

            let small = ["AMP": Self.makeSnapshots(count: 1)]
            XCTAssertFalse(store.replaceAllHistory(small))
            XCTAssertEqual(store.countSnapshots(), 100)
            XCTAssertTrue(store.replaceAllHistory(small, force: true))
            XCTAssertEqual(store.countSnapshots(), 1)
        }
    }

    func testSourceHealthMigration_isOneWayAfterMarker() {
        MainActor.assumeIsolated {
            let backend = InMemoryPersistenceBackend()
            let legacy = InMemoryPersistenceBackend()

            let legacyPayload = try! JSONEncoder().encode(["AMP": SourceHealthRecord(consecutiveFailures: 2)])
            legacy.set(legacyPayload, forKey: "ai.sourceHealth.v1")

            let store = SourceHealthStore(backend: backend, legacyBackends: [legacy])
            XCTAssertEqual(store.health(for: "AMP")?.consecutiveFailures, 2)

            let newPayload = try! JSONEncoder().encode(["AMP": SourceHealthRecord(consecutiveFailures: 0)])
            backend.set(newPayload, forKey: "ai.sourceHealth.v1")

            let reloaded = SourceHealthStore(backend: backend, legacyBackends: [legacy])
            XCTAssertEqual(reloaded.health(for: "AMP")?.consecutiveFailures, 0)
        }
    }

    private static func makeSnapshots(count: Int) -> [UsageSnapshot] {
        let now = Date()
        return (0..<count).map { index in
            UsageSnapshot(
                timestamp: now.addingTimeInterval(Double(index) * 60),
                usage: UsageResult(
                    remaining: Double(max(0, 100 - index)),
                    limit: 100,
                    resetDate: now.addingTimeInterval(3600),
                    cycleStartDate: now.addingTimeInterval(-3600)
                )
            )
        }
    }
}
#endif
