import XCTest
@testable import RashunCore

final class UsageForecastEngineTests: XCTestCase {
    func testEarlyCycleBurstDoesNotImmediatelyConserveHard() {
        let now = fixedDate(hour: 9)
        let reset = now.addingTimeInterval(5 * 3600)
        let current = UsageResult(
            remaining: 99,
            limit: 100,
            resetDate: reset,
            cycleStartDate: now.addingTimeInterval(-5 * 60)
        )
        let history = [
            UsageSnapshot(
                timestamp: now.addingTimeInterval(-5 * 60),
                usage: UsageResult(remaining: 100, limit: 100, resetDate: reset)
            )
        ]

        let assessment = UsageForecastEngine.resetWindowPacingAssessment(
            current: current,
            history: history,
            resetDate: reset,
            now: now
        )

        XCTAssertNotNil(assessment)
        XCTAssertNotEqual(assessment?.recommendation, .conserveHard)
        XCTAssertLessThan(assessment?.confidence ?? 1, 0.35)
    }

    func testOvernightResetDoesNotConserveWhenActiveTimeIsShort() {
        let now = fixedDate(hour: 22)
        let reset = fixedDate(dayOffset: 1, hour: 4)
        let cycleStart = fixedDate(hour: 8)
        let current = UsageResult(
            remaining: 60,
            limit: 100,
            resetDate: reset,
            cycleStartDate: cycleStart
        )
        let history = [
            UsageSnapshot(timestamp: fixedDate(hour: 20), usage: UsageResult(remaining: 90, limit: 100, resetDate: reset)),
            UsageSnapshot(timestamp: fixedDate(hour: 21), usage: UsageResult(remaining: 80, limit: 100, resetDate: reset)),
            UsageSnapshot(timestamp: now, usage: current),
        ]

        let assessment = UsageForecastEngine.resetWindowPacingAssessment(
            current: current,
            history: history,
            resetDate: reset,
            now: now
        )

        XCTAssertNotNil(assessment)
        XCTAssertFalse([.conserve, .conserveHard].contains(assessment!.recommendation))
    }

    func testSustainedDepletionWithEvidenceConserves() {
        let now = fixedDate(hour: 20)
        let reset = fixedDate(dayOffset: 1, hour: 22)
        let cycleStart = fixedDate(hour: 8)
        let current = UsageResult(
            remaining: 20,
            limit: 100,
            resetDate: reset,
            cycleStartDate: cycleStart
        )
        let history = [
            UsageSnapshot(timestamp: fixedDate(hour: 14), usage: UsageResult(remaining: 90, limit: 100, resetDate: reset)),
            UsageSnapshot(timestamp: fixedDate(hour: 16), usage: UsageResult(remaining: 75, limit: 100, resetDate: reset)),
            UsageSnapshot(timestamp: fixedDate(hour: 18), usage: UsageResult(remaining: 50, limit: 100, resetDate: reset)),
            UsageSnapshot(timestamp: now, usage: current),
        ]

        let assessment = UsageForecastEngine.resetWindowPacingAssessment(
            current: current,
            history: history,
            resetDate: reset,
            now: now
        )

        XCTAssertNotNil(assessment)
        XCTAssertTrue([.conserve, .conserveHard].contains(assessment!.recommendation))
        XCTAssertGreaterThan(assessment!.confidence, 0.35)
    }

    func testPacingAssessmentClampsDisplayedScore() {
        let now = fixedDate(dayOffset: 1, hour: 8)
        let reset = fixedDate(dayOffset: 3, hour: 10)
        let cycleStart = fixedDate(hour: 22)
        let current = UsageResult(
            remaining: 50,
            limit: 100,
            resetDate: reset,
            cycleStartDate: cycleStart
        )
        let history = [
            UsageSnapshot(timestamp: fixedDate(hour: 22), usage: UsageResult(remaining: 100, limit: 100, resetDate: reset)),
            UsageSnapshot(timestamp: fixedDate(hour: 23), usage: UsageResult(remaining: 90, limit: 100, resetDate: reset)),
            UsageSnapshot(timestamp: fixedDate(dayOffset: 1, hour: 0), usage: UsageResult(remaining: 80, limit: 100, resetDate: reset)),
            UsageSnapshot(timestamp: fixedDate(dayOffset: 1, hour: 2), usage: UsageResult(remaining: 70, limit: 100, resetDate: reset)),
            UsageSnapshot(timestamp: fixedDate(dayOffset: 1, hour: 4), usage: UsageResult(remaining: 60, limit: 100, resetDate: reset)),
            UsageSnapshot(timestamp: now, usage: current),
        ]

        let assessment = UsageForecastEngine.resetWindowPacingAssessment(
            current: current,
            history: history,
            resetDate: reset,
            now: now,
            mode: .simple
        )

        XCTAssertNotNil(assessment)
        XCTAssertEqual(assessment?.score, -100)
        XCTAssertEqual(assessment?.recommendation, .conserveHard)
    }

    func testSmartForecastLearnsDifferentHourlyBurnRates() {
        let now = fixedDate(dayOffset: 3, hour: 8)
        let reset = fixedDate(dayOffset: 3, hour: 14)
        let current = UsageResult(
            remaining: 60,
            limit: 100,
            resetDate: reset,
            cycleStartDate: fixedDate(dayOffset: 3, hour: 6)
        )
        let history = [
            UsageSnapshot(timestamp: fixedDate(hour: 7), usage: UsageResult(remaining: 100, limit: 100, resetDate: reset)),
            UsageSnapshot(timestamp: fixedDate(hour: 8), usage: UsageResult(remaining: 94, limit: 100, resetDate: reset)),
            UsageSnapshot(timestamp: fixedDate(dayOffset: 1, hour: 7), usage: UsageResult(remaining: 94, limit: 100, resetDate: reset)),
            UsageSnapshot(timestamp: fixedDate(dayOffset: 1, hour: 8), usage: UsageResult(remaining: 88, limit: 100, resetDate: reset)),
            UsageSnapshot(timestamp: fixedDate(dayOffset: 2, hour: 7), usage: UsageResult(remaining: 88, limit: 100, resetDate: reset)),
            UsageSnapshot(timestamp: fixedDate(dayOffset: 2, hour: 8), usage: UsageResult(remaining: 82, limit: 100, resetDate: reset)),
            UsageSnapshot(timestamp: fixedDate(dayOffset: 3, hour: 7), usage: UsageResult(remaining: 66, limit: 100, resetDate: reset)),
            UsageSnapshot(timestamp: now, usage: current),
        ]

        let smart = UsageForecastEngine.resetWindowForecast(
            sourceLabel: "Test",
            current: current,
            history: history,
            resetDate: reset,
            historyWindowHours: 24 * 7,
            now: now,
            mode: .smart
        )
        let simple = UsageForecastEngine.resetWindowForecast(
            sourceLabel: "Test",
            current: current,
            history: history,
            resetDate: reset,
            historyWindowHours: 24 * 7,
            now: now,
            mode: .simple
        )

        XCTAssertNotNil(smart)
        XCTAssertNotNil(simple)
        XCTAssertGreaterThan(smart!.points[smart!.points.count - 2].value, simple!.points[simple!.points.count - 2].value)
    }

    func testSmartForecastLearnsDifferentWeekdayHourlyBurnRates() {
        let mondayNow = fixedDate(dayOffset: 7, hour: 8)
        let mondayReset = fixedDate(dayOffset: 7, hour: 14)
        let thursdayNow = fixedDate(dayOffset: 10, hour: 8)
        let thursdayReset = fixedDate(dayOffset: 10, hour: 14)
        let mondayCurrent = UsageResult(
            remaining: 70,
            limit: 100,
            resetDate: mondayReset,
            cycleStartDate: fixedDate(dayOffset: 7, hour: 6)
        )
        let thursdayCurrent = UsageResult(
            remaining: 70,
            limit: 100,
            resetDate: thursdayReset,
            cycleStartDate: fixedDate(dayOffset: 10, hour: 6)
        )
        let mondayHistory = weekdayProfileHistory(resetDate: mondayReset)
        let thursdayHistory = weekdayProfileHistory(resetDate: thursdayReset)

        let monday = UsageForecastEngine.resetWindowForecast(
            sourceLabel: "Test",
            current: mondayCurrent,
            history: mondayHistory,
            resetDate: mondayReset,
            historyWindowHours: 24 * 21,
            now: mondayNow,
            mode: .smart
        )
        let thursday = UsageForecastEngine.resetWindowForecast(
            sourceLabel: "Test",
            current: thursdayCurrent,
            history: thursdayHistory,
            resetDate: thursdayReset,
            historyWindowHours: 24 * 21,
            now: thursdayNow,
            mode: .smart
        )

        XCTAssertNotNil(monday)
        XCTAssertNotNil(thursday)
        XCTAssertLessThan(monday!.points[monday!.points.count - 2].value, thursday!.points[thursday!.points.count - 2].value)
    }

    func testResetWindowPaceGuideRunsFromFullToEmptyAtReset() {
        let now = fixedDate(hour: 12)
        let reset = fixedDate(dayOffset: 1, hour: 12)
        let cycleStart = fixedDate(hour: 0)
        let current = UsageResult(
            remaining: 70,
            limit: 100,
            resetDate: reset,
            cycleStartDate: cycleStart
        )

        let guide = UsageForecastEngine.resetWindowPaceGuide(
            current: current,
            history: [],
            resetDate: reset,
            now: now,
            mode: .simple
        )

        XCTAssertNotNil(guide)
        XCTAssertEqual(guide?.points.first?.date, cycleStart)
        XCTAssertEqual(guide?.points.first?.value ?? -1, 100, accuracy: 0.001)
        XCTAssertEqual(guide?.points.last?.date, reset)
        XCTAssertEqual(guide?.points.last?.value ?? -1, 0, accuracy: 0.001)
    }

    func testAmpRefillSourceDoesNotExposePacingAssessment() {
        let source = AmpSource()
        let assessment = source.pacingAssessment(
            for: source.metrics[0].id,
            current: UsageResult(remaining: 5, limit: 10),
            history: [],
            now: fixedDate(hour: 12)
        )

        XCTAssertNil(assessment)
    }

    private func fixedDate(dayOffset: Int = 0, hour: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        var components = DateComponents()
        components.timeZone = calendar.timeZone
        components.year = 2026
        components.month = 7
        components.day = 6 + dayOffset
        components.hour = hour
        components.minute = 0
        components.second = 0
        return calendar.date(from: components)!
    }

    private func weekdayProfileHistory(resetDate: Date) -> [UsageSnapshot] {
        [
            UsageSnapshot(timestamp: fixedDate(dayOffset: -7, hour: 8), usage: UsageResult(remaining: 100, limit: 100, resetDate: resetDate)),
            UsageSnapshot(timestamp: fixedDate(dayOffset: -7, hour: 9), usage: UsageResult(remaining: 88, limit: 100, resetDate: resetDate)),
            UsageSnapshot(timestamp: fixedDate(hour: 8), usage: UsageResult(remaining: 88, limit: 100, resetDate: resetDate)),
            UsageSnapshot(timestamp: fixedDate(hour: 9), usage: UsageResult(remaining: 76, limit: 100, resetDate: resetDate)),
            UsageSnapshot(timestamp: fixedDate(dayOffset: 3, hour: 8), usage: UsageResult(remaining: 76, limit: 100, resetDate: resetDate)),
            UsageSnapshot(timestamp: fixedDate(dayOffset: 3, hour: 9), usage: UsageResult(remaining: 75, limit: 100, resetDate: resetDate)),
            UsageSnapshot(timestamp: fixedDate(dayOffset: 10, hour: 7), usage: UsageResult(remaining: 72, limit: 100, resetDate: resetDate)),
        ]
    }
}
