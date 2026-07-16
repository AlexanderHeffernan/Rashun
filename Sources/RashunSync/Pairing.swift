import Foundation

public struct SimplePairingAccess: Codable, Sendable {
    public let password: String
    public let expiresAt: Date
    public let scope: PeerCredential.Scope
}

public struct SimplePairingRequest: Codable, Sendable {
    public let password: String
    public let requesterName: String
    public let requesterDeviceID: UUID
    public let requesterEpoch: UUID
    public let scope: PeerCredential.Scope
    public let requesterAddress: URL?
    public let requesterVersion: String?
    public init(
        password: String, requesterName: String, requesterDeviceID: UUID, requesterEpoch: UUID,
        scope: PeerCredential.Scope, requesterAddress: URL? = nil, requesterVersion: String? = nil
    ) {
        self.password = password
        self.requesterName = requesterName
        self.requesterDeviceID = requesterDeviceID
        self.requesterEpoch = requesterEpoch
        self.scope = scope
        self.requesterAddress = requesterAddress
        self.requesterVersion = requesterVersion
    }
}

public struct SimplePairingResponse: Codable, Sendable {
    public let credential: PeerCredential
    public let host: DeviceIdentity
    public let hostVersion: String?
    public init(credential: PeerCredential, host: DeviceIdentity, hostVersion: String? = nil) {
        self.credential = credential
        self.host = host
        self.hostVersion = hostVersion
    }
}

public enum PairingCoordinator {
    public static func simpleAccess(
        repository: SyncRepository, scope: PeerCredential.Scope, now: Date = Date()
    ) throws -> SimplePairingAccess {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        var rng = SystemRandomNumberGenerator()
        let raw = String((0..<8).map { _ in alphabet.randomElement(using: &rng)! })
        let password = String(raw.prefix(4)) + "-" + String(raw.suffix(4))
        let expiry = now.addingTimeInterval(15 * 60)
        _ = try repository.createPairingSession(
            scope: scope, secret: Data(password.utf8), expiresAt: expiry)
        return .init(password: password, expiresAt: expiry, scope: scope)
    }
}
