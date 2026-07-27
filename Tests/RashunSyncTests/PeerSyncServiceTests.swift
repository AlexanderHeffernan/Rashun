import Foundation
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

    func testCancellationDuringTransientRetryPreventsSecondRequest() async throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("sync-state").path
        let repository = try SyncRepository(path: path)
        let credential = PeerCredential(
            secret: Data(repeating: 1, count: 32), scopes: [.desktopSync])
        try repository.savePeer(
            credential, deviceID: UUID(), epoch: UUID(), displayName: "Peer")
        try repository.saveAddress(
            credentialID: credential.id, url: URL(string: "https://peer.example")!,
            kind: .manual)
        let peer = RetryFailingPeer()
        let service = PeerSyncService(repository: repository) { _, _ in peer }

        let task = Task { await service.syncAllOnce() }
        while await peer.helloCallCount == 0 {
            await Task.yield()
        }
        task.cancel()
        let attempts = await task.value
        let helloCallCount = await peer.helloCallCount
        let storedPeer = try XCTUnwrap(repository.peers().first)

        XCTAssertTrue(attempts.isEmpty)
        XCTAssertEqual(helloCallCount, 1)
        XCTAssertNil(storedPeer.syncStartedAt)
        XCTAssertNil(storedPeer.lastSyncError)
    }
}

private actor RetryFailingPeer: SyncPeerTransport {
    private(set) var helloCallCount = 0

    func hello() async throws -> HelloDTO {
        helloCallCount += 1
        throw URLError(.timedOut)
    }

    func reconcileHistory(_ request: HistoryReconcileRequest) async throws
        -> HistoryReconcileResponse
    {
        throw URLError(.timedOut)
    }
}
