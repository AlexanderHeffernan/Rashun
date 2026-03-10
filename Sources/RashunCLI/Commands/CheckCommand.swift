import ArgumentParser
import Foundation
import RashunCore

struct CheckCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "check",
        abstract: "Run setup and fetch diagnostics for a source"
    )

    @OptionGroup
    var global: GlobalOptions

    @Argument(help: "Source name (for example: AMP, Codex, Copilot, Gemini)")
    var sourceName: String

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

        var checks: [MetricCheckResult] = []
        var failingExitCode: Int32 = 1

        for metric in source.metrics {
            do {
                let usage = try await source.fetchUsage(for: metric.id)
                if source.metrics.count > 1 {
                    SourceHealthStore.shared.recordSuccess(sourceName: source.name, metricId: metric.id, usage: usage)
                } else {
                    SourceHealthStore.shared.recordSuccess(sourceName: source.name, usage: usage)
                }
                checks.append(.success(metric: metric, usage: usage))
            } catch {
                let presentation = source.mapFetchError(for: metric.id, error)
                if source.metrics.count > 1 {
                    SourceHealthStore.shared.recordFailure(sourceName: source.name, metricId: metric.id, presentation: presentation)
                } else {
                    SourceHealthStore.shared.recordFailure(sourceName: source.name, presentation: presentation)
                }
                let errorCode = classificationCode(error)
                if errorCode == "source_not_configured" {
                    failingExitCode = 3
                }
                checks.append(.failure(metric: metric, code: errorCode, presentation: presentation))
            }
        }

        if global.json {
            try JSONOutput.print(CheckResponse(
                source: source.name,
                requirements: source.requirements,
                healthy: checks.allSatisfy { $0.isSuccess },
                checks: checks
            ))
        } else {
            try printHuman(source: source, checks: checks)
        }

        if checks.contains(where: { !$0.isSuccess }) {
            throw ExitCode(failingExitCode)
        }
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

    private func printHuman(source: AISource, checks: [MetricCheckResult]) throws {
        let formatter = OutputFormatter(noColor: global.noColor)
        print("\(formatter.emoji("🔍", fallback: "*")) Checking \(formatter.colorize(source.name, as: .bold))...")
        print("")
        print("Requirements: \(source.requirements)")
        print("")

        if checks.allSatisfy(\.isSuccess) {
            print("\(formatter.emoji("✅", fallback: "[ok]")) \(formatter.colorize("\(source.name) is healthy", as: .cyan))")
        } else {
            print("\(formatter.emoji("❌", fallback: "[x]")) \(formatter.colorize("\(source.name) check failed", as: .yellow))")
        }

        for check in checks {
            switch check {
            case let .success(metric, usage):
                let label = source.metrics.count > 1 ? metric.title : source.name
                let percent = String(format: "%.1f%%", usage.percentRemaining)
                let amounts = String(format: "(%.2f/%.2f)", usage.remaining, usage.limit)
                print("   \(label): \(percent) remaining \(amounts)")
            case let .failure(metric, _, presentation):
                let label = source.metrics.count > 1 ? metric.title : source.name
                print("   \(label): \(presentation.shortMessage)")
                print("   \(presentation.detailedMessage)")
            }
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

private enum MetricCheckResult: Encodable {
    case success(metric: AISourceMetric, usage: UsageResult)
    case failure(metric: AISourceMetric, code: String, presentation: SourceFetchErrorPresentation)

    private enum CodingKeys: String, CodingKey {
        case metricId
        case title
        case ok
        case percentRemaining
        case remaining
        case limit
        case resetDate
        case cycleStartDate
        case error
    }

    private enum ErrorKeys: String, CodingKey {
        case code
        case short
        case detail
    }

    var isSuccess: Bool {
        switch self {
        case .success:
            return true
        case .failure:
            return false
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case let .success(metric, usage):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(metric.id, forKey: .metricId)
            try container.encode(metric.title, forKey: .title)
            try container.encode(true, forKey: .ok)
            try container.encode(usage.percentRemaining, forKey: .percentRemaining)
            try container.encode(usage.remaining, forKey: .remaining)
            try container.encode(usage.limit, forKey: .limit)
            try container.encodeIfPresent(usage.resetDate, forKey: .resetDate)
            try container.encodeIfPresent(usage.cycleStartDate, forKey: .cycleStartDate)
        case let .failure(metric, code, presentation):
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(metric.id, forKey: .metricId)
            try container.encode(metric.title, forKey: .title)
            try container.encode(false, forKey: .ok)

            var errorContainer = container.nestedContainer(keyedBy: ErrorKeys.self, forKey: .error)
            try errorContainer.encode(code, forKey: .code)
            try errorContainer.encode(presentation.shortMessage, forKey: .short)
            try errorContainer.encode(presentation.detailedMessage, forKey: .detail)
        }
    }
}

private struct CheckResponse: Encodable {
    let source: String
    let requirements: String
    let healthy: Bool
    let checks: [MetricCheckResult]
}

private struct JSONErrorEnvelope: Encodable {
    let error: ErrorStatus
}

private struct ErrorStatus: Encodable {
    let code: String
    let short: String
    let detail: String
}
