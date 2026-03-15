import Foundation

public struct CopilotSource: AISource {
    public let name = "Copilot"
    public let requirements = "OS support: macOS/Linux/Windows. Requires GitHub CLI 'gh' configured, authenticated, and available on PATH (used to fetch auth token)."
    public let metrics = [AISourceMetric(id: "copilot-premium-interactions", title: "Copilot")]
    public let menuBarBrandColorHex: UInt32 = 0xFFFFFF
    public var agentConfigDirectory: String? { "~/.copilot" }
    public var agentInstructionFilePath: String? { "~/.copilot/instructions/rashun.instructions.md" }
    public var agentRequiresManualSetup: Bool { true }

    public init() {}

    public func pacingLookbackStart(for metricId: String) -> ((_ current: UsageResult, _ history: [UsageSnapshot], _ now: Date) -> Date?)? {
        { current, _, _ in
            current.cycleStartDate
        }
    }

    public func fetchUsage(for metricId: String) async throws -> UsageResult {
        guard metrics.contains(where: { $0.id == metricId }) else {
            throw unsupportedMetricError(metricId)
        }
        let json = try fetchCopilotUserPayloadViaGhApi()

                guard let quotaSnapshots = json["quota_snapshots"] as? [String: Any],
              let premium = quotaSnapshots["premium_interactions"] as? [String: Any],
              let remaining = premium["remaining"] as? Int,
              let entitlement = premium["entitlement"] as? Int else {
            throw CopilotFetchError.invalidPayload
        }

        guard let resetDate = monthlyResetDate(),
              let cycleStartDate = monthlyCycleStartDate() else {
            throw CopilotFetchError.cycleDateComputationFailed
        }

        return UsageResult(
            remaining: Double(remaining),
            limit: Double(entitlement),
            resetDate: resetDate,
            cycleStartDate: cycleStartDate
        )
    }

    public func mapFetchError(for metricId: String, _ error: Error) -> SourceFetchErrorPresentation {
        if let copilotError = error as? CopilotFetchError {
            switch copilotError {
            case let .ghNotInstalled(path):
                return SourceFetchErrorPresentation(
                    shortMessage: "GitHub CLI not found",
                    detailedMessage: "GitHub CLI (`gh`) was not found (\(path)). Install `gh`, ensure it is available on PATH, and run `gh auth login`, then try again."
                )
            case let .ghCommandFailed(exitCode, stderr):
                return SourceFetchErrorPresentation(
                    shortMessage: "GitHub CLI command failed",
                    detailedMessage: "Failed to run `gh` command (exit \(exitCode)). GitHub CLI output: \(stderr)"
                )
            case let .ghNoToken(stderr):
                return SourceFetchErrorPresentation(
                    shortMessage: "Copilot auth missing",
                    detailedMessage: "GitHub CLI returned an empty response for Copilot API data. Run `gh auth login` and confirm your session is active. Details: \(stderr)"
                )
            case let .apiStatus(statusCode, bodySnippet):
                let detailSuffix = bodySnippet.isEmpty ? "" : " Response: \(bodySnippet)"
                return SourceFetchErrorPresentation(
                    shortMessage: "Copilot API error (\(statusCode))",
                    detailedMessage: "Copilot API returned HTTP \(statusCode).\(detailSuffix)"
                )
            case .invalidPayload:
                return SourceFetchErrorPresentation(
                    shortMessage: "Unexpected Copilot response",
                    detailedMessage: "Copilot API response was missing expected quota fields. If this persists, the endpoint response format may have changed."
                )
            case .cycleDateComputationFailed:
                return SourceFetchErrorPresentation(
                    shortMessage: "Copilot date parsing failed",
                    detailedMessage: "Rashun could not compute Copilot cycle dates from the current system calendar context."
                )
            }
        }

        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == 2 {
            return SourceFetchErrorPresentation(
                shortMessage: "GitHub CLI not found",
                detailedMessage: "GitHub CLI (`gh`) was not found in PATH. Install `gh`, ensure it is available on your shell PATH, and run `gh auth login`, then try again."
            )
        }

        if let urlError = error as? URLError {
            return SourceFetchErrorPresentation(
                shortMessage: "Network error",
                detailedMessage: "Network request to GitHub failed (\(urlError.code.rawValue)). Check connectivity, VPN/proxy settings, and try again."
            )
        }

        return SourceFetchErrorPresentation(
            shortMessage: "Copilot fetch failed",
            detailedMessage: "Unable to fetch Copilot usage. \(nsError.localizedDescription)"
        )
    }

    public func forecast(for metricId: String, current: UsageResult, history: [UsageSnapshot]) -> ForecastResult? {
        let now = Date()
        guard let resetDate = current.resetDate ?? monthlyResetDate(reference: now) else {
            return nil
        }
        let utc = TimeZone(secondsFromGMT: 0)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc

        let yearMonth = calendar.dateComponents([.year, .month], from: now)
        guard let cycleStart = calendar.date(from: DateComponents(
            timeZone: utc,
            year: yearMonth.year,
            month: yearMonth.month,
            day: 1,
            hour: 0,
            minute: 0,
            second: 0
        )) else { return nil }

        let currentPercent = min(max(current.percentRemaining, 0), 100)
        let usedPercentSoFar = 100 - currentPercent
        let elapsedSinceCycleStart = max(now.timeIntervalSince(cycleStart), 1)
        let burnRatePerSecond = usedPercentSoFar > 0 ? (usedPercentSoFar / elapsedSinceCycleStart) : 0

        let displayFormatter = DateFormatter()
        displayFormatter.dateFormat = "MMM d, h:mm a"

        let preReset = resetDate.addingTimeInterval(-1)
        var points: [ForecastPoint] = [ForecastPoint(date: now, value: currentPercent)]

        let projectedPreReset: Double
        if burnRatePerSecond > 0 {
            let secondsToPreReset = max(0, preReset.timeIntervalSince(now))
            let secondsToZero = currentPercent / burnRatePerSecond
            let projectionHorizon = min(secondsToPreReset, secondsToZero)
            let steps = max(12, min(80, Int(projectionHorizon / 3600)))

            for index in 1...steps {
                let fraction = Double(index) / Double(steps)
                let date = now.addingTimeInterval(projectionHorizon * fraction)
                let value = max(currentPercent - burnRatePerSecond * date.timeIntervalSince(now), 0)
                points.append(ForecastPoint(date: date, value: value))
            }

            if secondsToZero < secondsToPreReset {
                points.append(ForecastPoint(date: preReset, value: 0))
            }

            projectedPreReset = max(currentPercent - burnRatePerSecond * secondsToPreReset, 0)
        } else {
            projectedPreReset = currentPercent
            if preReset > now {
                points.append(ForecastPoint(date: preReset, value: currentPercent))
            }
        }

        points.append(ForecastPoint(date: resetDate, value: projectedPreReset))
        points.append(ForecastPoint(date: resetDate, value: 100))

        let summary: String
        if burnRatePerSecond > 0 {
            let secondsToZero = currentPercent / burnRatePerSecond
            let zeroDate = now.addingTimeInterval(secondsToZero)
            if secondsToZero.isFinite, zeroDate > now, zeroDate < resetDate {
                summary = "Copilot: projected 0% by \(displayFormatter.string(from: zeroDate)); resets \(displayFormatter.string(from: resetDate))"
            } else {
                summary = "Copilot: projected \(String(format: "%.0f", projectedPreReset))% at reset (\(displayFormatter.string(from: resetDate)))"
            }
        } else {
            summary = "Copilot: resets \(displayFormatter.string(from: resetDate))"
        }

        return ForecastResult(points: points, summary: summary)
    }

    private func fetchCopilotUserPayloadViaGhApi() throws -> [String: Any] {
        let process = Process()

        #if os(Windows)
        let cmdPath = ProcessInfo.processInfo.environment["ComSpec"] ?? "C:\\Windows\\System32\\cmd.exe"
        process.executableURL = URL(fileURLWithPath: cmdPath)
        process.arguments = [
            "/c",
            "gh",
            "api",
            "/copilot_internal/user",
            "-H",
            "Accept: application/vnd.github.v3+json"
        ]
        #else
        guard let ghPath = ExecutableLocator.resolve(
            command: "gh",
            additionalCandidates: [
                "/opt/homebrew/bin",
                "/usr/local/bin",
                "~/.local/bin"
            ]
        ) else {
            throw CopilotFetchError.ghNotInstalled(path: "PATH")
        }
        process.executableURL = URL(fileURLWithPath: ghPath)
        process.arguments = [
            "api",
            "/copilot_internal/user",
            "-H",
            "Accept: application/vnd.github.v3+json"
        ]
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        #endif

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileNoSuchFileError {
                throw CopilotFetchError.ghNotInstalled(path: "gh (not found in PATH)")
            }
            throw error
        }
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: stdoutData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if process.terminationStatus != 0 {
            throw CopilotFetchError.ghCommandFailed(exitCode: Int(process.terminationStatus), stderr: stderr.isEmpty ? "No error output" : stderr)
        }

        guard !stdout.isEmpty else {
            throw CopilotFetchError.ghNoToken(stderr: stderr.isEmpty ? "No output from `gh auth token`." : stderr)
        }

        guard let json = try JSONSerialization.jsonObject(with: stdoutData) as? [String: Any] else {
            throw CopilotFetchError.invalidPayload
        }

        return json
    }

    private func monthlyCycleStartDate(reference: Date = Date()) -> Date? {
        let utc = TimeZone(secondsFromGMT: 0)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc

        let yearMonth = calendar.dateComponents([.year, .month], from: reference)
        return calendar.date(from: DateComponents(
            timeZone: utc,
            year: yearMonth.year,
            month: yearMonth.month,
            day: 1,
            hour: 0,
            minute: 0,
            second: 0
        ))
    }

    private func monthlyResetDate(reference: Date = Date()) -> Date? {
        let utc = TimeZone(secondsFromGMT: 0)!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = utc
        guard let cycleStart = monthlyCycleStartDate(reference: reference) else { return nil }
        return calendar.date(byAdding: .month, value: 1, to: cycleStart)
    }
}

public enum CopilotFetchError: Error {
    case ghNotInstalled(path: String)
    case ghCommandFailed(exitCode: Int, stderr: String)
    case ghNoToken(stderr: String)
    case apiStatus(statusCode: Int, bodySnippet: String)
    case invalidPayload
    case cycleDateComputationFailed
}
