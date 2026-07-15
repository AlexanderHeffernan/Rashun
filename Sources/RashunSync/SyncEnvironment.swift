import Foundation
import RashunCore

@MainActor
public final class SyncEnvironment {
    public static let shared = SyncEnvironment()
    public private(set) var repository: SyncRepository?
    public private(set) var startupError: Error?

    private init() {
        do {
            let directory = Self.dataDirectory()
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true)
            repository = try SyncRepository(path: directory.path)
        } catch {
            startupError = error
        }
    }

    public func record(sourceName: String, usage: UsageResult) throws {
        UsageHistoryStore.shared.append(sourceName: sourceName, usage: usage)
    }

    public static func dataDirectory() -> URL {
        #if os(Windows)
            if let appData = ProcessInfo.processInfo.environment["APPDATA"], !appData.isEmpty {
                return URL(fileURLWithPath: appData).appendingPathComponent("Rashun")
            }
        #endif
        #if os(macOS)
            return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
                .first!.appendingPathComponent("Rashun")
        #else
            return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".rashun")
        #endif
    }
}
