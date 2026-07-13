import Crypto
import XCTest

@testable import Rashun
@testable import RashunSync

final class WebPushSenderTests: XCTestCase {
    func testEncryptedPayloadUsesAES128GCMRecordFormat() throws {
        let client = P256.KeyAgreement.PrivateKey()
        let subscription = WebPushSubscription(
            endpoint: URL(string: "https://push.example.test/send/1")!,
            clientPublicKey: client.publicKey.x963Representation,
            authSecret: Data(repeating: 7, count: 16))
        let encrypted = try WebPushSender.encrypt(Data("hello".utf8), subscription: subscription)
        XCTAssertGreaterThan(encrypted.count, 16 + 4 + 1 + 65 + 5 + 16)
        XCTAssertEqual(Array(encrypted[16..<20]), [0, 0, 16, 0])
        XCTAssertEqual(encrypted[20], 65)
    }

    func testVAPIDAuthorizationContainsPublicKeyAndSignedToken() throws {
        let key = P256.Signing.PrivateKey()
        let value = try WebPushSender.vapidAuthorization(
            endpoint: URL(string: "https://push.example.test/send/1")!, signingKey: key,
            now: Date(timeIntervalSince1970: 1_000))
        XCTAssertTrue(value.hasPrefix("vapid t="))
        XCTAssertTrue(value.contains(", k="))
        XCTAssertEqual(value.split(separator: ".").count, 3)
    }
}
