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
            UsageSnapshot(
                timestamp: fixedDate(hour: 20),
                usage: UsageResult(remaining: 90, limit: 100, resetDate: reset)),
            UsageSnapshot(
                timestamp: fixedDate(hour: 21),
                usage: UsageResult(remaining: 80, limit: 100, resetDate: reset)),
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
            UsageSnapshot(
                timestamp: fixedDate(hour: 14),
                usage: UsageResult(remaining: 90, limit: 100, resetDate: reset)),
            UsageSnapshot(
                timestamp: fixedDate(hour: 16),
                usage: UsageResult(remaining: 75, limit: 100, resetDate: reset)),
            UsageSnapshot(
                timestamp: fixedDate(hour: 18),
                usage: UsageResult(remaining: 50, limit: 100, resetDate: reset)),
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
        XCTAssertNotEqual(assessment?.guidanceDeadline, reset)
        XCTAssertTrue(assessment?.message.contains("until") == true)
    }

    func testConserveDeadlineIsWhenZeroUsageMeetsGuideNotReset() {
        let now = fixedDate(hour: 10)
        let reset = fixedDate(dayOffset: 1, hour: 0)
        let cycleStart = fixedDate(hour: 0)
        let current = UsageResult(
            remaining: 25,
            limit: 100,
            resetDate: reset,
            cycleStartDate: cycleStart
        )

        let assessment = UsageForecastEngine.resetWindowPacingAssessment(
            current: current,
            history: [],
            resetDate: reset,
            now: now,
            calendar: utcCalendar,
            mode: .simple
        )

        XCTAssertEqual(assessment?.recommendation, .conserveHard)
        XCTAssertEqual(assessment?.score ?? 0, -100 / 3, accuracy: 0.001)
        XCTAssertEqual(assessment?.guidanceDeadline, fixedDate(hour: 18))
        XCTAssertEqual(
            guidePercent(at: assessment!.guidanceDeadline!, from: cycleStart, to: reset), 25,
            accuracy: 0.001)
    }

    func testConserveDeadlineConvertsActiveTimeToWallClock() {
        let now = fixedDate(hour: 20)
        let reset = fixedDate(dayOffset: 1, hour: 12)
        let current = UsageResult(
            remaining: 20,
            limit: 100,
            resetDate: reset,
            cycleStartDate: fixedDate(hour: 8)
        )

        let assessment = UsageForecastEngine.resetWindowPacingAssessment(
            current: current,
            history: [],
            resetDate: reset,
            now: now,
            calendar: utcCalendar,
            mode: .smart
        )

        XCTAssertEqual(assessment?.recommendation, .conserve)
        XCTAssertEqual(assessment?.guidanceDeadline, fixedDate(dayOffset: 1, hour: 0))
    }

    func testPushDeadlineIsUndefinedWithoutAConfidentIntersectingBurnRate() {
        let now = fixedDate(hour: 12)
        let reset = fixedDate(dayOffset: 1, hour: 0)
        let current = UsageResult(
            remaining: 70,
            limit: 100,
            resetDate: reset,
            cycleStartDate: fixedDate(hour: 0)
        )

        let assessment = UsageForecastEngine.resetWindowPacingAssessment(
            current: current,
            history: [],
            resetDate: reset,
            now: now,
            calendar: utcCalendar,
            mode: .simple
        )

        XCTAssertEqual(assessment?.recommendation, .push)
        XCTAssertNil(assessment?.guidanceDeadline)
        XCTAssertEqual(assessment?.message, "Push")
    }

    func testPushDurationEndsWhenObservedUsageMeetsGuide() {
        let guideBurnRate = 4.0 / 3600
        let observedBurnRate = 6.0 / 3600

        let duration = UsageForecastEngine.activeSecondsToPacingAlignment(
            currentPercent: 60,
            guidePercent: 50,
            guideBurnRate: guideBurnRate,
            observedBurnRate: observedBurnRate,
            confidence: 0.8
        )

        XCTAssertEqual(duration ?? 0, 5 * 3600, accuracy: 0.001)
        XCTAssertEqual(
            60 - observedBurnRate * duration!, 50 - guideBurnRate * duration!, accuracy: 0.001)
    }

    func testGuidanceDeadlineUsesTimeOnlyToday() {
        let now = fixedDate(hour: 10)
        let deadline = fixedDate(hour: 17, minute: 45)

        XCTAssertEqual(
            UsageForecastEngine.guidanceDeadlineDescription(
                deadline, relativeTo: now, calendar: utcCalendar, locale: enUSLocale),
            "5:45\u{202F}PM")
    }

    func testGuidanceDeadlineIncludesCalendarDateTomorrow() {
        let now = fixedDate(hour: 22)
        let deadline = fixedDate(dayOffset: 1, hour: 17, minute: 45)

        XCTAssertEqual(
            UsageForecastEngine.guidanceDeadlineDescription(
                deadline, relativeTo: now, calendar: utcCalendar, locale: enUSLocale),
            "Jul 7, 2026 at 5:45\u{202F}PM")
    }

    func testGuidanceDeadlineIncludesCalendarDateForLaterDay() {
        let now = fixedDate(hour: 10)
        let deadline = fixedDate(dayOffset: 6, hour: 9, minute: 5)

        XCTAssertEqual(
            UsageForecastEngine.guidanceDeadlineDescription(
                deadline, relativeTo: now, calendar: utcCalendar, locale: enUSLocale),
            "Jul 12, 2026 at 9:05\u{202F}AM")
    }

    func testGuidanceDeadlineUsesCalendarDayAcrossDSTBoundary() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let now = date(
            year: 2026, month: 3, day: 7, hour: 23, minute: 30, calendar: calendar)
        let deadline = date(
            year: 2026, month: 3, day: 8, hour: 3, minute: 30, calendar: calendar)

        XCTAssertEqual(deadline.timeIntervalSince(now), 3 * 3600)
        XCTAssertEqual(
            UsageForecastEngine.guidanceDeadlineDescription(
                deadline, relativeTo: now, calendar: calendar, locale: enUSLocale),
            "Mar 8, 2026 at 3:30\u{202F}AM")
    }

    func testPacingAssessmentScoreIsCurrentDistanceFromGuide() {
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
            UsageSnapshot(
                timestamp: fixedDate(hour: 22),
                usage: UsageResult(remaining: 100, limit: 100, resetDate: reset)),
            UsageSnapshot(
                timestamp: fixedDate(hour: 23),
                usage: UsageResult(remaining: 90, limit: 100, resetDate: reset)),
            UsageSnapshot(
                timestamp: fixedDate(dayOffset: 1, hour: 0),
                usage: UsageResult(remaining: 80, limit: 100, resetDate: reset)),
            UsageSnapshot(
                timestamp: fixedDate(dayOffset: 1, hour: 2),
                usage: UsageResult(remaining: 70, limit: 100, resetDate: reset)),
            UsageSnapshot(
                timestamp: fixedDate(dayOffset: 1, hour: 4),
                usage: UsageResult(remaining: 60, limit: 100, resetDate: reset)),
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
        XCTAssertEqual(assessment?.score ?? 0, -100 / 3, accuracy: 0.001)
        XCTAssertEqual(assessment?.recommendation, .conserveHard)
    }

    func testSeverelyBehindCycleNeverLabelsNegativeScoreOnPaceWithSparseHistory() {
        let now = fixedDate(hour: 4)
        let reset = fixedDate(dayOffset: 2, hour: 0)
        let cycleStart = fixedDate(hour: 0)
        let current = UsageResult(
            remaining: 5,
            limit: 100,
            resetDate: reset,
            cycleStartDate: cycleStart
        )

        let assessment = UsageForecastEngine.resetWindowPacingAssessment(
            current: current,
            history: [],
            resetDate: reset,
            now: now,
            mode: .simple
        )

        XCTAssertNotNil(assessment)
        XCTAssertLessThanOrEqual(assessment!.score, -30)
        XCTAssertEqual(assessment?.recommendation, .conserveHard)
        XCTAssertLessThan(assessment!.confidence, 0.25)
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
            UsageSnapshot(
                timestamp: fixedDate(hour: 7),
                usage: UsageResult(remaining: 100, limit: 100, resetDate: reset)),
            UsageSnapshot(
                timestamp: fixedDate(hour: 8),
                usage: UsageResult(remaining: 94, limit: 100, resetDate: reset)),
            UsageSnapshot(
                timestamp: fixedDate(dayOffset: 1, hour: 7),
                usage: UsageResult(remaining: 94, limit: 100, resetDate: reset)),
            UsageSnapshot(
                timestamp: fixedDate(dayOffset: 1, hour: 8),
                usage: UsageResult(remaining: 88, limit: 100, resetDate: reset)),
            UsageSnapshot(
                timestamp: fixedDate(dayOffset: 2, hour: 7),
                usage: UsageResult(remaining: 88, limit: 100, resetDate: reset)),
            UsageSnapshot(
                timestamp: fixedDate(dayOffset: 2, hour: 8),
                usage: UsageResult(remaining: 82, limit: 100, resetDate: reset)),
            UsageSnapshot(
                timestamp: fixedDate(dayOffset: 3, hour: 7),
                usage: UsageResult(remaining: 66, limit: 100, resetDate: reset)),
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
        XCTAssertGreaterThan(
            smart!.points[smart!.points.count - 2].value,
            simple!.points[simple!.points.count - 2].value)
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
        XCTAssertLessThan(
            monday!.points[monday!.points.count - 2].value,
            thursday!.points[thursday!.points.count - 2].value)
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

    func testOptimizedActiveOffsetsMatchIssue8BaselineGoldenOutputs() throws {
        let now = Date(timeIntervalSince1970: 1_706_400_000)
        let reset = now.addingTimeInterval(6 * 24 * 3_600)
        let cycleStart = now.addingTimeInterval(-90 * 24 * 3_600)
        let current = UsageResult(
            remaining: 61, limit: 100, resetDate: reset, cycleStartDate: cycleStart)
        let history = (0..<1_500).map { index in
            let fraction = Double(index) / 1_499
            return UsageSnapshot(
                timestamp: cycleStart.addingTimeInterval(fraction * 90 * 24 * 3_600),
                usage: UsageResult(
                    remaining: 100 - (39 * fraction), limit: 100, resetDate: reset,
                    cycleStartDate: cycleStart))
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        let forecast = try XCTUnwrap(
            UsageForecastEngine.resetWindowForecast(
                sourceLabel: "Fixture", current: current, history: history, resetDate: reset,
                historyWindowHours: 72, now: now, calendar: calendar, mode: .smart))
        let assessment = try XCTUnwrap(
            UsageForecastEngine.resetWindowPacingAssessment(
                current: current, history: history, resetDate: reset, historyWindowHours: 72,
                now: now, calendar: calendar, mode: .smart))
        let guide = try XCTUnwrap(
            UsageForecastEngine.resetWindowPaceGuide(
                current: current, history: history, resetDate: reset, now: now,
                calendar: calendar, mode: .smart))

        XCTAssertEqual(forecast.points.count, 83)
        XCTAssertEqual(
            forecast.points[forecast.points.count - 2].value, 59.23354337349265,
            accuracy: 1e-10)
        XCTAssertEqual(assessment.score, 54.75, accuracy: 1e-10)
        XCTAssertEqual(assessment.confidence, 0.6, accuracy: 1e-12)
        XCTAssertEqual(assessment.recommendation, .pushHard)
        XCTAssertNil(assessment.projectedZeroDate)
        XCTAssertEqual(guide.points.count, 81)
        XCTAssertEqual(guide.points[40].value, 50, accuracy: 1e-12)
        XCTAssertEqual(guide.points.last?.value ?? -1, 0, accuracy: 1e-12)
    }

    func testAmpDailySourceExposesPacingAssessment() {
        let source = AmpSource()
        let now = fixedDate(hour: 12)
        let reset = fixedDate(dayOffset: 1, hour: 0)
        let assessment = source.pacingAssessment(
            for: source.metrics[0].id,
            current: UsageResult(
                remaining: 50, limit: 100, resetDate: reset, cycleStartDate: fixedDate(hour: 0)),
            history: [],
            now: now
        )

        XCTAssertNotNil(assessment)
    }

    private func fixedDate(dayOffset: Int = 0, hour: Int, minute: Int = 0) -> Date {
        let calendar = utcCalendar
        var components = DateComponents()
        components.timeZone = calendar.timeZone
        components.year = 2026
        components.month = 7
        components.day = 6 + dayOffset
        components.hour = hour
        components.minute = minute
        components.second = 0
        return calendar.date(from: components)!
    }

    private var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private var enUSLocale: Locale {
        Locale(identifier: "en_US")
    }

    private func date(
        year: Int, month: Int, day: Int, hour: Int, minute: Int, calendar: Calendar
    ) -> Date {
        calendar.date(
            from: DateComponents(
                timeZone: calendar.timeZone, year: year, month: month, day: day, hour: hour,
                minute: minute))!
    }

    private func guidePercent(at date: Date, from cycleStart: Date, to reset: Date) -> Double {
        100 * reset.timeIntervalSince(date) / reset.timeIntervalSince(cycleStart)
    }

    private func weekdayProfileHistory(resetDate: Date) -> [UsageSnapshot] {
        [
            UsageSnapshot(
                timestamp: fixedDate(dayOffset: -7, hour: 8),
                usage: UsageResult(remaining: 100, limit: 100, resetDate: resetDate)),
            UsageSnapshot(
                timestamp: fixedDate(dayOffset: -7, hour: 9),
                usage: UsageResult(remaining: 88, limit: 100, resetDate: resetDate)),
            UsageSnapshot(
                timestamp: fixedDate(hour: 8),
                usage: UsageResult(remaining: 88, limit: 100, resetDate: resetDate)),
            UsageSnapshot(
                timestamp: fixedDate(hour: 9),
                usage: UsageResult(remaining: 76, limit: 100, resetDate: resetDate)),
            UsageSnapshot(
                timestamp: fixedDate(dayOffset: 3, hour: 8),
                usage: UsageResult(remaining: 76, limit: 100, resetDate: resetDate)),
            UsageSnapshot(
                timestamp: fixedDate(dayOffset: 3, hour: 9),
                usage: UsageResult(remaining: 75, limit: 100, resetDate: resetDate)),
            UsageSnapshot(
                timestamp: fixedDate(dayOffset: 10, hour: 7),
                usage: UsageResult(remaining: 72, limit: 100, resetDate: resetDate)),
        ]
    }
}
