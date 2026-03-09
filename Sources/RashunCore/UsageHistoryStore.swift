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
    public static let shared = UsageHistoryStore()
    private init() { load() }

    private let maxSnapshots = 10_000
    private let userDefaultsKey = "ai.notificationHistory.v1"
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

    public func sourceNamesWithHistory() -> [String] {
        historyBySource
            .filter { !$0.value.isEmpty }
            .map(\.key)
            .sorted()
    }

    public func allHistory() -> [String: [UsageSnapshot]] {
        historyBySource
    }

    public func replaceAllHistory(_ newHistory: [String: [UsageSnapshot]]) {
        historyBySource = Self.normalizedHistory(newHistory)
        save()
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
        guard let data = UserDefaults.standard.data(forKey: userDefaultsKey),
              let decoded = try? JSONDecoder().decode([String: [UsageSnapshot]].self, from: data) else { return }
        historyBySource = decoded
    }

    private func save() {
        if let data = try? JSONEncoder().encode(historyBySource) {
            UserDefaults.standard.set(data, forKey: userDefaultsKey)
        }
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
