import Foundation

struct CodexSource: AISource {
    let name = "Codex"
    let requirements = "Requires Codex app/CLI installed and local session logs at ~/.codex/sessions."
    let supportsPacingAlert = true
    func pacingLookbackStart(current: UsageResult, history: [UsageSnapshot], now: Date) -> Date? {
        current.cycleStartDate
    }

    func fetchUsage() async throws -> UsageResult {
        let sessionsURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/sessions")
        guard let files = newestSessionFiles(in: sessionsURL, limit: 20), !files.isEmpty else {
            throw NSError(domain: "CodexSource", code: -1, userInfo: [NSLocalizedDescriptionKey: "No Codex session files found"])
        }

        for fileURL in files {
            guard let text = try? String(contentsOf: fileURL, encoding: .utf8),
                  let sample = parseLatestTokenCount(from: text) else {
                continue
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

        throw NSError(domain: "CodexSource", code: -2, userInfo: [NSLocalizedDescriptionKey: "No token_count rate limit data found in recent Codex sessions"])
    }

    func forecast(current: UsageResult, history: [UsageSnapshot]) -> ForecastResult? {
        guard let resetDate = current.resetDate, resetDate > Date() else { return nil }
        return resetWindowForecast(
            sourceLabel: name,
            current: current,
            history: history,
            resetDate: resetDate,
            historyWindowHours: 72
        )
    }

    func newestSessionFiles(in root: URL, limit: Int) -> [URL]? {
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

    func parseLatestTokenCount(from sessionContent: String) -> TokenCountSample? {
        for line in sessionContent.split(whereSeparator: \.isNewline).reversed() {
            guard line.contains("\"type\":\"event_msg\""),
                  line.contains("\"type\":\"token_count\""),
                  line.contains("\"used_percent\""),
                  let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = object["payload"] as? [String: Any],
                  let payloadType = payload["type"] as? String,
                  payloadType == "token_count",
                  let primary = primaryRateLimits(from: payload),
                  let usedPercent = numericValue(primary["used_percent"]) else {
                continue
            }

            let resetEpoch = numericValue(primary["resets_at"])
            let windowMinutes = numericValue(primary["window_minutes"])
            return TokenCountSample(usedPercent: usedPercent, resetsAtEpoch: resetEpoch, windowMinutes: windowMinutes)
        }

        return nil
    }

    private func primaryRateLimits(from payload: [String: Any]) -> [String: Any]? {
        if let info = payload["info"] as? [String: Any],
           let rateLimits = info["rate_limits"] as? [String: Any],
           let primary = rateLimits["primary"] as? [String: Any] {
            return primary
        }

        if let rateLimits = payload["rate_limits"] as? [String: Any],
           let primary = rateLimits["primary"] as? [String: Any] {
            return primary
        }

        return nil
    }

    func numericValue(_ raw: Any?) -> Double? {
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
        let burnRate = burnRatePerSecond(from: history, now: now, currentPercent: currentPercent, lookbackHours: historyWindowHours)
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

struct TokenCountSample {
    let usedPercent: Double
    let resetsAtEpoch: Double?
    let windowMinutes: Double?
}
