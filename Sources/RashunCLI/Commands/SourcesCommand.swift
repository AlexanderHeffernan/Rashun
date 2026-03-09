import ArgumentParser
import Foundation
import RashunCore

struct SourcesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sources",
        abstract: "List available sources and setup status"
    )

    @OptionGroup
    var global: GlobalOptions

    @MainActor
    func run() async throws {
        let sources = allSources

        if global.json {
            try JSONOutput.print(sources.map(makeJSONEntry(for:)))
            return
        }

        let formatter = OutputFormatter(noColor: global.noColor)
        print("Available sources:")
        print("")
        for source in sources {
            let status = status(for: source)
            let healthy = status.healthy
            let hasHealthRecord = status.hasHealthRecord
            let symbol = healthy
                ? formatter.emoji("✅", fallback: "[ok]")
                : formatter.emoji("❌", fallback: "[x]")

            let displayName = healthy
                ? formatter.colorize(source.name, as: .magenta)
                : formatter.colorize(source.name, as: .yellow)

            let statusText = healthy
                ? "ready"
                : "needs attention"

            let statusColor: OutputFormatter.ANSIColor = healthy ? .cyan : .yellow

            print("  \(symbol) \(displayName)  \(formatter.colorize(statusText, as: statusColor))")
            if !hasHealthRecord {
                print("     Tip: run `rashun check \(source.name)` to verify setup.")
            }
            if let message = status.lastError, !message.isEmpty {
                print("     Last error: \(message)")
            }
            print("")
        }
    }

    @MainActor
    private func makeJSONEntry(for source: AISource) -> SourceEntry {
        let status = status(for: source)
        return SourceEntry(
            name: source.name,
            requirements: source.requirements,
            metrics: source.metrics.map { MetricEntry(id: $0.id, title: $0.title) },
            healthy: status.healthy,
            hasHealthRecord: status.hasHealthRecord,
            lastError: status.lastError
        )
    }

    @MainActor
    private func status(for source: AISource) -> (healthy: Bool, hasHealthRecord: Bool, lastError: String?) {
        if source.metrics.count <= 1 {
            let health = SourceHealthStore.shared.health(for: source.name)
            return (
                healthy: (health?.consecutiveFailures ?? 0) == 0,
                hasHealthRecord: health != nil,
                lastError: health?.shortErrorMessage
            )
        }

        let recordsByMetric: [(AISourceMetric, SourceHealthRecord?)] = source.metrics.map { metric in
            (metric, SourceHealthStore.shared.health(for: source.name, metricId: metric.id))
        }
        let records = recordsByMetric.compactMap(\.1)
        let hasHealthRecord = !records.isEmpty
        let hasFailure = records.contains { $0.consecutiveFailures > 0 }

        let lastError: String?
        if let failed = recordsByMetric.first(where: { pair in
            guard let record = pair.1 else { return false }
            return record.consecutiveFailures > 0 && !(record.shortErrorMessage ?? "").isEmpty
        }), let message = failed.1?.shortErrorMessage {
            lastError = "\(failed.0.title): \(message)"
        } else {
            lastError = nil
        }

        return (
            healthy: !hasFailure,
            hasHealthRecord: hasHealthRecord,
            lastError: lastError
        )
    }
}

private struct SourceEntry: Encodable {
    let name: String
    let requirements: String
    let metrics: [MetricEntry]
    let healthy: Bool
    let hasHealthRecord: Bool
    let lastError: String?
}

private struct MetricEntry: Encodable {
    let id: String
    let title: String
}
