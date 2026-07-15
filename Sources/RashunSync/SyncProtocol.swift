import Foundation
import RashunCore

public struct HelloDTO: Codable, Sendable {
    public let deviceID: UUID
    public let epoch: UUID
    public let protocolMinimum: Int
    public let protocolMaximum: Int
    public let serverTime: Date
    public let maximumBatch: Int
    public let appVersion: String?

    public init(
        deviceID: UUID, epoch: UUID, protocolMinimum: Int, protocolMaximum: Int,
        serverTime: Date, maximumBatch: Int, appVersion: String? = nil
    ) {
        self.deviceID = deviceID
        self.epoch = epoch
        self.protocolMinimum = protocolMinimum
        self.protocolMaximum = protocolMaximum
        self.serverTime = serverTime
        self.maximumBatch = maximumBatch
        self.appVersion = appVersion
    }
}

public struct HistoryReconcileRequest: Codable, Sendable {
    public let knownRemoteRevision: UInt64?
    public let changes: HistorySyncSnapshot

    public init(knownRemoteRevision: UInt64?, changes: HistorySyncSnapshot) {
        self.knownRemoteRevision = knownRemoteRevision
        self.changes = changes
    }
}

public struct HistoryReconcileResponse: Codable, Sendable {
    public let acknowledgedRevision: UInt64
    public let changes: HistorySyncSnapshot

    public init(acknowledgedRevision: UInt64, changes: HistorySyncSnapshot) {
        self.acknowledgedRevision = acknowledgedRevision
        self.changes = changes
    }
}

public protocol SyncPeerTransport: Sendable {
    func hello() async throws -> HelloDTO
    func reconcileHistory(_ request: HistoryReconcileRequest) async throws
        -> HistoryReconcileResponse
    func trackedUsage() async throws -> TrackedUsageSyncSnapshot
    func mergeTrackedUsage(_ snapshot: TrackedUsageSyncSnapshot) async throws
        -> TrackedUsageSyncSnapshot
}

public enum TrackedUsageSyncError: Error, Sendable { case unsupported }
extension SyncPeerTransport {
    public func trackedUsage() async throws -> TrackedUsageSyncSnapshot {
        throw TrackedUsageSyncError.unsupported
    }
    public func mergeTrackedUsage(_ snapshot: TrackedUsageSyncSnapshot) async throws
        -> TrackedUsageSyncSnapshot
    { throw TrackedUsageSyncError.unsupported }
}

public struct HistorySyncAccess: Sendable {
    public let revision: @Sendable () async -> UInt64
    public let snapshot: @Sendable (UInt64?) async -> HistorySyncSnapshot
    public let merge: @Sendable (HistorySyncSnapshot) async -> Bool

    public init(
        revision: @escaping @Sendable () async -> UInt64,
        snapshot: @escaping @Sendable (UInt64?) async -> HistorySyncSnapshot,
        merge: @escaping @Sendable (HistorySyncSnapshot) async -> Bool
    ) {
        self.revision = revision
        self.snapshot = snapshot
        self.merge = merge
    }

    public static let live = HistorySyncAccess(
        revision: { await UsageHistoryStore.shared.currentSyncRevision },
        snapshot: { revision in await UsageHistoryStore.shared.syncSnapshot(since: revision) },
        merge: { value in await UsageHistoryStore.shared.mergeSyncSnapshot(value) })
}

public struct TrackedUsageSyncAccess: Sendable {
    public let snapshot: @Sendable () async -> TrackedUsageSyncSnapshot
    public let merge: @Sendable (TrackedUsageSyncSnapshot) async -> Bool
    public init(
        snapshot: @escaping @Sendable () async -> TrackedUsageSyncSnapshot,
        merge: @escaping @Sendable (TrackedUsageSyncSnapshot) async -> Bool
    ) {
        self.snapshot = snapshot
        self.merge = merge
    }
    public static let live = TrackedUsageSyncAccess(
        snapshot: { await TrackedUsageStore.shared.syncSnapshot() },
        merge: { await TrackedUsageStore.shared.mergeSyncSnapshot($0) })
}

public struct SyncResult: Sendable {
    public let accepted: Int
    public let duplicates: Int
    public let pages: Int
}

public struct SyncCoordinator: Sendable {
    private let repository: SyncRepository
    private let requiredAppVersion: String?
    private let history: HistorySyncAccess
    private let trackedUsage: TrackedUsageSyncAccess?

    public init(
        repository: SyncRepository, requiredAppVersion: String? = nil,
        history: HistorySyncAccess = .live, trackedUsage: TrackedUsageSyncAccess? = nil
    ) {
        self.repository = repository
        self.requiredAppVersion = requiredAppVersion
        self.history = history
        self.trackedUsage = trackedUsage
    }

    public func reconcile(
        with peer: any SyncPeerTransport, credentialID: UUID? = nil
    ) async throws -> SyncResult {
        let hello = try await compatibleHello(from: peer)
        let peerRecord =
            try credentialID.flatMap { id in
                try repository.peers().first { $0.credentialID == id }
            }
            ?? repository.peers().first {
                $0.deviceID == hello.deviceID && $0.epoch == hello.epoch
            }
        let outgoing = await history.snapshot(peerRecord?.acknowledgedLocalHistoryRevision)
        let response = try await peer.reconcileHistory(
            .init(
                knownRemoteRevision: peerRecord?.remoteHistoryRevision, changes: outgoing))
        let changed = await history.merge(response.changes)
        let convergedLocalRevision = await history.revision()
        if let id = peerRecord?.credentialID {
            try repository.saveHistoryRevisions(
                credentialID: id, remote: response.changes.revision,
                localAcknowledged: max(response.acknowledgedRevision, convergedLocalRevision))
        }
        if let trackedUsage {
            // History has already reconciled successfully at this point. Tracked sessions are a
            // separate best-effort payload and must not turn that completed history sync into a
            // failure; the foreground loop will retry them on its next pass.
            do {
                _ = await trackedUsage.merge(try await peer.trackedUsage())
                let converged = try await peer.mergeTrackedUsage(await trackedUsage.snapshot())
                _ = await trackedUsage.merge(converged)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // Retried by the next normal sync cycle.
            }
        }
        return .init(
            accepted: changed ? response.changes.historyBySource.count : 0,
            duplicates: 0, pages: response.changes.historyBySource.isEmpty ? 0 : 1)
    }

    public func pull(from peer: any SyncPeerTransport) async throws -> SyncResult {
        try await reconcile(with: peer)
    }

    private func compatibleHello(from peer: any SyncPeerTransport) async throws -> HelloDTO {
        let hello = try await peer.hello()
        guard hello.protocolMinimum <= 1, hello.protocolMaximum >= 1 else {
            throw SyncValidationError.incompatibleProtocol
        }
        if let requiredAppVersion, hello.appVersion != requiredAppVersion {
            throw DesktopSyncCompatibilityError.versionMismatch(
                local: requiredAppVersion, remote: hello.appVersion)
        }
        return hello
    }
}

public enum DesktopSyncCompatibilityError: Error, Equatable, Sendable {
    case versionMismatch(local: String, remote: String?)
}
