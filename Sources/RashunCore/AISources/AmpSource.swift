import Foundation

public struct AmpSource: AISource {
    private actor UsageCache {
        private var inFlight: Task<[String: UsageResult], Error>?
        private var lastValue: (timestamp: Date, usages: [String: UsageResult])?

        func usages(loader: @escaping @Sendable () async throws -> [String: UsageResult])
            async throws -> [String: UsageResult]
        {
            if let cached = lastValue, Date().timeIntervalSince(cached.timestamp) < 2 {
                return cached.usages
            }
            if let inFlight {
                return try await inFlight.value
            }

            let task = Task { try await loader() }
            inFlight = task
            do {
                let usages = try await task.value
                lastValue = (Date(), usages)
                inFlight = nil
                return usages
            } catch {
                inFlight = nil
                throw error
            }
        }
    }

    private static let usageCache = UsageCache()

    /// Keep this stable so existing usage history and source settings continue to work.
    public let name = "AMP"
    public let displayName = "Amp"
    public let requirements =
        "OS support: macOS/Linux/Windows (where AMP CLI is available). Requires the amp CLI installed, signed in, and available on PATH (or at ~/.amp/bin/amp). Agent and orb usage require an Amp subscription."
    public let metrics = [
        AISourceMetric(
            id: "amp-free", title: "Free", defaultEnabled: false, menuBarBadgeText: "Free"),
        AISourceMetric(
            id: "amp-agent-usage", title: "Agent Usage", defaultEnabled: false,
            menuBarBadgeText: "Agent"),
        AISourceMetric(
            id: "amp-orb-usage", title: "Orb Usage", defaultEnabled: false,
            menuBarBadgeText: "Orb"),
    ]
    public let menuBarBrandColorHex: UInt32 = 0xF34E3F
    public var pacingBehavior: SourcePacingBehavior { .resetWindow }
    public var requiresUsageSampleStability: Bool { false }
    public var agentConfigDirectory: String? { "~/.config/amp" }
    public var agentInstructionFilePath: String? { "~/.config/amp/AGENTS.md" }
    public var agentName: String { "Amp" }

    public init() {}

    public func fetchUsage(for metricId: String) async throws -> UsageResult {
        guard metrics.contains(where: { $0.id == metricId }) else {
            throw unsupportedMetricError(metricId)
        }

        let usages = try await Self.usageCache.usages {
            let output = try runCommand()
            let parsed = parseUsageByMetric(from: output)
            guard !parsed.isEmpty else {
                throw AmpFetchError.parseFailed(output: output)
            }
            return parsed
        }
        guard let result = usages[metricId] else {
            throw AmpFetchError.metricUnavailable(metricId: metricId)
        }
        return result
    }

    public func mapFetchError(for metricId: String, _ error: Error) -> SourceFetchErrorPresentation
    {
        if let ampError = error as? AmpFetchError {
            switch ampError {
            case .binaryMissing(let path):
                return SourceFetchErrorPresentation(
                    shortMessage: "AMP CLI not found",
                    detailedMessage:
                        "AMP CLI was not found at \(path). Install AMP CLI or update your setup, then try enabling AMP again."
                )
            case .commandFailed(let exitCode, let output):
                if output.lowercased().contains("login")
                    || output.lowercased().contains("not logged in")
                {
                    return SourceFetchErrorPresentation(
                        shortMessage: "AMP login required",
                        detailedMessage:
                            "AMP CLI reported an authentication issue (exit \(exitCode)). Run AMP CLI and complete login, then try again."
                    )
                }
                return SourceFetchErrorPresentation(
                    shortMessage: "AMP command failed",
                    detailedMessage: "AMP CLI exited with code \(exitCode). Output: \(output)"
                )
            case .emptyOutput:
                return SourceFetchErrorPresentation(
                    shortMessage: "AMP returned no output",
                    detailedMessage:
                        "AMP CLI returned no output for the usage command. Run `~/.amp/bin/amp usage` manually to verify your AMP setup."
                )
            case .parseFailed:
                return SourceFetchErrorPresentation(
                    shortMessage: "Could not parse AMP output",
                    detailedMessage:
                        "Rashun could not parse AMP usage output. Run `~/.amp/bin/amp usage` in Terminal and confirm it reports Amp Free or subscription usage."
                )
            case .metricUnavailable(let unavailableMetricId):
                let metricTitle =
                    metrics.first(where: { $0.id == unavailableMetricId })?.title
                    ?? unavailableMetricId
                return SourceFetchErrorPresentation(
                    shortMessage: "\(metricTitle) unavailable",
                    detailedMessage:
                        "AMP CLI did not report \(metricTitle.lowercased()). Agent and orb usage are available with an active Amp subscription."
                )
            }
        }

        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == 2 {
            return SourceFetchErrorPresentation(
                shortMessage: "AMP CLI not found",
                detailedMessage:
                    "AMP CLI was not found at ~/.amp/bin/amp. Install AMP CLI or update your setup, then try enabling AMP again."
            )
        }

        return SourceFetchErrorPresentation(
            shortMessage: "AMP fetch failed",
            detailedMessage: "Unable to fetch AMP usage. \(nsError.localizedDescription)"
        )
    }

    private func runCommand() throws -> String {
        let defaultPath = NSHomeDirectory() + "/.amp/bin/amp"
        let executablePath =
            ExecutableLocator.resolve(
                command: "amp",
                additionalCandidates: [
                    NSHomeDirectory() + "/.amp/bin",
                    "/opt/homebrew/bin",
                    "/usr/local/bin",
                    "~/.local/bin",
                ]
            ) ?? defaultPath
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = ["usage"]
        #if !os(Windows)
            process.currentDirectoryURL = URL(fileURLWithPath: "/")
        #endif

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileNoSuchFileError {
                throw AmpFetchError.binaryMissing(path: executablePath)
            }
            throw error
        }
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard
            let output = String(data: data, encoding: .utf8)?.trimmingCharacters(
                in: .whitespacesAndNewlines)
        else {
            throw AmpFetchError.emptyOutput
        }

        if process.terminationStatus != 0 {
            throw AmpFetchError.commandFailed(
                exitCode: Int(process.terminationStatus), output: output)
        }

        guard !output.isEmpty else {
            throw AmpFetchError.emptyOutput
        }

        return output
    }

    public func pacingLookbackStart(for metricId: String) -> (
        (_ current: UsageResult, _ history: [UsageSnapshot], _ now: Date) -> Date?
    )? {
        if metricId == "amp-free" {
            return { current, _, _ in current.cycleStartDate }
        }
        guard isSubscriptionMetric(metricId) else { return nil }
        return { _, history, now in
            inferredSubscriptionCycle(history: history, now: now)?.start
        }
    }

    public func forecast(for metricId: String, current: UsageResult, history: [UsageSnapshot])
        -> ForecastResult?
    {
        let now = Date()
        let forecastCurrent = resolvedUsage(
            for: metricId, current: current, history: history, now: now)
        guard let resetDate = forecastCurrent.resetDate else { return nil }
        let forecastHistory = historyWithResolvedCycle(history, matching: forecastCurrent)
        let sourceLabel =
            metrics.first(where: { $0.id == metricId }).map {
                "\(displayName) - \($0.title)"
            } ?? displayName
        return UsageForecastEngine.resetWindowForecast(
            sourceLabel: sourceLabel,
            current: forecastCurrent,
            history: forecastHistory,
            resetDate: resetDate,
            historyWindowHours: forecastHistoryWindowHours(for: metricId) ?? 24,
            now: now
        )
    }

    public func forecastHistoryWindowHours(for metricId: String) -> Double? {
        metricId == "amp-free" ? 24 : isSubscriptionMetric(metricId) ? 31 * 24 : nil
    }

    public func pacingAssessment(
        for metricId: String, current: UsageResult, history: [UsageSnapshot], now: Date
    ) -> UsagePacingAssessment? {
        guard metricId == "amp-free" || isSubscriptionMetric(metricId) else { return nil }
        let resolved = resolvedUsage(
            for: metricId, current: current, history: history, now: now)
        guard let resetDate = resolved.resetDate else { return nil }
        let pacingHistory = historyWithResolvedCycle(history, matching: resolved)
        return UsageForecastEngine.resetWindowPacingAssessment(
            current: resolved,
            history: pacingHistory,
            resetDate: resetDate,
            historyWindowHours: forecastHistoryWindowHours(for: metricId) ?? 24,
            now: now
        )
    }

    public func resolvedUsage(
        for metricId: String, current: UsageResult, history: [UsageSnapshot], now: Date
    ) -> UsageResult {
        guard isSubscriptionMetric(metricId) else { return current }
        let currentSnapshot = UsageSnapshot(timestamp: now, usage: current)
        guard
            let cycle = inferredSubscriptionCycle(
                history: history + [currentSnapshot], now: now)
        else { return current }
        return UsageResult(
            remaining: current.remaining,
            limit: current.limit,
            resetDate: cycle.reset,
            cycleStartDate: cycle.start
        )
    }

    /// A renewal is a quota increase of at least 20 percentage points. Small upward
    /// corrections are ignored. The latest observed renewal re-anchors the monthly cycle.
    func inferredSubscriptionCycle(
        history: [UsageSnapshot], now: Date = Date(), calendar: Calendar = .current
    ) -> (start: Date, reset: Date)? {
        let ordered = UsageHistoryStore.compressed(
            history.filter { $0.timestamp <= now })
        var latestRenewal: Date?
        var previous: UsageSnapshot?
        for snapshot in ordered {
            if let previous,
                snapshot.usage.percentRemaining - previous.usage.percentRemaining >= 20
            {
                latestRenewal = snapshot.timestamp
            }
            previous = snapshot
        }

        guard var start = latestRenewal,
            var reset = calendar.date(byAdding: .month, value: 1, to: start)
        else { return nil }

        while reset <= now {
            start = reset
            guard let nextReset = calendar.date(byAdding: .month, value: 1, to: reset) else {
                return nil
            }
            reset = nextReset
        }
        return (start, reset)
    }

    private func isSubscriptionMetric(_ metricId: String) -> Bool {
        metricId == "amp-agent-usage" || metricId == "amp-orb-usage"
    }

    private func historyWithResolvedCycle(
        _ history: [UsageSnapshot], matching current: UsageResult
    ) -> [UsageSnapshot] {
        guard let cycleStart = current.cycleStartDate, let resetDate = current.resetDate else {
            return history
        }
        return history.map { snapshot in
            guard snapshot.timestamp >= cycleStart else { return snapshot }
            return UsageSnapshot(
                timestamp: snapshot.timestamp,
                usage: UsageResult(
                    remaining: snapshot.usage.remaining,
                    limit: snapshot.usage.limit,
                    resetDate: resetDate,
                    cycleStartDate: cycleStart
                )
            )
        }
    }

    /// Backwards-compatible Amp Free parser used by existing callers.
    public func parseUsage(from output: String) -> UsageResult? {
        parseAmpFreeUsage(from: output)
    }

    public func parseUsageByMetric(from output: String) -> [String: UsageResult] {
        var usages: [String: UsageResult] = [:]
        if let freeUsage = parseAmpFreeUsage(from: output) {
            usages["amp-free"] = freeUsage
        }

        // The initial subscription CLI calls agent allowance "other usage". Accept
        // "agent usage" as well so the tracker survives a terminology alignment.
        let subscriptionPattern =
            #"(?im)^\s*Subscription\s+[^:\r\n]+:\s*([\d.]+)%\s+(?:other|agent)\s+usage\s+and\s+([\d.]+)%\s+orb\s+usage\s+remaining\b"#
        if let regex = try? NSRegularExpression(pattern: subscriptionPattern) {
            let range = NSRange(output.startIndex..., in: output)
            if let match = regex.firstMatch(in: output, range: range), match.numberOfRanges == 3,
                let agentRange = Range(match.range(at: 1), in: output),
                let orbRange = Range(match.range(at: 2), in: output),
                let agentRemaining = validPercentage(output[agentRange]),
                let orbRemaining = validPercentage(output[orbRange])
            {
                usages["amp-agent-usage"] = UsageResult(remaining: agentRemaining, limit: 100)
                usages["amp-orb-usage"] = UsageResult(remaining: orbRemaining, limit: 100)
            }
        }

        return usages
    }

    private func parseAmpFreeUsage(from output: String) -> UsageResult? {
        let pattern = #"(?im)^\s*Amp Free:\s*([\d.]+)%\s+remaining\s+today\s*\(resets\s+daily\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }

        let range = NSRange(output.startIndex..., in: output)
        guard let match = regex.firstMatch(in: output, range: range),
            match.numberOfRanges == 2,
            let percentRange = Range(match.range(at: 1), in: output)
        else {
            return nil
        }

        guard let remaining = validPercentage(output[percentRange]),
            let resetDate = dailyResetDate(),
            let cycleStartDate = dailyCycleStartDate()
        else {
            return nil
        }

        return UsageResult(
            remaining: remaining, limit: 100, resetDate: resetDate, cycleStartDate: cycleStartDate)
    }

    private func validPercentage(_ value: Substring) -> Double? {
        guard let percentage = Double(value), percentage >= 0, percentage <= 100 else {
            return nil
        }
        return percentage
    }

    /// Amp reports only "today" and does not expose a reset timestamp.
    /// Amp Free resets daily at midnight GMT (UTC).
    private static let gmtTimeZone = TimeZone(identifier: "GMT") ?? TimeZone(secondsFromGMT: 0)!

    /// Internal for tests — cycle start is the previous midnight GMT reset.
    func dailyCycleStartDate(reference: Date = Date()) -> Date? {
        guard let resetDate = dailyResetDate(reference: reference) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.gmtTimeZone
        return calendar.date(byAdding: .day, value: -1, to: resetDate)
    }

    /// Internal for tests — next Amp Free reset at midnight GMT.
    func dailyResetDate(reference: Date = Date()) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = Self.gmtTimeZone

        var components = calendar.dateComponents([.year, .month, .day], from: reference)
        components.hour = 0
        components.minute = 0
        components.second = 0
        components.timeZone = Self.gmtTimeZone

        guard let todaysMidnight = calendar.date(from: components) else { return nil }

        // At or after today's midnight GMT, the next window opens tomorrow at midnight GMT.
        if reference < todaysMidnight {
            return todaysMidnight
        }
        return calendar.date(byAdding: .day, value: 1, to: todaysMidnight)
    }
}

public enum AmpFetchError: Error {
    case binaryMissing(path: String)
    case commandFailed(exitCode: Int, output: String)
    case emptyOutput
    case parseFailed(output: String)
    case metricUnavailable(metricId: String)
}
