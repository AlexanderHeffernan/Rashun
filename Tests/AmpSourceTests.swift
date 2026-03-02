import XCTest
@testable import Rashun

final class AmpSourceTests: XCTestCase {
    let source = AmpSource()

    // MARK: - parseUsage

    func testParseUsage_validOutput() {
        let result = source.parseUsage(from: "Amp Free: $5.00/$10.00 remaining")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.remaining, 5.0)
        XCTAssertEqual(result?.limit, 10.0)
    }

    func testParseUsage_zeroRemaining() {
        let result = source.parseUsage(from: "Amp Free: $0.00/$10.00 remaining")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.remaining, 0.0)
        XCTAssertEqual(result?.limit, 10.0)
    }

    func testParseUsage_decimalValues() {
        let result = source.parseUsage(from: "Amp Free: $3.57/$10.00 remaining")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.remaining, 3.57)
        XCTAssertEqual(result?.limit, 10.0)
    }

    func testParseUsage_fullRemaining() {
        let result = source.parseUsage(from: "Amp Free: $10.00/$10.00 remaining")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.remaining, 10.0)
        XCTAssertEqual(result?.limit, 10.0)
    }

    func testParseUsage_embeddedInMultilineOutput() {
        let output = "Some header\nAmp Free: $7.50/$10.00 remaining\nSome footer"
        let result = source.parseUsage(from: output)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.remaining, 7.5)
        XCTAssertEqual(result?.limit, 10.0)
    }

    func testParseUsage_malformedOutput_returnsNil() {
        XCTAssertNil(source.parseUsage(from: "something else"))
    }

    func testParseUsage_emptyString_returnsNil() {
        XCTAssertNil(source.parseUsage(from: ""))
    }

    func testParseUsage_partialMatch_returnsNil() {
        XCTAssertNil(source.parseUsage(from: "Amp Free: $5.00 remaining"))
    }

    // MARK: - forecast

    func testForecast_fullyCharged() {
        let usage = UsageResult(remaining: 10, limit: 10)
        let result = source.forecast(current: usage, history: [])
        XCTAssertNotNil(result)
        XCTAssertTrue(result!.points.isEmpty)
        XCTAssertTrue(result!.summary.contains("fully charged"))
    }

    func testForecast_zeroLimit_returnsNil() {
        let usage = UsageResult(remaining: 0, limit: 0)
        XCTAssertNil(source.forecast(current: usage, history: []))
    }

    func testForecast_partialCharge_reachesHundred() {
        let usage = UsageResult(remaining: 5, limit: 10)
        let result = source.forecast(current: usage, history: [])
        XCTAssertNotNil(result)
        XCTAssertFalse(result!.points.isEmpty)
        XCTAssertTrue(result!.summary.contains("reaches 100%"))
        XCTAssertEqual(result!.points.first!.value, 50.0, accuracy: 0.5)
        XCTAssertEqual(result!.points.last!.value, 100.0, accuracy: 0.1)
    }

    func testForecast_pointsAreChronological() {
        let usage = UsageResult(remaining: 2, limit: 10)
        let result = source.forecast(current: usage, history: [])!
        for i in 1..<result.points.count {
            XCTAssertGreaterThanOrEqual(result.points[i].date, result.points[i - 1].date)
        }
    }

    func testForecast_valuesMonotonicallyIncrease() {
        let usage = UsageResult(remaining: 3, limit: 10)
        let result = source.forecast(current: usage, history: [])!
        for i in 1..<result.points.count {
            XCTAssertGreaterThanOrEqual(result.points[i].value, result.points[i - 1].value - 0.001)
        }
    }
}
