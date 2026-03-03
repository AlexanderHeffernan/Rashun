import XCTest
@testable import Rashun

final class CodexSourceTests: XCTestCase {
    let source = CodexSource()

    func testParseLatestTokenCountParsesUsedPercentAndReset() {
        let line = #"{"timestamp":"2026-02-05T23:41:03.396Z","type":"event_msg","payload":{"type":"token_count","info":{"rate_limits":{"primary":{"used_percent":73.5,"window_minutes":10080,"resets_at":1770799659}}}}}"#
        let sample = source.parseLatestTokenCount(from: line)

        XCTAssertEqual(sample?.timestamp.timeIntervalSince1970 ?? 0, 1_770_334_863.396, accuracy: 0.001)
        XCTAssertEqual(sample?.usedPercent, 73.5)
        XCTAssertEqual(sample?.resetsAtEpoch, 1770799659)
    }

    func testParseLatestTokenCountParsesPayloadLevelRateLimits() {
        let line = #"{"timestamp":"2026-03-02T23:13:10.936Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"limit_id":"codex","primary":{"used_percent":4.0,"window_minutes":10080,"resets_at":1772691486}}}}"#
        let sample = source.parseLatestTokenCount(from: line)

        XCTAssertEqual(sample?.timestamp.timeIntervalSince1970 ?? 0, 1_772_493_190.936, accuracy: 0.001)
        XCTAssertEqual(sample?.usedPercent, 4.0)
        XCTAssertEqual(sample?.resetsAtEpoch, 1772691486)
    }

    func testParseLatestTokenCountIgnoresNonCodexLimitID() {
        let line = #"{"timestamp":"2026-03-02T23:13:10.936Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"something_else","primary":{"used_percent":4.0,"window_minutes":10080,"resets_at":1772691486}}}}"#
        let sample = source.parseLatestTokenCount(from: line)

        XCTAssertNil(sample)
    }

    func testParseLatestTokenCountUsesLatestMatchingLine() {
        let content = """
        {"timestamp":"2026-03-02T10:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"rate_limits":{"primary":{"used_percent":90.0}}}}}
        {"timestamp":"2026-03-02T11:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"rate_limits":{"primary":{"used_percent":40.0}}}}}
        """

        let sample = source.parseLatestTokenCount(from: content)
        XCTAssertEqual(sample?.usedPercent, 40.0)
    }

    func testNumericValueSupportsIntDoubleAndNSNumber() {
        XCTAssertEqual(source.numericValue(5), 5)
        XCTAssertEqual(source.numericValue(12.5), 12.5)
        XCTAssertEqual(source.numericValue(NSNumber(value: 8.25)), 8.25)
        XCTAssertNil(source.numericValue("10"))
    }

    func testForecast_jumpsTo100AtReset() {
        let now = Date()
        let reset = now.addingTimeInterval(6 * 3600)
        let current = UsageResult(remaining: 45, limit: 100, resetDate: reset)
        let history = [
            UsageSnapshot(timestamp: now.addingTimeInterval(-2 * 3600), usage: UsageResult(remaining: 70, limit: 100, resetDate: reset)),
            UsageSnapshot(timestamp: now.addingTimeInterval(-3600), usage: UsageResult(remaining: 58, limit: 100, resetDate: reset)),
        ]

        let forecast = source.forecast(current: current, history: history)
        XCTAssertNotNil(forecast)
        XCTAssertEqual(forecast!.points.last!.value, 100, accuracy: 0.001)
        XCTAssertTrue(forecast!.summary.contains("resets"))
    }

    func testForecast_ignoresOldCycleHistoryAfterResetChange() {
        let now = Date()
        let oldReset = now.addingTimeInterval(2 * 3600)
        let newReset = now.addingTimeInterval(5 * 24 * 3600)
        let current = UsageResult(
            remaining: 100,
            limit: 100,
            resetDate: newReset,
            cycleStartDate: now.addingTimeInterval(-30 * 60)
        )
        let history = [
            // Old cycle trend that should not influence the new cycle forecast.
            UsageSnapshot(timestamp: now.addingTimeInterval(-3 * 3600), usage: UsageResult(remaining: 70, limit: 100, resetDate: oldReset)),
            UsageSnapshot(timestamp: now.addingTimeInterval(-2 * 3600), usage: UsageResult(remaining: 40, limit: 100, resetDate: oldReset)),
            // New cycle sample is still full.
            UsageSnapshot(timestamp: now.addingTimeInterval(-10 * 60), usage: UsageResult(remaining: 100, limit: 100, resetDate: newReset)),
        ]

        let forecast = source.forecast(current: current, history: history)
        XCTAssertNotNil(forecast)
        XCTAssertFalse(forecast!.summary.contains("projected 0%"))
        XCTAssertTrue(forecast!.points.allSatisfy { abs($0.value - 100) < 0.001 })
    }
}
