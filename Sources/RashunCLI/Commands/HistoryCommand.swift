import ArgumentParser
import Foundation
import RashunCore

struct HistoryCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "history",
        abstract: "Inspect stored usage history",
        subcommands: [
            HistoryShowCommand.self,
            HistoryStatsCommand.self,
            HistoryClearCommand.self,
            HistoryExportCommand.self,
            HistoryImportCommand.self
        ],
        defaultSubcommand: HistoryShowCommand.self
    )

    func run() async throws {}
}

struct HistoryShowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show",
        abstract: "Show recent usage history snapshots for a source"
    )

    @OptionGroup
    var global: GlobalOptions

    @Argument(help: "Source name (for example: AMP, Codex, Copilot, Gemini)")
    var sourceName: String

    @Option(name: .long, help: "Time range filter: day, week, month, all")
    var range: HistoryRange = .week

    @Option(name: .long, help: "Maximum snapshots to show per metric")
    var limit: Int = 20

    @Option(name: .long, help: "Optional metric id when targeting a multi-metric source")
    var metric: String?

    @MainActor
    func run() async throws {
        guard limit > 0 else {
            try emitErrorAndExit(
                code: "invalid_argument",
                short: "Invalid limit",
                detail: "--limit must be greater than 0.",
                exitCode: 2
            )
            return
        }

        guard let source = SourceResolver.resolve(sourceName) else {
            try emitErrorAndExit(
                code: "unknown_source",
                short: "Unknown source",
                detail: "No source named '\(sourceName)' is available. Run `rashun sources` to see supported sources.",
                exitCode: 2
            )
            return
        }

        if let metric,
           !source.metrics.contains(where: { $0.id == metric }) {
            try emitErrorAndExit(
                code: "unknown_metric",
                short: "Unknown metric",
                detail: "Source '\(source.name)' does not provide metric '\(metric)'. Available metrics: \(source.metrics.map(\.id).joined(separator: ", ")).",
                exitCode: 2
            )
            return
        }

        let selectedMetrics = source.metrics.filter { metric == nil || $0.id == metric }
        let now = Date()
        let bounds = range.timeRange.rangeBounds(now: now)
        let start = bounds.start
        let end = bounds.end

        var metricHistories: [MetricHistory] = []
        for selectedMetric in selectedMetrics {
            let scopedName = scopedSourceName(source: source, metric: selectedMetric)
            let raw = UsageHistoryStore.shared.history(for: scopedName)
            let filtered = raw
                .filter { snapshot in
                    if let start, snapshot.timestamp < start { return false }
                    if let end, snapshot.timestamp > end { return false }
                    return true
                }
                .sorted(by: { $0.timestamp > $1.timestamp })

            metricHistories.append(MetricHistory(metric: selectedMetric, snapshots: Array(filtered.prefix(limit))))
        }

        if global.json {
            try JSONOutput.print(HistoryResponse(
                source: source.name,
                range: range.rawValue,
                limit: limit,
                metrics: metricHistories.map { history in
                    HistoryMetricResponse(
                        id: history.metric.id,
                        title: history.metric.title,
                        snapshotCount: history.snapshots.count,
                        snapshots: history.snapshots.map { snapshot in
                            HistorySnapshotResponse(
                                timestamp: snapshot.timestamp,
                                percentRemaining: snapshot.usage.percentRemaining,
                                remaining: snapshot.usage.remaining,
                                limit: snapshot.usage.limit,
                                resetDate: snapshot.usage.resetDate,
                                cycleStartDate: snapshot.usage.cycleStartDate
                            )
                        }
                    )
                }
            ))
            return
        }

        let formatter = OutputFormatter(noColor: global.noColor)
        print("\(formatter.emoji("📜", fallback: "*")) \(formatter.colorize("\(source.name) Usage History", as: .bold))")
        print("")

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MMM d, h:mm a"

        for history in metricHistories {
            if source.metrics.count > 1 {
                print(formatter.colorize(history.metric.title, as: .magenta))
            }

            if history.snapshots.isEmpty {
                print("  No snapshots found for this range.")
            } else {
                for snapshot in history.snapshots {
                    let stamp = dateFormatter.string(from: snapshot.timestamp)
                    let percent = String(format: "%5.1f%%", snapshot.usage.percentRemaining)
                    let amounts = String(format: "(%.2f/%.2f)", snapshot.usage.remaining, snapshot.usage.limit)
                    print("  \(stamp.padding(toLength: 18, withPad: " ", startingAt: 0)) \(percent) remaining  \(amounts)")
                }
            }

            print("")
        }
    }

    private func scopedSourceName(source: AISource, metric: AISourceMetric) -> String {
        source.metrics.count > 1 ? "\(source.name)::\(metric.id)" : source.name
    }

    private func emitErrorAndExit(code: String, short: String, detail: String, exitCode: Int32) throws {
        if global.json {
            try JSONOutput.print(JSONErrorEnvelope(error: ErrorStatus(code: code, short: short, detail: detail)))
        } else {
            let formatter = OutputFormatter(noColor: global.noColor)
            print("\(formatter.emoji("❌", fallback: "[x]")) \(formatter.colorize(short, as: .yellow))")
            print(detail)
        }
        throw ExitCode(exitCode)
    }
}

private struct MetricHistory {
    let metric: AISourceMetric
    let snapshots: [UsageSnapshot]
}

private struct HistoryResponse: Encodable {
    let source: String
    let range: String
    let limit: Int
    let metrics: [HistoryMetricResponse]
}

private struct HistoryMetricResponse: Encodable {
    let id: String
    let title: String
    let snapshotCount: Int
    let snapshots: [HistorySnapshotResponse]
}

private struct HistorySnapshotResponse: Encodable {
    let timestamp: Date
    let percentRemaining: Double
    let remaining: Double
    let limit: Double
    let resetDate: Date?
    let cycleStartDate: Date?
}

private struct JSONErrorEnvelope: Encodable {
    let error: ErrorStatus
}

private struct ErrorStatus: Encodable {
    let code: String
    let short: String
    let detail: String
}

enum HistoryRange: String, CaseIterable, ExpressibleByArgument {
    case day
    case week
    case month
    case all

    var timeRange: ChartTimeRange {
        switch self {
        case .day:
            return .day
        case .week:
            return .week
        case .month:
            return .month
        case .all:
            return .all
        }
    }
}

struct HistoryStatsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stats",
        abstract: "Show history storage statistics"
    )

    @OptionGroup
    var global: GlobalOptions

    @MainActor
    func run() async throws {
        let stats = UsageHistoryStore.shared.stats()

        if global.json {
            try JSONOutput.print(HistoryStatsResponse(
                sourceCount: stats.sourceCount,
                snapshotCount: stats.snapshotCount,
                oldestSnapshot: stats.oldestSnapshot,
                newestSnapshot: stats.newestSnapshot,
                estimatedBytes: stats.estimatedBytes
            ))
            return
        }

        let formatter = OutputFormatter(noColor: global.noColor)
        print("\(formatter.emoji("📊", fallback: "*")) \(formatter.colorize("History Storage Stats", as: .bold))")
        print("")

        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "MMM d, yyyy h:mm a"

        print("Sources tracked: \(stats.sourceCount)")
        print("Total snapshots: \(stats.snapshotCount)")
        if let oldest = stats.oldestSnapshot {
            print("Oldest snapshot: \(dateFormatter.string(from: oldest))")
        } else {
            print("Oldest snapshot: n/a")
        }
        if let newest = stats.newestSnapshot {
            print("Newest snapshot: \(dateFormatter.string(from: newest))")
        } else {
            print("Newest snapshot: n/a")
        }
        print("Storage size: ~\(ByteCountFormatter.string(fromByteCount: Int64(stats.estimatedBytes), countStyle: .file))")
    }
}

private struct HistoryStatsResponse: Encodable {
    let sourceCount: Int
    let snapshotCount: Int
    let oldestSnapshot: Date?
    let newestSnapshot: Date?
    let estimatedBytes: Int
}

struct HistoryClearCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clear",
        abstract: "Clear stored history snapshots"
    )

    @OptionGroup
    var global: GlobalOptions

    @Argument(help: "Optional source name to clear (omit to clear all sources)")
    var sourceName: String?

    @Option(name: .long, help: "Delete only snapshots older than this many days")
    var olderThan: Int?

    @Flag(name: [.short, .long], help: "Skip confirmation prompt")
    var yes = false

    @MainActor
    func run() async throws {
        if let olderThan, olderThan <= 0 {
            try emitErrorAndExit(
                code: "invalid_argument",
                short: "Invalid --older-than value",
                detail: "--older-than must be greater than 0 days.",
                exitCode: 2
            )
            return
        }

        let source = try resolveSourceIfNeeded()
        let targetKeys = source.map(historyKeys(for:))

        let deletionPlan = planDeletion(source: source, keys: targetKeys)

        if global.json {
            guard yes else {
                try emitErrorAndExit(
                    code: "confirmation_required",
                    short: "Confirmation required",
                    detail: "Pass --yes to confirm history deletion when using --json.",
                    exitCode: 4
                )
                return
            }
        } else if !yes {
            let confirmed = askForConfirmation(plan: deletionPlan)
            guard confirmed else {
                let formatter = OutputFormatter(noColor: global.noColor)
                print("\(formatter.emoji("⚠️", fallback: "!")) Cancelled. No snapshots were deleted.")
                throw ExitCode(4)
            }
        }

        let deleted = performDeletion(plan: deletionPlan)

        if global.json {
            try JSONOutput.print(HistoryClearResponse(
                source: source?.name,
                olderThanDays: olderThan,
                deletedSnapshots: deleted
            ))
            return
        }

        let formatter = OutputFormatter(noColor: global.noColor)
        if let source {
            print("\(formatter.emoji("✅", fallback: "[ok]")) Cleared \(deleted) snapshots for \(source.name).")
        } else {
            print("\(formatter.emoji("✅", fallback: "[ok]")) Cleared \(deleted) snapshots across all sources.")
        }
    }

    @MainActor
    private func resolveSourceIfNeeded() throws -> AISource? {
        guard let sourceName else { return nil }
        guard let source = SourceResolver.resolve(sourceName) else {
            try emitErrorAndExit(
                code: "unknown_source",
                short: "Unknown source",
                detail: "No source named '\(sourceName)' is available. Run `rashun sources` to see supported sources.",
                exitCode: 2
            )
            return nil
        }
        return source
    }

    private func historyKeys(for source: AISource) -> [String] {
        if source.metrics.count <= 1 {
            return [source.name]
        }

        var keys = [source.name]
        keys.append(contentsOf: source.metrics.map { "\(source.name)::\($0.id)" })
        return keys
    }

    @MainActor
    private func planDeletion(source: AISource?, keys: [String]?) -> DeletionPlan {
        if let days = olderThan {
            let cutoff = Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
            let count: Int
            if let keys {
                count = keys.reduce(0) { total, key in
                    total + UsageHistoryStore.shared.countSnapshotsOlderThan(cutoff, sourceName: key)
                }
            } else {
                count = UsageHistoryStore.shared.countSnapshotsOlderThan(cutoff)
            }
            return DeletionPlan(source: source, keys: keys, cutoff: cutoff, targetCount: count)
        }

        let count: Int
        if let keys {
            count = keys.reduce(0) { total, key in
                total + UsageHistoryStore.shared.countSnapshots(sourceName: key)
            }
        } else {
            count = UsageHistoryStore.shared.countSnapshots()
        }
        return DeletionPlan(source: source, keys: keys, cutoff: nil, targetCount: count)
    }

    private func askForConfirmation(plan: DeletionPlan) -> Bool {
        if let source = plan.source {
            if let days = olderThan {
                print("⚠️  This will delete \(plan.targetCount) snapshots older than \(days) days for \(source.name). Continue? [y/N]")
            } else {
                print("⚠️  This will delete all \(plan.targetCount) snapshots for \(source.name). Continue? [y/N]")
            }
        } else {
            if let days = olderThan {
                print("⚠️  This will delete \(plan.targetCount) snapshots older than \(days) days across all sources. Continue? [y/N]")
            } else {
                print("⚠️  This will delete all \(plan.targetCount) snapshots across all sources. Continue? [y/N]")
            }
        }

        guard let input = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return false
        }
        return input == "y" || input == "yes"
    }

    @MainActor
    private func performDeletion(plan: DeletionPlan) -> Int {
        if let cutoff = plan.cutoff {
            if let keys = plan.keys {
                return keys.reduce(0) { total, key in
                    total + UsageHistoryStore.shared.deleteSnapshotsOlderThan(cutoff, sourceName: key)
                }
            }
            return UsageHistoryStore.shared.deleteSnapshotsOlderThan(cutoff)
        }

        if let keys = plan.keys {
            let removed = keys.reduce(0) { total, key in
                total + UsageHistoryStore.shared.countSnapshots(sourceName: key)
            }
            for key in keys {
                UsageHistoryStore.shared.clearHistory(for: key)
            }
            return removed
        }

        let removed = UsageHistoryStore.shared.countSnapshots()
        UsageHistoryStore.shared.clearAllHistory()
        return removed
    }

    private func emitErrorAndExit(code: String, short: String, detail: String, exitCode: Int32) throws {
        if global.json {
            try JSONOutput.print(JSONErrorEnvelope(error: ErrorStatus(code: code, short: short, detail: detail)))
        } else {
            let formatter = OutputFormatter(noColor: global.noColor)
            print("\(formatter.emoji("❌", fallback: "[x]")) \(formatter.colorize(short, as: .yellow))")
            print(detail)
        }
        throw ExitCode(exitCode)
    }
}

private struct DeletionPlan {
    let source: AISource?
    let keys: [String]?
    let cutoff: Date?
    let targetCount: Int
}

private struct HistoryClearResponse: Encodable {
    let source: String?
    let olderThanDays: Int?
    let deletedSnapshots: Int
}

struct HistoryExportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "export",
        abstract: "Export history to a JSON file"
    )

    @OptionGroup
    var global: GlobalOptions

    @Argument(help: "Path to write exported history JSON")
    var path: String

    @MainActor
    func run() async throws {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        do {
            let data = try UsageHistoryTransferService.makeExportData(
                historyBySource: UsageHistoryStore.shared.allHistory(),
                appVersion: Versioning.versionString()
            )
            try data.write(to: url, options: .atomic)

            let stats = UsageHistoryStore.shared.stats()
            if global.json {
                try JSONOutput.print(HistoryExportResponse(
                    path: url.path,
                    snapshotCount: stats.snapshotCount,
                    sourceCount: stats.sourceCount
                ))
                return
            }

            let formatter = OutputFormatter(noColor: global.noColor)
            print("\(formatter.emoji("✅", fallback: "[ok]")) Exported \(stats.snapshotCount) snapshots to \(url.path)")
        } catch {
            try emitErrorAndExit(
                code: "export_failed",
                short: "Export failed",
                detail: error.localizedDescription,
                exitCode: 1
            )
        }
    }

    private func emitErrorAndExit(code: String, short: String, detail: String, exitCode: Int32) throws {
        if global.json {
            try JSONOutput.print(JSONErrorEnvelope(error: ErrorStatus(code: code, short: short, detail: detail)))
        } else {
            let formatter = OutputFormatter(noColor: global.noColor)
            print("\(formatter.emoji("❌", fallback: "[x]")) \(formatter.colorize(short, as: .yellow))")
            print(detail)
        }
        throw ExitCode(exitCode)
    }
}

struct HistoryImportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "import",
        abstract: "Import history from a JSON file"
    )

    @OptionGroup
    var global: GlobalOptions

    @Flag(name: .long, help: "Replace existing history with imported history")
    var replace = false

    @Flag(name: [.short, .long], help: "Skip confirmation prompt")
    var yes = false

    @Argument(help: "Path to history JSON file")
    var path: String

    @MainActor
    func run() async throws {
        let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        let data: Data

        do {
            data = try Data(contentsOf: url)
        } catch {
            try emitErrorAndExit(
                code: "file_not_found",
                short: "Import file not found",
                detail: "Could not read file at \(url.path).",
                exitCode: 2
            )
            return
        }

        let imported: [String: [UsageSnapshot]]
        do {
            imported = try UsageHistoryTransferService.readImportData(from: data)
        } catch {
            try emitErrorAndExit(
                code: "invalid_import",
                short: "Invalid import file",
                detail: error.localizedDescription,
                exitCode: 2
            )
            return
        }

        let mergedOrReplaced: [String: [UsageSnapshot]]
        if replace {
            mergedOrReplaced = imported
        } else {
            mergedOrReplaced = merge(current: UsageHistoryStore.shared.allHistory(), incoming: imported)
        }

        if global.json {
            guard yes else {
                try emitErrorAndExit(
                    code: "confirmation_required",
                    short: "Confirmation required",
                    detail: "Pass --yes to confirm history import when using --json.",
                    exitCode: 4
                )
                return
            }
        } else if !yes {
            let incomingCount = imported.values.reduce(0) { $0 + $1.count }
            let mode = replace ? "replace" : "merge"
            print("⚠️  This will \(mode) your local history with \(incomingCount) imported snapshots. Continue? [y/N]")
            let answer = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
            guard answer == "y" || answer == "yes" else {
                throw ExitCode(4)
            }
        }

        let didReplace = UsageHistoryStore.shared.replaceAllHistory(mergedOrReplaced, force: true)
        if !didReplace {
            try emitErrorAndExit(
                code: "import_blocked",
                short: "Import blocked",
                detail: "Import was blocked by data protection safeguards.",
                exitCode: 1
            )
            return
        }

        let stats = UsageHistoryStore.shared.stats()
        if global.json {
            try JSONOutput.print(HistoryImportResponse(
                path: url.path,
                replace: replace,
                snapshotCount: stats.snapshotCount,
                sourceCount: stats.sourceCount
            ))
            return
        }

        let formatter = OutputFormatter(noColor: global.noColor)
        print("\(formatter.emoji("✅", fallback: "[ok]")) Imported \(stats.snapshotCount) snapshots from \(url.path)")
    }

    private func merge(
        current: [String: [UsageSnapshot]],
        incoming: [String: [UsageSnapshot]]
    ) -> [String: [UsageSnapshot]] {
        var merged = current

        for (source, incomingSnapshots) in incoming {
            let existing = merged[source] ?? []
            var all = existing + incomingSnapshots
            all.sort { $0.timestamp < $1.timestamp }

            var deduped: [UsageSnapshot] = []
            deduped.reserveCapacity(all.count)
            for snapshot in all {
                if let last = deduped.last,
                   last.timestamp == snapshot.timestamp,
                   last.usage.remaining == snapshot.usage.remaining,
                   last.usage.limit == snapshot.usage.limit,
                   last.usage.resetDate == snapshot.usage.resetDate,
                   last.usage.cycleStartDate == snapshot.usage.cycleStartDate {
                    continue
                }
                deduped.append(snapshot)
            }

            merged[source] = Array(deduped.suffix(10_000))
        }

        return merged
    }

    private func emitErrorAndExit(code: String, short: String, detail: String, exitCode: Int32) throws {
        if global.json {
            try JSONOutput.print(JSONErrorEnvelope(error: ErrorStatus(code: code, short: short, detail: detail)))
        } else {
            let formatter = OutputFormatter(noColor: global.noColor)
            print("\(formatter.emoji("❌", fallback: "[x]")) \(formatter.colorize(short, as: .yellow))")
            print(detail)
        }
        throw ExitCode(exitCode)
    }
}

private struct HistoryExportResponse: Encodable {
    let path: String
    let snapshotCount: Int
    let sourceCount: Int
}

private struct HistoryImportResponse: Encodable {
    let path: String
    let replace: Bool
    let snapshotCount: Int
    let sourceCount: Int
}
