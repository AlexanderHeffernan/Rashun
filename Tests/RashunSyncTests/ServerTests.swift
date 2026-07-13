import Hummingbird
import HummingbirdTesting
import RashunCore
import XCTest

@testable import RashunSync
@testable import RashunSyncServer

final class ServerTests: XCTestCase {
    func testDesktopPairingRejectsDifferentAppVersion() async throws {
        let repo = try repository()
        let access = try PairingCoordinator.simpleAccess(repository: repo, scope: .desktopSync)
        let request = SimplePairingRequest(
            password: access.password, requesterName: "Old Mac", requesterDeviceID: UUID(),
            requesterEpoch: UUID(), scope: .desktopSync, requesterVersion: "1.0.0")
        let body = try JSONEncoder().encode(request)
        try await RashunSyncServer(repository: repo, appVersion: "2.0.0").application().test(
            .router
        ) {
            client in
            try await client.execute(
                uri: "/v1/pairing/connect", method: .post,
                headers: [.contentType: "application/json"],
                body: .init(data: body)
            ) { response in
                XCTAssertEqual(response.status, .conflict)
                XCTAssertTrue(try repo.peers().isEmpty)
            }
        }
    }

    func testDesktopPairingStoresReturnAddressForBidirectionalSync() async throws {
        let repo = try repository()
        let access = try PairingCoordinator.simpleAccess(repository: repo, scope: .desktopSync)
        let returnAddress = URL(string: "https://requester.invalid:8787")!
        let request = SimplePairingRequest(
            password: access.password, requesterName: "Second Mac", requesterDeviceID: UUID(),
            requesterEpoch: UUID(), scope: .desktopSync, requesterAddress: returnAddress)
        let body = try JSONEncoder().encode(request)
        try await RashunSyncServer(repository: repo).application().test(.router) { client in
            try await client.execute(
                uri: "/v1/pairing/connect", method: .post,
                headers: [.contentType: "application/json"],
                body: .init(data: body)
            ) { response in
                XCTAssertEqual(response.status, .ok)
                let result = try JSONDecoder().decode(
                    SimplePairingResponse.self, from: Data(buffer: response.body))
                XCTAssertEqual(
                    try repo.addresses(credentialID: result.credential.id).map(\.url),
                    [returnAddress])
                XCTAssertTrue(result.credential.scopes.contains(.desktopSync))
            }
        }
    }

    func testSimpleMobilePasswordCanPairBrowserAndInstalledPWAUntilExpiry() async throws {
        let repo = try repository()
        let access = try PairingCoordinator.simpleAccess(repository: repo, scope: .mobileRead)
        let request = SimplePairingRequest(
            password: access.password, requesterName: "Phone", requesterDeviceID: UUID(),
            requesterEpoch: UUID(), scope: .mobileRead)
        let body = try JSONEncoder().encode(request)
        try await RashunSyncServer(repository: repo).application().test(.router) { client in
            try await client.execute(
                uri: "/v1/pairing/connect", method: .post,
                headers: [.contentType: "application/json"],
                body: .init(data: body)
            ) { response in
                XCTAssertEqual(response.status, .ok)
                XCTAssertTrue(response.headers[.setCookie]?.contains("rashun_session=") == true)
                XCTAssertTrue(response.headers[.setCookie]?.contains("HttpOnly") == true)
                XCTAssertTrue(response.headers[.setCookie]?.contains("SameSite=Strict") == true)
                let result = try JSONDecoder().decode(
                    SimplePairingResponse.self, from: Data(buffer: response.body))
                XCTAssertTrue(result.credential.scopes.contains(.mobileRead))
            }
            try await client.execute(
                uri: "/v1/pairing/connect", method: .post,
                headers: [.contentType: "application/json"],
                body: .init(data: body)
            ) { response in
                XCTAssertEqual(response.status, .ok)
            }
        }
    }
    func testServesOfflinePWAShellFromConfiguredRoot() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("<!doctype html><title>Rashun PWA</title>".utf8).write(
            to: root.appendingPathComponent("index.html"))
        let app = try RashunSyncServer(repository: try repository(), webRoot: root.path)
            .application()
        try await app.test(.router) { client in
            try await client.execute(uri: "/", method: .get) { response in
                XCTAssertEqual(response.status, .ok)
                XCTAssertTrue(String(buffer: response.body).contains("Rashun PWA"))
            }
        }
    }
    func testCORSAllowsOnlyConfiguredExactOrigin() async throws {
        let repo = try repository()
        let credential = PeerCredential(
            secret: Data(repeating: 8, count: 32), scopes: [.mobileRead])
        try repo.savePeer(credential, deviceID: UUID(), epoch: UUID(), displayName: "Phone")
        let app = try RashunSyncServer(
            repository: repo, allowedBrowserOrigin: "https://phone.example"
        )
        .application()
        try await app.test(.router) { client in
            for (origin, expected) in [
                ("https://phone.example", "https://phone.example"), ("https://evil.example", nil),
            ] {
                let header = Self.authorization(
                    method: "GET", path: "/v1/current", body: Data(), credential: credential)
                try await client.execute(
                    uri: "/v1/current", method: .get,
                    headers: [.authorization: header, .origin: origin]
                ) { response in
                    XCTAssertEqual(response.headers[.accessControlAllowOrigin], expected)
                }
            }
        }
    }
    func testRemoteRotationRejectsOldCredentialAndAcceptsNew() async throws {
        let repo = try repository()
        let old = PeerCredential(secret: Data(repeating: 6, count: 32), scopes: [.desktopSync])
        try repo.savePeer(old, deviceID: UUID(), epoch: UUID(), displayName: "Desktop")
        let app = try RashunSyncServer(repository: repo).application()
        let box = CredentialBox()
        try await app.test(.router) { client in
            let rotate = Self.authorization(
                method: "POST", path: "/v1/peers/rotate", body: Data(), credential: old)
            try await client.execute(
                uri: "/v1/peers/rotate", method: .post, headers: [.authorization: rotate]
            ) { response in
                XCTAssertEqual(response.status, .ok)
                await box.set(
                    try? JSONDecoder().decode(
                        PeerCredential.self, from: Data(buffer: response.body)))
            }
            let oldHeader = Self.authorization(
                method: "GET", path: "/v1/hello", body: Data(), credential: old)
            try await client.execute(
                uri: "/v1/hello", method: .get, headers: [.authorization: oldHeader]
            ) { XCTAssertEqual($0.status, .unauthorized) }
            let fresh = await box.get()!
            let newHeader = Self.authorization(
                method: "GET", path: "/v1/hello", body: Data(), credential: fresh)
            try await client.execute(
                uri: "/v1/hello", method: .get, headers: [.authorization: newHeader]
            ) { XCTAssertEqual($0.status, .ok) }
        }
    }
    func testProtocolRejectsWrongScopeMalformedIncompatibleAndOversizedRequests() async throws {
        let repo = try repository()
        let desktop = PeerCredential(secret: Data(repeating: 2, count: 32), scopes: [.desktopSync])
        let mobile = PeerCredential(secret: Data(repeating: 3, count: 32), scopes: [.mobileRead])
        try repo.savePeer(desktop, deviceID: UUID(), epoch: UUID(), displayName: "Desktop")
        try repo.savePeer(mobile, deviceID: UUID(), epoch: UUID(), displayName: "Phone")
        let app = try RashunSyncServer(repository: repo).application()
        try await app.test(.router) { client in
            let wrong = Data("{}".utf8)
            let wrongHeader = Self.authorization(
                method: "POST", path: "/v1/observations/query", body: wrong, credential: mobile)
            try await client.execute(
                uri: "/v1/observations/query", method: .post,
                headers: [.authorization: wrongHeader],
                body: .init(data: wrong)
            ) { XCTAssertEqual($0.status, .unauthorized) }
            let malformed = Data("not-json".utf8)
            let malformedHeader = Self.authorization(
                method: "POST", path: "/v1/observations/query", body: malformed, credential: desktop
            )
            try await client.execute(
                uri: "/v1/observations/query", method: .post,
                headers: [.authorization: malformedHeader],
                body: .init(data: malformed)
            ) { XCTAssertEqual($0.status, .badRequest) }
            let query = ObservationQuery(
                protocolVersion: 99,
                requests: [
                    .init(
                        origin: .init(deviceID: UUID(), epoch: UUID()),
                        range: .init(from: 1, through: 1))
                ], limit: 1, pageToken: nil)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let incompatible = try encoder.encode(query)
            let incompatibleHeader = Self.authorization(
                method: "POST", path: "/v1/observations/query", body: incompatible,
                credential: desktop)
            try await client.execute(
                uri: "/v1/observations/query", method: .post,
                headers: [.authorization: incompatibleHeader],
                body: .init(data: incompatible)
            ) { XCTAssertEqual($0.status, .badRequest) }
            let oversized = Data(repeating: 65, count: 1_048_577)
            let oversizedHeader = Self.authorization(
                method: "POST", path: "/v1/observations", body: oversized, credential: desktop)
            try await client.execute(
                uri: "/v1/observations", method: .post, headers: [.authorization: oversizedHeader],
                body: .init(data: oversized)
            ) { XCTAssertNotEqual($0.status, .ok) }
        }
    }
    func testCurrentRequiresAuthenticationAndRejectsReplay() async throws {
        let repo = try repository()
        let credential = PeerCredential(
            secret: Data(repeating: 9, count: 32), scopes: [.mobileRead])
        try repo.savePeer(credential, deviceID: UUID(), epoch: UUID(), displayName: "Phone")
        _ = try repo.record(
            series: .init(providerID: "Codex", metricID: "weekly"),
            usage: .init(remaining: 42, limit: 100, resetDate: nil, cycleStartDate: nil))
        let app = try RashunSyncServer(repository: repo).application()
        try await app.test(.router) { client in
            try await client.execute(uri: "/v1/current", method: .get) {
                XCTAssertEqual($0.status, .unauthorized)
            }
            let header = Self.authorization(
                method: "GET", path: "/v1/current", body: Data(), credential: credential)
            try await client.execute(
                uri: "/v1/current", method: .get, headers: [.authorization: header]
            ) { response in
                XCTAssertEqual(response.status, .ok)
                XCTAssertTrue(String(buffer: response.body).contains("Codex"))
            }
            try await client.execute(
                uri: "/v1/current", method: .get, headers: [.authorization: header]
            ) { XCTAssertEqual($0.status, .unauthorized) }
        }
    }

    func testCurrentAcceptsHTTPBearerCompatibilityCredential() async throws {
        let repo = try repository()
        let credential = PeerCredential(
            secret: Data(repeating: 7, count: 32), scopes: [.mobileRead])
        try repo.savePeer(credential, deviceID: UUID(), epoch: UUID(), displayName: "Phone")
        let header =
            "RashunBearer \(credential.id.uuidString):\(credential.secret.base64EncodedString())"
        try await RashunSyncServer(repository: repo).application().test(.router) { client in
            try await client.execute(
                uri: "/v1/current", method: .get, headers: [.authorization: header]
            ) {
                XCTAssertEqual($0.status, .ok)
            }
        }
    }

    func testWidgetCredentialCanOnlyReadVersionedSnapshot() async throws {
        let repo = try repository()
        let widget = PeerCredential(
            secret: Data(repeating: 14, count: 32), scopes: [.widgetRead])
        try repo.savePeer(widget, deviceID: UUID(), epoch: UUID(), displayName: "iOS Widget")
        _ = try repo.record(
            series: .init(providerID: "Codex", metricID: "weekly"),
            usage: .init(
                remaining: 31, limit: 100,
                resetDate: Date(timeIntervalSince1970: 2_000_000_000)))
        await MobileUsagePresentationStore.shared.replaceAppearance(
            .init(
                colorMode: "pace", centerContentMode: "logo", showMetricBadges: true,
                metrics: [.init(providerID: "Codex", metricID: "weekly")],
                backgroundColorHex: "#010203", accentBrandColorHex: "#AABBCC"))
        let app = try RashunSyncServer(repository: repo, appVersion: "1.2.3").application()
        let header = "RashunBearer \(widget.id.uuidString):\(widget.secret.base64EncodedString())"
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/v1/widget/snapshot", method: .get,
                headers: [.authorization: header]
            ) { response in
                XCTAssertEqual(response.status, .ok)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let snapshot = try decoder.decode(
                    WidgetSnapshotDTO.self, from: Data(buffer: response.body))
                XCTAssertEqual(snapshot.schemaVersion, 1)
                XCTAssertEqual(snapshot.assetVersion, "1.2.3")
                XCTAssertEqual(snapshot.appearance.colorMode, "pace")
                XCTAssertEqual(snapshot.appearance.backgroundColorHex, "#010203")
                XCTAssertEqual(snapshot.appearance.accentBrandColorHex, "#AABBCC")
                XCTAssertEqual(snapshot.items.map(\.metricID), ["weekly"])
                XCTAssertEqual(snapshot.items.first?.remaining, 31)
            }
            try await client.execute(
                uri: "/v1/current", method: .get, headers: [.authorization: header]
            ) { XCTAssertEqual($0.status, .unauthorized) }
            try await client.execute(
                uri: "/v1/mobile/push/key", method: .get, headers: [.authorization: header]
            ) { XCTAssertEqual($0.status, .unauthorized) }
        }
        try repo.revokePeer(credentialID: widget.id)
        try await app.test(.router) { client in
            try await client.execute(
                uri: "/v1/widget/snapshot", method: .get,
                headers: [.authorization: header]
            ) { XCTAssertEqual($0.status, .unauthorized) }
        }
        await MobileUsagePresentationStore.shared.reset()
    }

    func testMobileCredentialCanCreateShortLivedWidgetSetup() async throws {
        let repo = try repository()
        let mobile = PeerCredential(
            secret: Data(repeating: 15, count: 32), scopes: [.mobileRead])
        try repo.savePeer(mobile, deviceID: UUID(), epoch: UUID(), displayName: "iPhone")
        let header = "RashunBearer \(mobile.id.uuidString):\(mobile.secret.base64EncodedString())"
        try await RashunSyncServer(repository: repo).application().test(.router) { client in
            try await client.execute(
                uri: "/v1/widget/setup", method: .post, headers: [.authorization: header]
            ) { response in
                XCTAssertEqual(response.status, .ok)
                let object = try JSONSerialization.jsonObject(
                    with: Data(buffer: response.body)) as? [String: Any]
                XCTAssertNotNil(object?["password"])
                XCTAssertNotNil(object?["expiresAt"])
            }
        }
    }

    func testCurrentAcceptsDurableSessionCookie() async throws {
        let repo = try repository()
        let credential = PeerCredential(
            secret: Data(repeating: 5, count: 32), scopes: [.mobileRead])
        try repo.savePeer(credential, deviceID: UUID(), epoch: UUID(), displayName: "Phone")
        let cookie =
            "rashun_session=\(credential.id.uuidString):\(credential.secret.base64EncodedString())"
        try await RashunSyncServer(repository: repo).application().test(.router) { client in
            try await client.execute(uri: "/v1/current", method: .get, headers: [.cookie: cookie]) {
                response in
                XCTAssertEqual(response.status, .ok)
                XCTAssertTrue(response.headers[.setCookie]?.contains("Max-Age=31536000") == true)
            }
        }
    }

    func testCurrentUsesDesktopMenuPresentationAndSelection() async throws {
        let repo = try repository()
        let credential = PeerCredential(
            secret: Data(repeating: 4, count: 32), scopes: [.mobileRead])
        try repo.savePeer(credential, deviceID: UUID(), epoch: UUID(), displayName: "Phone")
        _ = try repo.record(
            series: .init(providerID: "Codex", metricID: "weekly"),
            usage: .init(remaining: 54, limit: 100, resetDate: nil, cycleStartDate: nil))
        _ = try repo.record(
            series: .init(providerID: "Codex", metricID: "hidden"),
            usage: .init(remaining: 10, limit: 100, resetDate: nil, cycleStartDate: nil))
        await MobileUsagePresentationStore.shared.replace([
            .init(
                providerID: "Codex", metricID: "weekly", sourceName: "Codex",
                metricTitle: "Pro Weekly",
                headerDetail: "2 resets", detailText: "Resets in 5 days", iconName: "codex",
                colorHex: "#3C35FF", menuBarBadgeText: "7d",
                displayColorHex: "#FF1E33", paceColorHex: "#FF1E33", paceScore: -42,
                iconPath: "assets/codex.png", badgeColorHex: "#940F1E", hasWarning: true)
        ])
        defer { Task { await MobileUsagePresentationStore.shared.reset() } }
        let cookie =
            "rashun_session=\(credential.id.uuidString):\(credential.secret.base64EncodedString())"
        try await RashunSyncServer(repository: repo).application().test(.router) { client in
            try await client.execute(uri: "/v1/current", method: .get, headers: [.cookie: cookie]) {
                response in
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .iso8601
                let current = try decoder.decode(
                    CurrentUsageDTO.self, from: Data(buffer: response.body))
                XCTAssertEqual(current.items.count, 1)
                XCTAssertEqual(current.items.first?.metricTitle, "Pro Weekly")
                XCTAssertEqual(current.items.first?.detailText, "Resets in 5 days")
                XCTAssertEqual(current.items.first?.colorHex, "#3C35FF")
                XCTAssertEqual(current.items.first?.displayColorHex, "#FF1E33")
                XCTAssertEqual(current.items.first?.paceScore, -42)
                XCTAssertEqual(current.items.first?.menuBarBadgeText, "7d")
                XCTAssertEqual(current.items.first?.iconPath, "assets/codex.png")
                XCTAssertEqual(current.items.first?.badgeColorHex, "#940F1E")
                XCTAssertEqual(current.items.first?.hasWarning, true)
            }
        }
        await MobileUsagePresentationStore.shared.reset()
    }

    func testMobileDisconnectRevokesCredentialAndExpiresCookie() async throws {
        let repo = try repository()
        let credential = PeerCredential(
            secret: Data(repeating: 12, count: 32), scopes: [.mobileRead])
        try repo.savePeer(credential, deviceID: UUID(), epoch: UUID(), displayName: "Phone")
        let cookie =
            "rashun_session=\(credential.id.uuidString):\(credential.secret.base64EncodedString())"
        try await RashunSyncServer(repository: repo).application().test(.router) { client in
            try await client.execute(
                uri: "/v1/mobile/disconnect", method: .post, headers: [.cookie: cookie]
            ) { response in
                XCTAssertEqual(response.status, .noContent)
                XCTAssertTrue(response.headers[.setCookie]?.contains("Max-Age=0") == true)
            }
        }
        XCTAssertNil(try repo.peerCredential(id: credential.id))
    }

    func testDesktopCanQueryBackfillPage() async throws {
        let repo = try repository()
        let credential = PeerCredential(
            secret: Data(repeating: 3, count: 32), scopes: [.desktopSync])
        try repo.savePeer(credential, deviceID: UUID(), epoch: UUID(), displayName: "Desktop")
        let observation = try repo.record(
            series: .init(providerID: "Codex", metricID: "weekly"),
            usage: .init(remaining: 42, limit: 100, resetDate: nil, cycleStartDate: nil))
        let query = ObservationQuery(
            protocolVersion: 1,
            requests: [.init(origin: observation.origin, range: .init(from: 1, through: 1))],
            limit: 500,
            pageToken: nil)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let body = try encoder.encode(query)
        let header = Self.authorization(
            method: "POST", path: "/v1/observations/query", body: body, credential: credential)
        try await RashunSyncServer(repository: repo).application().test(.router) { client in
            try await client.execute(
                uri: "/v1/observations/query", method: .post,
                headers: [.authorization: header, .contentType: "application/json"],
                body: .init(data: body)
            ) { response in
                XCTAssertEqual(response.status, .ok)
                let decoder = JSONDecoder()
                decoder.dateDecodingStrategy = .secondsSince1970
                let page = try decoder.decode(
                    ObservationPage.self, from: Data(buffer: response.body))
                XCTAssertEqual(page.observations.first?.id, observation.id)
                XCTAssertNoThrow(
                    try SyncRepository(
                        path: FileManager.default.temporaryDirectory.appendingPathComponent(
                            UUID().uuidString
                        )
                        .path
                    ).ingest(page.observations))
            }
        }
    }
    private func repository() throws -> SyncRepository {
        try SyncRepository(
            path: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                .path)
    }
    private static func authorization(
        method: String, path: String, body: Data, credential: PeerCredential
    ) -> String {
        let signed = RequestAuthenticator.sign(
            method: method, path: path, body: body, credential: credential)
        return
            "Rashun \(signed.credentialID.uuidString):\(Int(signed.timestamp.timeIntervalSince1970)):\(signed.nonce):\(signed.signature.base64EncodedString())"
    }
}
private actor CredentialBox {
    private var value: PeerCredential?
    func set(_ value: PeerCredential?) { self.value = value }
    func get() -> PeerCredential? { value }
}
