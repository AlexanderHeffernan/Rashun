import Crypto
import Foundation
import RashunSync

struct MobileNotificationPayload: Codable, Sendable {
    let title: String
    let body: String
    let url: String
}

enum WebPushSender {
    static func send(_ payload: MobileNotificationPayload, repository: SyncRepository) async {
        do {
            let subscriptions = try repository.webPushSubscriptions()
            guard !subscriptions.isEmpty else { return }
            let privateKey = try P256.Signing.PrivateKey(
                rawRepresentation: repository.webPushSigningPrivateKey())
            let data = try JSONEncoder().encode(payload)
            await withTaskGroup(of: Void.self) { group in
                for record in subscriptions {
                    group.addTask {
                        do {
                            try await deliver(data, to: record.subscription, signingKey: privateKey)
                        } catch let error as DeliveryError where error.shouldRemoveSubscription {
                            try? repository.removeWebPushSubscription(
                                credentialID: record.credentialID)
                        } catch {
                            NSLog(
                                "Rashun mobile notification delivery failed: %@",
                                String(describing: error))
                        }
                    }
                }
            }
        } catch {
            NSLog("Rashun mobile notification preparation failed: %@", String(describing: error))
        }
    }

    static func sendTest(credentialID: UUID, repository: SyncRepository) async throws {
        guard let record = try repository.webPushSubscriptions(credentialID: credentialID).first
        else { throw WebPushTestError.subscriptionMissing }
        let signingKey = try P256.Signing.PrivateKey(
            rawRepresentation: repository.webPushSigningPrivateKey())
        let payload = try JSONEncoder().encode(
            MobileNotificationPayload(
                title: "Rashun notifications are working",
                body: "This is a test notification sent from your Mac.", url: "./"))
        do {
            try await deliver(payload, to: record.subscription, signingKey: signingKey)
        } catch let error as DeliveryError where error.shouldRemoveSubscription {
            try? repository.removeWebPushSubscription(credentialID: credentialID)
            throw WebPushTestError.subscriptionExpired
        }
    }

    private static func deliver(
        _ payload: Data, to subscription: WebPushSubscription, signingKey: P256.Signing.PrivateKey
    ) async throws {
        let encrypted = try encrypt(payload, subscription: subscription)
        var request = URLRequest(url: subscription.endpoint)
        request.httpMethod = "POST"
        request.httpBody = encrypted
        request.setValue("aes128gcm", forHTTPHeaderField: "Content-Encoding")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("86400", forHTTPHeaderField: "TTL")
        request.setValue(
            try vapidAuthorization(endpoint: subscription.endpoint, signingKey: signingKey),
            forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw DeliveryError(status: 0) }
        guard (200..<300).contains(http.statusCode) else {
            throw DeliveryError(status: http.statusCode)
        }
    }

    static func encrypt(_ payload: Data, subscription: WebPushSubscription) throws -> Data {
        let clientKey = try P256.KeyAgreement.PublicKey(
            x963Representation: subscription.clientPublicKey)
        let serverKey = P256.KeyAgreement.PrivateKey()
        let serverPublic = serverKey.publicKey.x963Representation
        let shared = try serverKey.sharedSecretFromKeyAgreement(with: clientKey)
        let sharedKey = shared.withUnsafeBytes { SymmetricKey(data: Data($0)) }
        let authPRK = HKDF<SHA256>.extract(
            inputKeyMaterial: sharedKey, salt: subscription.authSecret)
        var info = Data("WebPush: info\0".utf8)
        info.append(subscription.clientPublicKey)
        info.append(serverPublic)
        let inputKeyMaterial = HKDF<SHA256>.expand(
            pseudoRandomKey: authPRK, info: info, outputByteCount: 32)
        let salt = randomData(count: 16)
        let prk = HKDF<SHA256>.extract(inputKeyMaterial: inputKeyMaterial, salt: salt)
        let contentKey = HKDF<SHA256>.expand(
            pseudoRandomKey: prk, info: Data("Content-Encoding: aes128gcm\0".utf8),
            outputByteCount: 16)
        let nonceData = HKDF<SHA256>.expand(
            pseudoRandomKey: prk, info: Data("Content-Encoding: nonce\0".utf8), outputByteCount: 12)
        var plaintext = payload
        plaintext.append(2)
        let nonceBytes = nonceData.withUnsafeBytes { Data($0) }
        let sealed = try AES.GCM.seal(
            plaintext, using: contentKey, nonce: try AES.GCM.Nonce(data: nonceBytes))
        var result = salt
        result.append(contentsOf: [0, 0, 16, 0])  // RFC 8188 record size: 4096.
        result.append(UInt8(serverPublic.count))
        result.append(serverPublic)
        result.append(sealed.ciphertext)
        result.append(sealed.tag)
        return result
    }

    static func vapidAuthorization(
        endpoint: URL, signingKey: P256.Signing.PrivateKey, now: Date = Date()
    ) throws -> String {
        guard let scheme = endpoint.scheme, let host = endpoint.host else {
            throw URLError(.badURL)
        }
        let port = endpoint.port.map { ":\($0)" } ?? ""
        let header = base64URL(
            try JSONSerialization.data(withJSONObject: ["typ": "JWT", "alg": "ES256"]))
        let claims = base64URL(
            try JSONSerialization.data(withJSONObject: [
                "aud": "\(scheme)://\(host)\(port)", "exp": Int(now.timeIntervalSince1970) + 43_200,
                "sub": "mailto:notifications@rashun.app",
            ]))
        let unsigned = "\(header).\(claims)"
        let signature = try signingKey.signature(for: Data(unsigned.utf8)).rawRepresentation
        return
            "vapid t=\(unsigned).\(base64URL(signature)), k=\(base64URL(signingKey.publicKey.x963Representation))"
    }

    private static func randomData(count: Int) -> Data {
        var rng = SystemRandomNumberGenerator()
        return Data((0..<count).map { _ in UInt8.random(in: .min ... .max, using: &rng) })
    }
    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(
            of: "/", with: "_"
        ).replacingOccurrences(of: "=", with: "")
    }

    private struct DeliveryError: Error {
        let status: Int
        var shouldRemoveSubscription: Bool { status == 404 || status == 410 }
    }
}

enum WebPushTestError: LocalizedError {
    case subscriptionMissing
    case subscriptionExpired
    var errorDescription: String? {
        switch self {
        case .subscriptionMissing: "Notifications are not enabled on this device."
        case .subscriptionExpired:
            "The notification subscription expired. Re-enable notifications on this phone."
        }
    }
}
