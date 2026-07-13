import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum PairingHTTPClient {
    public static func exchange(invitation:PairingInvitation,with endpoint:URL,requester:DeviceIdentity) async throws -> PairingStatusDTO {try await post(PairingExchangeRequest(sessionID:invitation.sessionID,secret:invitation.secret,requester:requester),path:"/v1/pairing/exchange",endpoint:endpoint)}
    public static func complete(invitation:PairingInvitation,with endpoint:URL) async throws -> PairingStatusDTO {try await post(PairingCompleteRequest(sessionID:invitation.sessionID,secret:invitation.secret),path:"/v1/pairing/complete",endpoint:endpoint)}
    private static func post<I:Encodable,O:Decodable>(_ value:I,path:String,endpoint:URL) async throws -> O {guard endpoint.scheme=="https" || endpoint.scheme=="http" else{throw URLError(.unsupportedURL)};let encoder=JSONEncoder();encoder.dateEncodingStrategy = .iso8601;var request=URLRequest(url:endpoint.appendingPathComponent(String(path.dropFirst())));request.httpMethod="POST";request.httpBody=try encoder.encode(value);request.setValue("application/json",forHTTPHeaderField:"Content-Type");let(data,response)=try await URLSession.shared.data(for:request);guard let http=response as? HTTPURLResponse,(200..<300).contains(http.statusCode) else{throw URLError(.badServerResponse)};let decoder=JSONDecoder();decoder.dateDecodingStrategy = .iso8601;return try decoder.decode(O.self,from:data)}
}
