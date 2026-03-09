import XCTest
@testable import RashunCore

final class ChartTimeRangeTests: XCTestCase {

    func testAll_returnsNilBounds() {
        let (start, end) = ChartTimeRange.all.rangeBounds(now: Date())
        XCTAssertNil(start)
        XCTAssertNil(end)
    }

    func testDay_coversOneDay() {
        let now = Date()
        let (start, end) = ChartTimeRange.day.rangeBounds(now: now)
        XCTAssertNotNil(start)
        XCTAssertNotNil(end)
        let interval = end!.timeIntervalSince(start!)
        // Should be ~24 hours (86400s), with slight tolerance for DST
        XCTAssertEqual(interval, 86400, accuracy: 3600)
    }

    func testWeek_coversOneWeek() {
        let now = Date()
        let (start, end) = ChartTimeRange.week.rangeBounds(now: now)
        XCTAssertNotNil(start)
        XCTAssertNotNil(end)
        let days = end!.timeIntervalSince(start!) / 86400
        XCTAssertEqual(days, 7, accuracy: 1)
    }

    func testMonth_covers28to31Days() {
        let now = Date()
        let (start, end) = ChartTimeRange.month.rangeBounds(now: now)
        XCTAssertNotNil(start)
        XCTAssertNotNil(end)
        let days = end!.timeIntervalSince(start!) / 86400
        XCTAssertGreaterThanOrEqual(days, 28)
        XCTAssertLessThanOrEqual(days, 31)
    }

    func testDay_containsNow() {
        let now = Date()
        let (start, end) = ChartTimeRange.day.rangeBounds(now: now)
        XCTAssertLessThanOrEqual(start!, now)
        XCTAssertGreaterThanOrEqual(end!, now)
    }

    func testWeek_containsNow() {
        let now = Date()
        let (start, end) = ChartTimeRange.week.rangeBounds(now: now)
        XCTAssertLessThanOrEqual(start!, now)
        XCTAssertGreaterThanOrEqual(end!, now)
    }

    func testMonth_containsNow() {
        let now = Date()
        let (start, end) = ChartTimeRange.month.rangeBounds(now: now)
        XCTAssertLessThanOrEqual(start!, now)
        XCTAssertGreaterThanOrEqual(end!, now)
    }
}
