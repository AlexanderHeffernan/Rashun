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
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let repo = try SyncRepository(path: directory.appendingPathComponent("usage-sync.sqlite").path)
            repository = repo
            if try repo.allObservations().isEmpty {
                let legacy = UsageHistoryStore.shared.allHistory()
                if !legacy.isEmpty {
                    let data = try JSONEncoder().encode(legacy)
                    _ = try LegacyHistoryMigrator.migrate(history: legacy, sourceData: data, repository: repo,
                        backupRoot: directory.appendingPathComponent("Backups/sync-v1", isDirectory: true), registry: LegacyHistoryMigrator.defaultRegistry())
                    _ = UsageHistoryStore.shared.replaceAllHistory(try repo.projectedHistory(), force: true)
                }
            }
        } catch { repository = nil; startupError = error }
    }

    @discardableResult public func record(providerID: String, metricID: String, usage: UsageResult, at: Date = Date()) throws -> UsageObservation {
        guard let repository else { throw startupError ?? CocoaError(.fileWriteUnknown) }
        let observation = try repository.record(series: .init(providerID: providerID, metricID: metricID), usage: usage, at: at)
        // Compatibility consumers remain on the deterministic materialized view during v1.
        _ = UsageHistoryStore.shared.replaceAllHistory(try repository.projectedHistory(), force: true)
        return observation
    }

    public func refreshCompatibilityView() throws {
        guard let repository else { throw startupError ?? CocoaError(.fileReadUnknown) }
        _ = UsageHistoryStore.shared.replaceAllHistory(try repository.projectedHistory(), force: true)
    }

    public static func dataDirectory() -> URL {
        #if os(macOS)
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Rashun", isDirectory: true)
        #elseif os(Windows)
        return URL(fileURLWithPath: ProcessInfo.processInfo.environment["APPDATA"] ?? FileManager.default.homeDirectoryForCurrentUser.path).appendingPathComponent("Rashun", isDirectory: true)
        #else
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".rashun", isDirectory: true)
        #endif
    }
}
