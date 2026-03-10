import Foundation

public enum Versioning {
    public static func versionString(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        if let envVersion = environment["RASHUN_VERSION"], !envVersion.isEmpty {
            return envVersion
        }

        if let bundleVersion = bundle.infoDictionary?["CFBundleShortVersionString"] as? String,
           !bundleVersion.isEmpty {
            return bundleVersion
        }

        if let fileVersion = versionFromNearbyInfoPlist(), !fileVersion.isEmpty {
            return fileVersion
        }

        return "0.0.0"
    }

    private static func versionFromNearbyInfoPlist() -> String? {
        let fileManager = FileManager.default
        let candidates = [
            URL(fileURLWithPath: fileManager.currentDirectoryPath),
            URL(fileURLWithPath: CommandLine.arguments.first ?? "").deletingLastPathComponent()
        ]

        for base in candidates {
            var current = base
            for _ in 0..<6 {
                let plistURL = current.appendingPathComponent("Info.plist")
                if let data = try? Data(contentsOf: plistURL),
                   let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
                   let dict = plist as? [String: Any],
                   let version = dict["CFBundleShortVersionString"] as? String,
                   !version.isEmpty {
                    return version
                }
                current.deleteLastPathComponent()
            }
        }

        return nil
    }
}

public func isNewerVersion(_ a: String, than b: String) -> Bool {
    let aParts = a.split(separator: ".").compactMap { Int($0) }
    let bParts = b.split(separator: ".").compactMap { Int($0) }
    for i in 0..<max(aParts.count, bParts.count) {
        let av = i < aParts.count ? aParts[i] : 0
        let bv = i < bParts.count ? bParts[i] : 0
        if av > bv { return true }
        if av < bv { return false }
    }
    return false
}
