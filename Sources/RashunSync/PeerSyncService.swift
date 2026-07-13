import Foundation

public struct PeerSyncAttempt: Sendable {
    public let credentialID: UUID
    public let address: URL?
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
    public init(
        repository: SyncRepository,
        factory: @escaping TransportFactory = { url, credential in
            try HTTPPeerTransport(baseURL: url, credential: credential)
        }, historyChanged: HistoryChanged? = nil, appVersion: String? = nil
    ) {
        self.repository = repository
        self.factory = factory
        self.historyChanged = historyChanged
        self.appVersion = appVersion
    }
    public func syncAllOnce() async -> [PeerSyncAttempt] {
        var attempts: [PeerSyncAttempt] = []
        do {
            for peer in try repository.peers() where peer.scopes.contains(.desktopSync) {
                guard let credential = try repository.peerCredential(id: peer.credentialID) else {
                    continue
                }
                let addresses = try repository.addresses(credentialID: peer.credentialID)
                var completed = false
                try? repository.beginPeerSync(credentialID: peer.credentialID)
                for address in addresses {
                    do {
                        let result = try await SyncCoordinator(
                            repository: repository, requiredAppVersion: appVersion
                        ).reconcile(with: factory(address.url, credential))
                        try repository.recordAddressResult(
                            credentialID: peer.credentialID, url: address.url, succeeded: true)
                        try repository.finishPeerSync(
                            credentialID: peer.credentialID, imported: result.accepted)
                        if result.accepted > 0 { await historyChanged?() }
                        attempts.append(
                            .init(
                                credentialID: peer.credentialID, address: address.url,
                                result: result,
                                errorDescription: nil))
                        completed = true
                        break
                    } catch {
                        try? repository.recordAddressResult(
                            credentialID: peer.credentialID, url: address.url, succeeded: false)
                        attempts.append(
                            .init(
                                credentialID: peer.credentialID, address: address.url, result: nil,
                                errorDescription: Self.message(for: error, appVersion: appVersion)))
                    }
                }
                if !completed {
                    let message =
                        addresses.isEmpty
                        ? "No return address is available."
                        : (attempts.last?.errorDescription
                            ?? "The other device could not be reached.")
                    try? repository.finishPeerSync(
                        credentialID: peer.credentialID, imported: 0, error: message)
                    if addresses.isEmpty {
                        attempts.append(
                            .init(
                                credentialID: peer.credentialID, address: nil, result: nil,
                                errorDescription: message))
                    }
                }
            }
        } catch {
            attempts.append(
                .init(
                    credentialID: UUID(), address: nil, result: nil,
                    errorDescription: String(describing: error)))
        }
        return attempts
    }
    public func runForeground(interval: Duration = .seconds(15)) async {
        var failureCount = 0
        while !Task.isCancelled {
            let results = await syncAllOnce()
            let succeeded = results.contains { $0.result != nil }
            failureCount = succeeded ? 0 : min(failureCount + 1, 4)
            let seconds = [5, 15, 30, 60, 120][failureCount]
            try? await Task.sleep(for: succeeded ? interval : .seconds(seconds))
        }
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
}
