import ArgumentParser
import Foundation
import RashunCore

struct StatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show usage for one source or all sources"
    )

    @OptionGroup
    var global: GlobalOptions

    @Argument(help: "Optional source name (for example: AMP, Codex, Copilot, Gemini)")
    var sourceName: String?

    @Option(name: .long, help: "Optional metric id when targeting a multi-metric source")
    var metric: String?

    @MainActor
    func run() async throws {
        if let sourceName {
            try await runSingleSource(sourceName)
        } else {
            try await runAllSources()
        }
    }

    @MainActor
    private func runSingleSource(_ sourceName: String) async throws {
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

        let outcome = await fetchSource(source)
        switch outcome {
        case let .success(metrics):
            let filteredMetrics: [(AISourceMetric, UsageResult)]
            if let metric {
                filteredMetrics = metrics.filter { $0.0.id == metric }
            } else {
                filteredMetrics = metrics
            }

            if global.json {
                try JSONOutput.print(SingleSourceStatusResponse(
                    source: source.name,
                    metrics: filteredMetrics.map { metric, usage in
                        MetricStatus(
                            id: metric.id,
                            title: metric.title,
                            percentRemaining: usage.percentRemaining,
                            remaining: usage.remaining,
                            limit: usage.limit,
                            resetDate: usage.resetDate,
                            cycleStartDate: usage.cycleStartDate
                        )
                    }
                ))
                return
            }

            let formatter = OutputFormatter(noColor: global.noColor)
            print(formatter.colorize(source.name, as: .bold))
            for (metric, usage) in filteredMetrics {
                let label = source.metrics.count > 1 ? metric.title : source.name
                let bar = formatter.progressBar(percent: usage.percentRemaining)
                let color = colorForPercent(usage.percentRemaining)
                let percent = String(format: "%5.1f%%", usage.percentRemaining)
                var suffix: String = ""
                if let reset = usage.resetDate {
                    suffix = "  (resets \(shortResetText(reset)))"
                }
                print("  \(label.padding(toLength: 14, withPad: " ", startingAt: 0)) \(formatter.colorize(bar, as: color))  \(formatter.colorize(percent, as: color)) remaining\(suffix)")
            }

        case let .failure(code, presentation):
            try emitErrorAndExit(
                code: code,
                short: presentation.shortMessage,
                detail: presentation.detailedMessage,
                exitCode: code == "source_not_configured" ? 3 : 1
            )
        }
    }

    @MainActor
    private func runAllSources() async throws {
        var active: [AllSourcesActive] = []
        var inactive: [AllSourcesInactive] = []

        for source in allSources {
            let outcome = await fetchSource(source)
            switch outcome {
            case let .success(metrics):
                active.append(AllSourcesActive(
                    source: source.name,
                    metrics: metrics.map { metric, usage in
                        MetricStatus(
                            id: metric.id,
                            title: metric.title,
                            percentRemaining: usage.percentRemaining,
                            remaining: usage.remaining,
                            limit: usage.limit,
                            resetDate: usage.resetDate,
                            cycleStartDate: usage.cycleStartDate
                        )
                    }
                ))
            case let .failure(code, presentation):
                inactive.append(AllSourcesInactive(
                    source: source.name,
                    error: ErrorStatus(code: code, short: presentation.shortMessage, detail: presentation.detailedMessage)
                ))
            }
        }

        if global.json {
            try JSONOutput.print(AllSourcesStatusResponse(active: active, inactive: inactive))
            return
        }

        let formatter = OutputFormatter(noColor: global.noColor)
        print("\(formatter.emoji("📊", fallback: "*")) \(formatter.colorize("AI Usage Status", as: .bold))")
        print("")

        for source in active {
            for metric in source.metrics {
                let rowLabel = source.metrics.count > 1 ? "\(source.source) \(metric.title)" : source.source
                let bar = formatter.progressBar(percent: metric.percentRemaining)
                let color = colorForPercent(metric.percentRemaining)
                let percent = String(format: "%5.1f%%", metric.percentRemaining)
                var suffix = ""
                if let reset = metric.resetDate {
                    suffix = "  (resets \(shortResetText(reset)))"
                }
                print("\(rowLabel.padding(toLength: 18, withPad: " ", startingAt: 0)) \(formatter.colorize(bar, as: color))  \(formatter.colorize(percent, as: color)) remaining\(suffix)")
            }
        }

        if !inactive.isEmpty {
            print("")
            print("\(formatter.emoji("⚠️", fallback: "!")) \(formatter.colorize("Inactive sources:", as: .yellow))")
            for failed in inactive {
                print("  \(failed.source) - \(failed.error.short). Run `rashun check \(failed.source)` for details.")
            }
        }
    }

    @MainActor
    private func fetchSource(_ source: AISource) async -> SourceFetchOutcome {
        var successes: [(AISourceMetric, UsageResult)] = []

        for metric in source.metrics {
            do {
                let usage = try await source.fetchUsage(for: metric.id)
                let scopedName = source.metrics.count > 1 ? "\(source.name)::\(metric.id)" : source.name
                UsageHistoryStore.shared.append(sourceName: scopedName, usage: usage)
                if source.metrics.count > 1 {
                    SourceHealthStore.shared.recordSuccess(sourceName: source.name, metricId: metric.id, usage: usage)
                } else {
                    SourceHealthStore.shared.recordSuccess(sourceName: source.name, usage: usage)
                }
                successes.append((metric, usage))
            } catch {
                let presentation = source.mapFetchError(for: metric.id, error)
                if source.metrics.count > 1 {
                    SourceHealthStore.shared.recordFailure(sourceName: source.name, metricId: metric.id, presentation: presentation)
                } else {
                    SourceHealthStore.shared.recordFailure(sourceName: source.name, presentation: presentation)
                }
                return .failure(code: classificationCode(error), presentation: presentation)
            }
        }

        return .success(metrics: successes)
    }

    private func classificationCode(_ error: Error) -> String {
        switch error {
        case AmpFetchError.binaryMissing:
            return "source_not_configured"
        case CopilotFetchError.ghNotInstalled, CopilotFetchError.ghNoToken:
            return "source_not_configured"
        case CodexFetchError.sessionsDirectoryMissing, CodexFetchError.sessionsDirectoryUnreadable, CodexFetchError.noSessionFiles:
            return "source_not_configured"
        case GeminiFetchError.credentialsMissing, GeminiFetchError.accessTokenExpiredNoRefresh, GeminiFetchError.oauthClientUnavailable, GeminiFetchError.projectResolutionFailed:
            return "source_not_configured"
        default:
            return "fetch_failed"
        }
    }

    private func colorForPercent(_ percent: Double) -> OutputFormatter.ANSIColor {
        if percent >= 60 { return .cyan }
        if percent >= 30 { return .magenta }
        return .yellow
    }

    private func shortResetText(_ date: Date) -> String {
        let seconds = Int(date.timeIntervalSinceNow.rounded())
        let future = seconds >= 0
        let absSeconds = abs(seconds)

        let value: Int
        let unit: String
        if absSeconds >= 86_400 {
            value = absSeconds / 86_400
            unit = "d"
        } else if absSeconds >= 3_600 {
            value = absSeconds / 3_600
            unit = "h"
        } else if absSeconds >= 60 {
            value = absSeconds / 60
            unit = "m"
        } else {
            value = absSeconds
            unit = "s"
        }

        if future {
            return "in \(value)\(unit)"
        }
        return "\(value)\(unit) ago"
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

private enum SourceFetchOutcome {
    case success(metrics: [(AISourceMetric, UsageResult)])
    case failure(code: String, presentation: SourceFetchErrorPresentation)
}

private struct MetricStatus: Encodable {
    let id: String
    let title: String
    let percentRemaining: Double
    let remaining: Double
    let limit: Double
    let resetDate: Date?
    let cycleStartDate: Date?
}

private struct SingleSourceStatusResponse: Encodable {
    let source: String
    let metrics: [MetricStatus]
}

private struct AllSourcesStatusResponse: Encodable {
    let active: [AllSourcesActive]
    let inactive: [AllSourcesInactive]
}

private struct AllSourcesActive: Encodable {
    let source: String
    let metrics: [MetricStatus]
}

private struct AllSourcesInactive: Encodable {
    let source: String
    let error: ErrorStatus
}

private struct JSONErrorEnvelope: Encodable {
    let error: ErrorStatus
}

private struct ErrorStatus: Encodable {
    let code: String
    let short: String
    let detail: String
}
