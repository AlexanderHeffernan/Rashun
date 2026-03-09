import XCTest
@testable import RashunCore

final class UsageResultTests: XCTestCase {

    func testPercentRemaining_normalValues() {
        let result = UsageResult(remaining: 50, limit: 100)
        XCTAssertEqual(result.percentRemaining, 50.0)
    }

    func testPercentRemaining_zeroLimit() {
        let result = UsageResult(remaining: 50, limit: 0)
        XCTAssertEqual(result.percentRemaining, 0)
    }

    func testPercentRemaining_zeroRemaining() {
        let result = UsageResult(remaining: 0, limit: 100)
        XCTAssertEqual(result.percentRemaining, 0)
    }

    func testPercentRemaining_fullRemaining() {
        let result = UsageResult(remaining: 100, limit: 100)
        XCTAssertEqual(result.percentRemaining, 100.0)
    }

    func testPercentRemaining_fractionalValues() {
        let result = UsageResult(remaining: 3.5, limit: 10.0)
        XCTAssertEqual(result.percentRemaining, 35.0, accuracy: 0.001)
    }

    func testFormatted_halfRemaining() {
        let result = UsageResult(remaining: 50, limit: 100)
        XCTAssertEqual(result.formatted, "50.0%")
    }

    func testFormatted_zeroPercent() {
        let result = UsageResult(remaining: 0, limit: 100)
        XCTAssertEqual(result.formatted, "0.0%")
    }

    func testFormatted_fullPercent() {
        let result = UsageResult(remaining: 100, limit: 100)
        XCTAssertEqual(result.formatted, "100.0%")
    }

    func testFormatted_zeroLimit() {
        let result = UsageResult(remaining: 50, limit: 0)
        XCTAssertEqual(result.formatted, "0.0%")
    }
}
