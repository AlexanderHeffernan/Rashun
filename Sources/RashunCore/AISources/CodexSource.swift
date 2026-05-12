import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct CodexSource: AISource {
    private actor UsageCache {
        private var inFlight: Task<[String: UsageResult], Error>?
        private var lastValue: (timestamp: Date, usages: [String: UsageResult])?

        func usages(loader: @escaping @Sendable () async throws -> [String: UsageResult]) async throws -> [String: UsageResult] {
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

    public let name = "Codex"
    public let requirements = "OS support: macOS only. Requires Codex app/CLI login at ~/.codex/auth.json for Pro usage windows. Free weekly usage falls back to local session logs at ~/.codex/sessions."
    public let metrics = [
        AISourceMetric(id: "codex-free-weekly", title: "Free Weekly Usage"),
        AISourceMetric(id: "codex-pro-5h", title: "Pro 5 Hour"),
        AISourceMetric(id: "codex-pro-weekly", title: "Pro Weekly"),
    ]
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
        if metricId == "codex-free-weekly" {
            return try fetchFreeWeeklyUsageFromLogs()
        }

        let usages = try await Self.usageCache.usages {
            try await fetchProUsageByMetric()
        }
        guard let usage = usages[metricId] else {
            throw CodexFetchError.proUsageWindowMissing(metricId: metricId)
        }
        return usage
    }

    private func fetchFreeWeeklyUsageFromLogs() throws -> UsageResult {
        let sample = try latestRateLimitSample { sample in
            sample.planType == "free" && sample.primary?.windowMinutes == 10_080
        }
        guard sample.planType == "free",
              let primary = sample.primary,
              primary.windowMinutes == 10_080,
              let usage = parseUsageWindow(primary) else {
            throw CodexFetchError.noTokenCountEvents
        }
        return usage
    }

    private func latestRateLimitSample(matching predicate: (CodexRateLimitSample) -> Bool = { _ in true }) throws -> CodexRateLimitSample {
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

        var latestSample: CodexRateLimitSample?
        for fileURL in files {
            guard let text = try? String(contentsOf: fileURL, encoding: .utf8),
                  let sample = parseLatestRateLimitSample(from: text, matching: predicate) else {
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
        return sample
    }

    private let usageURL = URL(string: "https://chatgpt.com/backend-api/codex/usage")!
    private let tokenURL = URL(string: "https://auth.openai.com/oauth/token")!
    private let oauthClientID = "app_EMoamEEZ73f0CkXaXp7hrann"

    private func fetchProUsageByMetric() async throws -> [String: UsageResult] {
        do {
            let auth = try readAuth()
            let response = try await fetchUsageResponse(auth: auth)
            return parseProUsageByMetric(from: response)
        } catch {
            let logUsages = try fetchProUsageFromLogs()
            if logUsages.isEmpty {
                throw error
            }
            return logUsages
        }
    }

    private func fetchProUsageFromLogs() throws -> [String: UsageResult] {
        let sample = try latestRateLimitSample { sample in
            sample.primary?.windowMinutes == 300 || sample.secondary?.windowMinutes == 10_080
        }
        var usages: [String: UsageResult] = [:]
        if let primary = sample.primary,
           primary.windowMinutes == 300,
           let usage = parseUsageWindow(primary) {
            usages["codex-pro-5h"] = usage
        }
        if let secondary = sample.secondary,
           secondary.windowMinutes == 10_080,
           let usage = parseUsageWindow(secondary) {
            usages["codex-pro-weekly"] = usage
        }
        return usages
    }

    public func parseProUsageByMetric(from response: CodexUsageResponse) -> [String: UsageResult] {
        var parsed: [String: UsageResult] = [:]
        if let usage = parseUsageWindow(response.rateLimit?.primaryWindow) {
            parsed["codex-pro-5h"] = usage
        }
        if let usage = parseUsageWindow(response.rateLimit?.secondaryWindow) {
            parsed["codex-pro-weekly"] = usage
        }
        return parsed
    }

    private func parseUsageWindow(_ window: CodexRateLimitWindow?) -> UsageResult? {
        guard let usedPercent = window?.usedPercent, usedPercent.isFinite else { return nil }
        let remaining = max(0, min(100, 100 - usedPercent))
        let resetDate = window?.resetAt.map { Date(timeIntervalSince1970: $0) }
        let cycleStartDate: Date?
        if let resetDate, let seconds = window?.limitWindowSeconds {
            cycleStartDate = resetDate.addingTimeInterval(-seconds)
        } else {
            cycleStartDate = nil
        }
        return UsageResult(remaining: remaining, limit: 100, resetDate: resetDate, cycleStartDate: cycleStartDate)
    }

    private func parseUsageWindow(_ window: CodexLogRateLimitWindow?) -> UsageResult? {
        guard let usedPercent = window?.usedPercent, usedPercent.isFinite else { return nil }
        let remaining = max(0, min(100, 100 - usedPercent))
        let resetDate = window?.resetsAt.map { Date(timeIntervalSince1970: $0) }
        let cycleStartDate: Date?
        if let resetDate, let windowMinutes = window?.windowMinutes {
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
            case let .authMissing(path):
                return SourceFetchErrorPresentation(
                    shortMessage: "Codex auth missing",
                    detailedMessage: "Expected Codex auth file was not found at \(path). Open Codex and sign in with ChatGPT, then try again."
                )
            case let .authReadFailed(message):
                return SourceFetchErrorPresentation(
                    shortMessage: "Cannot read Codex auth",
                    detailedMessage: "Failed to read Codex auth. \(message)"
                )
            case .accessTokenMissing:
                return SourceFetchErrorPresentation(
                    shortMessage: "Codex auth incomplete",
                    detailedMessage: "Codex auth.json did not contain an access token. Open Codex and sign in again."
                )
            case .refreshTokenMissing:
                return SourceFetchErrorPresentation(
                    shortMessage: "Codex auth refresh unavailable",
                    detailedMessage: "Codex auth.json did not contain a refresh token. Open Codex and sign in again."
                )
            case let .tokenRefreshFailed(statusCode, bodySnippet):
                let suffix = bodySnippet.isEmpty ? "" : " Response: \(bodySnippet)"
                return SourceFetchErrorPresentation(
                    shortMessage: "Codex token refresh failed",
                    detailedMessage: "Codex OAuth token refresh failed with HTTP \(statusCode).\(suffix)"
                )
            case .tokenRefreshMissingAccessToken:
                return SourceFetchErrorPresentation(
                    shortMessage: "Codex auth issue",
                    detailedMessage: "Codex token refresh succeeded but returned no access token."
                )
            case let .usageAPIStatus(statusCode, bodySnippet):
                let suffix = bodySnippet.isEmpty ? "" : " Response: \(bodySnippet)"
                return SourceFetchErrorPresentation(
                    shortMessage: "Codex API error (\(statusCode))",
                    detailedMessage: "Codex usage API returned HTTP \(statusCode).\(suffix)"
                )
            case .usagePayloadInvalid:
                return SourceFetchErrorPresentation(
                    shortMessage: "Unexpected Codex response",
                    detailedMessage: "Codex usage API response was missing expected rate limit fields. If this persists, the endpoint response format may have changed."
                )
            case let .proUsageWindowMissing(metricId):
                return SourceFetchErrorPresentation(
                    shortMessage: "Codex usage unavailable",
                    detailedMessage: "Codex usage API did not include data for \(metricId)."
                )
            }
        }

        if let urlError = error as? URLError {
            return SourceFetchErrorPresentation(
                shortMessage: "Network error",
                detailedMessage: "Network request to Codex failed (\(urlError.code.rawValue)). Check connectivity, VPN/proxy settings, and try again."
            )
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

    public func parseLatestRateLimitSample(from sessionContent: String) -> CodexRateLimitSample? {
        parseLatestRateLimitSample(from: sessionContent, matching: { _ in true })
    }

    public func parseLatestRateLimitSample(
        from sessionContent: String,
        matching predicate: (CodexRateLimitSample) -> Bool
    ) -> CodexRateLimitSample? {
        for line in sessionContent.split(whereSeparator: \.isNewline).reversed() {
            guard line.contains("\"type\":\"event_msg\""),
                  line.contains("\"type\":\"token_count\""),
                  line.contains("\"used_percent\""),
                  let data = String(line).data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let payload = object["payload"] as? [String: Any],
                  let payloadType = payload["type"] as? String,
                  payloadType == "token_count",
                  let rateLimits = rateLimits(from: object, payload: payload),
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
            let primaryWindow = CodexLogRateLimitWindow(
                usedPercent: usedPercent,
                resetsAt: numericValue(primary["resets_at"]),
                windowMinutes: numericValue(primary["window_minutes"])
            )
            let secondaryWindow: CodexLogRateLimitWindow?
            if let secondary = rateLimits["secondary"] as? [String: Any],
               let secondaryUsedPercent = numericValue(secondary["used_percent"]) {
                secondaryWindow = CodexLogRateLimitWindow(
                    usedPercent: secondaryUsedPercent,
                    resetsAt: numericValue(secondary["resets_at"]),
                    windowMinutes: numericValue(secondary["window_minutes"])
                )
            } else {
                secondaryWindow = nil
            }

            let sample = CodexRateLimitSample(
                timestamp: timestamp,
                primary: primaryWindow,
                secondary: secondaryWindow,
                planType: rateLimits["plan_type"] as? String
            )
            guard predicate(sample) else { continue }
            return sample
        }

        return nil
    }

    private func rateLimits(from object: [String: Any], payload: [String: Any]) -> [String: Any]? {
        if let rateLimits = object["rate_limits"] as? [String: Any] {
            return rateLimits
        }

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

    private func readAuth() throws -> CodexAuth {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/auth.json")
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(CodexAuth.self, from: data)
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileReadNoSuchFileError {
                throw CodexFetchError.authMissing(path: url.path)
            }
            throw CodexFetchError.authReadFailed(message: nsError.localizedDescription)
        }
    }

    private func fetchUsageResponse(auth: CodexAuth) async throws -> CodexUsageResponse {
        guard var accessToken = auth.tokens.accessToken, !accessToken.isEmpty else {
            throw CodexFetchError.accessTokenMissing
        }

        for attempt in 0..<2 {
            var request = URLRequest(url: usageURL)
            request.addValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            if let accountID = auth.tokens.accountID, !accountID.isEmpty {
                request.addValue(accountID, forHTTPHeaderField: "chatgpt-account-id")
            }
            request.addValue("application/json", forHTTPHeaderField: "Accept")
            request.addValue(
                "Mozilla/5.0 (X11; Linux x86_64; rv:128.0) Gecko/20100101 Firefox/128.0",
                forHTTPHeaderField: "User-Agent"
            )

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw CodexFetchError.usageAPIStatus(statusCode: -1, bodySnippet: "Non-HTTP response")
            }
            if http.statusCode == 200 {
                let decoded = try JSONDecoder().decode(CodexUsageResponse.self, from: data)
                if parseProUsageByMetric(from: decoded).isEmpty {
                    throw CodexFetchError.usagePayloadInvalid
                }
                return decoded
            }
            if (http.statusCode == 401 || http.statusCode == 403), attempt == 0 {
                accessToken = try await refreshAccessToken(auth: auth)
                continue
            }
            throw CodexFetchError.usageAPIStatus(statusCode: http.statusCode, bodySnippet: bodySnippet(from: data))
        }

        throw CodexFetchError.usageAPIStatus(statusCode: -1, bodySnippet: "Failed after token refresh")
    }

    private func refreshAccessToken(auth: CodexAuth) async throws -> String {
        guard let refreshToken = auth.tokens.refreshToken, !refreshToken.isEmpty else {
            throw CodexFetchError.refreshTokenMissing
        }

        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "grant_type", value: "refresh_token"),
            URLQueryItem(name: "refresh_token", value: refreshToken),
            URLQueryItem(name: "client_id", value: oauthClientID),
        ]
        let body = components.percentEncodedQuery?.data(using: .utf8) ?? Data()

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.addValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CodexFetchError.tokenRefreshFailed(statusCode: -1, bodySnippet: "Non-HTTP response")
        }
        guard http.statusCode == 200 else {
            throw CodexFetchError.tokenRefreshFailed(statusCode: http.statusCode, bodySnippet: bodySnippet(from: data))
        }

        let refreshResponse = try JSONDecoder().decode(CodexTokenRefreshResponse.self, from: data)
        guard let accessToken = refreshResponse.accessToken, !accessToken.isEmpty else {
            throw CodexFetchError.tokenRefreshMissingAccessToken
        }
        try persistRefreshedAccessToken(accessToken)
        return accessToken
    }

    private func persistRefreshedAccessToken(_ accessToken: String) throws {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".codex/auth.json")
        let data = try Data(contentsOf: url)
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var tokens = root["tokens"] as? [String: Any] else {
            throw CodexFetchError.authReadFailed(message: "Unexpected auth.json structure.")
        }

        tokens["access_token"] = accessToken
        root["tokens"] = tokens
        root["last_refresh"] = ISO8601DateFormatter().string(from: Date())

        let updated = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
        try updated.write(to: url, options: .atomic)
    }

    private func bodySnippet(from data: Data, maxLength: Int = 500) -> String {
        let raw = String(data: data, encoding: .utf8) ?? ""
        let singleLine = raw
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(singleLine.prefix(maxLength))
    }
}

public enum CodexFetchError: Error {
    case sessionsDirectoryMissing(path: String)
    case sessionsDirectoryUnreadable(path: String)
    case sessionsEnumerationFailed(path: String)
    case noSessionFiles(path: String)
    case noTokenCountEvents
    case authMissing(path: String)
    case authReadFailed(message: String)
    case accessTokenMissing
    case refreshTokenMissing
    case tokenRefreshFailed(statusCode: Int, bodySnippet: String)
    case tokenRefreshMissingAccessToken
    case usageAPIStatus(statusCode: Int, bodySnippet: String)
    case usagePayloadInvalid
    case proUsageWindowMissing(metricId: String)
}

public struct CodexRateLimitSample {
    public let timestamp: Date
    public let primary: CodexLogRateLimitWindow?
    public let secondary: CodexLogRateLimitWindow?
    public let planType: String?

    public init(timestamp: Date, primary: CodexLogRateLimitWindow?, secondary: CodexLogRateLimitWindow?, planType: String?) {
        self.timestamp = timestamp
        self.primary = primary
        self.secondary = secondary
        self.planType = planType
    }
}

public struct CodexLogRateLimitWindow {
    public let usedPercent: Double
    public let resetsAt: Double?
    public let windowMinutes: Double?

    public init(usedPercent: Double, resetsAt: Double?, windowMinutes: Double?) {
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
        self.windowMinutes = windowMinutes
    }
}

public struct CodexAuth: Decodable {
    public let tokens: CodexAuthTokens
}

public struct CodexAuthTokens: Decodable {
    public let accessToken: String?
    public let refreshToken: String?
    public let accountID: String?

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case accountID = "account_id"
    }
}

public struct CodexUsageResponse: Decodable {
    public let planType: String?
    public let rateLimit: CodexRateLimit?

    public init(planType: String? = nil, rateLimit: CodexRateLimit? = nil) {
        self.planType = planType
        self.rateLimit = rateLimit
    }

    private enum CodingKeys: String, CodingKey {
        case planType = "plan_type"
        case rateLimit = "rate_limit"
    }
}

public struct CodexRateLimit: Decodable {
    public let primaryWindow: CodexRateLimitWindow?
    public let secondaryWindow: CodexRateLimitWindow?

    public init(primaryWindow: CodexRateLimitWindow? = nil, secondaryWindow: CodexRateLimitWindow? = nil) {
        self.primaryWindow = primaryWindow
        self.secondaryWindow = secondaryWindow
    }

    private enum CodingKeys: String, CodingKey {
        case primaryWindow = "primary_window"
        case secondaryWindow = "secondary_window"
    }
}

public struct CodexRateLimitWindow: Decodable {
    public let usedPercent: Double?
    public let resetAt: Double?
    public let limitWindowSeconds: Double?

    public init(usedPercent: Double? = nil, resetAt: Double? = nil, limitWindowSeconds: Double? = nil) {
        self.usedPercent = usedPercent
        self.resetAt = resetAt
        self.limitWindowSeconds = limitWindowSeconds
    }

    private enum CodingKeys: String, CodingKey {
        case usedPercent = "used_percent"
        case resetAt = "reset_at"
        case limitWindowSeconds = "limit_window_seconds"
    }
}

private struct CodexTokenRefreshResponse: Decodable {
    let accessToken: String?

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
    }
}
