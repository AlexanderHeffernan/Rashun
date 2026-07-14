import XCTest
@testable import RashunCore

final class AmpSourceTests: XCTestCase {
    let source = AmpSource()

    // MARK: - parseUsage

    func testMetricBadge() {
        XCTAssertEqual(source.metrics.first?.menuBarBadgeText, "1d")
    }

    func testDisplayName() {
        XCTAssertEqual(source.displayName, "Amp Free")
        XCTAssertEqual(source.metrics.first?.title, "Amp Free")
    }

    func testParseUsage_validOutput() {
        let result = source.parseUsage(from: "Amp Free: 50% remaining today (resets daily)")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.remaining, 50.0)
        XCTAssertEqual(result?.limit, 100.0)
        XCTAssertNotNil(result?.cycleStartDate)
        XCTAssertNotNil(result?.resetDate)
        XCTAssertGreaterThan(result?.resetDate ?? .distantPast, Date())
    }

    func testParseUsage_zeroRemaining() {
        let result = source.parseUsage(from: "Amp Free: 0% remaining today (resets daily)")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.remaining, 0.0)
        XCTAssertEqual(result?.limit, 100.0)
    }

    func testParseUsage_decimalValues() {
        let result = source.parseUsage(from: "Amp Free: 37.5% remaining today (resets daily)")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.remaining, 37.5)
        XCTAssertEqual(result?.limit, 100.0)
    }

    func testParseUsage_fullRemaining() {
        let result = source.parseUsage(from: "Amp Free: 100% remaining today (resets daily)")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.remaining, 100.0)
        XCTAssertEqual(result?.limit, 100.0)
    }

    func testParseUsage_embeddedInMultilineOutput() {
        let output = "Signed in as test\nAmp Free: 75% remaining today (resets daily)\nIndividual credits: $0 remaining"
        let result = source.parseUsage(from: output)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.remaining, 75.0)
        XCTAssertEqual(result?.limit, 100.0)
    }

    func testParseUsage_malformedOutput_returnsNil() {
        XCTAssertNil(source.parseUsage(from: "something else"))
    }

    func testParseUsage_emptyString_returnsNil() {
        XCTAssertNil(source.parseUsage(from: ""))
    }

    func testParseUsage_partialMatch_returnsNil() {
        XCTAssertNil(source.parseUsage(from: "Amp Free: 50% remaining today"))
    }

    func testParseUsage_outOfRangePercentage_returnsNil() {
        XCTAssertNil(source.parseUsage(from: "Amp Free: 101% remaining today (resets daily)"))
    }

    // MARK: - Daily reset schedule (midnight GMT)

    func testParseUsage_resetIsMidnightGMT() {
        let result = source.parseUsage(from: "Amp Free: 50% remaining today (resets daily)")
        guard let reset = result?.resetDate, let cycleStart = result?.cycleStartDate else {
            return XCTFail("Expected cycle start and reset dates")
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "GMT")!

        let resetComponents = calendar.dateComponents([.hour, .minute, .second], from: reset)
        XCTAssertEqual(resetComponents.hour, 0)
        XCTAssertEqual(resetComponents.minute, 0)
        XCTAssertEqual(resetComponents.second, 0)

        // Cycle is one GMT calendar day, midnight → midnight.
        let startComponents = calendar.dateComponents([.hour, .minute, .second], from: cycleStart)
        XCTAssertEqual(startComponents.hour, 0)
        XCTAssertEqual(startComponents.minute, 0)
        XCTAssertEqual(startComponents.second, 0)
        XCTAssertEqual(calendar.dateComponents([.day], from: cycleStart, to: reset).day, 1)
        XCTAssertEqual(reset.timeIntervalSince(cycleStart), 24 * 3600, accuracy: 1)

        let now = Date()
        XCTAssertLessThanOrEqual(cycleStart, now)
        XCTAssertGreaterThan(reset, now)
    }

    func testDailyReset_beforeAndAfterMidnightGMT() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "GMT")!

        // 2026-07-14 23:00 GMT — still waiting for midnight Jul 15.
        let beforeMidnight = gmtDate(2026, 7, 14, 23, calendar: calendar)
        // 2026-07-15 00:00 GMT — exactly at reset; next window is Jul 16.
        let atMidnight = gmtDate(2026, 7, 15, 0, calendar: calendar)
        // 2026-07-15 12:00 GMT — midday; next reset is Jul 16 midnight.
        let midday = gmtDate(2026, 7, 15, 12, calendar: calendar)

        let resetBefore = source.dailyResetDate(reference: beforeMidnight)
        let cycleBefore = source.dailyCycleStartDate(reference: beforeMidnight)
        let resetAtBoundary = source.dailyResetDate(reference: atMidnight)
        let cycleAtBoundary = source.dailyCycleStartDate(reference: atMidnight)
        let resetMidday = source.dailyResetDate(reference: midday)
        let cycleMidday = source.dailyCycleStartDate(reference: midday)

        let expectedResetBefore = gmtDate(2026, 7, 15, 0, calendar: calendar)
        let expectedCycleBefore = gmtDate(2026, 7, 14, 0, calendar: calendar)
        let expectedResetAfter = gmtDate(2026, 7, 16, 0, calendar: calendar)
        let expectedCycleAfter = gmtDate(2026, 7, 15, 0, calendar: calendar)

        XCTAssertEqual(resetBefore, expectedResetBefore)
        XCTAssertEqual(cycleBefore, expectedCycleBefore)
        // At/after midnight GMT rolls to the next GMT calendar day at midnight.
        XCTAssertEqual(resetAtBoundary, expectedResetAfter)
        XCTAssertEqual(cycleAtBoundary, expectedCycleAfter)
        XCTAssertEqual(resetMidday, expectedResetAfter)
        XCTAssertEqual(cycleMidday, expectedCycleAfter)

        XCTAssertEqual(expectedResetBefore.timeIntervalSince(expectedCycleBefore), 24 * 3600, accuracy: 1)
        XCTAssertEqual(calendar.component(.hour, from: resetBefore!), 0)
        XCTAssertEqual(calendar.component(.hour, from: cycleBefore!), 0)
        XCTAssertEqual(calendar.component(.hour, from: resetMidday!), 0)
        XCTAssertEqual(calendar.component(.hour, from: cycleMidday!), 0)
    }

    func testForecast_usesGMTDailyResetWindow() {
        let usage = source.parseUsage(from: "Amp Free: 40% remaining today (resets daily)")!
        let result = source.forecast(for: source.metrics[0].id, current: usage, history: [])
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.points.last?.value, 100.0)
        if let reset = usage.resetDate, let last = result?.points.last?.date {
            XCTAssertEqual(last.timeIntervalSince1970, reset.timeIntervalSince1970, accuracy: 1)
        }
    }

    private func gmtDate(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        calendar: Calendar
    ) -> Date {
        calendar.date(from: DateComponents(
            timeZone: TimeZone(identifier: "GMT")!,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: 0,
            second: 0
        ))!
    }
}
