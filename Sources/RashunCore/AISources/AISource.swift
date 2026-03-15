import Foundation

/// Provider-level protocol for all AI usage sources.
public protocol AISource: Sendable {
    /// Unique provider name shown in UI (for example, "Gemini").
    var name: String { get }
    /// Human-readable setup notes shown in Preferences.
    var requirements: String { get }
    /// Usage metrics exposed by this source. Single-metric sources return one element.
    var metrics: [AISourceMetric] { get }
    /// Fetch usage for a specific metric.
    func fetchUsage(for metricId: String) async throws -> UsageResult
    /// Optional metric-specific lookback start resolver for pacing checks.
    /// If this returns `nil`, pacing alerts are not exposed for this metric.
    func pacingLookbackStart(for metricId: String) -> ((_ current: UsageResult, _ history: [UsageSnapshot], _ now: Date) -> Date?)?
    /// Metric-specific fetch error mapper.
    func mapFetchError(for metricId: String, _ error: Error) -> SourceFetchErrorPresentation
    /// Metric-specific notification definitions.
    func notificationDefinitions(for metricId: String) -> [NotificationDefinition]
    /// Metric-specific forecast.
    func forecast(for metricId: String, current: UsageResult, history: [UsageSnapshot]) -> ForecastResult?
    /// Source-specific brand color used by source-solid menu bar rings.
    var menuBarBrandColorHex: UInt32 { get }
    /// Directory that indicates the agent is installed (e.g. "~/.config/amp").
    /// Return nil if this source has no associated agent.
    var agentConfigDirectory: String? { get }
    /// Path to the agent's global instruction file where skill text is injected.
    /// Return nil if the agent requires manual setup.
    var agentInstructionFilePath: String? { get }
    /// Display name for the agent in CLI output. Defaults to the source name.
    var agentName: String { get }
    /// If true, the agent requires manual setup (do not write instruction files).
    var agentRequiresManualSetup: Bool { get }
}

extension AISource {
    /// Default fetch behavior throws unsupported-metric.
    /// Source implementations should override and return usage for known metric IDs.
    public func fetchUsage(for metricId: String) async throws -> UsageResult {
        throw unsupportedMetricError(metricId)
    }

    /// Return `nil` to disable pacing for this metric.
    /// Return a closure to enable pacing and provide lookback-start logic.
    public func pacingLookbackStart(for metricId: String) -> ((_ current: UsageResult, _ history: [UsageSnapshot], _ now: Date) -> Date?)? {
        nil
    }

    /// Default metric notification rules shared by all sources.
    /// Multi-metric sources use "Source - Metric" in labels for clarity.
    /// Pacing rules are included only when a pacing resolver exists.
    public func notificationDefinitions(for metricId: String) -> [NotificationDefinition] {
        let sourceLabel: String
        if metrics.count > 1, let metric = metrics.first(where: { $0.id == metricId }) {
            sourceLabel = "\(name) - \(metric.title)"
        } else {
            sourceLabel = name
        }

        let pacingResolver = pacingLookbackStart(for: metricId)
        return NotificationDefinitions.generic(
            sourceName: sourceLabel,
            // Adapt source resolver signature to NotificationContext-based signature.
            pacingLookbackStart: pacingResolver.map { resolver in
                { context, now in
                    resolver(context.current, context.history, now)
                }
            }
        )
    }

    /// Generic error mapping fallback.
    /// Source implementations can override to provide actionable, source-specific messages.
    public func mapFetchError(for metricId: String, _ error: Error) -> SourceFetchErrorPresentation {
        let raw = (error as NSError).localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        let singleLine = raw.replacingOccurrences(of: "\n", with: " ")
        let fallback = singleLine.isEmpty ? "Unknown fetch error." : singleLine
        let short = singleLine.isEmpty ? "Unknown error" : String(singleLine.prefix(60))
        let metricLabel = metrics.first(where: { $0.id == metricId })?.title ?? metricId
        return SourceFetchErrorPresentation(
            shortMessage: short,
            detailedMessage: "Unable to fetch usage for \(name) (\(metricLabel)). \(fallback)"
        )
    }

    /// Forecasting is optional; default is no forecast for this metric.
    public func forecast(for metricId: String, current: UsageResult, history: [UsageSnapshot]) -> ForecastResult? {
        nil
    }

    public var menuBarBrandColorHex: UInt32 { 0x935AFD }

    /// Directory that indicates the agent is installed (e.g. "~/.config/amp").
    /// Return nil if this source has no associated agent.
    public var agentConfigDirectory: String? { nil }

    /// Path to the agent's global instruction file where skill text is injected.
    /// Return nil if the agent requires manual setup.
    public var agentInstructionFilePath: String? { nil }

    /// Display name for the agent in CLI output. Defaults to the source name.
    public var agentName: String { name }

    /// Return true if the agent requires manual setup.
    public var agentRequiresManualSetup: Bool { false }

    /// Shared helper used when a source receives an unsupported metric ID.
    public func unsupportedMetricError(_ metricId: String) -> NSError {
        NSError(
            domain: "AISource.UnsupportedMetric",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "\(name) does not provide usage for metric '\(metricId)'."]
        )
    }
}
