import Foundation

public struct SourceHealthRecord: Codable {
    public var lastSuccessfulUsage: UsageResult?
    public var lastSuccessAt: Date?
    public var lastFailureAt: Date?
    public var consecutiveFailures: Int
    public var shortErrorMessage: String?
    public var detailedErrorMessage: String?

    public init(
        lastSuccessfulUsage: UsageResult? = nil,
        lastSuccessAt: Date? = nil,
        lastFailureAt: Date? = nil,
        consecutiveFailures: Int = 0,
        shortErrorMessage: String? = nil,
        detailedErrorMessage: String? = nil
    ) {
        self.lastSuccessfulUsage = lastSuccessfulUsage
        self.lastSuccessAt = lastSuccessAt
        self.lastFailureAt = lastFailureAt
        self.consecutiveFailures = consecutiveFailures
        self.shortErrorMessage = shortErrorMessage
        self.detailedErrorMessage = detailedErrorMessage
    }
}

@MainActor
public final class SourceHealthStore {
    public static let shared = SourceHealthStore(backend: PersistenceBackendFactory.default())

    private let userDefaultsKey = "ai.sourceHealth.v1"
    private let migrationKey = "ai.sourceHealth.migrated.v1"
    private let backend: PersistenceBackend
    private let legacyBackends: [PersistenceBackend]
    private var recordsBySource: [String: SourceHealthRecord] = [:]

    public init(
        backend: PersistenceBackend,
        legacyBackends: [PersistenceBackend] = PersistenceBackendFactory.defaultLegacyBackends()
    ) {
        self.backend = backend
        self.legacyBackends = legacyBackends
        load()
    }

    private func scopedName(sourceName: String, metricId: String?) -> String {
        guard let metricId else { return sourceName }
        return "\(sourceName)::\(metricId)"
    }

    public func recordSuccess(sourceName: String, metricId: String, usage: UsageResult) {
        recordSuccess(sourceName: scopedName(sourceName: sourceName, metricId: metricId), usage: usage)
    }

    public func recordSuccess(sourceName: String, usage: UsageResult) {
        var record = recordsBySource[sourceName] ?? SourceHealthRecord()
        record.lastSuccessfulUsage = usage
        record.lastSuccessAt = Date()
        record.consecutiveFailures = 0
        record.shortErrorMessage = nil
        record.detailedErrorMessage = nil
        recordsBySource[sourceName] = record
        persistAndNotify()
    }

    public func recordFailure(sourceName: String, metricId: String, presentation: SourceFetchErrorPresentation) {
        recordFailure(sourceName: scopedName(sourceName: sourceName, metricId: metricId), presentation: presentation)
    }

    public func recordFailure(sourceName: String, presentation: SourceFetchErrorPresentation) {
        var record = recordsBySource[sourceName] ?? SourceHealthRecord()
        record.lastFailureAt = Date()
        record.consecutiveFailures += 1
        record.shortErrorMessage = presentation.shortMessage
        record.detailedErrorMessage = presentation.detailedMessage
        recordsBySource[sourceName] = record
        persistAndNotify()
    }

    public func health(for sourceName: String) -> SourceHealthRecord? {
        recordsBySource[sourceName]
    }

    public func health(for sourceName: String, metricId: String) -> SourceHealthRecord? {
        recordsBySource[scopedName(sourceName: sourceName, metricId: metricId)]
    }

    public func resetMigrationStateForTesting() {
        backend.set(nil, forKey: migrationKey)
    }

    private func load() {
        let hasMigrated = backend.data(forKey: migrationKey) != nil

        let sharedRecords = decodeRecords(from: backend.data(forKey: userDefaultsKey))
        let sharedCount = sharedRecords.count

        if hasMigrated {
            recordsBySource = sharedRecords
            return
        }

        var bestLegacyRecords: [String: SourceHealthRecord] = [:]
        var bestLegacyCount = 0

        for legacy in legacyBackends {
            guard let legacyData = legacy.data(forKey: userDefaultsKey) else {
                continue
            }
            let decoded = decodeRecords(from: legacyData)
            guard !decoded.isEmpty else { continue }

            if decoded.count > bestLegacyCount {
                bestLegacyRecords = decoded
                bestLegacyCount = decoded.count
            }
        }

        if sharedCount > 0 || bestLegacyCount > 0 {
            writeMigrationBackup(named: "shared", records: sharedRecords)
            writeMigrationBackup(named: "legacy", records: bestLegacyRecords)
        }

        let chosen = bestLegacyCount > sharedCount ? bestLegacyRecords : sharedRecords
        recordsBySource = chosen
        if let encoded = try? JSONEncoder().encode(chosen) {
            backend.set(encoded, forKey: userDefaultsKey)
        }
        backend.set(Data([1]), forKey: migrationKey)
    }

    private func decodeRecords(from data: Data?) -> [String: SourceHealthRecord] {
        guard let data,
              let decoded = try? JSONDecoder().decode([String: SourceHealthRecord].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private func persistAndNotify() {
        if let data = try? JSONEncoder().encode(recordsBySource) {
            backend.set(data, forKey: userDefaultsKey)
        }
        #if canImport(AppKit) || canImport(UIKit)
        NotificationCenter.default.post(name: .aiSourceHealthChanged, object: nil)
        #endif
    }

    private func writeMigrationBackup(named suffix: String, records: [String: SourceHealthRecord]) {
        guard !records.isEmpty else { return }
        #if os(macOS)
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        let backupDir = appSupport
            .appendingPathComponent("Rashun", isDirectory: true)
            .appendingPathComponent("Backups", isDirectory: true)
        try? fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let fileURL = backupDir.appendingPathComponent("health-\(suffix)-\(stamp).json")
        if let data = try? JSONEncoder().encode(records) {
            try? data.write(to: fileURL, options: .atomic)
        }
        #endif
    }
}
