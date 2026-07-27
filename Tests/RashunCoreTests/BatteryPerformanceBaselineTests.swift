import Foundation
import XCTest

@testable import RashunCore

final class BatteryPerformanceBaselineTests: XCTestCase {
    func testHistoryPersistenceBaseline() async throws {
        try await MainActor.run {
            let fixture = Self.makeHistoryFixture(snapshotCount: 24_630)
            let historyData = try JSONEncoder().encode(fixture)
            let backend = CountingPersistenceBackend(initialStorage: [
                "ai.notificationHistory.v1": historyData,
                "ai.notificationHistory.migrated.v1": Data([1]),
            ])
            let store = UsageHistoryStore(backend: backend, legacyBackends: [])
            backend.resetMeasurements()

            let started = DispatchTime.now().uptimeNanoseconds
            store.append(contentsOf: [
                "AMP::amp-free": UsageResult(remaining: 81, limit: 100),
                "Codex::codex-pro-weekly": UsageResult(
                    remaining: 72,
                    limit: 100,
                    resetDate: Date(timeIntervalSince1970: 1_706_400_000),
                    cycleStartDate: Date(timeIntervalSince1970: 1_705_795_200)
                ),
            ])
            let elapsed = DispatchTime.now().uptimeNanoseconds - started

            let historyWrites = backend.measurements(forKey: "ai.notificationHistory.v1")
            let metadataWrites = backend.measurements(
                forKey: "ai.notificationHistory.sync.v1")
            XCTAssertEqual(historyWrites.count, 1)
            XCTAssertEqual(metadataWrites.count, 1)
            XCTAssertEqual(store.currentSyncRevision, 2)
            print(
                "BATTERY_BASELINE history_persistence"
                    + " fixture_snapshots=24630"
                    + " fixture_bytes=\(historyData.count)"
                    + " enabled_metrics=2"
                    + " history_writes=\(historyWrites.count)"
                    + " history_bytes_written=\(historyWrites.reduce(0) { $0 + $1 })"
                    + " metadata_writes=\(metadataWrites.count)"
                    + " metadata_bytes_written=\(metadataWrites.reduce(0) { $0 + $1 })"
                    + " elapsed_ms=\(Self.milliseconds(elapsed))"
            )
        }
    }

    func testForecastConsumerBaseline() {
        let now = Date(timeIntervalSince1970: 1_706_400_000)
        let resetDate = now.addingTimeInterval(6 * 24 * 3_600)
        let cycleStart = now.addingTimeInterval(-90 * 24 * 3_600)
        let current = UsageResult(
            remaining: 61,
            limit: 100,
            resetDate: resetDate,
            cycleStartDate: cycleStart
        )
        let history = (0..<1_500).map { index in
            let fraction = Double(index) / 1_499
            return UsageSnapshot(
                timestamp: cycleStart.addingTimeInterval(fraction * 90 * 24 * 3_600),
                usage: UsageResult(
                    remaining: 100 - (39 * fraction),
                    limit: 100,
                    resetDate: resetDate,
                    cycleStartDate: cycleStart
                )
            )
        }

        var samples: [UInt64] = []
        for _ in 0..<5 {
            let started = DispatchTime.now().uptimeNanoseconds
            XCTAssertNotNil(
                UsageForecastEngine.resetWindowForecast(
                    sourceLabel: "Fixture",
                    current: current,
                    history: history,
                    resetDate: resetDate,
                    historyWindowHours: 72,
                    now: now,
                    mode: .smart
                )
            )
            XCTAssertNotNil(
                UsageForecastEngine.resetWindowPacingAssessment(
                    current: current,
                    history: history,
                    resetDate: resetDate,
                    historyWindowHours: 72,
                    now: now,
                    mode: .smart
                )
            )
            XCTAssertNotNil(
                UsageForecastEngine.resetWindowPaceGuide(
                    current: current,
                    history: history,
                    resetDate: resetDate,
                    now: now,
                    mode: .smart
                )
            )
            samples.append(DispatchTime.now().uptimeNanoseconds - started)
        }

        let sampleMilliseconds = samples.map(Self.milliseconds)
        let median = sampleMilliseconds.sorted()[sampleMilliseconds.count / 2]
        print(
            "BATTERY_BASELINE forecast_consumers"
                + " fixture_points=1500"
                + " consumers_per_sample=3"
                + " samples=5"
                + " sample_ms=\(sampleMilliseconds.map(String.init).joined(separator: ","))"
                + " median_ms=\(median)"
        )
    }

    nonisolated private static func makeHistoryFixture(snapshotCount: Int) -> [String:
        [UsageSnapshot]]
    {
        let names = ["AMP::amp-free", "Codex::codex-pro-weekly"]
        var result = Dictionary(uniqueKeysWithValues: names.map { ($0, [UsageSnapshot]()) })
        let start = Date(timeIntervalSince1970: 1_698_624_000)
        for index in 0..<snapshotCount {
            let name = names[index % names.count]
            let remaining = 100 - Double((index / names.count) % 100) / 10
            result[name, default: []].append(
                UsageSnapshot(
                    timestamp: start.addingTimeInterval(Double(index) * 60),
                    usage: UsageResult(remaining: remaining, limit: 100)
                )
            )
        }
        return result
    }

    nonisolated private static func milliseconds(_ nanoseconds: UInt64) -> UInt64 {
        nanoseconds / 1_000_000
    }
}

private final class CountingPersistenceBackend: PersistenceBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: Data]
    private var writesByKey: [String: [Int]] = [:]

    init(initialStorage: [String: Data]) {
        storage = initialStorage
    }

    func data(forKey key: String) -> Data? {
        lock.withLock { storage[key] }
    }

    func set(_ data: Data?, forKey key: String) {
        lock.withLock {
            storage[key] = data
            writesByKey[key, default: []].append(data?.count ?? 0)
        }
    }

    func resetMeasurements() {
        lock.withLock { writesByKey.removeAll() }
    }

    func measurements(forKey key: String) -> [Int] {
        lock.withLock { writesByKey[key] ?? [] }
    }
}
