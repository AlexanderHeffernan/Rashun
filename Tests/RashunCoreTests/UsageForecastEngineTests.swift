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
}
