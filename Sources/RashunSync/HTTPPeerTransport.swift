import Foundation
import RashunCore

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

public struct HTTPPeerTransport: SyncPeerTransport, Sendable {
    public let baseURL: URL
    public let credential: PeerCredential
    public init(baseURL: URL, credential: PeerCredential) throws {
        guard baseURL.scheme == "https" || baseURL.scheme == "http" else {
            throw URLError(.unsupportedURL)
        }
        self.baseURL = baseURL
        self.credential = credential
    }
    public func hello() async throws -> HelloDTO { try await get("/v1/hello", as: HelloDTO.self) }
    public func origins() async throws -> [OriginSummary] {
        try await get("/v1/origins", as: [OriginSummary].self)
    }
    public func query(_ request: ObservationQuery) async throws -> ObservationPage {
        try await sendExact(
            "POST", path: "/v1/observations/query", value: request, as: ObservationPage.self)
    }
    public func ingest(_ observations: [UsageObservation]) async throws -> IngestAcknowledgement {
        try await sendExact(
            "POST", path: "/v1/observations", value: observations, as: IngestAcknowledgement.self)
    }
    public func trackedUsage() async throws -> TrackedUsageSyncSnapshot {
        try await get("/v1/tracked-usage", as: TrackedUsageSyncSnapshot.self)
    }
    public func mergeTrackedUsage(_ snapshot: TrackedUsageSyncSnapshot) async throws -> TrackedUsageSyncSnapshot {
        try await sendExact("POST", path: "/v1/tracked-usage", value: snapshot, as: TrackedUsageSyncSnapshot.self)
    }
    public func current() async throws -> Data {
        let (data, _) = try await execute("GET", path: "/v1/current", body: Data())
        return data
    }
    public func rotate() async throws -> PeerCredential {
        let (data, _) = try await execute("POST", path: "/v1/peers/rotate", body: Data())
        return try decoder().decode(PeerCredential.self, from: data)
    }
    private func get<T: Decodable>(_ path: String, as: T.Type) async throws -> T {
        let (data, _) = try await execute("GET", path: path, body: Data())
        return try decoder().decode(T.self, from: data)
    }
    private func sendExact<I: Encodable, O: Decodable>(
        _ method: String, path: String, value: I, as: O.Type
    ) async throws -> O {
        let body = try exactEncoder().encode(value)
        let (data, _) = try await execute(method, path: path, body: body)
        return try exactDecoder().decode(O.self, from: data)
    }
    private func execute(_ method: String, path: String, body: Data) async throws -> (
        Data, HTTPURLResponse
    ) {
        let url = baseURL.appendingPathComponent(String(path.drop(while: { $0 == "/" })))
        let signed = RequestAuthenticator.sign(
            method: method, path: path, body: body, credential: credential)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body.isEmpty ? nil : body
        request.setValue(
            "application/vnd.rashun.sync+json;version=1", forHTTPHeaderField: "Content-Type")
        request.setValue(
            "Rashun \(signed.credentialID.uuidString):\(Int(signed.timestamp.timeIntervalSince1970)):\(signed.nonce):\(signed.signature.base64EncodedString())",
            forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard (200..<300).contains(http.statusCode) else {
            throw HTTPPeerTransportError.httpStatus(http.statusCode)
        }
        return (data, http)
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
    private func exactEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .secondsSince1970
        return e
    }
    private func exactDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .secondsSince1970
        return d
    }
}
public enum HTTPPeerTransportError: Error, Equatable, Sendable { case httpStatus(Int) }
