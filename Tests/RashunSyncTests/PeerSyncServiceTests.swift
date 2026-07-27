import XCTest

@testable import RashunSync

final class PeerSyncServiceTests: XCTestCase {
    func testFailureRetriesReturnToConfiguredIntervalAfterInitialBackoff() {
        let interval = Duration.seconds(1_200)

        XCTAssertEqual(
            PeerSyncService.failureRetryDelay(failureCount: 1, interval: interval), .seconds(15)
        )
        XCTAssertEqual(
            PeerSyncService.failureRetryDelay(failureCount: 2, interval: interval), .seconds(30)
        )
        XCTAssertEqual(
            PeerSyncService.failureRetryDelay(failureCount: 3, interval: interval), .seconds(60)
        )
        XCTAssertEqual(
            PeerSyncService.failureRetryDelay(failureCount: 4, interval: interval), interval
        )
        XCTAssertEqual(
            PeerSyncService.failureRetryDelay(failureCount: 20, interval: interval), interval
        )
    }
}
