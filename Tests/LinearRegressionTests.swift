import XCTest
@testable import Rashun

final class LinearRegressionTests: XCTestCase {

    func testSlope_positiveLinear() {
        let slope = LinearRegression.slope(xs: [0, 1, 2, 3], ys: [0, 2, 4, 6])
        XCTAssertNotNil(slope)
        XCTAssertEqual(slope!, 2.0, accuracy: 0.001)
    }

    func testSlope_negativeLinear() {
        let slope = LinearRegression.slope(xs: [0, 1, 2], ys: [6, 4, 2])
        XCTAssertNotNil(slope)
        XCTAssertEqual(slope!, -2.0, accuracy: 0.001)
    }

    func testSlope_flatLine() {
        let slope = LinearRegression.slope(xs: [0, 1, 2], ys: [5, 5, 5])
        XCTAssertNotNil(slope)
        XCTAssertEqual(slope!, 0.0, accuracy: 0.001)
    }

    func testSlope_twoPoints() {
        let slope = LinearRegression.slope(xs: [0, 10], ys: [0, 5])
        XCTAssertNotNil(slope)
        XCTAssertEqual(slope!, 0.5, accuracy: 0.001)
    }

    func testSlope_singlePoint_returnsNil() {
        XCTAssertNil(LinearRegression.slope(xs: [1], ys: [2]))
    }

    func testSlope_empty_returnsNil() {
        XCTAssertNil(LinearRegression.slope(xs: [], ys: []))
    }

    func testSlope_identicalXValues_returnsNil() {
        XCTAssertNil(LinearRegression.slope(xs: [3, 3, 3], ys: [1, 2, 3]))
    }

    func testSlope_fractionalResult() {
        let slope = LinearRegression.slope(xs: [1, 2, 3, 4], ys: [1, 3, 2, 4])
        XCTAssertNotNil(slope)
        XCTAssertEqual(slope!, 0.8, accuracy: 0.001)
    }
}
