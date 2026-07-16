import Foundation

public enum LocalNetworkEndpoint {
    public static func preferredIPv4Address() -> String? {
        Host.current().addresses.first { address in
            let parts = address.split(separator: ".").compactMap { Int($0) }
            guard parts.count == 4, parts.allSatisfy({ (0...255).contains($0) }) else {
                return false
            }
            return parts[0] != 127 && !(parts[0] == 169 && parts[1] == 254)
        }
    }

    public static func preferredURL(port: Int = 8787, secure: Bool = false) -> URL? {
        guard let address = preferredIPv4Address() else { return nil }
        return URL(string: "\(secure ? "https" : "http")://\(address):\(port)")
    }
}
