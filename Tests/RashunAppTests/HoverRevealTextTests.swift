import XCTest

@testable import Rashun

@MainActor
final class HoverRevealTextTests: XCTestCase {
    func testOverflowDistanceIsZeroWhenTextFits() {
        XCTAssertEqual(
            HoverRevealText.overflowDistance(naturalWidth: 120, availableWidth: 180),
            0
        )
    }

    func testOverflowDistanceMovesExactlyToTrailingEdge() {
        XCTAssertEqual(
            HoverRevealText.overflowDistance(naturalWidth: 245, availableWidth: 180),
            65
        )
    }

    func testRevealDurationIsRestrainedAndDistanceSensitive() {
        XCTAssertEqual(HoverRevealText.revealDuration(for: 5), 0.45)
        XCTAssertGreaterThan(
            HoverRevealText.revealDuration(for: 90),
            HoverRevealText.revealDuration(for: 45)
        )
        XCTAssertEqual(HoverRevealText.revealDuration(for: 500), 1.4)
    }
}
