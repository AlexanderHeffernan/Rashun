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

public struct HistorySyncSnapshot: Codable, Sendable, Equatable {
    public let revision: UInt64
    public let baseRevision: UInt64
    public let isComplete: Bool
    public let historyBySource: [String: [UsageSnapshot]]
    public let deletedSources: Set<String>

    public init(
        revision: UInt64, baseRevision: UInt64, isComplete: Bool,
        historyBySource: [String: [UsageSnapshot]], deletedSources: Set<String> = []
    ) {
        self.revision = revision
        self.baseRevision = baseRevision
        self.isComplete = isComplete
        self.historyBySource = historyBySource
        self.deletedSources = deletedSources
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

    private let userDefaultsKey = "ai.notificationHistory.v1"
    private let migrationKey = "ai.notificationHistory.migrated.v1"
    private let ampFreeScopeMigrationKey = "ai.notificationHistory.ampFreeScope.migrated.v1"
    private let syncMetadataKey = "ai.notificationHistory.sync.v1"
    private let backend: PersistenceBackend
    private let legacyBackends: [PersistenceBackend]
    private var historyBySource: [String: [UsageSnapshot]] = [:]
    private var syncRevision: UInt64 = 0
    private var changedSourcesByRevision: [UInt64: Set<String>] = [:]
    private var sourceDeletionRevisions: [String: UInt64] = [:]
    private var storedHistoryChecksum: UInt64?
    private let retainedSyncRevisions = 512

    public func history(for sourceName: String) -> [UsageSnapshot] {
        historyBySource[sourceName] ?? []
    }

    public func clearHistory(for sourceName: String) {
        historyBySource.removeValue(forKey: sourceName)
        didChange(sources: [sourceName])
        sourceDeletionRevisions[sourceName] = syncRevision
        saveSyncMetadata()
    }

    public func clearAllHistory() {
        let sources = Set(historyBySource.keys)
        historyBySource.removeAll()
        didChange(sources: sources)
        for source in sources { sourceDeletionRevisions[source] = syncRevision }
        saveSyncMetadata()
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
    public func replaceAllHistory(_ newHistory: [String: [UsageSnapshot]], force: Bool = false)
        -> Bool
    {
        let normalized = Self.canonicalizedAmpFreeHistory(Self.normalizedHistory(newHistory))
        let currentCount = Self.snapshotCount(in: historyBySource)
        let incomingCount = Self.snapshotCount(in: normalized)

        if !force, currentCount > 0, incomingCount * 2 < currentCount {
            return false
        }

        let previousSources = Set(historyBySource.keys)
        historyBySource = normalized
        didChange(sources: previousSources.union(normalized.keys))
        for source in previousSources.subtracting(normalized.keys) {
            sourceDeletionRevisions[source] = syncRevision
        }
        for source in normalized.keys { sourceDeletionRevisions.removeValue(forKey: source) }
        saveSyncMetadata()
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
        sourceDeletionRevisions.removeValue(forKey: sourceName)
        var history = historyBySource[sourceName] ?? []
        let now = Date()
        if let last = history.last, hasSameUsageState(lhs: last.usage, rhs: usage) {
            if history.count >= 2,
                let secondLast = history.dropLast().last,
                hasSameUsageState(lhs: secondLast.usage, rhs: usage)
            {
                history[history.count - 1] = UsageSnapshot(timestamp: now, usage: usage)
            } else {
                history.append(UsageSnapshot(timestamp: now, usage: usage))
            }
            historyBySource[sourceName] = history
            didChange(sources: [sourceName])
            return
        }
        history.append(UsageSnapshot(timestamp: now, usage: usage))
        historyBySource[sourceName] = history
        didChange(sources: [sourceName])
    }

    private func load() {
        let hasMigrated = backend.data(forKey: migrationKey) != nil
        loadSyncMetadata()
        defer { reconcileSyncMetadataWithHistory() }

        let sharedHistory = decodeHistory(from: backend.data(forKey: userDefaultsKey))
        let sharedCount = Self.snapshotCount(in: sharedHistory)

        if hasMigrated {
            historyBySource = sharedHistory
            migrateLegacyAmpFreeScopeIfNeeded()
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
        migrateLegacyAmpFreeScopeIfNeeded()
    }

    private func migrateLegacyAmpFreeScopeIfNeeded() {
        guard backend.data(forKey: ampFreeScopeMigrationKey) == nil else { return }
        defer { backend.set(Data([1]), forKey: ampFreeScopeMigrationKey) }

        guard let legacy = historyBySource["AMP"], !legacy.isEmpty else { return }
        let canonical = Self.compressed((historyBySource["AMP::amp-free"] ?? []) + legacy)
        guard canonical != historyBySource["AMP::amp-free"] else { return }
        historyBySource["AMP::amp-free"] = canonical
        save()
    }

    private func decodeHistory(from data: Data?) -> [String: [UsageSnapshot]] {
        guard let data,
            let decoded = try? JSONDecoder().decode([String: [UsageSnapshot]].self, from: data)
        else {
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

    public func syncSnapshot(since revision: UInt64?) -> HistorySyncSnapshot {
        guard let revision, revision <= syncRevision else {
            return .init(
                revision: syncRevision, baseRevision: 0, isComplete: true,
                historyBySource: historyBySource,
                deletedSources: Set(sourceDeletionRevisions.keys))
        }
        if revision == syncRevision {
            return .init(
                revision: syncRevision, baseRevision: revision, isComplete: false,
                historyBySource: [:])
        }
        let earliest = changedSourcesByRevision.keys.min() ?? syncRevision
        guard revision + 1 >= earliest else {
            return .init(
                revision: syncRevision, baseRevision: 0, isComplete: true,
                historyBySource: historyBySource,
                deletedSources: Set(sourceDeletionRevisions.keys))
        }
        let changed =
            changedSourcesByRevision
            .filter { $0.key > revision }
            .values.reduce(into: Set<String>()) { $0.formUnion($1) }
        return .init(
            revision: syncRevision, baseRevision: revision, isComplete: false,
            historyBySource: Dictionary(
                uniqueKeysWithValues: changed.map {
                    ($0, historyBySource[$0] ?? [])
                }),
            deletedSources: Set(
                sourceDeletionRevisions.compactMap {
                    $0.value > revision ? $0.key : nil
                }))
    }

    public var currentSyncRevision: UInt64 { syncRevision }

    @discardableResult
    public func mergeSyncSnapshot(_ snapshot: HistorySyncSnapshot) -> Bool {
        var changed = Set<String>()
        var deleted = Set<String>()
        for source in snapshot.deletedSources {
            if historyBySource.removeValue(forKey: source) != nil {
                changed.insert(source)
                deleted.insert(source)
            }
        }
        for (source, incoming) in snapshot.historyBySource {
            guard !snapshot.deletedSources.contains(source) else { continue }
            if incoming.isEmpty {
                if historyBySource.removeValue(forKey: source) != nil { changed.insert(source) }
                continue
            }
            let merged = Self.compressed((historyBySource[source] ?? []) + incoming)
            if merged != historyBySource[source] {
                historyBySource[source] = merged
                sourceDeletionRevisions.removeValue(forKey: source)
                changed.insert(source)
            }
        }
        if let legacy = historyBySource["AMP"], !legacy.isEmpty {
            let canonical = Self.compressed((historyBySource["AMP::amp-free"] ?? []) + legacy)
            if canonical != historyBySource["AMP::amp-free"] {
                historyBySource["AMP::amp-free"] = canonical
                sourceDeletionRevisions.removeValue(forKey: "AMP::amp-free")
                changed.insert("AMP::amp-free")
            }
        }
        guard !changed.isEmpty else { return false }
        didChange(sources: changed)
        for source in deleted { sourceDeletionRevisions[source] = syncRevision }
        saveSyncMetadata()
        return true
    }

    nonisolated public static func compressed(_ snapshots: [UsageSnapshot]) -> [UsageSnapshot] {
        let ordered = Array(Set(snapshots)).sorted {
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            return snapshotTieBreaker($0) < snapshotTieBreaker($1)
        }
        var result: [UsageSnapshot] = []
        for snapshot in ordered {
            if result.count >= 2,
                sameUsageState(result[result.count - 1].usage, snapshot.usage),
                sameUsageState(result[result.count - 2].usage, snapshot.usage)
            {
                result[result.count - 1] = snapshot
            } else {
                result.append(snapshot)
            }
        }
        return result
    }

    private func didChange(sources: Set<String>) {
        guard !sources.isEmpty else { return }
        syncRevision &+= 1
        changedSourcesByRevision[syncRevision] = sources
        if changedSourcesByRevision.count > retainedSyncRevisions {
            for key in changedSourcesByRevision.keys.sorted().dropLast(retainedSyncRevisions) {
                changedSourcesByRevision.removeValue(forKey: key)
            }
        }
        save()
        saveSyncMetadata()
    }

    private struct SyncMetadata: Codable {
        let revision: UInt64
        let changes: [UInt64: Set<String>]
        let historyChecksum: UInt64?
        let deletionRevisions: [String: UInt64]?
    }

    private func loadSyncMetadata() {
        guard let data = backend.data(forKey: syncMetadataKey),
            let value = try? JSONDecoder().decode(SyncMetadata.self, from: data)
        else { return }
        syncRevision = value.revision
        changedSourcesByRevision = value.changes
        storedHistoryChecksum = value.historyChecksum
        sourceDeletionRevisions = value.deletionRevisions ?? [:]
    }

    private func saveSyncMetadata() {
        let value = SyncMetadata(
            revision: syncRevision, changes: changedSourcesByRevision,
            historyChecksum: historyChecksum(), deletionRevisions: sourceDeletionRevisions)
        if let data = try? JSONEncoder().encode(value) {
            backend.set(data, forKey: syncMetadataKey)
        }
    }

    private func reconcileSyncMetadataWithHistory() {
        let checksum = historyChecksum()
        guard storedHistoryChecksum != checksum else { return }
        syncRevision &+= 1
        changedSourcesByRevision = [syncRevision: Set(historyBySource.keys)]
        saveSyncMetadata()
    }

    private func historyChecksum() -> UInt64 {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(historyBySource) else { return 0 }
        return data.reduce(14_695_981_039_346_656_037) { hash, byte in
            (hash ^ UInt64(byte)) &* 1_099_511_628_211
        }
    }

    nonisolated private static func snapshotTieBreaker(_ snapshot: UsageSnapshot) -> String {
        let usage = snapshot.usage
        return [
            String(usage.remaining.bitPattern), String(usage.limit.bitPattern),
            usage.resetDate.map { String($0.timeIntervalSince1970.bitPattern) } ?? "-",
            usage.cycleStartDate.map { String($0.timeIntervalSince1970.bitPattern) } ?? "-",
        ].joined(separator: ":")
    }

    nonisolated private static func sameUsageState(_ lhs: UsageResult, _ rhs: UsageResult) -> Bool {
        lhs.remaining == rhs.remaining && lhs.limit == rhs.limit
            && lhs.resetDate == rhs.resetDate && lhs.cycleStartDate == rhs.cycleStartDate
    }

    private func writeMigrationBackup(named suffix: String, history: [String: [UsageSnapshot]]) {
        guard !history.isEmpty else { return }
        #if os(macOS)
            let fm = FileManager.default
            let appSupport =
                fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fm.homeDirectoryForCurrentUser.appendingPathComponent(
                    "Library/Application Support", isDirectory: true)
            let backupDir =
                appSupport
                .appendingPathComponent("Rashun", isDirectory: true)
                .appendingPathComponent("Backups", isDirectory: true)
            try? fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(
                of: ":", with: "-")
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

    private static func normalizedHistory(_ input: [String: [UsageSnapshot]]) -> [String:
        [UsageSnapshot]]
    {
        var normalized: [String: [UsageSnapshot]] = [:]
        for (source, snapshots) in input {
            let sorted = snapshots.sorted(by: { $0.timestamp < $1.timestamp })
            normalized[source] = compressed(sorted)
        }
        return normalized
    }

    private static func canonicalizedAmpFreeHistory(
        _ history: [String: [UsageSnapshot]]
    ) -> [String: [UsageSnapshot]] {
        guard let legacy = history["AMP"], !legacy.isEmpty else { return history }
        var result = history
        result["AMP::amp-free"] = compressed((result["AMP::amp-free"] ?? []) + legacy)
        return result
    }

    private func hasSameUsageState(lhs: UsageResult, rhs: UsageResult) -> Bool {
        Self.sameUsageState(lhs, rhs)
    }
}
