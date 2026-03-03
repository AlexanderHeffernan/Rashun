import XCTest
@testable import Rashun

final class CopilotSourceTests: XCTestCase {
    let source = CopilotSource()

    func testForecast_zeroBurnRate() {
        let usage = UsageResult(remaining: 300, limit: 300)
        let result = source.forecast(current: usage, history: [])
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.summary.contains("resets"))
        XCTAssertFalse(result!.summary.contains("UTC"))
    }

    func testForecast_activeBurnRate_lastPointIs100() {
        let usage = UsageResult(remaining: 150, limit: 300)
        let result = source.forecast(current: usage, history: [])
        XCTAssertNotNil(result)
        XCTAssertFalse(result!.points.isEmpty)
        XCTAssertEqual(result!.points.last!.value, 100.0)
    }

    func testForecast_firstPointIsCurrentPercent() {
        let usage = UsageResult(remaining: 150, limit: 300)
        let result = source.forecast(current: usage, history: [])!
        XCTAssertEqual(result.points.first!.value, 50.0, accuracy: 0.1)
    }

    func testForecast_zeroRemaining() {
        let usage = UsageResult(remaining: 0, limit: 300)
        let result = source.forecast(current: usage, history: [])
        XCTAssertNotNil(result)
        // Already at 0%, so summary shows projected value at reset
        XCTAssertTrue(result!.summary.contains("reset"))
    }

    func testForecast_pointsAreChronological() {
        let usage = UsageResult(remaining: 100, limit: 300)
        let result = source.forecast(current: usage, history: [])!
        for i in 1..<result.points.count {
            XCTAssertGreaterThanOrEqual(result.points[i].date, result.points[i - 1].date)
        }
    }

    func testForecast_resetJumpsTo100() {
        let usage = UsageResult(remaining: 100, limit: 300)
        let result = source.forecast(current: usage, history: [])!
        let lastTwo = Array(result.points.suffix(2))
        XCTAssertEqual(lastTwo.count, 2)
        // The second-to-last point should be the pre-reset value, last should be 100%
        XCTAssertEqual(lastTwo[1].value, 100.0)
        XCTAssertLessThanOrEqual(lastTwo[0].value, 100.0)
    }
}
