import ArgumentParser
import Foundation
import RashunCore

struct ForecastCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "forecast",
        abstract: "Show forecast/projection for a source"
    )

    @OptionGroup
    var global: GlobalOptions

    @Argument(help: "Source name (for example: AMP, Codex, Copilot, Gemini)")
    var sourceName: String

    @Option(name: .long, help: "Optional metric id when targeting a multi-metric source")
    var metric: String?

    @MainActor
    func run() async throws {
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
        var forecasts: [MetricForecast] = []

        for selectedMetric in selectedMetrics {
            do {
                let usage = try await source.fetchUsage(for: selectedMetric.id)
                let scoped = scopedSourceName(source: source, metric: selectedMetric)
                UsageHistoryStore.shared.append(sourceName: scoped, usage: usage)

                if source.metrics.count > 1 {
                    SourceHealthStore.shared.recordSuccess(sourceName: source.name, metricId: selectedMetric.id, usage: usage)
                } else {
                    SourceHealthStore.shared.recordSuccess(sourceName: source.name, usage: usage)
                }

                let history = UsageHistoryStore.shared.history(for: scoped)
                let forecast = source.forecast(for: selectedMetric.id, current: usage, history: history)
                forecasts.append(MetricForecast(metric: selectedMetric, forecast: forecast))
            } catch {
                let presentation = source.mapFetchError(for: selectedMetric.id, error)
                if source.metrics.count > 1 {
                    SourceHealthStore.shared.recordFailure(sourceName: source.name, metricId: selectedMetric.id, presentation: presentation)
                } else {
                    SourceHealthStore.shared.recordFailure(sourceName: source.name, presentation: presentation)
                }
                let code = classificationCode(error)
                try emitErrorAndExit(
                    code: code,
                    short: presentation.shortMessage,
                    detail: presentation.detailedMessage,
                    exitCode: code == "source_not_configured" ? 3 : 1
                )
                return
            }
        }

        if global.json {
            try JSONOutput.print(ForecastResponse(
                source: source.name,
                metrics: forecasts.map { forecast in
                    ForecastMetricResponse(
                        id: forecast.metric.id,
                        title: forecast.metric.title,
                        summary: forecast.forecast?.summary,
                        points: forecast.forecast?.points.map { ForecastPointResponse(date: $0.date, value: $0.value) } ?? []
                    )
                }
            ))
            return
        }

        let formatter = OutputFormatter(noColor: global.noColor)
        print("\(formatter.emoji("📈", fallback: "*")) \(formatter.colorize("\(source.name) Forecast", as: .bold))")
        for forecast in forecasts {
            if let result = forecast.forecast {
                if source.metrics.count > 1 {
                    print("\(forecast.metric.title): \(result.summary)")
                } else {
                    print(result.summary)
                }
            } else {
                if source.metrics.count > 1 {
                    print("\(forecast.metric.title): No forecast available. Not enough usage history or no active reset window.")
                } else {
                    print("No forecast available. Not enough usage history or no active reset window.")
                }
            }
        }
    }

    private func scopedSourceName(source: AISource, metric: AISourceMetric) -> String {
        source.metrics.count > 1 ? "\(source.name)::\(metric.id)" : source.name
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

private struct MetricForecast {
    let metric: AISourceMetric
    let forecast: ForecastResult?
}

private struct ForecastResponse: Encodable {
    let source: String
    let metrics: [ForecastMetricResponse]
}

private struct ForecastMetricResponse: Encodable {
    let id: String
    let title: String
    let summary: String?
    let points: [ForecastPointResponse]
}

private struct ForecastPointResponse: Encodable {
    let date: Date
    let value: Double
}

private struct JSONErrorEnvelope: Encodable {
    let error: ErrorStatus
}

private struct ErrorStatus: Encodable {
    let code: String
    let short: String
    let detail: String
}
