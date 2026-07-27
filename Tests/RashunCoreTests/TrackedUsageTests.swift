import XCTest

@testable import RashunCore

final class TrackedUsageTests: XCTestCase, @unchecked Sendable {
    private let base = Date(timeIntervalSinceReferenceDate: 1_000)
    private func observation(
        _ minute: Double, _ remaining: Double, limit: Double = 100, reset: Date? = nil,
        cycle: Date? = nil, origin: TrackedUsageObservationOrigin = .poll
    ) -> TrackedUsageObservation {
        TrackedUsageObservation(
            timestamp: base.addingTimeInterval(minute * 60), sourceName: "Codex",
            metricID: "weekly", metricTitle: "Weekly", remaining: remaining, limit: limit,
            resetDate: reset, cycleStartDate: cycle, origin: origin)
    }
    private func session(_ observations: [TrackedUsageObservation]) -> TrackedSession {
        TrackedSession(labelID: UUID(), labelNameSnapshot: "Acme", observations: observations)
    }

    func testCommandStartRequiresExistingLabelAndRejectsActiveSession() async throws {
        try await MainActor.run {
            let backend = InMemoryPersistenceBackend()
            let appStore = TrackedUsageStore(backend: backend)
            let cliStore = TrackedUsageStore(backend: backend)
            XCTAssertThrowsError(try cliStore.startExistingLabel("Missing"))
            let label = try appStore.createLabel(name: "Work")
            let started = try cliStore.startExistingLabel(label.id.uuidString)
            XCTAssertEqual(started.labelNameSnapshot, "Work")
            XCTAssertEqual(try appStore.readActiveSession()?.id, started.id)
            XCTAssertThrowsError(try appStore.startExistingLabel("Work"))
        }
    }

    func testCommandStopPersistsEmptySessionAndRefreshesOtherStore() async throws {
        try await MainActor.run {
            let backend = InMemoryPersistenceBackend()
            let appStore = TrackedUsageStore(backend: backend)
            let cliStore = TrackedUsageStore(backend: backend)
            _ = try appStore.createLabel(name: "Work")
            let started = try cliStore.startExistingLabel("work")
            let stopped = try appStore.stopActiveSession(
                at: started.startedAt.addingTimeInterval(60))
            XCTAssertEqual(stopped.id, started.id)
            XCTAssertNil(try cliStore.readActiveSession())
            XCTAssertEqual(try cliStore.readSessions().first?.id, started.id)
        }
    }

    func testNoUsageIsHidden() {
        XCTAssertTrue(
            TrackedUsageAttributionEngine.results(
                for: session([
                    observation(0, 50, origin: .start), observation(1, 50, origin: .stop),
                ])
            ).isEmpty)
    }
    func testMonotonicUsage() {
        let result = TrackedUsageAttributionEngine.results(
            for: session([
                observation(0, 80, origin: .start), observation(1, 60),
                observation(2, 50, origin: .stop),
            ]))[0]
        XCTAssertEqual(result.totalConsumedNativeUnits, 30)
        XCTAssertEqual(result.percentagePointsConsumed, 30)
    }
    func testOneResetDoesNotSubtractUpwardMovement() {
        let cycle2 = base.addingTimeInterval(3_600)
        let result = TrackedUsageAttributionEngine.results(
            for: session([
                observation(0, 50, cycle: base, origin: .start), observation(1, 30, cycle: base),
                observation(2, 100, cycle: cycle2), observation(3, 75, cycle: cycle2),
                observation(4, 50, cycle: cycle2, origin: .stop),
            ]))[0]
        XCTAssertEqual(result.totalConsumedNativeUnits, 70)
        XCTAssertEqual(result.segments.count, 2)
    }
    func testMultipleResets() {
        let result = TrackedUsageAttributionEngine.results(
            for: session([
                observation(0, 100, cycle: base, origin: .start), observation(1, 90, cycle: base),
                observation(2, 100, cycle: base.addingTimeInterval(100)),
                observation(3, 80, cycle: base.addingTimeInterval(100)),
                observation(4, 100, cycle: base.addingTimeInterval(200)),
                observation(5, 70, cycle: base.addingTimeInterval(200), origin: .stop),
            ]))[0]
        XCTAssertEqual(result.totalConsumedNativeUnits, 60)
        XCTAssertEqual(result.segments.count, 3)
    }
    func testProgressiveRegenerationIsNotConsumption() {
        let result = TrackedUsageAttributionEngine.results(
            for: session([
                observation(0, 50, origin: .start), observation(1, 30), observation(2, 40),
                observation(3, 35, origin: .stop),
            ]))[0]
        XCTAssertEqual(result.totalConsumedNativeUnits, 25)
        XCTAssertEqual(result.segments.count, 1)
    }
    func testMissingBoundariesAreReported() {
        let result = TrackedUsageAttributionEngine.results(
            for: session([observation(0, 80), observation(1, 60)]))[0]
        XCTAssertFalse(result.isComplete)
        XCTAssertEqual(result.warnings.count, 2)
    }
    func testDuplicateObservationsDoNotAddUsage() {
        let item = observation(1, 50)
        let result = TrackedUsageAttributionEngine.results(
            for: session([
                observation(0, 70, origin: .start), item, item, observation(2, 40, origin: .stop),
            ]))[0]
        XCTAssertEqual(result.totalConsumedNativeUnits, 30)
        XCTAssertEqual(result.observationCount, 4)
    }
    func testLimitChangeUsesPercentageOfPriorLimit() {
        let result = TrackedUsageAttributionEngine.results(
            for: session([
                observation(0, 100, limit: 100, origin: .start),
                observation(1, 80, limit: 200, origin: .stop),
            ]))[0]
        XCTAssertEqual(result.totalConsumedNativeUnits, 20)
        XCTAssertEqual(result.percentagePointsConsumed, 20)
    }
    func testUnconfirmedUpwardJumpDoesNotCreateResetSegment() {
        let result = TrackedUsageAttributionEngine.results(
            for: session([
                observation(0, 20, origin: .start), observation(1, 95),
                observation(2, 80, origin: .stop),
            ]))[0]
        XCTAssertEqual(result.segments.count, 1)
        XCTAssertEqual(result.totalConsumedNativeUnits, 15)
    }
    func testActiveSessionSurvivesStoreReload() async throws {
        try await MainActor.run {
            let backend = InMemoryPersistenceBackend()
            let store = TrackedUsageStore(backend: backend)
            let label = try store.createLabel(name: "Personal")
            _ = try store.start(label: label)
            try store.append(observation(0, 50, origin: .start))
            let reloaded = TrackedUsageStore(backend: backend)
            XCTAssertEqual(try reloaded.readActiveSession()?.labelNameSnapshot, "Personal")
            XCTAssertEqual(try reloaded.readActiveSession()?.observations.count, 1)
        }
    }
    func testSwitchFinalizesExistingSession() async throws {
        try await MainActor.run {
            let store = TrackedUsageStore(backend: InMemoryPersistenceBackend())
            let a = try store.createLabel(name: "A")
            let b = try store.createLabel(name: "B")
            _ = try store.start(label: a, at: base)
            _ = try store.start(label: b, at: base.addingTimeInterval(60))
            XCTAssertEqual(try store.readSessions().count, 1)
            XCTAssertEqual(try store.readSessions()[0].completionState, .interrupted)
            XCTAssertEqual(try store.readActiveSession()?.labelNameSnapshot, "B")
        }
    }
    func testStopDiscardsSessionWithNoObservedUsage() async throws {
        try await MainActor.run {
            let store = TrackedUsageStore(backend: InMemoryPersistenceBackend())
            let label = try store.createLabel(name: "Personal")
            _ = try store.start(label: label)
            try store.append(observation(0, 80, origin: .start))
            try store.append(observation(1, 80, origin: .stop))
            XCTAssertNil(try store.stop())
            XCTAssertTrue(try store.readSessions().isEmpty)
            XCTAssertNil(try store.readActiveSession())
        }
    }
    func testInterleavedUnchangedMetricsAreCoalesced() async throws {
        try await MainActor.run {
            let store = TrackedUsageStore(backend: InMemoryPersistenceBackend())
            let label = try store.createLabel(name: "Personal")
            _ = try store.start(label: label)
            let first = observation(0, 80, origin: .start)
            let other = TrackedUsageObservation(
                timestamp: base, sourceName: "Codex", metricID: "five-hour",
                metricTitle: "Five Hour", remaining: 90, limit: 100, origin: .start)
            try store.append(contentsOf: [first, other])
            try store.append(contentsOf: [
                observation(1, 80),
                TrackedUsageObservation(
                    timestamp: base.addingTimeInterval(60), sourceName: "Codex",
                    metricID: "five-hour", metricTitle: "Five Hour", remaining: 90, limit: 100,
                    origin: .poll),
            ])
            XCTAssertEqual(try store.readActiveSession()?.observations.count, 2)
        }
    }
    func testBoundaryObservationsAreKeptWhenReadingIsUnchanged() async throws {
        try await MainActor.run {
            let store = TrackedUsageStore(backend: InMemoryPersistenceBackend())
            let label = try store.createLabel(name: "Personal")
            _ = try store.start(label: label)
            try store.append(observation(0, 80, origin: .start))
            try store.append(observation(1, 80, origin: .stop))
            XCTAssertEqual(try store.readActiveSession()?.observations.count, 2)
        }
    }
    func testRenamingLabelUpdatesCompletedAndActiveSessions() async throws {
        try await MainActor.run {
            let store = TrackedUsageStore(backend: InMemoryPersistenceBackend())
            var label = try store.createLabel(name: "Old Name")
            _ = try store.start(label: label, at: base)
            try store.append(observation(0, 80, origin: .start))
            try store.append(observation(1, 70, origin: .stop))
            _ = try store.stop(at: base.addingTimeInterval(60))
            _ = try store.start(label: label, at: base.addingTimeInterval(120))

            label.name = "New Name"
            try store.updateLabel(label)

            XCTAssertEqual(try store.readLabels().first?.name, "New Name")
            XCTAssertEqual(try store.readSessions().first?.labelNameSnapshot, "New Name")
            XCTAssertEqual(try store.readActiveSession()?.labelNameSnapshot, "New Name")
        }
    }
    func testEmptyLabelRenameIsRejected() async throws {
        try await MainActor.run {
            let store = TrackedUsageStore(backend: InMemoryPersistenceBackend())
            var label = try store.createLabel(name: "Original")
            label.name = "   "
            XCTAssertThrowsError(try store.updateLabel(label))
            XCTAssertEqual(try store.readLabels().first?.name, "Original")
        }
    }
    func testSyncSnapshotExcludesActiveSessionAndMergesCompletedSession() async throws {
        try await MainActor.run {
            let source = TrackedUsageStore(backend: InMemoryPersistenceBackend())
            let label = try source.createLabel(name: "Client work")
            _ = try source.start(label: label, at: base)
            try source.append(observation(0, 80, origin: .start))
            XCTAssertTrue(try source.syncSnapshot().sessions.isEmpty)

            try source.append(observation(1, 60, origin: .stop))
            let completed = try source.stop(at: base.addingTimeInterval(60))
            XCTAssertNotNil(completed)

            let destination = TrackedUsageStore(backend: InMemoryPersistenceBackend())
            XCTAssertTrue(try destination.mergeSyncSnapshot(source.syncSnapshot()))
            XCTAssertEqual(try destination.readLabels().map(\.id), [label.id])
            XCTAssertEqual(try destination.readSessions().map(\.id), [completed!.id])
            XCTAssertNil(try destination.readActiveSession())
        }
    }
    func testSyncedSessionDeletionDoesNotResurrect() async throws {
        try await MainActor.run {
            let source = TrackedUsageStore(backend: InMemoryPersistenceBackend())
            let label = try source.createLabel(name: "Client work")
            _ = try source.start(label: label, at: base)
            try source.append(observation(0, 80, origin: .start))
            try source.append(observation(1, 60, origin: .stop))
            let session = try source.stop(at: base.addingTimeInterval(60))!
            let stale = try source.syncSnapshot()
            try source.deleteSession(id: session.id)

            let destination = TrackedUsageStore(backend: InMemoryPersistenceBackend())
            _ = try destination.mergeSyncSnapshot(stale)
            _ = try destination.mergeSyncSnapshot(source.syncSnapshot())
            _ = try destination.mergeSyncSnapshot(stale)
            XCTAssertTrue(try destination.readSessions().isEmpty)
        }
    }

    func testQualifiedAppendDoesNotWriteToReplacementSession() async throws {
        try await MainActor.run {
            let store = TrackedUsageStore(backend: InMemoryPersistenceBackend())
            let firstLabel = try store.createLabel(name: "First")
            let secondLabel = try store.createLabel(name: "Second")
            let first = try store.start(label: firstLabel, at: base)
            _ = try store.stopActiveSession(at: base.addingTimeInterval(30))
            let second = try store.start(label: secondLabel, at: base.addingTimeInterval(60))

            XCTAssertFalse(
                try store.append(
                    observation(2, 50, origin: .stop), toActiveSessionID: first.id))
            XCTAssertEqual(try store.readActiveSession()?.id, second.id)
            XCTAssertTrue(try XCTUnwrap(store.readActiveSession()).observations.isEmpty)
        }
    }

    func testQualifiedStopDoesNotStopReplacementSession() async throws {
        try await MainActor.run {
            let store = TrackedUsageStore(backend: InMemoryPersistenceBackend())
            let firstLabel = try store.createLabel(name: "First")
            let secondLabel = try store.createLabel(name: "Second")
            let first = try store.start(label: firstLabel, at: base)
            _ = try store.stopActiveSession(at: base.addingTimeInterval(30))
            let second = try store.start(label: secondLabel, at: base.addingTimeInterval(60))

            XCTAssertNil(try store.stop(activeSessionID: first.id))
            XCTAssertEqual(try store.readActiveSession()?.id, second.id)
        }
    }

    func testMalformedPayloadReadAndMutationPreserveBytes() async throws {
        try await MainActor.run {
            let malformed = Data("{not-json".utf8)
            let backend = InMemoryPersistenceBackend(initialStorage: ["trackedUsage.v1": malformed])
            let store = TrackedUsageStore(backend: backend)

            XCTAssertThrowsError(try store.readLabels()) { error in
                XCTAssertEqual(error as? TrackedUsageStoreError, .invalidPayload)
            }
            XCTAssertThrowsError(try store.createLabel(name: "Would overwrite"))
            XCTAssertEqual(try backend.data(forKey: "trackedUsage.v1"), malformed)
        }
    }

    func testFutureSchemaReadAndMutationPreserveBytes() async throws {
        try await MainActor.run {
            let future = Data(
                "{\"schemaVersion\":3,\"labels\":[],\"sessions\":[],\"activeSession\":null,\"deletedLabels\":[],\"deletedSessions\":[],\"futureField\":true}"
                    .utf8)
            let backend = InMemoryPersistenceBackend(initialStorage: ["trackedUsage.v1": future])
            let store = TrackedUsageStore(backend: backend)

            XCTAssertThrowsError(try store.readSessions()) { error in
                XCTAssertEqual(error as? TrackedUsageStoreError, .unsupportedSchema(3))
            }
            XCTAssertThrowsError(try store.createLabel(name: "Would downgrade"))
            XCTAssertEqual(try backend.data(forKey: "trackedUsage.v1"), future)
        }
    }

    func testFailedCommitDoesNotChangeDurableOrCachedState() async throws {
        try await MainActor.run {
            let backend = FailingPersistenceBackend()
            let store = TrackedUsageStore(backend: backend)
            _ = try store.createLabel(name: "Work")
            let before = try XCTUnwrap(backend.data(forKey: "trackedUsage.v1"))
            backend.failUpdates = true

            XCTAssertThrowsError(try store.startExistingLabel("Work"))
            XCTAssertEqual(try backend.data(forKey: "trackedUsage.v1"), before)
            XCTAssertNil(try store.readActiveSession())
        }
    }

    func testEveryPublicReadPropagatesBackendFailure() async throws {
        try await MainActor.run {
            let backend = FailingPersistenceBackend()
            let store = TrackedUsageStore(backend: backend)
            backend.failReads = true

            XCTAssertThrowsError(try store.readLabels())
            XCTAssertThrowsError(try store.readSessions())
            XCTAssertThrowsError(try store.readActiveSession())
            XCTAssertThrowsError(try store.syncSnapshot())
        }
    }

    func testEncodingFailurePreservesDurableBytes() async throws {
        try await MainActor.run {
            let backend = InMemoryPersistenceBackend()
            let store = TrackedUsageStore(backend: backend)
            _ = try store.createLabel(name: "Work")
            let before = try XCTUnwrap(backend.data(forKey: "trackedUsage.v1"))
            let invalid = TrackedUsageObservation(
                sourceName: "Codex", metricID: "weekly", metricTitle: "Weekly",
                remaining: .nan, limit: 100, origin: .stop)
            let remote = TrackedUsageSyncSnapshot(
                labels: [],
                sessions: [
                    TrackedSession(
                        labelID: UUID(), labelNameSnapshot: "Invalid",
                        observations: [invalid], completionState: .completed)
                ],
                deletedLabels: [], deletedSessions: [])

            XCTAssertThrowsError(try store.mergeSyncSnapshot(remote))
            XCTAssertEqual(try backend.data(forKey: "trackedUsage.v1"), before)
        }
    }

    func testActiveLabelNamesAreCaseInsensitiveUnique() async throws {
        try await MainActor.run {
            let store = TrackedUsageStore(backend: InMemoryPersistenceBackend())
            let first = try store.createLabel(name: "Work")
            var second = try store.createLabel(name: "Personal")
            XCTAssertThrowsError(try store.createLabel(name: "wOrK")) { error in
                XCTAssertEqual(
                    error as? TrackedUsageStoreError, .duplicateActiveLabelName("wOrK"))
            }

            second.name = "WORK"
            XCTAssertThrowsError(try store.updateLabel(second))

            try store.archiveLabel(id: first.id)
            _ = try store.createLabel(name: "WORK")
            XCTAssertThrowsError(try store.archiveLabel(id: first.id, archived: false))
        }
    }

    func testSyncRejectsDuplicateActiveLabelNames() async throws {
        try await MainActor.run {
            let store = TrackedUsageStore(backend: InMemoryPersistenceBackend())
            let local = try store.createLabel(name: "Work")
            let remote = TrackedUsageSyncSnapshot(
                labels: [TrackingLabel(name: "wOrK")], sessions: [], deletedLabels: [],
                deletedSessions: [])

            XCTAssertThrowsError(try store.mergeSyncSnapshot(remote))
            XCTAssertEqual(try store.readLabels().map(\.id), [local.id])
        }
    }
}

private final class FailingPersistenceBackend: PersistenceBackend, @unchecked Sendable {
    private var storage: [String: Data] = [:]
    var failReads = false
    var failUpdates = false

    func data(forKey key: String) throws -> Data? {
        if failReads {
            throw PersistenceBackendError.readFailed(path: key, detail: "injected failure")
        }
        return storage[key]
    }

    func set(_ data: Data?, forKey key: String) throws {
        storage[key] = data
    }

    func updateData(forKey key: String, _ update: (Data?) throws -> Data?) throws -> Data? {
        let updated = try update(storage[key])
        if failUpdates {
            throw PersistenceBackendError.writeFailed(path: key, detail: "injected failure")
        }
        storage[key] = updated
        return updated
    }
}
