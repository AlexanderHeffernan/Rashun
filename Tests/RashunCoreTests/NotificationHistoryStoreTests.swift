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
            store.append(
                sourceName: Self.source,
                usage: UsageResult(
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
            store.append(
                sourceName: Self.source,
                usage: UsageResult(
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
            store.append(
                sourceName: Self.source,
                usage: UsageResult(
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
            store.append(
                sourceName: Self.source,
                usage: UsageResult(
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
                    UsageSnapshot(
                        timestamp: now.addingTimeInterval(-3600), usage: Self.baseUsage()),
                    UsageSnapshot(timestamp: now.addingTimeInterval(-60), usage: Self.baseUsage()),
                ]
            ])

            let removed = store.deleteSnapshotsOlderThan(
                now.addingTimeInterval(-300), sourceName: Self.source)

            XCTAssertEqual(removed, 1)
            XCTAssertEqual(store.history(for: Self.source).count, 1)
        }
    }

    func testHistoryHasNoAutomaticSnapshotCap() {
        let snapshots = (0...10_000).map { index in
            UsageSnapshot(
                timestamp: Date(timeIntervalSince1970: Double(index)),
                usage: UsageResult(remaining: Double(index), limit: 20_000))
        }
        MainActor.assumeIsolated {
            let store = Self.makeStore()
            XCTAssertTrue(store.replaceAllHistory([Self.source: snapshots], force: true))
            XCTAssertEqual(store.history(for: Self.source).count, 10_001)
        }
    }

    func testSyncSnapshotReturnsOnlySeriesChangedSinceRevision() {
        MainActor.assumeIsolated {
            let store = Self.makeStore()
            store.append(sourceName: "Codex::weekly", usage: Self.baseUsage())
            let first = store.syncSnapshot(since: nil)
            store.append(
                sourceName: "Amp::daily", usage: UsageResult(remaining: 20, limit: 100))
            let delta = store.syncSnapshot(since: first.revision)
            XCTAssertFalse(delta.isComplete)
            XCTAssertEqual(Set(delta.historyBySource.keys), ["Amp::daily"])
        }
    }

    func testDeletedSeriesIsIncludedInIncrementalAndFullSyncSnapshots() {
        MainActor.assumeIsolated {
            let store = Self.makeStore()
            store.append(sourceName: "Codex::weekly", usage: Self.baseUsage())
            let beforeDelete = store.currentSyncRevision
            store.clearHistory(for: "Codex::weekly")
            XCTAssertEqual(
                store.syncSnapshot(since: beforeDelete).deletedSources, ["Codex::weekly"])
            XCTAssertEqual(store.syncSnapshot(since: nil).deletedSources, ["Codex::weekly"])
        }
    }

    func testLegacyAmpHistoryIsCopiedOnlyToFreeMetricAndMigrationIsIdempotent() {
        let legacy = [
            UsageSnapshot(
                timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                usage: UsageResult(remaining: 42, limit: 100))
        ]
        let backend = InMemoryPersistenceBackend(initialStorage: [
            "ai.notificationHistory.v1": try! JSONEncoder().encode(["AMP": legacy]),
            "ai.notificationHistory.migrated.v1": Data([1]),
        ])

        MainActor.assumeIsolated {
            let migrated = UsageHistoryStore(backend: backend, legacyBackends: [])
            XCTAssertEqual(migrated.history(for: "AMP::amp-free"), legacy)
            XCTAssertTrue(migrated.history(for: "AMP::amp-agent-usage").isEmpty)
            XCTAssertTrue(migrated.history(for: "AMP::amp-orb-usage").isEmpty)

            let reloaded = UsageHistoryStore(backend: backend, legacyBackends: [])
            XCTAssertEqual(reloaded.history(for: "AMP::amp-free"), legacy)
            XCTAssertEqual(reloaded.history(for: "AMP"), legacy)
        }
    }

    func testLegacyAmpHistoryImportedAfterStartupIsCanonicalizedIdempotently() {
        let legacy = [
            UsageSnapshot(
                timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                usage: UsageResult(remaining: 42, limit: 100))
        ]

        MainActor.assumeIsolated {
            let store = Self.makeStore()
            XCTAssertTrue(store.replaceAllHistory(["AMP": legacy], force: true))
            XCTAssertEqual(store.history(for: "AMP::amp-free"), legacy)
            XCTAssertTrue(store.history(for: "AMP::amp-agent-usage").isEmpty)
            XCTAssertTrue(store.history(for: "AMP::amp-orb-usage").isEmpty)
            XCTAssertEqual(store.countSnapshots(), legacy.count)
            XCTAssertEqual(store.stats().snapshotCount, legacy.count)
            XCTAssertEqual(store.sourceNamesWithHistory(), ["AMP::amp-free"])

            XCTAssertTrue(store.replaceAllHistory(["AMP": legacy], force: true))
            XCTAssertEqual(store.history(for: "AMP::amp-free"), legacy)
        }
    }

    func testLegacyAmpHistorySyncedAfterStartupIsCanonicalizedIdempotently() {
        let legacy = [
            UsageSnapshot(
                timestamp: Date(timeIntervalSince1970: 1_700_000_000),
                usage: UsageResult(remaining: 42, limit: 100))
        ]
        let snapshot = HistorySyncSnapshot(
            revision: 1,
            baseRevision: 0,
            isComplete: false,
            historyBySource: ["AMP": legacy]
        )

        MainActor.assumeIsolated {
            let store = Self.makeStore()
            XCTAssertTrue(store.mergeSyncSnapshot(snapshot))
            XCTAssertEqual(store.history(for: "AMP::amp-free"), legacy)
            XCTAssertTrue(store.history(for: "AMP::amp-agent-usage").isEmpty)
            XCTAssertTrue(store.history(for: "AMP::amp-orb-usage").isEmpty)

            XCTAssertFalse(store.mergeSyncSnapshot(snapshot))
            XCTAssertEqual(store.history(for: "AMP::amp-free"), legacy)
        }
    }

    func testLegacyAmpHealthIsCopiedOnlyToFreeMetricWithoutOverwritingCanonicalHealth() {
        let legacy = SourceHealthRecord(consecutiveFailures: 2, shortErrorMessage: "legacy")
        let canonical = SourceHealthRecord(consecutiveFailures: 0, shortErrorMessage: "canonical")
        let backend = InMemoryPersistenceBackend(initialStorage: [
            "ai.sourceHealth.v1": try! JSONEncoder().encode([
                "AMP": legacy,
                "AMP::amp-free": canonical,
            ]),
            "ai.sourceHealth.migrated.v1": Data([1]),
        ])

        MainActor.assumeIsolated {
            let store = SourceHealthStore(backend: backend, legacyBackends: [])
            XCTAssertEqual(
                store.health(for: "AMP", metricId: "amp-free")?.shortErrorMessage, "canonical")
            XCTAssertNil(store.health(for: "AMP", metricId: "amp-agent-usage"))
            XCTAssertNil(store.health(for: "AMP", metricId: "amp-orb-usage"))
        }
    }

    func testLegacyAmpHealthIsCopiedToFreeMetricWhenCanonicalHealthIsMissing() {
        let legacy = SourceHealthRecord(consecutiveFailures: 2, shortErrorMessage: "legacy")
        let backend = InMemoryPersistenceBackend(initialStorage: [
            "ai.sourceHealth.v1": try! JSONEncoder().encode(["AMP": legacy]),
            "ai.sourceHealth.migrated.v1": Data([1]),
        ])

        MainActor.assumeIsolated {
            let store = SourceHealthStore(backend: backend, legacyBackends: [])
            XCTAssertEqual(
                store.health(for: "AMP", metricId: "amp-free")?.shortErrorMessage, "legacy")

            let reloaded = SourceHealthStore(backend: backend, legacyBackends: [])
            XCTAssertEqual(
                reloaded.health(for: "AMP", metricId: "amp-free")?.shortErrorMessage,
                "legacy")
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
