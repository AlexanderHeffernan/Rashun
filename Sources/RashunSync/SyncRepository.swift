import Crypto
import Foundation

public final class SyncRepository: @unchecked Sendable {
    private struct StoredPeer: Codable {
        var credentialID: UUID
        var deviceID: UUID
        var epoch: UUID
        var displayName: String
        var protectedSecret: Data
        var scopes: Set<PeerCredential.Scope>
        var createdAt: Date
        var expiresAt: Date? = nil
        var revokedAt: Date? = nil
        var lastSeenAt: Date? = nil
        var syncStartedAt: Date? = nil
        var lastSyncAt: Date? = nil
        var lastSyncImported: Int? = nil
        var lastSyncError: String? = nil
        var remoteHistoryRevision: UInt64? = nil
        var acknowledgedLocalHistoryRevision: UInt64? = nil
    }

    private struct StoredAddress: Codable {
        var credentialID: UUID
        var url: URL
        var kind: AddressKind
        var priority: Int
        var lastSuccessAt: Date? = nil
        var lastFailureAt: Date? = nil
    }

    private struct PairingSession: Codable {
        var id: UUID
        var secretHash: Data
        var scope: PeerCredential.Scope
        var expiresAt: Date
        var attempts: Int
        var consumedAt: Date? = nil
    }

    private struct StoredPushSubscription: Codable {
        var credentialID: UUID
        var endpoint: URL
        var protectedClientPublicKey: Data
        var protectedAuthSecret: Data
        var createdAt: Date
    }

    private struct Nonce: Codable, Hashable {
        var credentialID: UUID
        var value: String
        var expiresAt: Date
    }

    private struct State: Codable {
        var schemaVersion = 1
        var identity: DeviceIdentity
        var peers: [UUID: StoredPeer] = [:]
        var addresses: [StoredAddress] = []
        var pairingSessions: [UUID: PairingSession] = [:]
        var nonces: Set<Nonce> = []
        var protectedWebPushSigningKey: Data?
        var pushSubscriptions: [UUID: StoredPushSubscription] = [:]
    }

    private let stateURL: URL
    private let secrets: SecretProtector
    private let lock = NSLock()
    private var state: State
    public var identity: DeviceIdentity { withLock { state.identity } }

    public init(path: String, displayName: String = Host.current().localizedName ?? "Rashun device")
        throws
    {
        let requested = URL(fileURLWithPath: path)
        let directory =
            requested.pathExtension.isEmpty
            ? requested : requested.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        stateURL = directory.appendingPathComponent("sync-state.json")
        secrets = try SecretProtector(storageDirectory: directory)
        if let data = try? Data(contentsOf: stateURL) {
            state = try JSONDecoder.sync.decode(State.self, from: data)
        } else {
            state = State(
                identity: DeviceIdentity(displayName: displayName))
            try Self.write(state, to: stateURL)
        }
    }

    public struct PeerRecord: Sendable {
        public let credentialID: UUID
        public let deviceID: UUID
        public let epoch: UUID
        public let displayName: String
        public let scopes: Set<PeerCredential.Scope>
        public let revokedAt: Date?
        public let lastSeenAt: Date?
        public let syncStartedAt: Date?
        public let lastSyncAt: Date?
        public let lastSyncImported: Int?
        public let lastSyncError: String?
        public let hasPushSubscription: Bool
        public let remoteHistoryRevision: UInt64?
        public let acknowledgedLocalHistoryRevision: UInt64?
    }

    public enum AddressKind: String, Codable, Sendable, Hashable, CaseIterable {
        case manual, bonjour
    }

    public struct PeerAddress: Sendable {
        public let credentialID: UUID
        public let url: URL
        public let kind: AddressKind
        public let priority: Int
        public let lastSuccessAt: Date?
        public let lastFailureAt: Date?
    }

    public func savePeer(
        _ credential: PeerCredential, deviceID: UUID, epoch: UUID, displayName: String
    ) throws {
        try mutate { state in
            state.peers[credential.id] = StoredPeer(
                credentialID: credential.id, deviceID: deviceID, epoch: epoch,
                displayName: displayName, protectedSecret: try secrets.seal(credential.secret),
                scopes: credential.scopes, createdAt: Date(), expiresAt: credential.expiresAt)
        }
    }

    public func peerCredential(id: UUID) throws -> PeerCredential? {
        try withLock {
            guard let peer = state.peers[id], peer.revokedAt == nil else { return nil }
            return PeerCredential(
                id: id, secret: try secrets.open(peer.protectedSecret), scopes: peer.scopes,
                expiresAt: peer.expiresAt)
        }
    }

    public func peers(includeRevoked: Bool = false) throws -> [PeerRecord] {
        withLock {
            state.peers.values.filter { includeRevoked || $0.revokedAt == nil }.map { peer in
                PeerRecord(
                    credentialID: peer.credentialID, deviceID: peer.deviceID, epoch: peer.epoch,
                    displayName: peer.displayName, scopes: peer.scopes, revokedAt: peer.revokedAt,
                    lastSeenAt: peer.lastSeenAt, syncStartedAt: peer.syncStartedAt,
                    lastSyncAt: peer.lastSyncAt, lastSyncImported: peer.lastSyncImported,
                    lastSyncError: peer.lastSyncError,
                    hasPushSubscription: state.pushSubscriptions[peer.credentialID] != nil,
                    remoteHistoryRevision: peer.remoteHistoryRevision,
                    acknowledgedLocalHistoryRevision: peer.acknowledgedLocalHistoryRevision)
            }.sorted {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        }
    }

    public func revokePeer(credentialID: UUID, at date: Date = Date()) throws {
        try mutate { state in
            guard state.peers[credentialID] != nil else { throw SyncRepositoryError.peerNotFound }
            state.peers[credentialID]?.revokedAt = date
            state.pushSubscriptions.removeValue(forKey: credentialID)
        }
    }

    public func rotatePeer(credentialID: UUID, at date: Date = Date()) throws -> PeerCredential {
        let old = try requiredPeer(credentialID)
        let credential = PeerCredential(
            secret: Self.randomData(), scopes: old.scopes, expiresAt: old.expiresAt)
        try mutate { state in
            state.peers[credentialID]?.revokedAt = date
            state.peers[credential.id] = StoredPeer(
                credentialID: credential.id, deviceID: old.deviceID, epoch: old.epoch,
                displayName: old.displayName, protectedSecret: try secrets.seal(credential.secret),
                scopes: credential.scopes, createdAt: date, expiresAt: credential.expiresAt,
                remoteHistoryRevision: old.remoteHistoryRevision,
                acknowledgedLocalHistoryRevision: old.acknowledgedLocalHistoryRevision)
            for index in state.addresses.indices
            where state.addresses[index].credentialID == credentialID {
                state.addresses[index].credentialID = credential.id
            }
        }
        return credential
    }

    public func replacePeerCredential(oldID: UUID, with new: PeerCredential, at date: Date = Date())
        throws
    {
        let old = try requiredPeer(oldID)
        try mutate { state in
            state.peers[oldID]?.revokedAt = date
            state.peers[new.id] = StoredPeer(
                credentialID: new.id, deviceID: old.deviceID, epoch: old.epoch,
                displayName: old.displayName, protectedSecret: try secrets.seal(new.secret),
                scopes: new.scopes, createdAt: date, expiresAt: new.expiresAt,
                remoteHistoryRevision: old.remoteHistoryRevision,
                acknowledgedLocalHistoryRevision: old.acknowledgedLocalHistoryRevision)
            for index in state.addresses.indices where state.addresses[index].credentialID == oldID
            {
                state.addresses[index].credentialID = new.id
            }
        }
    }

    public func markPeerSeen(credentialID: UUID, at date: Date = Date()) throws {
        try updatePeer(credentialID) { $0.lastSeenAt = date }
    }

    public func beginPeerSync(credentialID: UUID, at date: Date = Date()) throws {
        try updatePeer(credentialID) {
            $0.syncStartedAt = date
            $0.lastSyncError = nil
        }
    }

    public func finishPeerSync(
        credentialID: UUID, imported: Int, error: String? = nil, at date: Date = Date()
    ) throws {
        try updatePeer(credentialID) {
            $0.syncStartedAt = nil
            $0.lastSyncAt = date
            $0.lastSyncImported = imported
            $0.lastSyncError = error
        }
    }

    /// Records a failed outbound attempt without allowing it to overwrite a successful inbound
    /// sync that completed after the attempt began.
    public func failPeerSync(
        credentialID: UUID, error: String, attemptStartedAt: Date, at date: Date = Date()
    ) throws {
        try updatePeer(credentialID) {
            if let activeStart = $0.syncStartedAt, activeStart <= attemptStartedAt {
                $0.syncStartedAt = nil
            }
            guard ($0.lastSyncAt ?? .distantPast) < attemptStartedAt else { return }
            $0.lastSyncImported = 0
            $0.lastSyncError = error
        }
    }

    public func historyRevisions(for credentialID: UUID) throws -> (
        remote: UInt64?, localAcknowledged: UInt64?
    ) {
        let peer = try requiredPeer(credentialID)
        return (peer.remoteHistoryRevision, peer.acknowledgedLocalHistoryRevision)
    }

    public func saveHistoryRevisions(
        credentialID: UUID, remote: UInt64, localAcknowledged: UInt64
    ) throws {
        try updatePeer(credentialID) {
            $0.remoteHistoryRevision = remote
            $0.acknowledgedLocalHistoryRevision = localAcknowledged
        }
    }

    public func saveAddress(credentialID: UUID, url: URL, kind: AddressKind) throws {
        try mutate { state in
            guard state.peers[credentialID]?.revokedAt == nil else {
                throw SyncRepositoryError.peerNotFound
            }
            state.addresses.removeAll { $0.credentialID == credentialID && $0.url == url }
            state.addresses.append(
                .init(
                    credentialID: credentialID, url: url, kind: kind,
                    priority: kind == .manual ? 0 : 1))
        }
    }

    public func addresses(credentialID: UUID) throws -> [PeerAddress] {
        withLock {
            state.addresses.filter { $0.credentialID == credentialID }.sorted {
                if $0.priority != $1.priority { return $0.priority < $1.priority }
                return ($0.lastSuccessAt ?? .distantPast) > ($1.lastSuccessAt ?? .distantPast)
            }.map {
                .init(
                    credentialID: $0.credentialID, url: $0.url, kind: $0.kind,
                    priority: $0.priority, lastSuccessAt: $0.lastSuccessAt,
                    lastFailureAt: $0.lastFailureAt)
            }
        }
    }

    public func recordAddressResult(
        credentialID: UUID, url: URL, succeeded: Bool, at date: Date = Date()
    ) throws {
        try mutate { state in
            guard
                let index = state.addresses.firstIndex(where: {
                    $0.credentialID == credentialID && $0.url == url
                })
            else { return }
            if succeeded {
                state.addresses[index].lastSuccessAt = date
            } else {
                state.addresses[index].lastFailureAt = date
            }
        }
    }

    public func consumeNonce(
        credentialID: UUID, nonce: String, expiresAt: Date, now: Date = Date()
    ) throws -> Bool {
        try mutate { state in
            state.nonces = state.nonces.filter { $0.expiresAt >= now }
            let value = Nonce(credentialID: credentialID, value: nonce, expiresAt: expiresAt)
            guard
                !state.nonces.contains(where: {
                    $0.credentialID == credentialID && $0.value == nonce
                })
            else { return false }
            state.nonces.insert(value)
            return true
        }
    }

    public func createPairingSession(
        scope: PeerCredential.Scope, secret: Data, expiresAt: Date
    ) throws -> UUID {
        let id = UUID()
        try mutate { state in
            state.pairingSessions[id] = .init(
                id: id, secretHash: Data(SHA256.hash(data: secret)), scope: scope,
                expiresAt: expiresAt, attempts: 0)
        }
        return id
    }

    public func connectPairingSession(
        password: String, requesterName: String, requesterDeviceID: UUID, requesterEpoch: UUID,
        scope: PeerCredential.Scope, now: Date = Date()
    ) throws -> PeerCredential? {
        let normalized = password.uppercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let hash = Data(SHA256.hash(data: Data(normalized.utf8)))
        return try mutate { state in
            guard
                let session = state.pairingSessions.values
                    .filter({
                        $0.secretHash == hash && $0.scope == scope && $0.expiresAt > now
                            && $0.attempts < 5
                    })
                    .sorted(by: { $0.expiresAt > $1.expiresAt }).first,
                scope == .mobileRead || session.consumedAt == nil
            else { return nil }
            let credential = PeerCredential(secret: Self.randomData(), scopes: [scope])
            if scope != .mobileRead { state.pairingSessions[session.id]?.consumedAt = now }
            state.pairingSessions[session.id]?.attempts += 1
            state.peers[credential.id] = StoredPeer(
                credentialID: credential.id, deviceID: requesterDeviceID, epoch: requesterEpoch,
                displayName: requesterName, protectedSecret: try secrets.seal(credential.secret),
                scopes: credential.scopes, createdAt: now)
            return credential
        }
    }

    public func webPushSigningPrivateKey() throws -> Data {
        try mutate { state in
            if let protected = state.protectedWebPushSigningKey {
                return try secrets.open(protected)
            }
            let key = P256.Signing.PrivateKey().rawRepresentation
            state.protectedWebPushSigningKey = try secrets.seal(key)
            return key
        }
    }

    public func saveWebPushSubscription(
        _ subscription: WebPushSubscription, credentialID: UUID
    ) throws {
        guard subscription.endpoint.scheme == "https", subscription.clientPublicKey.count == 65,
            subscription.authSecret.count >= 16
        else { throw SyncRepositoryError.invalidPushSubscription }
        try mutate { state in
            guard state.peers[credentialID]?.revokedAt == nil else {
                throw SyncRepositoryError.peerNotFound
            }
            state.pushSubscriptions[credentialID] = .init(
                credentialID: credentialID, endpoint: subscription.endpoint,
                protectedClientPublicKey: try secrets.seal(subscription.clientPublicKey),
                protectedAuthSecret: try secrets.seal(subscription.authSecret), createdAt: Date())
        }
    }

    public func removeWebPushSubscription(credentialID: UUID) throws {
        _ = try mutate { $0.pushSubscriptions.removeValue(forKey: credentialID) }
    }

    public func webPushSubscriptions(credentialID: UUID? = nil) throws
        -> [WebPushSubscriptionRecord]
    {
        try withLock {
            try state.pushSubscriptions.values.filter {
                credentialID == nil || $0.credentialID == credentialID
            }.compactMap { value in
                guard state.peers[value.credentialID]?.revokedAt == nil else { return nil }
                return WebPushSubscriptionRecord(
                    credentialID: value.credentialID,
                    subscription: .init(
                        endpoint: value.endpoint,
                        clientPublicKey: try secrets.open(value.protectedClientPublicKey),
                        authSecret: try secrets.open(value.protectedAuthSecret)))
            }
        }
    }

    private func requiredPeer(_ id: UUID) throws -> StoredPeer {
        try withLock {
            guard let peer = state.peers[id], peer.revokedAt == nil else {
                throw SyncRepositoryError.peerNotFound
            }
            return peer
        }
    }

    private func updatePeer(_ id: UUID, _ body: (inout StoredPeer) -> Void) throws {
        try mutate { state in
            guard state.peers[id]?.revokedAt == nil else { throw SyncRepositoryError.peerNotFound }
            body(&state.peers[id]!)
        }
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func mutate<T>(_ body: (inout State) throws -> T) throws -> T {
        try withLock {
            var copy = state
            let result = try body(&copy)
            try Self.write(copy, to: stateURL)
            state = copy
            return result
        }
    }

    private static func write(_ state: State, to url: URL) throws {
        try JSONEncoder.sync.encode(state).write(to: url, options: .atomic)
    }

    private static func randomData(count: Int = 32) -> Data {
        var rng = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &rng) })
    }
}

extension JSONEncoder {
    fileprivate static var sync: JSONEncoder {
        let value = JSONEncoder()
        value.dateEncodingStrategy = .iso8601
        value.outputFormatting = [.sortedKeys]
        return value
    }
}

extension JSONDecoder {
    fileprivate static var sync: JSONDecoder {
        let value = JSONDecoder()
        value.dateDecodingStrategy = .iso8601
        return value
    }
}

public enum SyncRepositoryError: Error, Equatable {
    case corruptDatabase(String)
    case peerNotFound, invalidPushSubscription
}
