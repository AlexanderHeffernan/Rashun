import Crypto
import Foundation
import Hummingbird
import HummingbirdTLS
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
    public let appVersion: String?
    public init(
        repository: SyncRepository, host: String = "127.0.0.1", port: Int = 8787,
        webRoot: String? = nil, allowedBrowserOrigin: String? = nil, tlsFiles: TLSFiles? = nil,
        historyChanged: (@Sendable () async -> Void)? = nil, appVersion: String? = nil
    ) {
        self.repository = repository
        self.host = host
        self.port = port
        self.webRoot = webRoot
        self.allowedBrowserOrigin = allowedBrowserOrigin
        self.tlsFiles = tlsFiles
        self.historyChanged = historyChanged
        self.appVersion = appVersion
    }

    public func application() throws -> Application<RouterResponder<BasicRequestContext>> {
        let repository = repository
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
        router.post("/v1/pairing/exchange") { request, _ -> String in
            let buffer = try await request.body.collect(upTo: 16_384)
            let body = Data(buffer.readableBytesView)
            let exchange = try decodeJSON(PairingExchangeRequest.self, from: body)
            guard
                try repository.exchangePairingSession(
                    id: exchange.sessionID, secret: exchange.secret, requester: exchange.requester)
            else { throw HTTPError(.unauthorized) }
            return try json(PairingStatusDTO(pendingApproval: true))
        }
        router.post("/v1/pairing/complete") { request, _ -> String in
            let buffer = try await request.body.collect(upTo: 4_096)
            let body = Data(buffer.readableBytesView)
            let complete = try decodeJSON(PairingCompleteRequest.self, from: body)
            guard
                let credential = try repository.completePairingSession(
                    id: complete.sessionID, secret: complete.secret)
            else { throw HTTPError(.accepted) }
            return try json(PairingStatusDTO(pendingApproval: false, credential: credential))
        }
        router.post("/v1/pairing/connect") { request, _ in
            let buffer = try await request.body.collect(upTo: 4_096)
            let value = try decodeJSON(
                SimplePairingRequest.self, from: Data(buffer.readableBytesView))
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
                    do {
                        try repository.beginPeerSync(credentialID: credential.id)
                        let result = try await SyncCoordinator(
                            repository: repository, requiredAppVersion: appVersion
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
                        try? repository.finishPeerSync(
                            credentialID: credential.id, imported: 0,
                            error: String(describing: error))
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
        router.get("/v1/origins") { request, _ -> String in
            _ = try authenticate(
                request: request, body: Data(), repository: repository, required: .desktopSync)
            return try json(repository.originSummaries())
        }
        router.get("/v1/current") { request, _ in
            let credential = try authenticate(
                request: request, body: Data(), repository: repository, required: .mobileRead,
                allowDesktop: true)
            let values = HistoryProjector.current(try repository.allObservations()).values.sorted {
                $0.series.description < $1.series.description
            }
            let presentation = await MobileUsagePresentationStore.shared.snapshot()
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
                                remaining: value.remaining,
                                limit: value.limit, resetAt: value.resetAt,
                                cycleStartedAt: value.cycleStartedAt,
                                observedAt: value.observedAt, originDeviceID: value.origin.deviceID,
                                originEpoch: value.origin.epoch)
                        }, generatedAt: Date())))
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
            let buffer = try await request.body.collect(upTo: 8_192)
            let body = Data(buffer.readableBytesView)
            let credential = try authenticate(
                request: request, body: body, repository: repository, required: .mobileRead)
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
        router.post("/v1/observations/query") { request, _ -> String in
            let buffer = try await request.body.collect(upTo: 1_048_576)
            let body = Data(buffer.readableBytesView)
            _ = try authenticate(
                request: request, body: body, repository: repository, required: .desktopSync)
            let query = try decodeExactJSON(ObservationQuery.self, from: body)
            guard query.protocolVersion == 1, query.limit > 0, query.limit <= 500,
                query.requests.count == 1
            else { throw HTTPError(.badRequest) }
            let item = query.requests[0]
            let after = query.pageToken.flatMap(UInt64.init) ?? (item.range.from - 1)
            guard after < item.range.through else { throw HTTPError(.badRequest) }
            let effective = SequenceRange(
                from: max(item.range.from, after + 1), through: item.range.through)
            let observations = try repository.observations(
                origin: item.origin, range: effective, limit: query.limit)
            let next = observations.last.flatMap {
                $0.originSequence < item.range.through && observations.count == query.limit
                    ? String($0.originSequence) : nil
            }
            return try exactJSON(ObservationPage(observations: observations, nextPageToken: next))
        }
        router.post("/v1/observations") { request, _ -> String in
            let buffer = try await request.body.collect(upTo: 1_048_576)
            let body = Data(buffer.readableBytesView)
            let credential = try authenticate(
                request: request, body: body, repository: repository, required: .desktopSync)
            let values = try decodeExactJSON([UsageObservation].self, from: body)
            let before = Set(try repository.allObservations().map(\.id))
            _ = try repository.ingest(values)
            let accepted = values.filter { !before.contains($0.id) }.map(\.id)
            let duplicates = values.filter { before.contains($0.id) }.map(\.id)
            try? repository.finishPeerSync(credentialID: credential.id, imported: accepted.count)
            if !accepted.isEmpty { await historyChanged?() }
            return try json(
                IngestAcknowledgement(
                    accepted: accepted, duplicates: duplicates, rejected: [],
                    origins: try repository.originSummaries()))
        }
        router.post("/v1/peers/rotate") { request, _ -> String in
            let buffer = try await request.body.collect(upTo: 64)
            let body = Data(buffer.readableBytesView)
            let credential = try authenticate(
                request: request, body: body, repository: repository, required: .desktopSync)
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
