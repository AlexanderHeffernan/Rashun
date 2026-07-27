import Foundation
import XCTest

@testable import Rashun
@testable import RashunCore

final class BatteryOptimizationTests: XCTestCase {
    @MainActor
    func testMetricFetchOnlyRequestsSelectedMetrics() async throws {
        let recorder = MetricFetchRecorder()
        let source = RecordingSource(recorder: recorder)
        let selected = [source.metrics[2]]

        let result = try await AppDelegate().fetchUsageByMetric(for: source, metrics: selected)
        let recordedMetricIDs = await recorder.metricIDs

        XCTAssertEqual(recordedMetricIDs, ["weekly"])
        XCTAssertEqual(Set(result.usages.keys), ["weekly"])
        XCTAssertTrue(result.errorsByMetric.isEmpty)
    }

    @MainActor
    func testMetricFetchDoesNoWorkWhenNoMetricsAreSelected() async throws {
        let recorder = MetricFetchRecorder()
        let source = RecordingSource(recorder: recorder)

        let result = try await AppDelegate().fetchUsageByMetric(for: source, metrics: [])
        let recordedMetricIDs = await recorder.metricIDs

        XCTAssertEqual(recordedMetricIDs, [])
        XCTAssertTrue(result.usages.isEmpty)
        XCTAssertTrue(result.errorsByMetric.isEmpty)
    }
}

private actor MetricFetchRecorder {
    private(set) var metricIDs: [String] = []

    func record(_ metricID: String) {
        metricIDs.append(metricID)
    }
}

private struct RecordingSource: AISource {
    let recorder: MetricFetchRecorder
    let name = "Recording"
    let requirements = ""
    let metrics = [
        AISourceMetric(id: "free", title: "Free"),
        AISourceMetric(id: "five-hour", title: "Five Hour"),
        AISourceMetric(id: "weekly", title: "Weekly"),
    ]

    func fetchUsage(for metricId: String) async throws -> UsageResult {
        await recorder.record(metricId)
        return UsageResult(remaining: 50, limit: 100)
    }
}
