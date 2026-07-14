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

    // MARK: - Daily reset schedule (5pm Pacific)

    func testParseUsage_resetIs5PMPacific() {
        let result = source.parseUsage(from: "Amp Free: 50% remaining today (resets daily)")
        guard let reset = result?.resetDate, let cycleStart = result?.cycleStartDate else {
            return XCTFail("Expected cycle start and reset dates")
        }

        guard let pacific = TimeZone(identifier: "America/Los_Angeles") else {
            return XCTFail("America/Los_Angeles timezone unavailable")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = pacific

        let resetComponents = calendar.dateComponents([.hour, .minute, .second], from: reset)
        XCTAssertEqual(resetComponents.hour, 17)
        XCTAssertEqual(resetComponents.minute, 0)
        XCTAssertEqual(resetComponents.second, 0)

        // Cycle is one Pacific calendar day (23/24/25h across DST), always 5pm→5pm.
        let startComponents = calendar.dateComponents([.hour, .minute, .second], from: cycleStart)
        XCTAssertEqual(startComponents.hour, 17)
        XCTAssertEqual(startComponents.minute, 0)
        XCTAssertEqual(startComponents.second, 0)
        XCTAssertEqual(calendar.dateComponents([.day], from: cycleStart, to: reset).day, 1)

        let now = Date()
        XCTAssertLessThanOrEqual(cycleStart, now)
        XCTAssertGreaterThan(reset, now)
    }

    func testDailyReset_stays5PMPacificAcrossSpringDST() {
        // 2026-03-08 02:00 → 03:00 PDT (spring forward).
        guard let pacific = TimeZone(identifier: "America/Los_Angeles") else {
            return XCTFail("America/Los_Angeles timezone unavailable")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = pacific

        let after5pmBeforeSpring = pacificDate(2026, 3, 7, 18, calendar: calendar, pacific: pacific)
        let middayOnSpringDay = pacificDate(2026, 3, 8, 12, calendar: calendar, pacific: pacific)
        let exactly5pmSpringDay = pacificDate(2026, 3, 8, 17, calendar: calendar, pacific: pacific)
        let after5pmSpringDay = pacificDate(2026, 3, 8, 18, calendar: calendar, pacific: pacific)

        let resetBefore = source.dailyResetDate(reference: after5pmBeforeSpring)
        let cycleBefore = source.dailyCycleStartDate(reference: after5pmBeforeSpring)
        let resetMidday = source.dailyResetDate(reference: middayOnSpringDay)
        let cycleMidday = source.dailyCycleStartDate(reference: middayOnSpringDay)
        let resetAtBoundary = source.dailyResetDate(reference: exactly5pmSpringDay)
        let cycleAtBoundary = source.dailyCycleStartDate(reference: exactly5pmSpringDay)
        let resetAfter = source.dailyResetDate(reference: after5pmSpringDay)
        let cycleAfter = source.dailyCycleStartDate(reference: after5pmSpringDay)

        // Spring forward happens early morning Mar 8; the 5pm→5pm window that
        // spans it is only 23 wall-clock hours, but still lands on 5pm PT.
        let expectedResetBefore = pacificDate(2026, 3, 8, 17, calendar: calendar, pacific: pacific)
        let expectedCycleBefore = pacificDate(2026, 3, 7, 17, calendar: calendar, pacific: pacific)
        let expectedResetAfter = pacificDate(2026, 3, 9, 17, calendar: calendar, pacific: pacific)
        let expectedCycleAfter = pacificDate(2026, 3, 8, 17, calendar: calendar, pacific: pacific)

        XCTAssertEqual(resetBefore, expectedResetBefore)
        XCTAssertEqual(cycleBefore, expectedCycleBefore)
        // Before 5pm on the spring day, still waiting for that day's 5pm reset.
        XCTAssertEqual(resetMidday, expectedResetBefore)
        XCTAssertEqual(cycleMidday, expectedCycleBefore)
        // At/after 5pm rolls to the next Pacific calendar day at 5pm.
        XCTAssertEqual(resetAtBoundary, expectedResetAfter)
        XCTAssertEqual(cycleAtBoundary, expectedCycleAfter)
        XCTAssertEqual(resetAfter, expectedResetAfter)
        XCTAssertEqual(cycleAfter, expectedCycleAfter)

        XCTAssertEqual(expectedResetBefore.timeIntervalSince(expectedCycleBefore), 23 * 3600, accuracy: 1)
        XCTAssertEqual(calendar.component(.hour, from: resetBefore!), 17)
        XCTAssertEqual(calendar.component(.hour, from: cycleBefore!), 17)
        XCTAssertEqual(calendar.component(.hour, from: resetAfter!), 17)
        XCTAssertEqual(calendar.component(.hour, from: cycleAfter!), 17)
    }

    func testDailyReset_stays5PMPacificAcrossFallDST() {
        // 2026-11-01 02:00 → 01:00 PST (fall back).
        guard let pacific = TimeZone(identifier: "America/Los_Angeles") else {
            return XCTFail("America/Los_Angeles timezone unavailable")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = pacific

        let after5pmBeforeFall = pacificDate(2026, 10, 31, 18, calendar: calendar, pacific: pacific)
        let middayAfterFall = pacificDate(2026, 11, 1, 12, calendar: calendar, pacific: pacific)

        let resetBefore = source.dailyResetDate(reference: after5pmBeforeFall)
        let cycleBefore = source.dailyCycleStartDate(reference: after5pmBeforeFall)
        let resetAfter = source.dailyResetDate(reference: middayAfterFall)
        let cycleAfter = source.dailyCycleStartDate(reference: middayAfterFall)

        let expectedResetBefore = pacificDate(2026, 11, 1, 17, calendar: calendar, pacific: pacific)
        let expectedCycleBefore = pacificDate(2026, 10, 31, 17, calendar: calendar, pacific: pacific)
        let expectedResetAfter = pacificDate(2026, 11, 1, 17, calendar: calendar, pacific: pacific)
        let expectedCycleAfter = pacificDate(2026, 10, 31, 17, calendar: calendar, pacific: pacific)

        XCTAssertEqual(resetBefore, expectedResetBefore)
        XCTAssertEqual(cycleBefore, expectedCycleBefore)
        XCTAssertEqual(resetAfter, expectedResetAfter)
        XCTAssertEqual(cycleAfter, expectedCycleAfter)

        // Fall-back day is 25h wall-clock; still consecutive 5pm PT anchors.
        XCTAssertEqual(expectedResetBefore.timeIntervalSince(expectedCycleBefore), 25 * 3600, accuracy: 1)
        XCTAssertEqual(calendar.component(.hour, from: resetBefore!), 17)
        XCTAssertEqual(calendar.component(.hour, from: cycleBefore!), 17)
    }

    func testForecast_usesPacificDailyResetWindow() {
        let usage = source.parseUsage(from: "Amp Free: 40% remaining today (resets daily)")!
        let result = source.forecast(for: source.metrics[0].id, current: usage, history: [])
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.points.last?.value, 100.0)
        if let reset = usage.resetDate, let last = result?.points.last?.date {
            XCTAssertEqual(last.timeIntervalSince1970, reset.timeIntervalSince1970, accuracy: 1)
        }
    }

    private func pacificDate(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        calendar: Calendar,
        pacific: TimeZone
    ) -> Date {
        calendar.date(from: DateComponents(
            timeZone: pacific,
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: 0,
            second: 0
        ))!
    }
}
