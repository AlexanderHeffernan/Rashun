import Crypto
import Foundation
import Hummingbird
import HummingbirdTLS
import RashunCore
import RashunSync

public struct CurrentUsageDTO: Codable, Sendable {
    public struct Item: Codable, Sendable {
        public let providerID: String
        public let metricID: String
        public let sourceName: String
        public let metricTitle: String
        public let headerDetail: String?
        public let detailText: String?
        public let iconName: String?
        public let colorHex: String
        public let displayColorHex: String
        public let paceColorHex: String?
        public let paceScore: Double?
        public let iconPath: String?
        public let badgeColorHex: String
        public let menuBarBadgeText: String?
        public let hasWarning: Bool
        public let remaining: Double
        public let limit: Double
        public let resetAt: Date?
        public let cycleStartedAt: Date?
        public let observedAt: Date
        public let originDeviceID: UUID
        public let originEpoch: UUID
    }
    public let items: [Item]
    public let generatedAt: Date
}

public struct WidgetSnapshotDTO: Codable, Sendable {
    public struct Device: Codable, Sendable {
        public let id: UUID
        public let name: String
    }
    public struct Appearance: Codable, Sendable {
        public struct Metric: Codable, Sendable {
            public let providerID: String
            public let metricID: String
        }
        public let colorMode: String
        public let centerContentMode: String
        public let showMetricBadges: Bool
        public let metrics: [Metric]
        public let backgroundColorHex: String
        public let cardColorHex: String
        public let cardAlternateColorHex: String
        public let primaryTextColorHex: String
        public let secondaryTextColorHex: String
        public let warningColorHex: String
        public let primaryBrandColorHex: String
        public let accentBrandColorHex: String
        public let ringTrackColorHex: String
    }
    public let schemaVersion: Int
    public let assetVersion: String?
    public let generatedAt: Date
    public let device: Device
    public let appearance: Appearance
    public let items: [CurrentUsageDTO.Item]
}

private struct WidgetSetupDTO: Codable {
    let password: String
    let expiresAt: Date
}

private struct WebPushKeyDTO: Codable { let publicKey: String }
private struct WebPushSubscriptionDTO: Codable {
    struct Keys: Codable {
        let p256dh: String
        let auth: String
    }
    let endpoint: String
    let keys: Keys
}

public struct RashunSyncServer: Sendable {
    public struct TLSFiles: Sendable {
        public let certificateChain: String
        public let privateKey: String
        public init(certificateChain: String, privateKey: String) {
            self.certificateChain = certificateChain
            self.privateKey = privateKey
        }
    }
    public let repository: SyncRepository
    public let host: String
    public let port: Int
    public let webRoot: String?
    public let allowedBrowserOrigin: String?
    public let tlsFiles: TLSFiles?
    public let historyChanged: (@Sendable () async -> Void)?
    public let history: HistorySyncAccess
    public let trackedUsage: TrackedUsageSyncAccess?
    public let appVersion: String?
    public init(
        repository: SyncRepository, host: String = "127.0.0.1", port: Int = 8787,
        webRoot: String? = nil, allowedBrowserOrigin: String? = nil, tlsFiles: TLSFiles? = nil,
        historyChanged: (@Sendable () async -> Void)? = nil, appVersion: String? = nil,
        history: HistorySyncAccess = .live, trackedUsage: TrackedUsageSyncAccess? = .live
    ) {
        self.repository = repository
        self.host = host
        self.port = port
        self.webRoot = webRoot
        self.allowedBrowserOrigin = allowedBrowserOrigin
        self.tlsFiles = tlsFiles
        self.historyChanged = historyChanged
        self.appVersion = appVersion
        self.history = history
        self.trackedUsage = trackedUsage
    }

    public func application() throws -> Application<RouterResponder<BasicRequestContext>> {
        let repository = repository
        let trackedUsage = trackedUsage
        let history = history
        let router = Router()
        if let allowedBrowserOrigin {
            router.addMiddleware {
                CORSMiddleware(
                    allowOrigin: .oneOf(allowedBrowserOrigin),
                    allowHeaders: [.authorization, .contentType, .origin],
                    allowMethods: [.get, .options],
                    allowCredentials: false, maxAge: .seconds(300))
            }
        }
        if let webRoot {
            router.addMiddleware { FileMiddleware(webRoot, searchForIndexHtml: true) }
        }
        router.post("/v1/pairing/connect") { request, _ in
            let value = try decodeJSON(
                SimplePairingRequest.self, from: try await collectBody(request, upTo: 4_096))
            if value.scope == .desktopSync, let appVersion, value.requesterVersion != appVersion {
                throw HTTPError(.conflict)
            }
            guard
                let credential = try repository.connectPairingSession(
                    password: value.password, requesterName: value.requesterName,
                    requesterDeviceID: value.requesterDeviceID,
                    requesterEpoch: value.requesterEpoch,
                    scope: value.scope)
            else { throw HTTPError(.unauthorized) }
            if value.scope == .desktopSync, let address = value.requesterAddress,
                ["http", "https"].contains(address.scheme?.lowercased() ?? ""), address.host != nil
            {
                try repository.saveAddress(credentialID: credential.id, url: address, kind: .manual)
                Task {
                    let attemptStartedAt = Date()
                    do {
                        try repository.beginPeerSync(
                            credentialID: credential.id, at: attemptStartedAt)
                        let result = try await SyncCoordinator(
                            repository: repository, requiredAppVersion: appVersion,
                            trackedUsage: trackedUsage
                        ).reconcile(
                            with: HTTPPeerTransport(baseURL: address, credential: credential))
                        try repository.recordAddressResult(
                            credentialID: credential.id, url: address, succeeded: true)
                        try repository.finishPeerSync(
                            credentialID: credential.id, imported: result.accepted)
                        if result.accepted > 0 { await historyChanged?() }
                    } catch {
                        try? repository.recordAddressResult(
                            credentialID: credential.id, url: address, succeeded: false)
                        try? repository.failPeerSync(
                            credentialID: credential.id, error: String(describing: error),
                            attemptStartedAt: attemptStartedAt)
                    }
                }
            }
            let cookie = Cookie(
                name: "rashun_session", value: cookieValue(for: credential), maxAge: 31_536_000,
                path: "/",
                httpOnly: true, sameSite: .strict)
            return EditedResponse(
                headers: [.setCookie: cookie.description],
                response: try json(
                    SimplePairingResponse(
                        credential: credential, host: repository.identity, hostVersion: appVersion))
            )
        }
        router.get("/v1/hello") { request, _ -> String in
            _ = try authenticate(
                request: request, body: Data(), repository: repository, required: .mobileRead,
                allowDesktop: true)
            return try json(
                HelloDTO(
                    deviceID: repository.identity.deviceID, epoch: repository.identity.epoch,
                    protocolMinimum: 1, protocolMaximum: 1, serverTime: Date(), maximumBatch: 500,
                    appVersion: appVersion))
        }
        router.get("/v1/current") { request, _ in
            let credential = try authenticate(
                request: request, body: Data(), repository: repository, required: .mobileRead,
                allowDesktop: true)
            let presentation = await MobileUsagePresentationStore.shared.snapshot()
            let values = currentValues(await history.snapshot(nil), presentation: presentation)
            let selected =
                presentation.map { configured in
                    configured.compactMap { item in
                        values.first(where: {
                            $0.series.providerID == item.providerID
                                && $0.series.metricID == item.metricID
                        }).map { ($0, item) }
                    }
                }
                ?? values.map { value in
                    (
                        value,
                        MobileMetricPresentation(
                            providerID: value.series.providerID, metricID: value.series.metricID,
                            sourceName: value.series.providerID, metricTitle: value.series.metricID,
                            headerDetail: nil, detailText: nil, iconName: nil, colorHex: "#935AFD")
                    )
                }
            let cookie = Cookie(
                name: "rashun_session", value: cookieValue(for: credential), maxAge: 31_536_000,
                path: "/",
                httpOnly: true, sameSite: .strict)
            return EditedResponse(
                headers: [.setCookie: cookie.description],
                response: try json(
                    CurrentUsageDTO(
                        items: selected.map { value, display in
                            .init(
                                providerID: value.series.providerID,
                                metricID: value.series.metricID,
                                sourceName: display.sourceName, metricTitle: display.metricTitle,
                                headerDetail: display.headerDetail, detailText: display.detailText,
                                iconName: display.iconName, colorHex: display.colorHex,
                                displayColorHex: display.displayColorHex,
                                paceColorHex: display.paceColorHex, paceScore: display.paceScore,
                                iconPath: display.iconPath,
                                badgeColorHex: display.badgeColorHex,
                                menuBarBadgeText: display.menuBarBadgeText,
                                hasWarning: display.hasWarning,
                                remaining: value.snapshot.usage.remaining,
                                limit: value.snapshot.usage.limit,
                                resetAt: value.snapshot.usage.resetDate,
                                cycleStartedAt: value.snapshot.usage.cycleStartDate,
                                observedAt: value.snapshot.timestamp,
                                originDeviceID: repository.identity.deviceID,
                                originEpoch: repository.identity.epoch)
                        }, generatedAt: Date())))
        }
        router.post("/v1/widget/setup") { request, _ -> String in
            _ = try authenticate(
                request: request, body: Data(), repository: repository, required: .mobileRead)
            let access = try PairingCoordinator.simpleAccess(
                repository: repository, scope: .widgetRead)
            return try json(WidgetSetupDTO(password: access.password, expiresAt: access.expiresAt))
        }
        router.get("/v1/widget/snapshot") { request, _ -> String in
            _ = try authenticate(
                request: request, body: Data(), repository: repository, required: .widgetRead)
            let items = await currentItems(repository: repository, history: history)
            let configured = await MobileUsagePresentationStore.shared.appearanceSnapshot()
            let appearance = WidgetSnapshotDTO.Appearance(
                colorMode: configured?.colorMode ?? "sourceSolid",
                centerContentMode: configured?.centerContentMode ?? "percentage",
                showMetricBadges: configured?.showMetricBadges ?? true,
                metrics: (configured?.metrics ?? []).map {
                    .init(providerID: $0.providerID, metricID: $0.metricID)
                }, backgroundColorHex: configured?.backgroundColorHex ?? "#131129",
                cardColorHex: configured?.cardColorHex ?? "#1C1836",
                cardAlternateColorHex: configured?.cardAlternateColorHex ?? "#241E44",
                primaryTextColorHex: configured?.primaryTextColorHex ?? "#FFFFFF",
                secondaryTextColorHex: configured?.secondaryTextColorHex ?? "#B9B4D6",
                warningColorHex: configured?.warningColorHex ?? "#FFD166",
                primaryBrandColorHex: configured?.primaryBrandColorHex ?? "#935AFD",
                accentBrandColorHex: configured?.accentBrandColorHex ?? "#0DE4D1",
                ringTrackColorHex: configured?.ringTrackColorHex ?? "#5C596A")
            return try json(
                WidgetSnapshotDTO(
                    schemaVersion: 1, assetVersion: appVersion, generatedAt: Date(),
                    device: .init(
                        id: repository.identity.deviceID, name: repository.identity.displayName),
                    appearance: appearance, items: items))
        }
        router.post("/v1/mobile/disconnect") { request, _ -> Response in
            let credential = try authenticate(
                request: request, body: Data(), repository: repository, required: .mobileRead)
            try repository.revokePeer(credentialID: credential.id)
            var response = Response(status: .noContent)
            response.setCookie(
                .init(
                    name: "rashun_session", value: "deleted", maxAge: 0, path: "/", httpOnly: true,
                    sameSite: .strict))
            return response
        }
        router.get("/v1/mobile/push/key") { request, _ -> String in
            _ = try authenticate(
                request: request, body: Data(), repository: repository, required: .mobileRead)
            let privateKey = try P256.Signing.PrivateKey(
                rawRepresentation: repository.webPushSigningPrivateKey())
            return try json(
                WebPushKeyDTO(publicKey: base64URL(privateKey.publicKey.x963Representation)))
        }
        router.put("/v1/mobile/push/subscription") { request, _ -> Response in
            let (credential, body) = try await authenticatedBody(
                request, upTo: 8_192, repository: repository, required: .mobileRead)
            let value = try decodeJSON(WebPushSubscriptionDTO.self, from: body)
            guard let endpoint = URL(string: value.endpoint),
                let key = base64URLData(value.keys.p256dh),
                let auth = base64URLData(value.keys.auth)
            else { throw HTTPError(.badRequest) }
            try repository.saveWebPushSubscription(
                .init(endpoint: endpoint, clientPublicKey: key, authSecret: auth),
                credentialID: credential.id)
            return Response(status: .noContent)
        }
        router.delete("/v1/mobile/push/subscription") { request, _ -> Response in
            let credential = try authenticate(
                request: request, body: Data(), repository: repository, required: .mobileRead)
            try repository.removeWebPushSubscription(credentialID: credential.id)
            return Response(status: .noContent)
        }
        router.post("/v1/history/reconcile") { request, _ -> String in
            let (credential, body) = try await authenticatedBody(
                request, upTo: 16_777_216, repository: repository, required: .desktopSync)
            let value = try decodeExactJSON(HistoryReconcileRequest.self, from: body)
            let changed = await history.merge(value.changes)
            let outgoing = await history.snapshot(value.knownRemoteRevision)
            try repository.saveHistoryRevisions(
                credentialID: credential.id, remote: value.changes.revision,
                localAcknowledged: value.knownRemoteRevision ?? 0)
            try? repository.finishPeerSync(
                credentialID: credential.id,
                imported: changed ? value.changes.historyBySource.count : 0)
            if changed { await historyChanged?() }
            return try exactJSON(
                HistoryReconcileResponse(
                    acknowledgedRevision: value.changes.revision, changes: outgoing))
        }
        router.get("/v1/tracked-usage") { request, _ -> String in
            _ = try authenticate(
                request: request, body: Data(), repository: repository, required: .desktopSync)
            guard let trackedUsage else { throw HTTPError(.notImplemented) }
            return try exactJSON(await trackedUsage.snapshot())
        }
        router.post("/v1/tracked-usage") { request, _ -> String in
            let (_, body) = try await authenticatedBody(
                request, upTo: 4_194_304, repository: repository, required: .desktopSync)
            guard let trackedUsage else { throw HTTPError(.notImplemented) }
            let snapshot = try decodeExactJSON(TrackedUsageSyncSnapshot.self, from: body)
            _ = await trackedUsage.merge(snapshot)
            return try exactJSON(await trackedUsage.snapshot())
        }
        router.post("/v1/peers/rotate") { request, _ -> String in
            let (credential, _) = try await authenticatedBody(
                request, upTo: 64, repository: repository, required: .desktopSync)
            return try json(try repository.rotatePeer(credentialID: credential.id))
        }
        if let tlsFiles {
            let certificates = try NIOSSLCertificate.fromPEMFile(tlsFiles.certificateChain)
            let key = try NIOSSLPrivateKey(file: tlsFiles.privateKey, format: .pem)
            let configuration = TLSConfiguration.makeServerConfiguration(
                certificateChain: certificates.map { .certificate($0) },
                privateKey: .privateKey(key))
            return Application(
                router: router, server: try .tls(tlsConfiguration: configuration),
                configuration: .init(address: .hostname(host, port: port)))
        }
        return Application(
            router: router, configuration: .init(address: .hostname(host, port: port)))
    }
    public func run() async throws { try await application().runService() }
}

private func collectBody(_ request: Request, upTo maximumBytes: Int) async throws -> Data {
    let buffer = try await request.body.collect(upTo: maximumBytes)
    return Data(buffer.readableBytesView)
}

private func authenticatedBody(
    _ request: Request, upTo maximumBytes: Int, repository: SyncRepository,
    required: PeerCredential.Scope
) async throws -> (PeerCredential, Data) {
    let body = try await collectBody(request, upTo: maximumBytes)
    return (
        try authenticate(request: request, body: body, repository: repository, required: required),
        body
    )
}

private func authenticate(
    request: Request, body: Data, repository: SyncRepository, required: PeerCredential.Scope,
    allowDesktop: Bool = false
) throws -> PeerCredential {
    guard let header = request.headers[.authorization] else {
        guard let value = request.cookies["rashun_session"]?.value,
            let credential = try credential(fromCookie: value, repository: repository),
            credential.scopes.contains(required)
                || (allowDesktop && credential.scopes.contains(.desktopSync))
        else { throw HTTPError(.unauthorized) }
        try repository.markPeerSeen(credentialID: credential.id)
        return credential
    }
    if header.hasPrefix("RashunBearer ") {
        let parts = header.dropFirst("RashunBearer ".count).split(separator: ":", maxSplits: 1).map(
            String.init)
        guard parts.count == 2, let id = UUID(uuidString: parts[0]),
            let supplied = Data(base64Encoded: parts[1]),
            let credential = try repository.peerCredential(id: id),
            credential.scopes.contains(required)
                || (allowDesktop && credential.scopes.contains(.desktopSync)),
            constantTimeEqual(supplied, credential.secret)
        else { throw HTTPError(.unauthorized) }
        try repository.markPeerSeen(credentialID: id)
        return credential
    }
    guard header.hasPrefix("Rashun ") else { throw HTTPError(.unauthorized) }
    let parts = header.dropFirst(7).split(separator: ":", maxSplits: 3).map(String.init)
    guard parts.count == 4, let id = UUID(uuidString: parts[0]),
        let seconds = TimeInterval(parts[1]),
        let signature = Data(base64Encoded: parts[3]),
        let credential = try repository.peerCredential(id: id),
        credential.scopes.contains(required)
            || (allowDesktop && credential.scopes.contains(.desktopSync))
    else { throw HTTPError(.unauthorized) }
    let signed = SignedRequest(
        credentialID: id, timestamp: Date(timeIntervalSince1970: seconds), nonce: parts[2],
        signature: signature)
    guard
        RequestAuthenticator.verify(
            signed, method: request.method.rawValue, path: request.uri.path, body: body,
            credential: credential),
        try repository.consumeNonce(
            credentialID: id, nonce: parts[2], expiresAt: Date().addingTimeInterval(300))
    else { throw HTTPError(.unauthorized) }
    try repository.markPeerSeen(credentialID: id)
    return credential
}

private struct CurrentHistoryValue {
    let series: UsageSeriesID
    let snapshot: UsageSnapshot
}

private func currentValues(
    _ history: HistorySyncSnapshot, presentation: [MobileMetricPresentation]? = nil
) -> [CurrentHistoryValue] {
    history.historyBySource.compactMap { key, snapshots in
        let parts = key.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: true)
        guard let snapshot = snapshots.last else { return nil }
        let series: UsageSeriesID
        if parts.count == 2 {
            series = .init(providerID: String(parts[0]), metricID: String(parts[1]))
        } else if let configured = presentation?.first(where: { $0.providerID == key }) {
            series = .init(providerID: configured.providerID, metricID: configured.metricID)
        } else {
            return nil
        }
        return CurrentHistoryValue(
            series: series, snapshot: snapshot)
    }.sorted { $0.series.description < $1.series.description }
}

private func currentItems(
    repository: SyncRepository, history: HistorySyncAccess
) async -> [CurrentUsageDTO.Item] {
    let presentation = await MobileUsagePresentationStore.shared.snapshot()
    let values = currentValues(await history.snapshot(nil), presentation: presentation)
    let selected =
        presentation.map { configured in
            configured.compactMap { item in
                values.first(where: {
                    $0.series.providerID == item.providerID && $0.series.metricID == item.metricID
                }).map { ($0, item) }
            }
        }
        ?? values.map { value in
            (
                value,
                MobileMetricPresentation(
                    providerID: value.series.providerID, metricID: value.series.metricID,
                    sourceName: value.series.providerID, metricTitle: value.series.metricID,
                    headerDetail: nil, detailText: nil, iconName: nil, colorHex: "#935AFD")
            )
        }
    return selected.map { value, display in
        .init(
            providerID: value.series.providerID, metricID: value.series.metricID,
            sourceName: display.sourceName, metricTitle: display.metricTitle,
            headerDetail: display.headerDetail, detailText: display.detailText,
            iconName: display.iconName, colorHex: display.colorHex,
            displayColorHex: display.displayColorHex,
            paceColorHex: display.paceColorHex, paceScore: display.paceScore,
            iconPath: display.iconPath,
            badgeColorHex: display.badgeColorHex,
            menuBarBadgeText: display.menuBarBadgeText,
            hasWarning: display.hasWarning,
            remaining: value.snapshot.usage.remaining, limit: value.snapshot.usage.limit,
            resetAt: value.snapshot.usage.resetDate,
            cycleStartedAt: value.snapshot.usage.cycleStartDate,
            observedAt: value.snapshot.timestamp,
            originDeviceID: repository.identity.deviceID,
            originEpoch: repository.identity.epoch)
    }
}
private func cookieValue(for credential: PeerCredential) -> String {
    "\(credential.id.uuidString):\(credential.secret.base64EncodedString())"
}
private func credential(fromCookie value: String, repository: SyncRepository) throws
    -> PeerCredential?
{
    let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
    guard parts.count == 2, let id = UUID(uuidString: parts[0]),
        let supplied = Data(base64Encoded: parts[1]),
        let credential = try repository.peerCredential(id: id),
        constantTimeEqual(supplied, credential.secret)
    else { return nil }
    return credential
}
private func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
    guard lhs.count == rhs.count else { return false }
    var difference: UInt8 = 0
    for (a, b) in zip(lhs, rhs) { difference |= a ^ b }
    return difference == 0
}
private func encoder() -> JSONEncoder {
    let e = JSONEncoder()
    e.dateEncodingStrategy = .iso8601
    return e
}
private func decoder() -> JSONDecoder {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    return d
}
private func decodeJSON<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    do { return try decoder().decode(type, from: data) } catch { throw HTTPError(.badRequest) }
}
private func json<T: Encodable>(_ value: T) throws -> String {
    String(decoding: try encoder().encode(value), as: UTF8.self)
}
private func exactJSON<T: Encodable>(_ value: T) throws -> String {
    let e = JSONEncoder()
    e.dateEncodingStrategy = .secondsSince1970
    return String(decoding: try e.encode(value), as: UTF8.self)
}
private func decodeExactJSON<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .secondsSince1970
    do { return try d.decode(type, from: data) } catch { throw HTTPError(.badRequest) }
}
private func base64URL(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(
        of: "/", with: "_"
    ).replacingOccurrences(of: "=", with: "")
}
private func base64URLData(_ value: String) -> Data? {
    var value = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(
        of: "_", with: "/")
    value += String(repeating: "=", count: (4 - value.count % 4) % 4)
    return Data(base64Encoded: value)
}
