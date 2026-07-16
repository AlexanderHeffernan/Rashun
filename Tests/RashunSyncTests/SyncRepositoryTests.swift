import Foundation
import RashunCore
import XCTest

@testable import RashunSync

final class SyncRepositoryTests: XCTestCase {
    func testStatePersistsIdentityPeersAddressesAndEncryptedSecrets() throws {
        let path = temporaryPath()
        let repository = try SyncRepository(path: path, displayName: "First Mac")
        let credential = PeerCredential(
            secret: Data(repeating: 7, count: 32), scopes: [.desktopSync])
        try repository.savePeer(
            credential, deviceID: UUID(), epoch: UUID(), displayName: "Second Mac")
        let address = URL(string: "https://second-mac.example")!
        try repository.saveAddress(credentialID: credential.id, url: address, kind: .manual)

        let state = try Data(contentsOf: stateURL(for: path))
        XCTAssertFalse(state.range(of: credential.secret) != nil)

        let reopened = try SyncRepository(path: path)
        XCTAssertEqual(reopened.identity.deviceID, repository.identity.deviceID)
        XCTAssertEqual(try reopened.peers().first?.displayName, "Second Mac")
        XCTAssertEqual(try reopened.addresses(credentialID: credential.id).first?.url, address)
        XCTAssertEqual(try reopened.peerCredential(id: credential.id)?.secret, credential.secret)
    }

    func testSimplePairingExpiresAndDesktopCodeIsConsumedOnce() throws {
        let repository = try SyncRepository(path: temporaryPath())
        let now = Date(timeIntervalSince1970: 1_000)
        let access = try PairingCoordinator.simpleAccess(
            repository: repository, scope: .desktopSync, now: now)
        let first = try repository.connectPairingSession(
            password: access.password, requesterName: "Laptop", requesterDeviceID: UUID(),
            requesterEpoch: UUID(), scope: .desktopSync, now: now)
        XCTAssertNotNil(first)
        XCTAssertNil(
            try repository.connectPairingSession(
                password: access.password, requesterName: "Other", requesterDeviceID: UUID(),
                requesterEpoch: UUID(), scope: .desktopSync, now: now))
    }

    func testReplayNoncePersistsAndExpires() throws {
        let repository = try SyncRepository(path: temporaryPath())
        let id = UUID()
        let now = Date(timeIntervalSince1970: 100)
        XCTAssertTrue(
            try repository.consumeNonce(
                credentialID: id, nonce: "one", expiresAt: now.addingTimeInterval(30), now: now))
        XCTAssertFalse(
            try repository.consumeNonce(
                credentialID: id, nonce: "one", expiresAt: now.addingTimeInterval(30), now: now))
        XCTAssertTrue(
            try repository.consumeNonce(
                credentialID: id, nonce: "one", expiresAt: now.addingTimeInterval(90),
                now: now.addingTimeInterval(31)))
    }

    func testCredentialRotationRevokesOldAndPreservesAddresses() throws {
        let repository = try SyncRepository(path: temporaryPath())
        let old = PeerCredential(secret: Data(repeating: 4, count: 32), scopes: [.desktopSync])
        try repository.savePeer(old, deviceID: UUID(), epoch: UUID(), displayName: "Peer")
        let url = URL(string: "http://peer.local:8787")!
        try repository.saveAddress(credentialID: old.id, url: url, kind: .manual)
        let fresh = try repository.rotatePeer(credentialID: old.id)
        XCTAssertNil(try repository.peerCredential(id: old.id))
        XCTAssertNotNil(try repository.peerCredential(id: fresh.id))
        XCTAssertEqual(try repository.addresses(credentialID: fresh.id).first?.url, url)
    }

    func testWebPushSubscriptionPersistsEncryptedAndIsRemovedWithPeer() throws {
        let path = temporaryPath()
        let repository = try SyncRepository(path: path)
        let credential = PeerCredential(
            secret: Data(repeating: 3, count: 32), scopes: [.mobileRead])
        try repository.savePeer(credential, deviceID: UUID(), epoch: UUID(), displayName: "Phone")
        let subscription = WebPushSubscription(
            endpoint: URL(string: "https://push.example/subscription")!,
            clientPublicKey: Data(repeating: 2, count: 65),
            authSecret: Data(repeating: 9, count: 16))
        try repository.saveWebPushSubscription(subscription, credentialID: credential.id)
        XCTAssertEqual(try repository.webPushSubscriptions().first?.subscription, subscription)
        let state = try Data(contentsOf: stateURL(for: path))
        XCTAssertFalse(state.range(of: subscription.authSecret) != nil)
        try repository.revokePeer(credentialID: credential.id)
        XCTAssertTrue(try repository.webPushSubscriptions().isEmpty)
    }

    func testHistoryRevisionCursorsPersistPerPeer() throws {
        let path = temporaryPath()
        let repository = try SyncRepository(path: path)
        let credential = PeerCredential(
            secret: Data(repeating: 5, count: 32), scopes: [.desktopSync])
        try repository.savePeer(credential, deviceID: UUID(), epoch: UUID(), displayName: "Peer")
        try repository.saveHistoryRevisions(
            credentialID: credential.id, remote: 42, localAcknowledged: 37)
        let reopened = try SyncRepository(path: path)
        let revisions = try reopened.historyRevisions(for: credential.id)
        XCTAssertEqual(revisions.remote, 42)
        XCTAssertEqual(revisions.localAcknowledged, 37)
    }

    func testOverlappingOutboundFailureDoesNotOverwriteNewerInboundSuccess() throws {
        let repository = try SyncRepository(path: temporaryPath())
        let credential = PeerCredential(
            secret: Data(repeating: 6, count: 32), scopes: [.desktopSync])
        try repository.savePeer(
            credential, deviceID: UUID(), epoch: UUID(), displayName: "Peer")
        let outboundStart = Date(timeIntervalSince1970: 100)
        try repository.beginPeerSync(credentialID: credential.id, at: outboundStart)
        try repository.finishPeerSync(
            credentialID: credential.id, imported: 4,
            at: outboundStart.addingTimeInterval(1))

        try repository.failPeerSync(
            credentialID: credential.id, error: "Transient network failure",
            attemptStartedAt: outboundStart, at: outboundStart.addingTimeInterval(2))

        let peer = try XCTUnwrap(repository.peers().first)
        XCTAssertNil(peer.lastSyncError)
        XCTAssertEqual(peer.lastSyncImported, 4)
        XCTAssertEqual(peer.lastSyncAt, outboundStart.addingTimeInterval(1))
    }

    func testManualAddressValidation() throws {
        XCTAssertEqual(
            try PeerConnectionService.normalizedURL("192.168.1.20:8787").absoluteString,
            "http://192.168.1.20:8787")
        XCTAssertThrowsError(try PeerConnectionService.normalizedURL("file:///tmp/socket"))
    }

    func testRevisionSyncConvergesOfflineHistoriesAndThenSendsNoDelta() async throws {
        let localRepository = try SyncRepository(path: temporaryPath())
        let remoteRepository = try SyncRepository(path: temporaryPath())
        let credential = PeerCredential(
            secret: Data(repeating: 8, count: 32), scopes: [.desktopSync])
        try localRepository.savePeer(
            credential, deviceID: remoteRepository.identity.deviceID,
            epoch: remoteRepository.identity.epoch, displayName: "Remote")
        let local = HistoryHarness(["Codex::weekly": [Self.snapshot(90, at: 1)]])
        let remote = HistoryHarness(["Codex::weekly": [Self.snapshot(70, at: 2)]])
        let peer = HistoryPeer(identity: remoteRepository.identity, history: remote)
        let coordinator = SyncCoordinator(
            repository: localRepository, history: local.access)

        let first = try await coordinator.reconcile(
            with: peer, credentialID: credential.id)
        let localValues = await local.values()
        let remoteValues = await remote.values()
        XCTAssertEqual(first.accepted, 1)
        XCTAssertEqual(localValues["Codex::weekly"]?.count, 2)
        XCTAssertEqual(remoteValues["Codex::weekly"]?.count, 2)

        let second = try await coordinator.reconcile(
            with: peer, credentialID: credential.id)
        let receivedCount = await peer.lastReceivedSeriesCount()
        XCTAssertEqual(second.accepted, 0)
        XCTAssertEqual(receivedCount, 0)
    }

    func testTrackedUsageTransportFailureDoesNotInvalidateSuccessfulHistorySync() async throws {
        let localRepository = try SyncRepository(path: temporaryPath())
        let remoteRepository = try SyncRepository(path: temporaryPath())
        let credential = PeerCredential(
            secret: Data(repeating: 9, count: 32), scopes: [.desktopSync])
        try localRepository.savePeer(
            credential, deviceID: remoteRepository.identity.deviceID,
            epoch: remoteRepository.identity.epoch, displayName: "Remote")
        let local = HistoryHarness([:])
        let remote = HistoryHarness([:])
        let emptyTrackedUsage = TrackedUsageSyncSnapshot(
            labels: [], sessions: [], deletedLabels: [], deletedSessions: [])
        let trackedUsage = TrackedUsageSyncAccess(
            snapshot: { emptyTrackedUsage }, merge: { _ in false })
        let coordinator = SyncCoordinator(
            repository: localRepository, history: local.access, trackedUsage: trackedUsage)

        let result = try await coordinator.reconcile(
            with: HistoryPeer(identity: remoteRepository.identity, history: remote),
            credentialID: credential.id)

        XCTAssertEqual(result.accepted, 0)
    }

    private func temporaryPath() -> String {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("sync-state").path
    }

    private func stateURL(for path: String) -> URL {
        URL(fileURLWithPath: path).appendingPathComponent("sync-state.json")
    }

    private static func snapshot(_ remaining: Double, at timestamp: TimeInterval) -> UsageSnapshot {
        .init(
            timestamp: Date(timeIntervalSince1970: timestamp),
            usage: .init(remaining: remaining, limit: 100))
    }
}

private actor HistoryHarness {
    private var history: [String: [UsageSnapshot]]
    private var revision: UInt64 = 1
    init(_ history: [String: [UsageSnapshot]]) { self.history = history }
    nonisolated var access: HistorySyncAccess {
        .init(
            revision: { [self] in await currentRevision() },
            snapshot: { [self] since in await snapshot(since) },
            merge: { [self] value in await merge(value) })
    }
    func currentRevision() -> UInt64 { revision }
    func values() -> [String: [UsageSnapshot]] { history }
    func snapshot(_ since: UInt64?) -> HistorySyncSnapshot {
        .init(
            revision: revision, baseRevision: since ?? 0, isComplete: since == nil,
            historyBySource: since == revision ? [:] : history)
    }
    func merge(_ value: HistorySyncSnapshot) -> Bool {
        var changed = false
        for (key, incoming) in value.historyBySource {
            let merged = UsageHistoryStore.compressed((history[key] ?? []) + incoming)
            if merged != history[key] {
                history[key] = merged
                changed = true
            }
        }
        if changed { revision += 1 }
        return changed
    }
}

private actor HistoryPeer: SyncPeerTransport {
    let identity: DeviceIdentity
    let history: HistoryHarness
    private var receivedCount = 0
    init(identity: DeviceIdentity, history: HistoryHarness) {
        self.identity = identity
        self.history = history
    }
    func hello() async throws -> HelloDTO {
        .init(
            deviceID: identity.deviceID, epoch: identity.epoch, protocolMinimum: 1,
            protocolMaximum: 1, serverTime: .now, maximumBatch: 500)
    }
    func reconcileHistory(_ request: HistoryReconcileRequest) async throws
        -> HistoryReconcileResponse
    {
        receivedCount = request.changes.historyBySource.count
        _ = await history.merge(request.changes)
        return .init(
            acknowledgedRevision: request.changes.revision,
            changes: await history.snapshot(request.knownRemoteRevision))
    }
    func lastReceivedSeriesCount() -> Int { receivedCount }
}
