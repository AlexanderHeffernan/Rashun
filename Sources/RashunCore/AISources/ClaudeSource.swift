import Foundation

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

// Claude exposes plan usage through the same OAuth endpoint Claude Code's `/usage` command
// calls (`api.anthropic.com/api/oauth/usage`). The OAuth token is read from Claude Code's
// own credential store: the macOS login Keychain item "Claude Code-credentials" (read via
// `/usr/bin/security`, which Claude Code already trusts, so no Keychain prompt appears), or
// `~/.claude/.credentials.json` on Linux/Windows. Refreshing the token here would rotate
// Claude Code's refresh token behind its back and could sign it out, so this source never
// refreshes on its own; it surfaces an "open Claude Code" error once the token expires.
//
// Metrics:
//   - Session: the rolling 5-hour window (`five_hour`).
//   - Weekly: the all-models 7-day window (`seven_day`).
//   - Fable Weekly: the Fable-scoped 7-day window (`limits[kind=weekly_scoped]` whose
//     scope model is Fable). Opt-in, since not every plan has one.
public struct ClaudeSource: AISource {
    /// Serialises fetches and throttles them against a cache on disk. The app, the CLI, and
    /// Claude Code itself all share one small per-account rate limit on the usage endpoint,
    /// so every process reads and writes the same cache file, and a 429 is honoured across
    /// all of them.
    private actor UsageCache {
        private var inFlight: Task<[String: UsageResult], Error>?
        private var memoryState = ClaudeUsageCacheState()

        func usages(loader: @escaping @Sendable () async throws -> [String: UsageResult])
            async throws -> [String: UsageResult]
        {
            if let inFlight {
                return try await inFlight.value
            }

            let task = Task { try await self.load(loader: loader) }
            inFlight = task
            defer { inFlight = nil }
            return try await task.value
        }

        private func load(loader: @Sendable () async throws -> [String: UsageResult])
            async throws -> [String: UsageResult]
        {
            var state = readState()
            switch ClaudeSource.fetchPlan(state: state, now: Date()) {
            case .useCached(let usages):
                return usages
            case .rateLimited(let retryAt):
                throw ClaudeFetchError.rateLimited(retryAt: retryAt)
            case .fetch:
                break
            }

            do {
                let usages = try await loader()
                state = ClaudeUsageCacheState(fetchedAt: Date(), usages: usages)
                writeState(state)
                return usages
            } catch ClaudeFetchError.rateLimited(let retryAt) {
                state.rateLimitedUntil =
                    retryAt ?? Date().addingTimeInterval(ClaudeSource.defaultRateLimitBackoff)
                writeState(state)
                if case .useCached(let usages) = ClaudeSource.fetchPlan(state: state, now: Date())
                {
                    return usages
                }
                throw ClaudeFetchError.rateLimited(retryAt: state.rateLimitedUntil)
            }
        }

        private func readState() -> ClaudeUsageCacheState {
            guard let url = ClaudeSource.cacheFileURL,
                let data = try? Data(contentsOf: url),
                let state = try? JSONDecoder().decode(ClaudeUsageCacheState.self, from: data)
            else {
                return memoryState
            }
            memoryState = state
            return state
        }

        private func writeState(_ state: ClaudeUsageCacheState) {
            memoryState = state
            guard let url = ClaudeSource.cacheFileURL,
                let data = try? JSONEncoder().encode(state)
            else { return }
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }

    private static let usageCache = UsageCache()

    /// Minimum time between network requests; polls in between reuse the cached result.
    static let minimumFetchInterval: TimeInterval = 5 * 60
    /// How old a cached result may be and still stand in for a rate-limited request.
    static let staleUsageLimit: TimeInterval = 30 * 60
    /// Backoff used when a 429 response carries no usable `Retry-After` header.
    static let defaultRateLimitBackoff: TimeInterval = 5 * 60

    static var cacheFileURL: URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Rashun", isDirectory: true)
            .appendingPathComponent("claude-usage.json")
    }

    enum FetchPlan: Equatable {
        case useCached([String: UsageResult])
        case rateLimited(retryAt: Date)
        case fetch
    }

    static func fetchPlan(state: ClaudeUsageCacheState, now: Date) -> FetchPlan {
        let cacheAge = state.fetchedAt.map { now.timeIntervalSince($0) }
        let hasUsages = !state.usages.isEmpty

        if hasUsages, let cacheAge, cacheAge >= 0, cacheAge < minimumFetchInterval {
            return .useCached(state.usages)
        }
        if let retryAt = state.rateLimitedUntil, retryAt > now {
            if hasUsages, let cacheAge, cacheAge >= 0, cacheAge < staleUsageLimit {
                return .useCached(state.usages)
            }
            return .rateLimited(retryAt: retryAt)
        }
        return .fetch
    }

    public let name = "Claude"
    public let requirements =
        "OS support: macOS/Linux/Windows. Requires Claude Code signed in with a Claude subscription (Pro/Max/Team). The OAuth token is read from the macOS Keychain item \"Claude Code-credentials\", or ~/.claude/.credentials.json on Linux/Windows."
    public let metrics = [
        AISourceMetric(id: "claude-session", title: "Session", menuBarBadgeText: "5h"),
        AISourceMetric(id: "claude-weekly", title: "Weekly", menuBarBadgeText: "7d"),
        AISourceMetric(
            id: "claude-weekly-fable", title: "Fable Weekly", defaultEnabled: false,
            menuBarBadgeText: "Fable"),
    ]
    public let menuBarBrandColorHex: UInt32 = 0xD97757
    public var pacingBehavior: SourcePacingBehavior { .resetWindow }
    public var agentConfigDirectory: String? { "~/.claude" }
    public var agentInstructionFilePath: String? { "~/.claude/CLAUDE.md" }
    public var agentName: String { "Claude Code" }

    private static let sessionWindowSeconds: TimeInterval = 5 * 60 * 60
    private static let weeklyWindowSeconds: TimeInterval = 7 * 24 * 60 * 60

    public init() {}

    public func pacingLookbackStart(for metricId: String) -> (
        (_ current: UsageResult, _ history: [UsageSnapshot], _ now: Date) -> Date?
    )? {
        { current, _, _ in
            current.cycleStartDate
        }
    }

    public func fetchUsage(for metricId: String) async throws -> UsageResult {
        guard metrics.contains(where: { $0.id == metricId }) else {
            throw unsupportedMetricError(metricId)
        }

        let usages = try await Self.usageCache.usages {
            try await fetchUsageByMetric()
        }
        guard let usage = usages[metricId] else {
            throw ClaudeFetchError.metricUnavailable(metricId: metricId)
        }
        return usage
    }

    private func fetchUsageByMetric() async throws -> [String: UsageResult] {
        let credentials = try readCredentials()
        let response = try await fetchUsageResponse(accessToken: credentials.accessToken)
        let parsed = parseUsageByMetric(from: response)
        guard !parsed.isEmpty else {
            throw ClaudeFetchError.usagePayloadInvalid
        }
        return parsed
    }

    // MARK: - Parsing

    /// Maps a decoded Claude usage response into per-metric usage results.
    /// Utilisation values are percentages used (0–100); remaining is clamped to 0–100.
    public func parseUsageByMetric(from response: ClaudeUsageResponse) -> [String: UsageResult] {
        var parsed: [String: UsageResult] = [:]

        if let usage = parseWindow(
            utilization: response.fiveHour?.utilization,
            resetsAt: response.fiveHour?.resetsAt,
            windowSeconds: Self.sessionWindowSeconds
        ) {
            parsed["claude-session"] = usage
        }

        if let usage = parseWindow(
            utilization: response.sevenDay?.utilization,
            resetsAt: response.sevenDay?.resetsAt,
            windowSeconds: Self.weeklyWindowSeconds
        ) {
            parsed["claude-weekly"] = usage
        }

        let fableLimit = (response.limits ?? []).first {
            $0.kind == "weekly_scoped"
                && $0.modelDisplayName?.caseInsensitiveCompare("Fable") == .orderedSame
        }
        if let fableLimit,
            let usage = parseWindow(
                utilization: fableLimit.percent, resetsAt: fableLimit.resetsAt,
                windowSeconds: Self.weeklyWindowSeconds)
        {
            parsed["claude-weekly-fable"] = usage
        }

        return parsed
    }

    private func parseWindow(utilization: Double?, resetsAt: String?, windowSeconds: TimeInterval)
        -> UsageResult?
    {
        guard let utilization, utilization.isFinite else { return nil }
        let remaining = max(0, min(100, 100 - utilization))
        // A window that has not started yet (no usage since the last reset) has no reset time.
        let resetDate = resetsAt.flatMap(Self.parseTimestamp)
        let cycleStartDate = resetDate?.addingTimeInterval(-windowSeconds)
        return UsageResult(
            remaining: remaining, limit: 100, resetDate: resetDate, cycleStartDate: cycleStartDate)
    }

    /// Parses ISO 8601 timestamps such as `2026-09-25T03:09:59.621245+00:00`.
    /// Fractional seconds are dropped because their precision varies (microseconds here),
    /// which `ISO8601DateFormatter` does not parse consistently across platforms.
    static func parseTimestamp(_ raw: String) -> Date? {
        let trimmed = raw.replacingOccurrences(
            of: "\\.\\d+", with: "", options: .regularExpression)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: trimmed)
    }

    // MARK: - Credentials

    private func readCredentials() throws -> ClaudeOAuthCredentials {
        var data: Data?
        #if os(macOS)
            data = try readKeychainCredentials()
        #endif
        if data == nil {
            data = try readCredentialsFile()
        }
        guard let data else {
            throw ClaudeFetchError.credentialsMissing(location: credentialsLocationDescription)
        }
        return try parseCredentials(from: data, now: Date())
    }

    public func parseCredentials(from data: Data, now: Date) throws -> ClaudeOAuthCredentials {
        let file: ClaudeCredentialsFile
        do {
            file = try JSONDecoder().decode(ClaudeCredentialsFile.self, from: data)
        } catch {
            throw ClaudeFetchError.credentialsReadFailed(message: "Unexpected credentials format.")
        }
        guard let oauth = file.claudeAiOauth, let accessToken = oauth.accessToken,
            !accessToken.isEmpty
        else {
            throw ClaudeFetchError.accessTokenMissing
        }
        if let expiresAt = oauth.expiresAt,
            Date(timeIntervalSince1970: expiresAt / 1000) <= now
        {
            throw ClaudeFetchError.accessTokenExpired(statusCode: nil)
        }
        return ClaudeOAuthCredentials(accessToken: accessToken)
    }

    #if os(macOS)
        private func readKeychainCredentials() throws -> Data? {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
            process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]

            let stdoutPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = FileHandle.nullDevice

            try process.run()
            let stdout = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()

            // Exit status 44 is errSecItemNotFound; fall back to the credentials file.
            guard process.terminationStatus == 0 else { return nil }
            let trimmed = String(data: stdout, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? nil : Data(trimmed.utf8)
        }
    #endif

    private var credentialsFileURL: URL {
        let configDir =
            ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"]
            .map { NSString(string: $0).expandingTildeInPath }
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude").path
        return URL(fileURLWithPath: configDir).appendingPathComponent(".credentials.json")
    }

    private var credentialsLocationDescription: String {
        #if os(macOS)
            return "Keychain item \"Claude Code-credentials\" or \(credentialsFileURL.path)"
        #else
            return credentialsFileURL.path
        #endif
    }

    private func readCredentialsFile() throws -> Data? {
        let url = credentialsFileURL
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try Data(contentsOf: url)
        } catch {
            throw ClaudeFetchError.credentialsReadFailed(
                message: (error as NSError).localizedDescription)
        }
    }

    // MARK: - Network

    private let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    private func fetchUsageResponse(accessToken: String) async throws -> ClaudeUsageResponse {
        var request = URLRequest(url: usageURL)
        request.addValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.addValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.addValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClaudeFetchError.usageAPIStatus(statusCode: -1, bodySnippet: "Non-HTTP response")
        }
        if http.statusCode == 401 {
            throw ClaudeFetchError.accessTokenExpired(statusCode: http.statusCode)
        }
        if http.statusCode == 429 {
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After")
                .flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }
                .flatMap { $0 > 0 ? $0 : nil }
            throw ClaudeFetchError.rateLimited(
                retryAt: retryAfter.map { Date().addingTimeInterval($0) })
        }
        guard http.statusCode == 200 else {
            throw ClaudeFetchError.usageAPIStatus(
                statusCode: http.statusCode, bodySnippet: bodySnippet(from: data))
        }

        do {
            return try JSONDecoder().decode(ClaudeUsageResponse.self, from: data)
        } catch {
            throw ClaudeFetchError.usagePayloadInvalid
        }
    }

    private func bodySnippet(from data: Data, maxLength: Int = 500) -> String {
        let raw = String(data: data, encoding: .utf8) ?? ""
        let singleLine =
            raw
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return String(singleLine.prefix(maxLength))
    }

    // MARK: - Errors

    public func mapFetchError(for metricId: String, _ error: Error) -> SourceFetchErrorPresentation
    {
        if let claudeError = error as? ClaudeFetchError {
            switch claudeError {
            case .credentialsMissing(let location):
                return SourceFetchErrorPresentation(
                    shortMessage: "Claude Code not signed in",
                    detailedMessage:
                        "No Claude Code credentials were found (\(location)). Install Claude Code and run `claude` to sign in with your Claude subscription, then try again."
                )
            case .credentialsReadFailed(let message):
                return SourceFetchErrorPresentation(
                    shortMessage: "Cannot read Claude auth",
                    detailedMessage: "Failed to read Claude Code credentials. \(message)"
                )
            case .accessTokenMissing:
                return SourceFetchErrorPresentation(
                    shortMessage: "Claude auth incomplete",
                    detailedMessage:
                        "Claude Code credentials did not contain a subscription OAuth token. Run `claude` and sign in with your Claude account (API key logins do not have plan usage limits)."
                )
            case .accessTokenExpired:
                return SourceFetchErrorPresentation(
                    shortMessage: "Claude auth expired",
                    detailedMessage:
                        "The Claude Code access token has expired. Open Claude Code (run `claude`) to refresh it, then try again."
                )
            case .rateLimited(let retryAt):
                let retryText: String
                if let retryAt {
                    let formatter = DateFormatter()
                    formatter.dateStyle = .none
                    formatter.timeStyle = .short
                    retryText = "Rashun will try again after \(formatter.string(from: retryAt))."
                } else {
                    retryText = "Rashun will try again in a few minutes."
                }
                return SourceFetchErrorPresentation(
                    shortMessage: "Claude API rate limited",
                    detailedMessage:
                        "Claude's usage API is rate limiting requests. This limit is shared with Claude Code itself, so heavy use of `/usage` or other usage tools can trigger it. \(retryText)"
                )
            case .usageAPIStatus(let statusCode, let bodySnippet):
                let suffix = bodySnippet.isEmpty ? "" : " Response: \(bodySnippet)"
                return SourceFetchErrorPresentation(
                    shortMessage: "Claude API error (\(statusCode))",
                    detailedMessage: "Claude usage API returned HTTP \(statusCode).\(suffix)"
                )
            case .usagePayloadInvalid:
                return SourceFetchErrorPresentation(
                    shortMessage: "Unexpected Claude response",
                    detailedMessage:
                        "Claude usage API response was missing expected usage fields. If this persists, the endpoint response format may have changed."
                )
            case .metricUnavailable(let metricId):
                let metricLabel = metrics.first(where: { $0.id == metricId })?.title ?? metricId
                return SourceFetchErrorPresentation(
                    shortMessage: "Not on this plan",
                    detailedMessage:
                        "Claude's usage API did not report a \(metricLabel) limit for your plan."
                )
            }
        }

        if let urlError = error as? URLError {
            return SourceFetchErrorPresentation(
                shortMessage: "Network error",
                detailedMessage:
                    "Network request to Claude failed (\(urlError.code.rawValue)). Check connectivity, VPN/proxy settings, and try again."
            )
        }

        let nsError = error as NSError
        return SourceFetchErrorPresentation(
            shortMessage: "Claude fetch failed",
            detailedMessage: "Unable to fetch Claude usage. \(nsError.localizedDescription)"
        )
    }

    // MARK: - Forecasting

    public func forecast(for metricId: String, current: UsageResult, history: [UsageSnapshot])
        -> ForecastResult?
    {
        guard let resetDate = current.resetDate, resetDate > Date() else { return nil }
        return UsageForecastEngine.resetWindowForecast(
            sourceLabel: displayName,
            current: current,
            history: history,
            resetDate: resetDate,
            historyWindowHours: forecastHistoryWindowHours(for: metricId) ?? 24
        )
    }

    public func forecastHistoryWindowHours(for metricId: String) -> Double? {
        72
    }
}

public enum ClaudeFetchError: Error {
    case credentialsMissing(location: String)
    case credentialsReadFailed(message: String)
    case accessTokenMissing
    case accessTokenExpired(statusCode: Int?)
    case rateLimited(retryAt: Date?)
    case usageAPIStatus(statusCode: Int, bodySnippet: String)
    case usagePayloadInvalid
    case metricUnavailable(metricId: String)
}

struct ClaudeUsageCacheState: Codable, Equatable {
    var fetchedAt: Date?
    var usages: [String: UsageResult] = [:]
    var rateLimitedUntil: Date?
}

public struct ClaudeOAuthCredentials: Sendable, Equatable {
    public let accessToken: String
}

struct ClaudeCredentialsFile: Decodable {
    let claudeAiOauth: ClaudeCredentialsOAuth?
}

struct ClaudeCredentialsOAuth: Decodable {
    let accessToken: String?
    /// Milliseconds since the Unix epoch.
    let expiresAt: Double?
}

public struct ClaudeUsageResponse: Decodable {
    public let fiveHour: ClaudeUsageWindow?
    public let sevenDay: ClaudeUsageWindow?
    public let limits: [ClaudeUsageLimit]?

    public init(
        fiveHour: ClaudeUsageWindow? = nil,
        sevenDay: ClaudeUsageWindow? = nil,
        limits: [ClaudeUsageLimit]? = nil
    ) {
        self.fiveHour = fiveHour
        self.sevenDay = sevenDay
        self.limits = limits
    }

    private enum CodingKeys: String, CodingKey {
        case fiveHour = "five_hour"
        case sevenDay = "seven_day"
        case limits
    }
}

public struct ClaudeUsageWindow: Decodable {
    public let utilization: Double?
    public let resetsAt: String?

    public init(utilization: Double?, resetsAt: String?) {
        self.utilization = utilization
        self.resetsAt = resetsAt
    }

    private enum CodingKeys: String, CodingKey {
        case utilization
        case resetsAt = "resets_at"
    }
}

public struct ClaudeUsageLimit: Decodable {
    public let kind: String?
    public let percent: Double?
    public let resetsAt: String?
    /// `scope.model.display_name` for model-scoped limits (for example, "Fable").
    public let modelDisplayName: String?

    public init(kind: String?, percent: Double?, resetsAt: String?, modelDisplayName: String? = nil) {
        self.kind = kind
        self.percent = percent
        self.resetsAt = resetsAt
        self.modelDisplayName = modelDisplayName
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decodeIfPresent(String.self, forKey: .kind)
        percent = try container.decodeIfPresent(Double.self, forKey: .percent)
        resetsAt = try container.decodeIfPresent(String.self, forKey: .resetsAt)
        let scope = try? container.decodeIfPresent(Scope.self, forKey: .scope)
        modelDisplayName = scope?.model?.displayName
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case percent
        case resetsAt = "resets_at"
        case scope
    }

    private struct Scope: Decodable {
        let model: Model?
    }

    private struct Model: Decodable {
        let displayName: String?

        private enum CodingKeys: String, CodingKey {
            case displayName = "display_name"
        }
    }
}
