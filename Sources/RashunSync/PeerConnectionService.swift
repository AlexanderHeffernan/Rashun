import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

public struct PeerConnectionResult: Sendable {
    public let peer: DeviceIdentity
    public let sync: SyncResult
}

public enum PeerConnectionError: Error, Equatable, Sendable {
    case invalidAddress
    case versionMismatch
    case pairingRejected
}

public enum PeerConnectionService {
    public static func normalizedURL(_ value: String) throws -> URL {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.contains("://") ? trimmed : "http://\(trimmed)"
        guard let url = URL(string: candidate), url.host != nil,
            url.scheme == "http" || url.scheme == "https"
        else {
            throw PeerConnectionError.invalidAddress
        }
        return url
    }

    public static func connect(
        repository: SyncRepository, endpoint: URL, password: String, requesterAddress: URL?,
        appVersion: String, trackedUsage: TrackedUsageSyncAccess? = nil
    ) async throws -> PeerConnectionResult {
        let request = SimplePairingRequest(
            password: password.uppercased(), requesterName: repository.identity.displayName,
            requesterDeviceID: repository.identity.deviceID,
            requesterEpoch: repository.identity.epoch, scope: .desktopSync,
            requesterAddress: requesterAddress, requesterVersion: appVersion)
        let response: SimplePairingResponse
        do {
            response = try await PairingHTTPClient.connect(request, with: endpoint)
        } catch PairingHTTPClientError.httpStatus(409) {
            throw PeerConnectionError.versionMismatch
        } catch PairingHTTPClientError.httpStatus(401) {
            throw PeerConnectionError.pairingRejected
        }
        guard response.hostVersion == appVersion else {
            throw PeerConnectionError.versionMismatch
        }

        try repository.savePeer(
            response.credential, deviceID: response.host.deviceID, epoch: response.host.epoch,
            displayName: response.host.displayName)
        try repository.saveAddress(
            credentialID: response.credential.id, url: endpoint, kind: .manual)
        let attemptStartedAt = Date()
        try repository.beginPeerSync(
            credentialID: response.credential.id, at: attemptStartedAt)
        do {
            let sync = try await SyncCoordinator(
                repository: repository, requiredAppVersion: appVersion, trackedUsage: trackedUsage
            ).reconcile(
                with: HTTPPeerTransport(baseURL: endpoint, credential: response.credential),
                credentialID: response.credential.id)
            try repository.recordAddressResult(
                credentialID: response.credential.id, url: endpoint, succeeded: true)
            try repository.finishPeerSync(
                credentialID: response.credential.id, imported: sync.accepted)
            return .init(peer: response.host, sync: sync)
        } catch {
            try? repository.recordAddressResult(
                credentialID: response.credential.id, url: endpoint, succeeded: false)
            try? repository.failPeerSync(
                credentialID: response.credential.id, error: String(describing: error),
                attemptStartedAt: attemptStartedAt)
            throw error
        }
    }
}
