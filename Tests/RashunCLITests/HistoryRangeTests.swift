import XCTest
@testable import RashunCLI
import RashunCore

final class HistoryRangeTests: XCTestCase {
    func testHistoryRangeRawValuesMatchCLIInput() {
        XCTAssertEqual(HistoryRange.day.rawValue, "day")
        XCTAssertEqual(HistoryRange.week.rawValue, "week")
        XCTAssertEqual(HistoryRange.month.rawValue, "month")
        XCTAssertEqual(HistoryRange.all.rawValue, "all")
    }

    func testHistoryRangeMappingToCoreTimeRange() {
        XCTAssertEqual(HistoryRange.day.timeRange, .day)
        XCTAssertEqual(HistoryRange.week.timeRange, .week)
        XCTAssertEqual(HistoryRange.month.timeRange, .month)
        XCTAssertEqual(HistoryRange.all.timeRange, .all)
    }

    func testHistoryRangeSupportsArgumentParserConversion() {
        XCTAssertEqual(HistoryRange(argument: "day"), .day)
        XCTAssertEqual(HistoryRange(argument: "week"), .week)
        XCTAssertEqual(HistoryRange(argument: "month"), .month)
        XCTAssertEqual(HistoryRange(argument: "all"), .all)
        XCTAssertNil(HistoryRange(argument: "year"))
    }
}
