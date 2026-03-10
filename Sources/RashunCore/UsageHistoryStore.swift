import Foundation

public struct HistoryStorageStats {
    public let sourceCount: Int
    public let snapshotCount: Int
    public let oldestSnapshot: Date?
    public let newestSnapshot: Date?
    public let estimatedBytes: Int

    public init(
        sourceCount: Int,
        snapshotCount: Int,
        oldestSnapshot: Date?,
        newestSnapshot: Date?,
        estimatedBytes: Int
    ) {
        self.sourceCount = sourceCount
        self.snapshotCount = snapshotCount
        self.oldestSnapshot = oldestSnapshot
        self.newestSnapshot = newestSnapshot
        self.estimatedBytes = estimatedBytes
    }
}

@MainActor
public final class UsageHistoryStore {
    public static let shared = UsageHistoryStore(backend: PersistenceBackendFactory.default())
    public init(
        backend: PersistenceBackend,
        legacyBackends: [PersistenceBackend] = PersistenceBackendFactory.defaultLegacyBackends()
    ) {
        self.backend = backend
        self.legacyBackends = legacyBackends
        load()
    }

    private let maxSnapshots = 10_000
    private let userDefaultsKey = "ai.notificationHistory.v1"
    private let migrationKey = "ai.notificationHistory.migrated.v1"
    private let backend: PersistenceBackend
    private let legacyBackends: [PersistenceBackend]
    private var historyBySource: [String: [UsageSnapshot]] = [:]

    public func history(for sourceName: String) -> [UsageSnapshot] {
        historyBySource[sourceName] ?? []
    }

    public func clearHistory(for sourceName: String) {
        historyBySource.removeValue(forKey: sourceName)
        save()
    }

    public func clearAllHistory() {
        historyBySource.removeAll()
        save()
    }

    public func resetMigrationStateForTesting() {
        backend.set(nil, forKey: migrationKey)
    }

    public func sourceNamesWithHistory() -> [String] {
        historyBySource
            .filter { !$0.value.isEmpty }
            .map(\.key)
            .sorted()
    }

    public func allHistory() -> [String: [UsageSnapshot]] {
        historyBySource
    }

    @discardableResult
    public func replaceAllHistory(_ newHistory: [String: [UsageSnapshot]], force: Bool = false) -> Bool {
        let normalized = Self.normalizedHistory(newHistory)
        let currentCount = Self.snapshotCount(in: historyBySource)
        let incomingCount = Self.snapshotCount(in: normalized)

        if !force, currentCount > 0, incomingCount * 2 < currentCount {
            return false
        }

        historyBySource = normalized
        save()
        return true
    }

    public func countSnapshots(sourceName: String? = nil) -> Int {
        if let sourceName {
            return historyBySource[sourceName]?.count ?? 0
        }
        return historyBySource.values.reduce(0) { $0 + $1.count }
    }

    public func countSnapshotsOlderThan(_ cutoff: Date, sourceName: String? = nil) -> Int {
        countMatching(sourceName: sourceName) { $0.timestamp < cutoff }
    }

    @discardableResult
    public func deleteSnapshotsOlderThan(_ cutoff: Date, sourceName: String? = nil) -> Int {
        deleteMatching(sourceName: sourceName) { $0.timestamp < cutoff }
    }

    public func stats() -> HistoryStorageStats {
        let snapshots = historyBySource.values.flatMap { $0 }
        let oldest = snapshots.min(by: { $0.timestamp < $1.timestamp })?.timestamp
        let newest = snapshots.max(by: { $0.timestamp < $1.timestamp })?.timestamp
        let estimatedBytes = (try? JSONEncoder().encode(historyBySource).count) ?? 0
        return HistoryStorageStats(
            sourceCount: historyBySource.keys.count,
            snapshotCount: snapshots.count,
            oldestSnapshot: oldest,
            newestSnapshot: newest,
            estimatedBytes: estimatedBytes
        )
    }

    public func append(sourceName: String, usage: UsageResult) {
        var history = historyBySource[sourceName] ?? []
        let now = Date()
        if let last = history.last, hasSameUsageState(lhs: last.usage, rhs: usage) {
            if history.count >= 2,
               let secondLast = history.dropLast().last,
               hasSameUsageState(lhs: secondLast.usage, rhs: usage) {
                history[history.count - 1] = UsageSnapshot(timestamp: now, usage: usage)
            } else {
                history.append(UsageSnapshot(timestamp: now, usage: usage))
            }
            if history.count > maxSnapshots {
                history.removeFirst(history.count - maxSnapshots)
            }
            historyBySource[sourceName] = history
            save()
            return
        }
        history.append(UsageSnapshot(timestamp: now, usage: usage))
        if history.count > maxSnapshots {
            history.removeFirst(history.count - maxSnapshots)
        }
        historyBySource[sourceName] = history
        save()
    }

    private func load() {
        let hasMigrated = backend.data(forKey: migrationKey) != nil

        let sharedHistory = decodeHistory(from: backend.data(forKey: userDefaultsKey))
        let sharedCount = Self.snapshotCount(in: sharedHistory)

        if hasMigrated {
            historyBySource = sharedHistory
            return
        }

        var bestLegacyHistory: [String: [UsageSnapshot]] = [:]
        var bestLegacyCount = 0

        for legacy in legacyBackends {
            guard let legacyData = legacy.data(forKey: userDefaultsKey) else {
                continue
            }
            let decoded = decodeHistory(from: legacyData)
            guard !decoded.isEmpty else { continue }

            let count = Self.snapshotCount(in: decoded)
            if count > bestLegacyCount {
                bestLegacyHistory = decoded
                bestLegacyCount = count
            }
        }

        if sharedCount > 0 || bestLegacyCount > 0 {
            writeMigrationBackup(named: "shared", history: sharedHistory)
            writeMigrationBackup(named: "legacy", history: bestLegacyHistory)
        }

        let chosen = bestLegacyCount > sharedCount ? bestLegacyHistory : sharedHistory
        historyBySource = chosen
        if let encoded = try? JSONEncoder().encode(chosen) {
            backend.set(encoded, forKey: userDefaultsKey)
        }
        backend.set(Data([1]), forKey: migrationKey)
    }

    private func decodeHistory(from data: Data?) -> [String: [UsageSnapshot]] {
        guard let data,
              let decoded = try? JSONDecoder().decode([String: [UsageSnapshot]].self, from: data) else {
            return [:]
        }
        return decoded
    }

    private static func snapshotCount(in history: [String: [UsageSnapshot]]) -> Int {
        history.values.reduce(0) { $0 + $1.count }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(historyBySource) {
            backend.set(data, forKey: userDefaultsKey)
        }
    }

    private func writeMigrationBackup(named suffix: String, history: [String: [UsageSnapshot]]) {
        guard !history.isEmpty else { return }
        #if os(macOS)
        let fm = FileManager.default
        let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fm.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
        let backupDir = appSupport
            .appendingPathComponent("Rashun", isDirectory: true)
            .appendingPathComponent("Backups", isDirectory: true)
        try? fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let fileURL = backupDir.appendingPathComponent("history-\(suffix)-\(stamp).json")
        if let data = try? JSONEncoder().encode(history) {
            try? data.write(to: fileURL, options: .atomic)
        }
        #endif
    }

    private func countMatching(sourceName: String?, predicate: (UsageSnapshot) -> Bool) -> Int {
        if let sourceName {
            return historyBySource[sourceName]?.filter(predicate).count ?? 0
        }
        return historyBySource.values.reduce(0) { partial, snapshots in
            partial + snapshots.filter(predicate).count
        }
    }

    @discardableResult
    private func deleteMatching(sourceName: String?, predicate: (UsageSnapshot) -> Bool) -> Int {
        var removed = 0

        if let sourceName {
            let existing = historyBySource[sourceName] ?? []
            let filtered = existing.filter { !predicate($0) }
            removed = existing.count - filtered.count
            if filtered.isEmpty {
                historyBySource.removeValue(forKey: sourceName)
            } else {
                historyBySource[sourceName] = filtered
            }
            save()
            return removed
        }

        for (name, snapshots) in historyBySource {
            let filtered = snapshots.filter { !predicate($0) }
            removed += snapshots.count - filtered.count
            if filtered.isEmpty {
                historyBySource.removeValue(forKey: name)
            } else {
                historyBySource[name] = filtered
            }
        }
        save()
        return removed
    }

    private static func normalizedHistory(_ input: [String: [UsageSnapshot]]) -> [String: [UsageSnapshot]] {
        var normalized: [String: [UsageSnapshot]] = [:]
        for (source, snapshots) in input {
            let sorted = snapshots.sorted(by: { $0.timestamp < $1.timestamp })
            normalized[source] = Array(sorted.suffix(10_000))
        }
        return normalized
    }

    private func hasSameUsageState(lhs: UsageResult, rhs: UsageResult) -> Bool {
        lhs.remaining == rhs.remaining &&
            lhs.limit == rhs.limit &&
            lhs.resetDate == rhs.resetDate &&
            lhs.cycleStartDate == rhs.cycleStartDate
    }
}
