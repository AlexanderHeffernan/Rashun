import XCTest
@testable import RashunCore

final class TrackedUsageTests: XCTestCase {
    private let base = Date(timeIntervalSinceReferenceDate: 1_000)
    private func observation(_ minute: Double, _ remaining: Double, limit: Double = 100, reset: Date? = nil, cycle: Date? = nil, origin: TrackedUsageObservationOrigin = .poll) -> TrackedUsageObservation {
        TrackedUsageObservation(timestamp: base.addingTimeInterval(minute * 60), sourceName: "Codex", metricID: "weekly", metricTitle: "Weekly", remaining: remaining, limit: limit, resetDate: reset, cycleStartDate: cycle, origin: origin)
    }
    private func session(_ observations: [TrackedUsageObservation]) -> TrackedSession { TrackedSession(labelID: UUID(), labelNameSnapshot: "Acme", observations: observations) }

    func testNoUsageIsHidden() { XCTAssertTrue(TrackedUsageAttributionEngine.results(for: session([observation(0, 50, origin: .start), observation(1, 50, origin: .stop)])).isEmpty) }
    func testMonotonicUsage() { let result = TrackedUsageAttributionEngine.results(for: session([observation(0, 80, origin: .start), observation(1, 60), observation(2, 50, origin: .stop)]))[0]; XCTAssertEqual(result.totalConsumedNativeUnits, 30); XCTAssertEqual(result.percentagePointsConsumed, 30) }
    func testOneResetDoesNotSubtractUpwardMovement() { let cycle2 = base.addingTimeInterval(3_600); let result = TrackedUsageAttributionEngine.results(for: session([observation(0, 50, cycle: base, origin: .start), observation(1, 30, cycle: base), observation(2, 100, cycle: cycle2), observation(3, 75, cycle: cycle2), observation(4, 50, cycle: cycle2, origin: .stop)]))[0]; XCTAssertEqual(result.totalConsumedNativeUnits, 70); XCTAssertEqual(result.segments.count, 2) }
    func testMultipleResets() { let result = TrackedUsageAttributionEngine.results(for: session([observation(0, 100, cycle: base, origin: .start), observation(1, 90, cycle: base), observation(2, 100, cycle: base.addingTimeInterval(100)), observation(3, 80, cycle: base.addingTimeInterval(100)), observation(4, 100, cycle: base.addingTimeInterval(200)), observation(5, 70, cycle: base.addingTimeInterval(200), origin: .stop)]))[0]; XCTAssertEqual(result.totalConsumedNativeUnits, 60); XCTAssertEqual(result.segments.count, 3) }
    func testProgressiveRegenerationIsNotConsumption() { let result = TrackedUsageAttributionEngine.results(for: session([observation(0, 50, origin: .start), observation(1, 30), observation(2, 40), observation(3, 35, origin: .stop)]))[0]; XCTAssertEqual(result.totalConsumedNativeUnits, 25); XCTAssertEqual(result.segments.count, 1) }
    func testMissingBoundariesAreReported() { let result = TrackedUsageAttributionEngine.results(for: session([observation(0, 80), observation(1, 60)]))[0]; XCTAssertFalse(result.isComplete); XCTAssertEqual(result.warnings.count, 2) }
    func testDuplicateObservationsDoNotAddUsage() { let item = observation(1, 50); let result = TrackedUsageAttributionEngine.results(for: session([observation(0, 70, origin: .start), item, item, observation(2, 40, origin: .stop)]))[0]; XCTAssertEqual(result.totalConsumedNativeUnits, 30); XCTAssertEqual(result.observationCount, 4) }
    func testLimitChangeUsesPercentageOfPriorLimit() { let result = TrackedUsageAttributionEngine.results(for: session([observation(0, 100, limit: 100, origin: .start), observation(1, 80, limit: 200, origin: .stop)]))[0]; XCTAssertEqual(result.totalConsumedNativeUnits, 20); XCTAssertEqual(result.percentagePointsConsumed, 20) }
    func testUnconfirmedUpwardJumpDoesNotCreateResetSegment() { let result = TrackedUsageAttributionEngine.results(for: session([observation(0, 20, origin: .start), observation(1, 95), observation(2, 80, origin: .stop)]))[0]; XCTAssertEqual(result.segments.count, 1); XCTAssertEqual(result.totalConsumedNativeUnits, 15) }
    @MainActor func testActiveSessionSurvivesStoreReload() { let backend = InMemoryPersistenceBackend(); let store = TrackedUsageStore(backend: backend); let label = store.createLabel(name: "Personal"); _ = store.start(label: label); store.append(observation(0, 50, origin: .start)); let reloaded = TrackedUsageStore(backend: backend); XCTAssertEqual(reloaded.activeSession?.labelNameSnapshot, "Personal"); XCTAssertEqual(reloaded.activeSession?.observations.count, 1) }
    @MainActor func testSwitchFinalizesExistingSession() { let store = TrackedUsageStore(backend: InMemoryPersistenceBackend()); let a = store.createLabel(name: "A"); let b = store.createLabel(name: "B"); _ = store.start(label: a, at: base); _ = store.start(label: b, at: base.addingTimeInterval(60)); XCTAssertEqual(store.sessions.count, 1); XCTAssertEqual(store.sessions[0].completionState, .interrupted); XCTAssertEqual(store.activeSession?.labelNameSnapshot, "B") }
    @MainActor func testStopDiscardsSessionWithNoObservedUsage() { let store = TrackedUsageStore(backend: InMemoryPersistenceBackend()); let label = store.createLabel(name: "Personal"); _ = store.start(label: label); store.append(observation(0, 80, origin: .start)); store.append(observation(1, 80, origin: .stop)); XCTAssertNil(store.stop()); XCTAssertTrue(store.sessions.isEmpty); XCTAssertNil(store.activeSession) }
    @MainActor func testInterleavedUnchangedMetricsAreCoalesced() {
        let store = TrackedUsageStore(backend: InMemoryPersistenceBackend())
        let label = store.createLabel(name: "Personal")
        _ = store.start(label: label)
        let first = observation(0, 80, origin: .start)
        let other = TrackedUsageObservation(timestamp: base, sourceName: "Codex", metricID: "five-hour", metricTitle: "Five Hour", remaining: 90, limit: 100, origin: .start)
        store.append(contentsOf: [first, other])
        store.append(contentsOf: [observation(1, 80), TrackedUsageObservation(timestamp: base.addingTimeInterval(60), sourceName: "Codex", metricID: "five-hour", metricTitle: "Five Hour", remaining: 90, limit: 100, origin: .poll)])
        XCTAssertEqual(store.activeSession?.observations.count, 2)
    }
    @MainActor func testBoundaryObservationsAreKeptWhenReadingIsUnchanged() {
        let store = TrackedUsageStore(backend: InMemoryPersistenceBackend())
        let label = store.createLabel(name: "Personal")
        _ = store.start(label: label)
        store.append(observation(0, 80, origin: .start))
        store.append(observation(1, 80, origin: .stop))
        XCTAssertEqual(store.activeSession?.observations.count, 2)
    }
    @MainActor func testRenamingLabelUpdatesCompletedAndActiveSessions() {
        let store = TrackedUsageStore(backend: InMemoryPersistenceBackend())
        var label = store.createLabel(name: "Old Name")
        _ = store.start(label: label, at: base)
        store.append(observation(0, 80, origin: .start))
        store.append(observation(1, 70, origin: .stop))
        _ = store.stop(at: base.addingTimeInterval(60))
        _ = store.start(label: label, at: base.addingTimeInterval(120))

        label.name = "New Name"
        store.updateLabel(label)

        XCTAssertEqual(store.labels.first?.name, "New Name")
        XCTAssertEqual(store.sessions.first?.labelNameSnapshot, "New Name")
        XCTAssertEqual(store.activeSession?.labelNameSnapshot, "New Name")
    }
    @MainActor func testEmptyLabelRenameIsRejected() {
        let store = TrackedUsageStore(backend: InMemoryPersistenceBackend())
        var label = store.createLabel(name: "Original")
        label.name = "   "
        store.updateLabel(label)
        XCTAssertEqual(store.labels.first?.name, "Original")
    }
}
