import Foundation

public struct PeerSyncAttempt: Sendable {
    public let credentialID: UUID
    public let result: SyncResult?
    public let errorDescription: String?
}
public actor PeerSyncService {
    public typealias TransportFactory =
        @Sendable (URL, PeerCredential) throws -> any SyncPeerTransport
    public typealias HistoryChanged = @Sendable () async -> Void
    private let repository: SyncRepository
    private let factory: TransportFactory
    private let historyChanged: HistoryChanged?
    private let appVersion: String?
    private let trackedUsage: TrackedUsageSyncAccess?
    public init(
        repository: SyncRepository,
        factory: @escaping TransportFactory = { url, credential in
            try HTTPPeerTransport(baseURL: url, credential: credential)
        }, historyChanged: HistoryChanged? = nil, appVersion: String? = nil,
        trackedUsage: TrackedUsageSyncAccess? = nil
    ) {
        self.repository = repository
        self.factory = factory
        self.historyChanged = historyChanged
        self.appVersion = appVersion
        self.trackedUsage = trackedUsage
    }
    public func syncAllOnce() async -> [PeerSyncAttempt] {
        var attempts: [PeerSyncAttempt] = []
        do {
            for peer in try repository.peers() where peer.scopes.contains(.desktopSync) {
                if Task.isCancelled { return attempts }
                guard let credential = try repository.peerCredential(id: peer.credentialID) else {
                    continue
                }
                let addresses = try repository.addresses(credentialID: peer.credentialID)
                var completed = false
                let attemptStartedAt = Date()
                try? repository.beginPeerSync(
                    credentialID: peer.credentialID, at: attemptStartedAt)
                for address in addresses {
                    for attempt in 0..<2 {
                        if Task.isCancelled {
                            try? repository.cancelPeerSync(
                                credentialID: peer.credentialID,
                                attemptStartedAt: attemptStartedAt)
                            return attempts
                        }
                        do {
                            let result = try await SyncCoordinator(
                                repository: repository, requiredAppVersion: appVersion,
                                trackedUsage: trackedUsage
                            ).reconcile(
                                with: factory(address.url, credential),
                                credentialID: peer.credentialID)
                            try repository.recordAddressResult(
                                credentialID: peer.credentialID, url: address.url, succeeded: true)
                            try repository.finishPeerSync(
                                credentialID: peer.credentialID, imported: result.accepted)
                            if result.accepted > 0 { await historyChanged?() }
                            attempts.append(
                                .init(
                                    credentialID: peer.credentialID, result: result,
                                    errorDescription: nil))
                            completed = true
                            break
                        } catch {
                            if Task.isCancelled {
                                try? repository.cancelPeerSync(
                                    credentialID: peer.credentialID,
                                    attemptStartedAt: attemptStartedAt)
                                return attempts
                            }
                            if attempt == 0, Self.shouldRetry(error) {
                                do {
                                    try await Task.sleep(for: .milliseconds(750))
                                } catch {
                                    try? repository.cancelPeerSync(
                                        credentialID: peer.credentialID,
                                        attemptStartedAt: attemptStartedAt)
                                    return attempts
                                }
                                continue
                            }
                            try? repository.recordAddressResult(
                                credentialID: peer.credentialID, url: address.url, succeeded: false)
                            attempts.append(
                                .init(
                                    credentialID: peer.credentialID, result: nil,
                                    errorDescription: Self.message(
                                        for: error, appVersion: appVersion)))
                            break
                        }
                    }
                    if completed { break }
                }
                if Task.isCancelled {
                    try? repository.cancelPeerSync(
                        credentialID: peer.credentialID, attemptStartedAt: attemptStartedAt)
                    return attempts
                }
                if !completed {
                    let message =
                        addresses.isEmpty
                        ? "No return address is available."
                        : (attempts.last?.errorDescription
                            ?? "The other device could not be reached.")
                    try? repository.failPeerSync(
                        credentialID: peer.credentialID, error: message,
                        attemptStartedAt: attemptStartedAt)
                    if addresses.isEmpty {
                        attempts.append(
                            .init(
                                credentialID: peer.credentialID, result: nil,
                                errorDescription: message))
                    }
                }
            }
        } catch {
            attempts.append(
                .init(
                    credentialID: UUID(), result: nil,
                    errorDescription: String(describing: error)))
        }
        return attempts
    }
    public func runForeground(interval: Duration = .seconds(120)) async {
        var failureCount = 0
        while !Task.isCancelled {
            let results = await syncAllOnce()
            if results.isEmpty {
                failureCount = 0
                do {
                    try await Task.sleep(for: interval)
                } catch {
                    return
                }
                continue
            }
            let succeeded = results.contains { $0.result != nil }
            failureCount = succeeded ? 0 : min(failureCount + 1, 4)
            do {
                try await Task.sleep(
                    for: succeeded
                        ? interval
                        : Self.failureRetryDelay(failureCount: failureCount, interval: interval))
            } catch {
                return
            }
        }
    }

    static func failureRetryDelay(failureCount: Int, interval: Duration) -> Duration {
        guard failureCount < 4 else { return interval }
        return .seconds([5, 15, 30, 60][max(0, failureCount)])
    }
    private static func message(for error: Error, appVersion: String?) -> String {
        if case DesktopSyncCompatibilityError.versionMismatch = error {
            return "Update both devices to Rashun \(appVersion ?? "the same version")."
        }
        if case HTTPPeerTransportError.httpStatus(401) = error {
            return "Connection authorization expired. Remove this device and connect it again."
        }
        return
            "Could not reach the other device. Check that Rashun is running and the address is reachable."
    }

    private static func shouldRetry(_ error: Error) -> Bool {
        if error is URLError { return true }
        if case HTTPPeerTransportError.httpStatus(let status) = error {
            return status == 408 || status == 429 || status >= 500
        }
        return false
    }
}
