import XCTest

@testable import Rashun

final class UsageChartViewTests: XCTestCase {
    func testHourAxisUsesCompactTimeTicksAndSingleDateContext() throws {
        let tickFormatter = DateFormatter()
        tickFormatter.locale = Locale(identifier: "en_US_POSIX")
        tickFormatter.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        tickFormatter.dateFormat = UsageChartView.xAxisTickDateFormat(duration: 3600)

        let eightAM = Date(timeIntervalSince1970: 28_800)
        let eightTenAM = eightAM.addingTimeInterval(10 * 60)
        XCTAssertEqual(tickFormatter.string(from: eightAM), "8:00")
        XCTAssertEqual(tickFormatter.string(from: eightTenAM), "8:10")

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = tickFormatter.timeZone
        dateFormatter.dateFormat = try XCTUnwrap(
            UsageChartView.xAxisDateContextFormat(duration: 3600))
        XCTAssertEqual(dateFormatter.string(from: eightAM), "Jan 1, 1970")
    }

    func testOtherAxisRangesRetainExistingFormatsWithoutExtraDateContext() {
        let dayDuration: TimeInterval = 24 * 3600
        let weekDuration: TimeInterval = 7 * 24 * 3600
        let monthDuration: TimeInterval = 30 * 24 * 3600
        let allDuration: TimeInterval = 90 * 24 * 3600

        XCTAssertEqual(UsageChartView.xAxisTickDateFormat(duration: dayDuration), "h a MMM d")
        XCTAssertEqual(UsageChartView.xAxisTickDateFormat(duration: weekDuration), "MMM d")
        XCTAssertEqual(UsageChartView.xAxisTickDateFormat(duration: monthDuration), "MMM d")
        XCTAssertEqual(UsageChartView.xAxisTickDateFormat(duration: allDuration), "MMM yyyy")

        XCTAssertNil(UsageChartView.xAxisDateContextFormat(duration: dayDuration))
        XCTAssertNil(UsageChartView.xAxisDateContextFormat(duration: weekDuration))
        XCTAssertNil(UsageChartView.xAxisDateContextFormat(duration: monthDuration))
        XCTAssertNil(UsageChartView.xAxisDateContextFormat(duration: allDuration))
    }
}
