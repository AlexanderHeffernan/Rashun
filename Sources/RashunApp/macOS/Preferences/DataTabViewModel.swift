import AppKit
import Foundation
import UniformTypeIdentifiers
import RashunCore

@MainActor
final class DataTabViewModel: ObservableObject {
    enum DeleteScope: String, CaseIterable, Hashable {
        case allSources = "All Sources"
        case singleSource = "Single Source"
    }

    enum DeleteMode: String, CaseIterable, Hashable {
        case olderThanDate = "Delete Older Than Date"
        case keepLastDays = "Keep Last N Days"
        case deleteAll = "Delete All"
    }

    @Published var deleteScope: DeleteScope = .allSources
    @Published var selectedSourceName = ""
    @Published var deleteMode: DeleteMode = .keepLastDays
    @Published var olderThanDate: Date = Calendar.current.date(byAdding: .day, value: -30, to: Date()) ?? Date()
    @Published var keepLastDaysText = "90"

    @Published private(set) var availableSourceNames: [String] = []
    @Published private(set) var stats: HistoryStorageStats = UsageHistoryStore.shared.stats()

    @Published var showDeleteConfirmation = false
    @Published private(set) var pendingDeleteMessage = ""
    @Published var showImportConfirmation = false
    @Published private(set) var pendingImportMessage = ""

    @Published private(set) var transferStatusText = ""
    @Published private(set) var transferStatusIsError = false
    @Published private(set) var deleteStatusText = ""
    @Published private(set) var deleteStatusIsError = false

    private var configuredSourceNames: Set<String> = []
    private var targetKeysByDisplayName: [String: Set<String>] = [:]
    private var pendingImportURL: URL?
    private var pendingImportHistory: [String: [UsageSnapshot]]?

    func configure(sources: [AISource]) {
        configuredSourceNames = Set(sources.map(\.name))
        buildDeleteTargets(sources: sources, historyNames: UsageHistoryStore.shared.sourceNamesWithHistory())
        updateAvailableSources()
        stats = UsageHistoryStore.shared.stats()
    }

    var selectedSourceDisplayName: String {
        deleteScope == .singleSource ? selectedSourceName : "all sources"
    }

    var deletePreviewText: String {
        guard let count = pendingDeleteCount() else {
            return "Enter a valid day count greater than 0."
        }
        if count == 0 {
            return "No matching snapshots to remove."
        }
        return "Will remove \(count.formatted()) snapshots from \(selectedSourceDisplayName)."
    }

    var canDelete: Bool {
        guard let count = pendingDeleteCount() else { return false }
        return count > 0
    }

    var statsSubtitle: String {
        let bytes = ByteCountFormatter.string(fromByteCount: Int64(stats.estimatedBytes), countStyle: .file)
        return "\(stats.snapshotCount.formatted()) snapshots across \(stats.sourceCount.formatted()) sources (\(bytes))."
    }

    var statsDateRangeText: String {
        guard let oldest = stats.oldestSnapshot, let newest = stats.newestSnapshot else {
            return "No usage history stored yet."
        }
        return "\(Self.displayFormatter.string(from: oldest)) to \(Self.displayFormatter.string(from: newest))."
    }

    func exportHistory() {
        let panel = NSSavePanel()
        panel.title = "Export Usage History"
        panel.nameFieldStringValue = "rashun-usage-history.json"
        if #available(macOS 12.0, *) {
            panel.allowedContentTypes = [.json]
        } else {
            panel.allowedFileTypes = ["json"]
        }
        panel.canCreateDirectories = true

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            let appVersion = Versioning.versionString(bundle: .main)
            let data = try UsageHistoryTransferService.makeExportData(
                historyBySource: UsageHistoryStore.shared.allHistory(),
                appVersion: appVersion
            )
            try data.write(to: url, options: .atomic)
            setTransferStatus("Exported usage history to \(url.lastPathComponent).")
            refreshStats()
        } catch {
            setTransferStatus("Export failed: \(error.localizedDescription)", isError: true)
        }
    }

    func importHistory() {
        let panel = NSOpenPanel()
        panel.title = "Import Usage History"
        if #available(macOS 12.0, *) {
            panel.allowedContentTypes = [.json]
        } else {
            panel.allowedFileTypes = ["json"]
        }
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let imported = try UsageHistoryTransferService.readImportData(from: data)
            pendingImportURL = url
            pendingImportHistory = imported

            let currentStats = UsageHistoryStore.shared.stats()
            let incomingStats = stats(for: imported)
            pendingImportMessage = """
            This will replace your current usage history with data from \(url.lastPathComponent). This cannot be undone.

            Current:
            \(summaryText(for: currentStats))

            Import:
            \(summaryText(for: incomingStats))
            """
            showImportConfirmation = true
        } catch {
            setTransferStatus("Import failed: \(error.localizedDescription)", isError: true)
        }
    }

    func confirmImport() {
        guard let url = pendingImportURL, let imported = pendingImportHistory else { return }
        pendingImportURL = nil
        pendingImportHistory = nil
        pendingImportMessage = ""

        let didReplace = UsageHistoryStore.shared.replaceAllHistory(imported, force: true)
        guard didReplace else {
            setTransferStatus("Import was blocked to protect existing history. Please try again.", isError: true)
            return
        }
        refreshStats()
        notifyDataChanged()
        setTransferStatus("Imported \(stats.snapshotCount.formatted()) snapshots from \(url.lastPathComponent).")
    }

    func cancelImport() {
        pendingImportURL = nil
        pendingImportHistory = nil
        pendingImportMessage = ""
    }

    func beginDeleteFlow() {
        guard canDelete, let deleteCount = pendingDeleteCount() else {
            setDeleteStatus("Nothing to delete with the selected criteria.", isError: true)
            return
        }
        pendingDeleteMessage = "This will permanently delete \(deleteCount.formatted()) snapshots from \(selectedSourceDisplayName)."
        showDeleteConfirmation = true
    }

    func confirmDelete() {
        let removed: Int

        switch deleteMode {
        case .deleteAll:
            if deleteScope == .singleSource {
                let targetKeys = selectedSourceTargetKeys()
                removed = targetKeys.reduce(0) { partial, key in
                    partial + UsageHistoryStore.shared.countSnapshots(sourceName: key)
                }
                for key in targetKeys {
                    UsageHistoryStore.shared.clearHistory(for: key)
                }
            } else {
                removed = UsageHistoryStore.shared.countSnapshots()
                UsageHistoryStore.shared.clearAllHistory()
            }
        case .olderThanDate, .keepLastDays:
            guard let cutoff = cutoffDate() else {
                setDeleteStatus("Could not calculate cutoff date.", isError: true)
                return
            }
            if deleteScope == .singleSource {
                removed = selectedSourceTargetKeys().reduce(0) { partial, key in
                    partial + UsageHistoryStore.shared.deleteSnapshotsOlderThan(cutoff, sourceName: key)
                }
            } else {
                removed = UsageHistoryStore.shared.deleteSnapshotsOlderThan(cutoff, sourceName: nil)
            }
        }

        refreshStats()
        notifyDataChanged()
        setDeleteStatus("Deleted \(removed.formatted()) snapshots from \(selectedSourceDisplayName).")
    }

    private func pendingDeleteCount() -> Int? {
        switch deleteMode {
        case .deleteAll:
            if deleteScope == .singleSource {
                return selectedSourceTargetKeys().reduce(0) { partial, key in
                    partial + UsageHistoryStore.shared.countSnapshots(sourceName: key)
                }
            }
            return UsageHistoryStore.shared.countSnapshots()
        case .olderThanDate, .keepLastDays:
            guard let cutoff = cutoffDate() else { return nil }
            if deleteScope == .singleSource {
                return selectedSourceTargetKeys().reduce(0) { partial, key in
                    partial + UsageHistoryStore.shared.countSnapshotsOlderThan(cutoff, sourceName: key)
                }
            }
            return UsageHistoryStore.shared.countSnapshotsOlderThan(cutoff, sourceName: nil)
        }
    }

    private func cutoffDate() -> Date? {
        switch deleteMode {
        case .deleteAll:
            return nil
        case .olderThanDate:
            return Calendar.current.startOfDay(for: olderThanDate)
        case .keepLastDays:
            guard let days = Int(keepLastDaysText), days > 0 else { return nil }
            return Calendar.current.date(byAdding: .day, value: -days, to: Date())
        }
    }

    private func refreshStats() {
        stats = UsageHistoryStore.shared.stats()
        updateAvailableSources()
    }

    private func notifyDataChanged() {
        NotificationCenter.default.post(name: .aiDataRefreshed, object: nil)
    }

    private func setTransferStatus(_ text: String, isError: Bool = false) {
        transferStatusText = text
        transferStatusIsError = isError
    }

    private func setDeleteStatus(_ text: String, isError: Bool = false) {
        deleteStatusText = text
        deleteStatusIsError = isError
    }

    private func stats(for historyBySource: [String: [UsageSnapshot]]) -> HistoryStorageStats {
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

    private func summaryText(for stats: HistoryStorageStats) -> String {
        let byteText = ByteCountFormatter.string(fromByteCount: Int64(stats.estimatedBytes), countStyle: .file)
        return "- \(stats.snapshotCount.formatted()) snapshots across \(stats.sourceCount.formatted()) sources (\(byteText))\n- \(dateRangeText(for: stats))"
    }

    private func dateRangeText(for stats: HistoryStorageStats) -> String {
        guard let oldest = stats.oldestSnapshot, let newest = stats.newestSnapshot else {
            return "No snapshots."
        }
        return "\(Self.displayFormatter.string(from: oldest)) to \(Self.displayFormatter.string(from: newest))"
    }

    private func updateAvailableSources() {
        availableSourceNames = targetKeysByDisplayName.keys.sorted()
        if !availableSourceNames.contains(selectedSourceName) {
            selectedSourceName = availableSourceNames.first ?? ""
        }
    }

    private func selectedSourceTargetKeys() -> Set<String> {
        targetKeysByDisplayName[selectedSourceName] ?? [selectedSourceName]
    }

    private func buildDeleteTargets(sources: [AISource], historyNames: [String]) {
        var displayToTargets: [String: Set<String>] = [:]
        var knownTargetNames: Set<String> = []

        for source in sources {
            if source.metrics.count <= 1 {
                displayToTargets[source.name] = [source.name]
                knownTargetNames.insert(source.name)
                continue
            }

            for metric in source.metrics {
                let displayName = "\(source.name) - \(metric.title)"
                let metricScopeName = "\(source.name)::\(metric.id)"
                displayToTargets[displayName] = [displayName, metricScopeName]
                knownTargetNames.insert(displayName)
                knownTargetNames.insert(metricScopeName)
            }
        }

        // Include orphaned history keys so historical data from removed/renamed sources is still deletable.
        for historyName in historyNames where !knownTargetNames.contains(historyName) {
            displayToTargets[historyName] = [historyName]
        }

        targetKeysByDisplayName = displayToTargets
    }

    private static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
