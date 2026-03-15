import Foundation

public struct CodexSource: AISource {
    public let name = "Codex"
    public let requirements = "OS support: macOS only. Requires Codex app installed and local session logs at ~/.codex/sessions."
    public let metrics = [AISourceMetric(id: "codex", title: "Codex")]
    public let menuBarBrandColorHex: UInt32 = 0x3C35FF
    public var agentConfigDirectory: String? { "~/.codex" }
    public var agentInstructionFilePath: String? { "~/.codex/AGENTS.md" }

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
        let sessionsURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/sessions")
        let sessionsPath = sessionsURL.path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sessionsPath, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CodexFetchError.sessionsDirectoryMissing(path: sessionsPath)
        }
        guard FileManager.default.isReadableFile(atPath: sessionsPath) else {
            throw CodexFetchError.sessionsDirectoryUnreadable(path: sessionsPath)
        }

        guard let files = newestSessionFiles(in: sessionsURL, limit: 20) else {
            throw CodexFetchError.sessionsEnumerationFailed(path: sessionsPath)
        }
        guard !files.isEmpty else {
            throw CodexFetchError.noSessionFiles(path: sessionsPath)
        }

        var latestSample: TokenCountSample?
        for fileURL in files {
            guard let text = try? String(contentsOf: fileURL, encoding: .utf8),
                  let sample = parseLatestTokenCount(from: text) else {
                continue
            }

            if let existing = latestSample {
                if sample.timestamp > existing.timestamp {
                    latestSample = sample
                }
            } else {
                latestSample = sample
            }
        }

        guard let sample = latestSample else {
            throw CodexFetchError.noTokenCountEvents
        }

        let remaining = max(0, min(100, 100 - sample.usedPercent))
        let resetDate = sample.resetsAtEpoch.map { Date(timeIntervalSince1970: $0) }
        let cycleStartDate: Date?
        if let resetDate, let windowMinutes = sample.windowMinutes {
            cycleStartDate = resetDate.addingTimeInterval(-(windowMinutes * 60))
        } else {
            cycleStartDate = nil
        }
        return UsageResult(remaining: remaining, limit: 100, resetDate: resetDate, cycleStartDate: cycleStartDate)
    }

    public func mapFetchError(for metricId: String, _ error: Error) -> SourceFetchErrorPresentation {
        if let codexError = error as? CodexFetchError {
            switch codexError {
            case let .sessionsDirectoryMissing(path):
                return SourceFetchErrorPresentation(
                    shortMessage: "Codex sessions folder missing",
                    detailedMessage: "Expected Codex sessions folder was not found at \(path). Open Codex and run at least one request, then retry."
                )
            case let .sessionsDirectoryUnreadable(path):
                return SourceFetchErrorPresentation(
                    shortMessage: "Codex sessions unreadable",
                    detailedMessage: "Rashun cannot read Codex session files at \(path). Check file permissions and try again."
                )
            case let .sessionsEnumerationFailed(path):
                return SourceFetchErrorPresentation(
                    shortMessage: "Could not read Codex sessions",
                    detailedMessage: "Rashun failed to enumerate files in \(path). Check permissions and that the folder is accessible."
                )
            case let .noSessionFiles(path):
                return SourceFetchErrorPresentation(
                    shortMessage: "No Codex sessions found",
                    detailedMessage: "No recent `.jsonl` session files were found in \(path). Open Codex and run at least one request, then retry."
                )
            case .noTokenCountEvents:
                return SourceFetchErrorPresentation(
                    shortMessage: "No Codex usage data yet",
                    detailedMessage: "Recent Codex sessions did not include token usage events. Run a Codex request that emits `token_count` data, then try again."
                )
            }
        }

        let nsError = error as NSError
        return SourceFetchErrorPresentation(
            shortMessage: "Codex fetch failed",
            detailedMessage: "Unable to fetch Codex usage. \(nsError.localizedDescription)"
        )
    }

    public func forecast(for metricId: String, current: UsageResult, history: [UsageSnapshot]) -> ForecastResult? {
        guard let resetDate = current.resetDate, resetDate > Date() else { return nil }
        return resetWindowForecast(
            sourceLabel: name,
            current: current,
            history: history,
            resetDate: resetDate,
            historyWindowHours: 72
        )
    }

    public func newestSessionFiles(in root: URL, limit: Int) -> [URL]? {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys)) else {
            return nil
        }

        var candidates: [(url: URL, modified: Date)] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "jsonl",
                  let values = try? fileURL.resourceValues(forKeys: keys),
                  values.isRegularFile == true else {
                continue
            }

            candidates.append((fileURL, values.contentModificationDate ?? .distantPast))
        }

        return candidates
            .sorted { $0.modified > $1.modified }
            .prefix(max(1, limit))
            .map(\.url)
    }

    public func parseLatestTokenCount(from sessionContent: String) -> TokenCountSample? {
        for line in sessionContent.split(whereSeparator: \.isNewline).reversed() {
            guard line.contains("\"type\":\"event_msg\""),
                  line.contains("\"type\":\"token_count\""),
                  line.contains("\"used_percent\""),
                  let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = object["payload"] as? [String: Any],
                  let payloadType = payload["type"] as? String,
                  payloadType == "token_count",
                  let rateLimits = rateLimits(from: payload),
                  let primary = rateLimits["primary"] as? [String: Any],
                  let usedPercent = numericValue(primary["used_percent"]) else {
                continue
            }

            if let limitID = rateLimits["limit_id"] as? String,
               !limitID.isEmpty,
               limitID != "codex" {
                continue
            }

            let timestamp = parsedTimestamp(from: object)
            let resetEpoch = numericValue(primary["resets_at"])
            let windowMinutes = numericValue(primary["window_minutes"])
            return TokenCountSample(timestamp: timestamp, usedPercent: usedPercent, resetsAtEpoch: resetEpoch, windowMinutes: windowMinutes)
        }

        return nil
    }

    private func rateLimits(from payload: [String: Any]) -> [String: Any]? {
        if let info = payload["info"] as? [String: Any],
           let rateLimits = info["rate_limits"] as? [String: Any] {
            return rateLimits
        }

        if let rateLimits = payload["rate_limits"] as? [String: Any] {
            return rateLimits
        }

        return nil
    }

    private func parsedTimestamp(from object: [String: Any]) -> Date {
        guard let raw = object["timestamp"] as? String else { return .distantPast }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) {
            return date
        }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: raw) ?? .distantPast
    }

    public func numericValue(_ raw: Any?) -> Double? {
        if let value = raw as? Double { return value }
        if let value = raw as? Int { return Double(value) }
        if let number = raw as? NSNumber { return number.doubleValue }
        return nil
    }

    private func resetWindowForecast(
        sourceLabel: String,
        current: UsageResult,
        history: [UsageSnapshot],
        resetDate: Date,
        historyWindowHours: Double
    ) -> ForecastResult? {
        let now = Date()
        guard resetDate > now else { return nil }

        let currentPercent = min(max(current.percentRemaining, 0), 100)
        var points: [ForecastPoint] = [ForecastPoint(date: now, value: currentPercent)]
        let filteredHistory = historyForCurrentCycle(history, current: current)
        let burnRate = burnRatePerSecond(from: filteredHistory, now: now, currentPercent: currentPercent, lookbackHours: historyWindowHours)
        let preReset = resetDate.addingTimeInterval(-1)

        let projectedPreReset: Double
        if burnRate > 0 {
            let secondsToZero = currentPercent / burnRate
            let secondsToPreReset = max(0, preReset.timeIntervalSince(now))
            let horizon = min(secondsToZero, secondsToPreReset)
            let steps = max(12, min(80, Int(horizon / 1800)))

            if steps > 0, horizon > 0 {
                for index in 1...steps {
                    let fraction = Double(index) / Double(steps)
                    let date = now.addingTimeInterval(horizon * fraction)
                    let value = max(currentPercent - burnRate * date.timeIntervalSince(now), 0)
                    points.append(ForecastPoint(date: date, value: value))
                }
            }

            projectedPreReset = max(currentPercent - burnRate * secondsToPreReset, 0)
        } else {
            projectedPreReset = currentPercent
            if preReset > now {
                points.append(ForecastPoint(date: preReset, value: currentPercent))
            }
        }

        points.append(ForecastPoint(date: resetDate, value: projectedPreReset))
        points.append(ForecastPoint(date: resetDate, value: 100))

        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d, h:mm a"

        let summary: String
        if burnRate > 0 {
            let secondsToZero = currentPercent / burnRate
            let zeroDate = now.addingTimeInterval(secondsToZero)
            if secondsToZero.isFinite, zeroDate > now, zeroDate < resetDate {
                summary = "\(sourceLabel): projected 0% by \(formatter.string(from: zeroDate)); resets \(formatter.string(from: resetDate))"
            } else {
                summary = "\(sourceLabel): projected \(String(format: "%.0f", projectedPreReset))% at reset (\(formatter.string(from: resetDate)))"
            }
        } else {
            summary = "\(sourceLabel): resets \(formatter.string(from: resetDate))"
        }

        return ForecastResult(points: points, summary: summary)
    }

    private func historyForCurrentCycle(_ history: [UsageSnapshot], current: UsageResult) -> [UsageSnapshot] {
        let epsilon: TimeInterval = 1
        return history.filter { snapshot in
            if let currentReset = current.resetDate {
                guard let snapshotReset = snapshot.usage.resetDate else { return false }
                return abs(snapshotReset.timeIntervalSince(currentReset)) <= epsilon
            }
            if let cycleStart = current.cycleStartDate {
                return snapshot.timestamp >= cycleStart
            }
            return true
        }
    }

    private func burnRatePerSecond(
        from history: [UsageSnapshot],
        now: Date,
        currentPercent: Double,
        lookbackHours: Double
    ) -> Double {
        let lookbackStart = now.addingTimeInterval(-(lookbackHours * 3600))
        let recent = history.filter { $0.timestamp >= lookbackStart && $0.timestamp <= now }

        var xs: [Double] = recent.map { $0.timestamp.timeIntervalSinceReferenceDate }
        var ys: [Double] = recent.map { min(max($0.usage.percentRemaining, 0), 100) }

        if xs.isEmpty || xs.last != now.timeIntervalSinceReferenceDate {
            xs.append(now.timeIntervalSinceReferenceDate)
            ys.append(currentPercent)
        }

        guard let slope = LinearRegression.slope(xs: xs, ys: ys) else { return 0 }
        return max(0, -slope)
    }
}

public enum CodexFetchError: Error {
    case sessionsDirectoryMissing(path: String)
    case sessionsDirectoryUnreadable(path: String)
    case sessionsEnumerationFailed(path: String)
    case noSessionFiles(path: String)
    case noTokenCountEvents
}

public struct TokenCountSample {
    public let timestamp: Date
    public let usedPercent: Double
    public let resetsAtEpoch: Double?
    public let windowMinutes: Double?

    public init(timestamp: Date, usedPercent: Double, resetsAtEpoch: Double?, windowMinutes: Double?) {
        self.timestamp = timestamp
        self.usedPercent = usedPercent
        self.resetsAtEpoch = resetsAtEpoch
        self.windowMinutes = windowMinutes
    }
}
