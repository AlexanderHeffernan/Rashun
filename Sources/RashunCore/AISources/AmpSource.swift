import Foundation

public struct AmpSource: AISource {
    /// Keep this stable so existing usage history and source settings continue to work.
    public let name = "AMP"
    public let displayName = "Amp Free"
    public let requirements = "OS support: macOS/Linux/Windows (where AMP CLI is available). Requires the amp CLI installed and available on PATH (or at ~/.amp/bin/amp)."
    public let metrics = [AISourceMetric(id: "amp-free", title: "Amp Free", menuBarBadgeText: "1d")]
    public let menuBarBrandColorHex: UInt32 = 0xF34E3F
    public var pacingBehavior: SourcePacingBehavior { .resetWindow }
    public var agentConfigDirectory: String? { "~/.config/amp" }
    public var agentInstructionFilePath: String? { "~/.config/amp/AGENTS.md" }
    public var agentName: String { "Amp" }

    public init() {}

    public func fetchUsage(for metricId: String) async throws -> UsageResult {
        guard metrics.contains(where: { $0.id == metricId }) else {
            throw unsupportedMetricError(metricId)
        }
        let output = try runCommand()
        guard let result = parseUsage(from: output) else {
            throw AmpFetchError.parseFailed(output: output)
        }
        return result
    }

    public func mapFetchError(for metricId: String, _ error: Error) -> SourceFetchErrorPresentation {
        if let ampError = error as? AmpFetchError {
            switch ampError {
            case let .binaryMissing(path):
                return SourceFetchErrorPresentation(
                    shortMessage: "AMP CLI not found",
                    detailedMessage: "AMP CLI was not found at \(path). Install AMP CLI or update your setup, then try enabling AMP again."
                )
            case let .commandFailed(exitCode, output):
                if output.lowercased().contains("login") || output.lowercased().contains("not logged in") {
                    return SourceFetchErrorPresentation(
                        shortMessage: "AMP login required",
                        detailedMessage: "AMP CLI reported an authentication issue (exit \(exitCode)). Run AMP CLI and complete login, then try again."
                    )
                }
                return SourceFetchErrorPresentation(
                    shortMessage: "AMP command failed",
                    detailedMessage: "AMP CLI exited with code \(exitCode). Output: \(output)"
                )
            case .emptyOutput:
                return SourceFetchErrorPresentation(
                    shortMessage: "AMP returned no output",
                    detailedMessage: "AMP CLI returned no output for the usage command. Run `~/.amp/bin/amp usage` manually to verify your AMP setup."
                )
            case .parseFailed:
                return SourceFetchErrorPresentation(
                    shortMessage: "Could not parse AMP output",
                    detailedMessage: "Rashun could not parse AMP usage output. Run `~/.amp/bin/amp usage` in Terminal and confirm it returns `Amp Free: x% remaining today (resets daily)`."
                )
            }
        }

        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == 2 {
            return SourceFetchErrorPresentation(
                shortMessage: "AMP CLI not found",
                detailedMessage: "AMP CLI was not found at ~/.amp/bin/amp. Install AMP CLI or update your setup, then try enabling AMP again."
            )
        }

        return SourceFetchErrorPresentation(
            shortMessage: "AMP fetch failed",
            detailedMessage: "Unable to fetch AMP usage. \(nsError.localizedDescription)"
        )
    }

    private func runCommand() throws -> String {
        let defaultPath = NSHomeDirectory() + "/.amp/bin/amp"
        let executablePath = ExecutableLocator.resolve(
            command: "amp",
            additionalCandidates: [
                NSHomeDirectory() + "/.amp/bin",
                "/opt/homebrew/bin",
                "/usr/local/bin",
                "~/.local/bin"
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
        guard let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw AmpFetchError.emptyOutput
        }

        if process.terminationStatus != 0 {
            throw AmpFetchError.commandFailed(exitCode: Int(process.terminationStatus), output: output)
        }

        guard !output.isEmpty else {
            throw AmpFetchError.emptyOutput
        }

        return output
    }

    public func pacingLookbackStart(for metricId: String) -> ((_ current: UsageResult, _ history: [UsageSnapshot], _ now: Date) -> Date?)? {
        { current, _, _ in current.cycleStartDate }
    }

    public func forecast(for metricId: String, current: UsageResult, history: [UsageSnapshot]) -> ForecastResult? {
        let now = Date()
        guard let resetDate = current.resetDate ?? dailyResetDate(reference: now) else { return nil }
        return UsageForecastEngine.resetWindowForecast(
            sourceLabel: displayName,
            current: current,
            history: history,
            resetDate: resetDate,
            historyWindowHours: forecastHistoryWindowHours(for: metricId) ?? 24,
            now: now
        )
    }

    public func forecastHistoryWindowHours(for metricId: String) -> Double? {
        24
    }

    public func parseUsage(from output: String) -> UsageResult? {
        let pattern = #"(?im)^\s*Amp Free:\s*([\d.]+)%\s+remaining\s+today\s*\(resets\s+daily\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }

        let range = NSRange(output.startIndex..., in: output)
        guard let match = regex.firstMatch(in: output, range: range),
              match.numberOfRanges == 2,
              let percentRange = Range(match.range(at: 1), in: output) else {
            return nil
        }

        guard let remaining = Double(output[percentRange]), remaining >= 0, remaining <= 100,
              let resetDate = dailyResetDate(),
              let cycleStartDate = dailyCycleStartDate() else {
            return nil
        }

        return UsageResult(remaining: remaining, limit: 100, resetDate: resetDate, cycleStartDate: cycleStartDate)
    }

    /// Amp reports only "today" and does not expose a reset timestamp.
    /// Per Amp Discord, Amp Free resets daily at 5:00 PM Pacific Time
    /// (`America/Los_Angeles`, observing PST/PDT).
    private static let pacificTimeZone = TimeZone(identifier: "America/Los_Angeles")
    private static let dailyResetHourPacific = 17

    /// Internal for tests — cycle start is the previous 5pm Pacific reset.
    func dailyCycleStartDate(reference: Date = Date()) -> Date? {
        // Use calendar day arithmetic (not a fixed 24h) so spring/fall DST
        // transitions keep the window anchored to consecutive 5pm Pacific resets.
        guard let resetDate = dailyResetDate(reference: reference),
              let pacific = Self.pacificTimeZone else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = pacific
        return calendar.date(byAdding: .day, value: -1, to: resetDate)
    }

    /// Internal for tests — next Amp Free reset at 5:00 PM Pacific.
    func dailyResetDate(reference: Date = Date()) -> Date? {
        guard let pacific = Self.pacificTimeZone else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = pacific

        var components = calendar.dateComponents([.year, .month, .day], from: reference)
        components.hour = Self.dailyResetHourPacific
        components.minute = 0
        components.second = 0
        components.timeZone = pacific

        guard let todaysReset = calendar.date(from: components) else { return nil }

        // At or after today's 5pm Pacific, the next window opens tomorrow at 5pm.
        // Calendar day math (not +24h) preserves wall-clock 5pm across DST.
        if reference < todaysReset {
            return todaysReset
        }
        return calendar.date(byAdding: .day, value: 1, to: todaysReset)
    }
}

public enum AmpFetchError: Error {
    case binaryMissing(path: String)
    case commandFailed(exitCode: Int, output: String)
    case emptyOutput
    case parseFailed(output: String)
}
