import AppKit
import Foundation
import UniformTypeIdentifiers

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
    @Published private(set) var stats: HistoryStorageStats = NotificationHistoryStore.shared.stats()

    @Published var showDeleteConfirmation = false
    @Published private(set) var pendingDeleteMessage = ""
    @Published var showImportConfirmation = false
    @Published private(set) var pendingImportMessage = ""

    @Published private(set) var transferStatusText = ""
    @Published private(set) var transferStatusIsError = false
    @Published private(set) var deleteStatusText = ""
    @Published private(set) var deleteStatusIsError = false

    private var configuredSourceNames: Set<String> = []
    private var pendingImportURL: URL?
    private var pendingImportHistory: [String: [UsageSnapshot]]?

    func configure(sourceNames: [String]) {
        configuredSourceNames = Set(sourceNames)
        let known = configuredSourceNames.union(NotificationHistoryStore.shared.sourceNamesWithHistory())
        updateAvailableSources(knownSourceNames: known)
        stats = NotificationHistoryStore.shared.stats()
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
            let data = try UsageHistoryTransferService.makeExportData(historyBySource: NotificationHistoryStore.shared.allHistory())
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

            let currentStats = NotificationHistoryStore.shared.stats()
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

        NotificationHistoryStore.shared.replaceAllHistory(imported)
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
        let sourceName = deleteScope == .singleSource ? selectedSourceName : nil
        let removed: Int

        switch deleteMode {
        case .deleteAll:
            if let sourceName {
                removed = NotificationHistoryStore.shared.countSnapshots(sourceName: sourceName)
                NotificationHistoryStore.shared.clearHistory(for: sourceName)
            } else {
                removed = NotificationHistoryStore.shared.countSnapshots()
                NotificationHistoryStore.shared.clearAllHistory()
            }
        case .olderThanDate, .keepLastDays:
            guard let cutoff = cutoffDate() else {
                setDeleteStatus("Could not calculate cutoff date.", isError: true)
                return
            }
            removed = NotificationHistoryStore.shared.deleteSnapshotsOlderThan(cutoff, sourceName: sourceName)
        }

        refreshStats()
        notifyDataChanged()
        setDeleteStatus("Deleted \(removed.formatted()) snapshots from \(selectedSourceDisplayName).")
    }

    private func pendingDeleteCount() -> Int? {
        let sourceName = deleteScope == .singleSource ? selectedSourceName : nil
        switch deleteMode {
        case .deleteAll:
            return NotificationHistoryStore.shared.countSnapshots(sourceName: sourceName)
        case .olderThanDate, .keepLastDays:
            guard let cutoff = cutoffDate() else { return nil }
            return NotificationHistoryStore.shared.countSnapshotsOlderThan(cutoff, sourceName: sourceName)
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
        stats = NotificationHistoryStore.shared.stats()
        let known = configuredSourceNames.union(NotificationHistoryStore.shared.sourceNamesWithHistory())
        updateAvailableSources(knownSourceNames: known)
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

    private func updateAvailableSources(knownSourceNames: Set<String>) {
        availableSourceNames = knownSourceNames.sorted()
        if !availableSourceNames.contains(selectedSourceName) {
            selectedSourceName = availableSourceNames.first ?? ""
        }
    }

    private static let displayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
}
