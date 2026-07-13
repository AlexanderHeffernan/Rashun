import Foundation
import Crypto

public struct PeerCredential: Codable, Sendable {
    public enum Scope: String, Codable, Sendable { case desktopSync, mobileRead }
    public let id: UUID; public let secret: Data; public let scopes: Set<Scope>; public let expiresAt: Date?
    public init(id: UUID = UUID(), secret: Data, scopes: Set<Scope>, expiresAt: Date? = nil) { self.id=id; self.secret=secret; self.scopes=scopes; self.expiresAt=expiresAt }
}

public struct SignedRequest: Sendable {
    public let credentialID: UUID; public let timestamp: Date; public let nonce: String; public let signature: Data
    public init(credentialID: UUID, timestamp: Date, nonce: String, signature: Data) { self.credentialID=credentialID;self.timestamp=timestamp;self.nonce=nonce;self.signature=signature }
}

public enum RequestAuthenticator {
    public static func sign(method: String, path: String, body: Data, credential: PeerCredential, now: Date = Date(), nonce: String = UUID().uuidString) -> SignedRequest {
        let message = canonical(method: method, path: path, body: body, credentialID: credential.id, timestamp: now, nonce: nonce)
        return SignedRequest(credentialID: credential.id, timestamp: now, nonce: nonce, signature: Data(HMAC<SHA256>.authenticationCode(for: message, using: SymmetricKey(data: credential.secret))))
    }
    public static func verify(_ request: SignedRequest, method: String, path: String, body: Data, credential: PeerCredential, now: Date = Date(), allowedSkew: TimeInterval = 120) -> Bool {
        guard request.credentialID == credential.id, credential.expiresAt.map({ $0 > now }) ?? true, abs(now.timeIntervalSince(request.timestamp)) <= allowedSkew else { return false }
        return HMAC<SHA256>.isValidAuthenticationCode(request.signature, authenticating: canonical(method: method, path: path, body: body, credentialID: request.credentialID, timestamp: request.timestamp, nonce: request.nonce), using: SymmetricKey(data: credential.secret))
    }
    private static func canonical(method: String, path: String, body: Data, credentialID: UUID, timestamp: Date, nonce: String) -> Data {
        let bodyHash = Data(SHA256.hash(data: body)).base64EncodedString()
        return Data([method.uppercased(), path, bodyHash, credentialID.uuidString.lowercased(), String(Int(timestamp.timeIntervalSince1970)), nonce].joined(separator: "\n").utf8)
    }
}

public actor ReplayProtector {
    private var nonces: [UUID: [String: Date]] = [:]
    public init() {}
    public func consume(credentialID: UUID, nonce: String, now: Date = Date(), ttl: TimeInterval = 300) -> Bool {
        nonces[credentialID] = nonces[credentialID, default: [:]].filter { $0.value > now }
        guard nonces[credentialID]?[nonce] == nil else { return false }
        nonces[credentialID]?[nonce] = now.addingTimeInterval(ttl); return true
    }
}

public actor PairingChallengeStore {
    public struct Challenge: Sendable { public let id: UUID; public let secret: Data; public let expiresAt: Date }
    private struct State { let hash: Data; let expiresAt: Date; var attempts = 0; var consumed = false }
    private var states: [UUID: State] = [:]
    public func create(now: Date = Date()) -> Challenge { var rng=SystemRandomNumberGenerator(); let secret=Data((0..<32).map { _ in UInt8.random(in: .min ... .max, using: &rng) }), id=UUID(); states[id]=State(hash:Data(SHA256.hash(data:secret)),expiresAt:now.addingTimeInterval(120)); return .init(id:id,secret:secret,expiresAt:now.addingTimeInterval(120)) }
    public func consume(id: UUID, secret: Data, now: Date = Date()) -> Bool { guard var s=states[id], !s.consumed, s.expiresAt>now, s.attempts<5 else{return false}; s.attempts += 1; let ok=s.hash==Data(SHA256.hash(data:secret)); s.consumed=ok; states[id]=s; return ok }
}
