import Crypto
import RashunCore
import XCTest

@testable import RashunSync

final class SyncRepositoryTests: XCTestCase {
    func testWebPushSubscriptionPersistsEncryptedAndIsRemovedWithRevokedPeer() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .path
        let repo = try SyncRepository(path: path)
        let credential = PeerCredential(
            secret: Data(repeating: 4, count: 32), scopes: [.mobileRead])
        try repo.savePeer(credential, deviceID: UUID(), epoch: UUID(), displayName: "Phone")
        let clientKey = P256.KeyAgreement.PrivateKey().publicKey.x963Representation
        let auth = Data(repeating: 9, count: 16)
        let subscription = WebPushSubscription(
            endpoint: URL(string: "https://push.example.test/message/1")!,
            clientPublicKey: clientKey,
            authSecret: auth)
        try repo.saveWebPushSubscription(subscription, credentialID: credential.id)
        XCTAssertEqual(try repo.webPushSubscriptions().first?.subscription, subscription)
        XCTAssertEqual(try repo.peers().first?.hasPushSubscription, true)
        let databaseBytes = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertNil(databaseBytes.range(of: auth))
        try repo.removeWebPushSubscription(credentialID: credential.id)
        XCTAssertEqual(try repo.peers().first?.hasPushSubscription, false)
        try repo.saveWebPushSubscription(subscription, credentialID: credential.id)
        try repo.revokePeer(credentialID: credential.id)
        XCTAssertTrue(try repo.webPushSubscriptions().isEmpty)
    }

    func testManualAddressSecurity() throws {
        XCTAssertThrowsError(try ManualPeerAddress.validate("http://192.168.1.2:8787"))
        XCTAssertNoThrow(try ManualPeerAddress.validate("https://desk.example.com"))
        XCTAssertNoThrow(
            try ManualPeerAddress.validate("http://127.0.0.1:8787", allowLoopbackHTTP: true))
    }
    func testPeerConnectionNormalizesUserFriendlyAddresses() throws {
        XCTAssertEqual(
            try PeerConnectionService.normalizedURL("192.168.1.20:8787").absoluteString,
            "http://192.168.1.20:8787")
        XCTAssertEqual(
            try PeerConnectionService.normalizedURL("https://desktop.example.test").absoluteString,
            "https://desktop.example.test")
        XCTAssertThrowsError(try PeerConnectionService.normalizedURL("not an address"))
    }
    func testLegacyMigrationBacksUpAndIsRetrySafe() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let repo = try SyncRepository(path: root.appendingPathComponent("db.sqlite").path)
        let history = [
            "Codex::weekly": [
                UsageSnapshot(timestamp: Date(timeIntervalSince1970: 10), usage: usage(70))
            ]
        ]
        let data = try JSONEncoder().encode(history)
        let registry = ["Codex::weekly": UsageSeriesID(providerID: "Codex", metricID: "weekly")]
        let first = try LegacyHistoryMigrator.migrate(
            history: history, sourceData: data, repository: repo,
            backupRoot: root.appendingPathComponent("backups"), registry: registry)
        let retry = try LegacyHistoryMigrator.migrate(
            history: history, sourceData: data, repository: repo,
            backupRoot: root.appendingPathComponent("backups"), registry: registry)
        XCTAssertEqual(first.imported, 1)
        XCTAssertEqual(retry.imported, 0)
        let fingerprint = Data(SHA256.hash(data: data)).map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(try repo.migrationState(fingerprint: fingerprint), "committed")
        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: first.backupURL.appendingPathComponent("ai.notificationHistory.v1.json")
                    .path))
    }
    func testMigrationBatchRollsBackOnSequenceConflict() throws {
        let repo = try SyncRepository(
            path: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                .path)
        let origin = OriginID(deviceID: UUID(), epoch: UUID())
        let series = UsageSeriesID(providerID: "Codex", metricID: "weekly")
        let first = try UsageObservation(
            origin: origin, originSequence: 1, series: series, observedAt: .now, remaining: 10,
            limit: 100, resetAt: nil, cycleStartedAt: nil)
        let conflict = try UsageObservation(
            origin: origin, originSequence: 1, series: series, observedAt: .now, remaining: 20,
            limit: 100, resetAt: nil, cycleStartedAt: nil)
        XCTAssertThrowsError(
            try repo.importMigration(
                [first, conflict], fingerprint: "conflict", backupPath: "/backup",
                quarantinedCount: 0))
        XCTAssertTrue(try repo.allObservations().isEmpty)
        XCTAssertNil(try repo.migrationState(fingerprint: "conflict"))
    }
    func testCorruptDatabaseIsNeverSilentlyReplaced() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .path
        try Data("not a sqlite database".utf8).write(to: URL(fileURLWithPath: path))
        XCTAssertThrowsError(try SyncRepository(path: path))
        XCTAssertEqual(
            try Data(contentsOf: URL(fileURLWithPath: path)), Data("not a sqlite database".utf8))
    }

    func testRequestAuthenticationAndPairingReplayControls() async throws {
        let credential = PeerCredential(
            secret: Data(repeating: 7, count: 32), scopes: [.desktopSync])
        let signed = RequestAuthenticator.sign(
            method: "post", path: "/v1/observations", body: Data("x".utf8), credential: credential)
        XCTAssertTrue(
            RequestAuthenticator.verify(
                signed, method: "POST", path: "/v1/observations", body: Data("x".utf8),
                credential: credential))
        XCTAssertFalse(
            RequestAuthenticator.verify(
                signed, method: "POST", path: "/v1/current", body: Data("x".utf8),
                credential: credential))
        let replay = ReplayProtector()
        let firstNonce = await replay.consume(credentialID: credential.id, nonce: signed.nonce)
        let replayedNonce = await replay.consume(credentialID: credential.id, nonce: signed.nonce)
        XCTAssertTrue(firstNonce)
        XCTAssertFalse(replayedNonce)
        let pairing = PairingChallengeStore()
        let challenge = await pairing.create()
        let firstPair = await pairing.consume(id: challenge.id, secret: challenge.secret)
        let replayedPair = await pairing.consume(id: challenge.id, secret: challenge.secret)
        XCTAssertTrue(firstPair)
        XCTAssertFalse(replayedPair)
    }
    func testPersistentPairingRequiresApprovalExpiresAndCompletesOnce() throws {
        let repo = try SyncRepository(
            path: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                .path)
        let now = Date(timeIntervalSince1970: 1000)
        let invite = try PairingCoordinator.invite(repository: repo, scope: .mobileRead, now: now)
        let requester = DeviceIdentity(displayName: "Phone", signingPublicKey: Data([1]))
        XCTAssertFalse(
            try repo.exchangePairingSession(
                id: invite.sessionID, secret: Data(repeating: 0, count: 32), requester: requester,
                now: now)
        )
        XCTAssertTrue(try repo.pendingPairings(now: now).isEmpty)
        XCTAssertTrue(
            try repo.exchangePairingSession(
                id: invite.sessionID, secret: invite.secret, requester: requester, now: now))
        let pending = try repo.pendingPairings(now: now)
        XCTAssertEqual(pending.first?.requesterDeviceID, requester.deviceID)
        XCTAssertEqual(pending.first?.requesterEpoch, requester.epoch)
        XCTAssertEqual(pending.first?.requesterName, "Phone")
        let issued = try repo.approvePairingSession(id: invite.sessionID, now: now)
        XCTAssertEqual(issued.scopes, [.mobileRead])
        XCTAssertNotNil(
            try repo.completePairingSession(id: invite.sessionID, secret: invite.secret, now: now))
        XCTAssertNil(
            try repo.completePairingSession(id: invite.sessionID, secret: invite.secret, now: now))
        let expired = try PairingCoordinator.invite(repository: repo, scope: .desktopSync, now: now)
        XCTAssertFalse(
            try repo.exchangePairingSession(
                id: expired.sessionID, secret: expired.secret, requester: requester,
                now: now.addingTimeInterval(121)))
    }
    func testPeerSecretIsNotStoredInPlaintext() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .path
        let repo = try SyncRepository(path: path)
        let plain = Data("recognizable-peer-secret-material".utf8)
        let credential = PeerCredential(secret: plain, scopes: [.desktopSync])
        try repo.savePeer(credential, deviceID: UUID(), epoch: UUID(), displayName: "Peer")
        XCTAssertEqual(try repo.peerCredential(id: credential.id)?.secret, plain)
        XCTAssertNil(try Data(contentsOf: URL(fileURLWithPath: path)).range(of: plain))
    }
    func testCredentialRotationRevokesOldAndPreservesAddresses() throws {
        let repo = try SyncRepository(
            path: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                .path)
        let old = PeerCredential(secret: Data(repeating: 1, count: 32), scopes: [.desktopSync])
        let url = URL(string: "https://peer.example")!
        try repo.savePeer(old, deviceID: UUID(), epoch: UUID(), displayName: "Peer")
        try repo.saveAddress(credentialID: old.id, url: url, kind: .manual)
        let new = try repo.rotatePeer(credentialID: old.id)
        XCTAssertNil(try repo.peerCredential(id: old.id))
        XCTAssertNotEqual(new.secret, old.secret)
        XCTAssertEqual(try repo.addresses(credentialID: new.id).map(\.url), [url])
        XCTAssertThrowsError(try repo.rotatePeer(credentialID: old.id))
    }
    func testCanonicalTransferRoundTripAndLegacyCompatibility() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = try SyncRepository(path: root.appendingPathComponent("source.sqlite").path)
        let destination = try SyncRepository(
            path: root.appendingPathComponent("destination.sqlite").path)
        _ = try source.record(
            series: .init(providerID: "Codex", metricID: "weekly"), usage: usage(66),
            at: Date(timeIntervalSince1970: 123))
        let data = try CanonicalHistoryTransfer.export(repository: source, appVersion: "test")
        XCTAssertEqual(
            try CanonicalHistoryTransfer.importData(
                data, repository: destination, backupRoot: root.appendingPathComponent("backups")),
            1)
        XCTAssertEqual(try destination.allObservations(), try source.allObservations())
        XCTAssertEqual(
            try CanonicalHistoryTransfer.importData(
                data, repository: destination, backupRoot: root.appendingPathComponent("backups")),
            0)
        let legacy = try UsageHistoryTransferService.makeExportData(
            historyBySource: [
                "Codex::codex-pro-weekly": [UsageSnapshot(timestamp: .now, usage: usage(50))]
            ], appVersion: "old")
        XCTAssertEqual(
            try CanonicalHistoryTransfer.importData(
                legacy, repository: destination, backupRoot: root.appendingPathComponent("backups")),
            1)
    }
    func testRecordsAllocateSequenceAndSurviveReopen() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .path
        let first = try SyncRepository(path: path, displayName: "A")
        let a = try first.record(
            series: .init(providerID: "Codex", metricID: "five-hour"), usage: usage(90),
            at: Date(timeIntervalSince1970: 1))
        let b = try first.record(
            series: .init(providerID: "Codex", metricID: "five-hour"), usage: usage(80),
            at: Date(timeIntervalSince1970: 2))
        XCTAssertEqual([a.originSequence, b.originSequence], [1, 2])
        let reopened = try SyncRepository(path: path)
        XCTAssertEqual(reopened.identity.deviceID, first.identity.deviceID)
        XCTAssertEqual(try reopened.allObservations().count, 2)
    }

    func testIngestDeduplicatesAndRejectsSequenceConflict() throws {
        let repo = try SyncRepository(
            path: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                .path)
        let origin = OriginID(deviceID: UUID(), epoch: UUID())
        let one = try UsageObservation(
            origin: origin, originSequence: 1,
            series: .init(providerID: "Codex", metricID: "weekly"),
            observedAt: .now, remaining: 50, limit: 100, resetAt: nil, cycleStartedAt: nil)
        XCTAssertEqual(try repo.ingest([one]).accepted, 1)
        XCTAssertEqual(try repo.ingest([one]).duplicates, 1)
        let conflict = try UsageObservation(
            origin: origin, originSequence: 1, series: one.series, observedAt: .now, remaining: 40,
            limit: 100, resetAt: nil, cycleStartedAt: nil)
        XCTAssertThrowsError(try repo.ingest([conflict]))
    }

    func testProjectionIsOrderIndependentAndKeepsPlateauEnds() throws {
        let origin = OriginID(deviceID: UUID(), epoch: UUID())
        let series = UsageSeriesID(providerID: "Codex", metricID: "weekly")
        let values = try (1...4).map {
            try UsageObservation(
                origin: origin, originSequence: UInt64($0), series: series,
                observedAt: Date(timeIntervalSince1970: Double($0)), remaining: $0 == 4 ? 40 : 50,
                limit: 100, resetAt: nil, cycleStartedAt: nil)
        }
        XCTAssertEqual(
            HistoryProjector.project(values)[series.description]?.map(\.timestamp),
            [
                Date(timeIntervalSince1970: 1), Date(timeIntervalSince1970: 3),
                Date(timeIntervalSince1970: 4),
            ])
        XCTAssertEqual(
            HistoryProjector.project(values)[series.description]?.map(\.timestamp),
            HistoryProjector.project(values.reversed())[series.description]?.map(\.timestamp))
    }
    func testRangePlannerAndCoordinatorResumePagedBackfill() async throws {
        let source = try SyncRepository(
            path: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                .path)
        let destination = try SyncRepository(
            path: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                .path)
        for value in 1...1_201 {
            _ = try source.record(
                series: .init(providerID: "Codex", metricID: "weekly"),
                usage: usage(Double(value % 100)))
        }
        let result = try await SyncCoordinator(repository: destination).pull(
            from: FakePeer(repository: source))
        XCTAssertEqual(result.accepted, 1_201)
        XCTAssertEqual(result.pages, 3)
        XCTAssertEqual(try destination.allObservations().count, 1_201)
    }
    func testReconcileConvergesBothRepositoriesOverOneConnection() async throws {
        let first = try SyncRepository(
            path: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                .path)
        let second = try SyncRepository(
            path: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                .path)
        _ = try first.record(
            series: .init(providerID: "Codex", metricID: "weekly"), usage: usage(80))
        _ = try second.record(
            series: .init(providerID: "Codex", metricID: "weekly"), usage: usage(60))
        _ = try await SyncCoordinator(repository: first).reconcile(
            with: FakePeer(repository: second))
        XCTAssertEqual(try first.allObservations().count, 2)
        XCTAssertEqual(try second.allObservations().count, 2)
        XCTAssertEqual(
            Set(try first.allObservations().map(\.id)), Set(try second.allObservations().map(\.id)))
    }
    func testCoordinatorRejectsMissingOrDifferentRequiredAppVersion() async throws {
        let source = try SyncRepository(
            path: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                .path)
        let destination = try SyncRepository(
            path: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                .path)
        do {
            _ = try await SyncCoordinator(repository: destination, requiredAppVersion: "2.0.0")
                .pull(
                    from: FakePeer(repository: source))
            XCTFail("Expected version mismatch")
        } catch let error as DesktopSyncCompatibilityError {
            XCTAssertEqual(error, .versionMismatch(local: "2.0.0", remote: nil))
        }
    }
    func testPeerSyncFallsBackAcrossPersistedAddresses() async throws {
        let source = try SyncRepository(
            path: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                .path)
        let destination = try SyncRepository(
            path: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                .path)
        let credential = PeerCredential(
            secret: Data(repeating: 4, count: 32), scopes: [.desktopSync])
        _ = try source.record(
            series: .init(providerID: "Codex", metricID: "weekly"), usage: usage(40))
        try destination.savePeer(
            credential, deviceID: source.identity.deviceID, epoch: source.identity.epoch,
            displayName: "Source")
        let unavailable = URL(string: "https://first.invalid")!
        let working = URL(string: "https://second.invalid")!
        try destination.saveAddress(credentialID: credential.id, url: unavailable, kind: .manual)
        try destination.saveAddress(credentialID: credential.id, url: working, kind: .bonjour)
        let service = PeerSyncService(repository: destination) { url, _ in
            if url == unavailable { throw URLError(.cannotConnectToHost) }
            return FakePeer(repository: source)
        }
        let attempts = await service.syncAllOnce()
        XCTAssertEqual(attempts.count, 2)
        XCTAssertNil(attempts[0].result)
        XCTAssertEqual(attempts[1].result?.accepted, 1)
    }
    private func usage(_ remaining: Double) -> UsageResult {
        UsageResult(remaining: remaining, limit: 100, resetDate: nil, cycleStartDate: nil)
    }
}
private struct FakePeer: SyncPeerTransport {
    let repository: SyncRepository
    func hello() async throws -> HelloDTO {
        .init(
            deviceID: repository.identity.deviceID, epoch: repository.identity.epoch,
            protocolMinimum: 1,
            protocolMaximum: 1, serverTime: .now, maximumBatch: 500)
    }
    func origins() async throws -> [OriginSummary] { try repository.originSummaries() }
    func query(_ request: ObservationQuery) async throws -> ObservationPage {
        let r = request.requests[0]
        let after = request.pageToken.flatMap(UInt64.init) ?? r.range.from - 1
        let values = try repository.observations(
            origin: r.origin,
            range: .init(from: max(r.range.from, after + 1), through: r.range.through),
            limit: request.limit)
        return .init(
            observations: values,
            nextPageToken: values.count == request.limit
                && values.last!.originSequence < r.range.through
                ? String(values.last!.originSequence) : nil)
    }
    func ingest(_ observations: [UsageObservation]) async throws -> IngestAcknowledgement {
        let before = Set(try repository.allObservations().map(\.id))
        _ = try repository.ingest(observations)
        return .init(
            accepted: observations.filter { !before.contains($0.id) }.map(\.id),
            duplicates: observations.filter { before.contains($0.id) }.map(\.id), rejected: [],
            origins: try repository.originSummaries())
    }
}
