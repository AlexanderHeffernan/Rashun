import ArgumentParser
import Foundation
import RashunCore

struct HistoryCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "history",
        abstract: "Inspect stored usage history",
        subcommands: [
            HistoryShowCommand.self,
            HistoryStatsCommand.self
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
