import Foundation

public struct AmpSource: AISource {
    public let name = "AMP"
    public let requirements = "OS support: macOS/Linux/Windows (where AMP CLI is available). Requires the amp CLI installed and available on PATH (or at ~/.amp/bin/amp)."
    public let metrics = [AISourceMetric(id: "amp-free", title: "AMP")]
    public let menuBarBrandColorHex: UInt32 = 0xF34E3F
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
                    detailedMessage: "Rashun could not parse AMP usage output. Run `~/.amp/bin/amp usage` in Terminal and confirm it returns `Amp Free: $x/$y remaining`."
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

    public func forecast(for metricId: String, current: UsageResult, history: [UsageSnapshot]) -> ForecastResult? {
        let regenRatePerHour = 0.42 // Amp Free: +$0.42/hour
        guard current.limit > 0 else { return nil }
        let percentPerHour = (regenRatePerHour / current.limit) * 100
        let currentPercent = current.percentRemaining

        guard currentPercent < 100 else {
            return ForecastResult(points: [], summary: "AMP: fully charged ✓")
        }

        let hoursToFull = (100 - currentPercent) / percentPerHour
        let now = Date()
        let fullDate = now.addingTimeInterval(hoursToFull * 3600)

        let steps = min(100, max(10, Int(hoursToFull * 2)))
        var points: [ForecastPoint] = []
        for i in 0...steps {
            let fraction = Double(i) / Double(steps)
            let date = now.addingTimeInterval(fraction * hoursToFull * 3600)
            let value = min(currentPercent + percentPerHour * fraction * hoursToFull, 100)
            points.append(ForecastPoint(date: date, value: value))
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "EEE, MMM d 'at' h:mm a"
        return ForecastResult(
            points: points,
            summary: "AMP: reaches 100% \(formatter.string(from: fullDate))"
        )
    }

    public func parseUsage(from output: String) -> UsageResult? {
        let pattern = #"Amp Free: \$([\d.]+)/\$([\d.]+) remaining"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }

        let range = NSRange(output.startIndex..., in: output)
        guard let match = regex.firstMatch(in: output, range: range),
              match.numberOfRanges == 3,
              let currentRange = Range(match.range(at: 1), in: output),
              let limitRange = Range(match.range(at: 2), in: output) else {
            return nil
        }

        guard let remaining = Double(output[currentRange]),
              let limit = Double(output[limitRange]) else {
            return nil
        }

        return UsageResult(remaining: remaining, limit: limit)
    }
}

public enum AmpFetchError: Error {
    case binaryMissing(path: String)
    case commandFailed(exitCode: Int, output: String)
    case emptyOutput
    case parseFailed(output: String)
}
