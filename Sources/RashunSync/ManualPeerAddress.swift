import Foundation

public enum ManualPeerAddress {
    public static func validate(_ value: String, allowLoopbackHTTP: Bool = false) throws -> URL {
        guard let url = URL(string: value), url.host != nil,
            url.scheme == "https"
                || (allowLoopbackHTTP && url.scheme == "http"
                    && ["localhost", "127.0.0.1", "::1"].contains(url.host))
        else {
            throw URLError(.badURL)
        }
        return url
    }
}
