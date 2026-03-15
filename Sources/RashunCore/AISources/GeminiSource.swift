import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct GeminiSource: AISource {
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

    public let name = "Gemini"
    public let requirements = "OS support: macOS/Linux/Windows (where Gemini CLI is available). Requires Gemini CLI with Google login and local credentials at ~/.gemini/oauth_creds.json."
    public let menuBarBrandColorHex: UInt32 = 0xDE4D5C
    public var agentConfigDirectory: String? { "~/.gemini" }
    public var agentInstructionFilePath: String? { "~/.gemini/AGENTS.md" }
    public var agentName: String { "Gemini CLI" }
    public let metrics: [AISourceMetric] = [
        AISourceMetric(id: "gemini-2.5-flash", title: "2.5-Flash"),
        AISourceMetric(id: "gemini-2.5-flash-lite", title: "2.5-Flash-Lite"),
        AISourceMetric(id: "gemini-2.5-pro", title: "2.5-Pro"),
        AISourceMetric(id: "gemini-3-flash-preview", title: "3-Flash-Preview"),
        AISourceMetric(id: "gemini-3-pro-preview", title: "3-Pro-Preview"),
    ]

    public init() {}

    public func pacingLookbackStart(for metricId: String) -> ((_ current: UsageResult, _ history: [UsageSnapshot], _ now: Date) -> Date?)? {
        guard metricId == "gemini-3-pro-preview" else {
            return nil
        }
        return { current, _, _ in
            current.cycleStartDate
        }
    }

    private let loadCodeAssistURL = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!
    private let retrieveUserQuotaURL = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota")!

    public func fetchUsage(for metricId: String) async throws -> UsageResult {
        guard metrics.contains(where: { $0.id == metricId }) else {
            throw unsupportedMetricError(metricId)
        }
        let metricUsages = try await Self.usageCache.usages {
            try await fetchUsageByMetric()
        }
        guard let usage = metricUsages[metricId] else {
            throw GeminiFetchError.noUsableQuotaBucket(modelId: metricId)
        }
        return usage
    }

    private func fetchUsageByMetric() async throws -> [String: UsageResult] {
        let credentials = try readCredentials()
        let accessToken = try await validAccessToken(from: credentials)

        let loadResponse = try await loadCodeAssist(accessToken: accessToken)
        let envProject = ProcessInfo.processInfo.environment["GOOGLE_CLOUD_PROJECT"] ??
            ProcessInfo.processInfo.environment["GOOGLE_CLOUD_PROJECT_ID"]
        guard let projectId = resolveProjectId(from: loadResponse, envProject: envProject) else {
            throw GeminiFetchError.projectResolutionFailed
        }

        let quotaResponse = try await retrieveUserQuota(accessToken: accessToken, projectId: projectId)
        let metricUsages = parseUsageByMetric(from: quotaResponse.buckets ?? [])
        if metricUsages.isEmpty {
            throw GeminiFetchError.noUsableQuotaBucket(modelId: metrics.first?.id ?? "Gemini")
        }
        return metricUsages
    }

    public func mapFetchError(for metricId: String, _ error: Error) -> SourceFetchErrorPresentation {
        if let geminiError = error as? GeminiFetchError {
            switch geminiError {
            case let .credentialsMissing(path):
                return SourceFetchErrorPresentation(
                    shortMessage: "Gemini credentials missing",
                    detailedMessage: "Gemini credentials file was not found at \(path). Open Gemini CLI and complete login, then try again."
                )
            case let .credentialsReadFailed(message):
                return SourceFetchErrorPresentation(
                    shortMessage: "Cannot read Gemini credentials",
                    detailedMessage: "Failed to read Gemini credentials. \(message)"
                )
            case .projectResolutionFailed:
                return SourceFetchErrorPresentation(
                    shortMessage: "Gemini project ID missing",
                    detailedMessage: "Could not resolve Gemini Code Assist project ID from CLI response or environment."
                )
            case let .noUsableQuotaBucket(modelId):
                return SourceFetchErrorPresentation(
                    shortMessage: "Gemini quota unavailable",
                    detailedMessage: "No usable Gemini quota bucket was found for \(modelId)."
                )
            case .accessTokenExpiredNoRefresh:
                return SourceFetchErrorPresentation(
                    shortMessage: "Gemini auth issue",
                    detailedMessage: "Gemini access token expired and no refresh token was available. Open Gemini CLI once to refresh login."
                )
            case let .tokenRefreshFailed(statusCode, body):
                let suffix = body.isEmpty ? "" : " Response: \(body)"
                return SourceFetchErrorPresentation(
                    shortMessage: "Gemini token refresh failed",
                    detailedMessage: "Gemini OAuth token refresh failed with HTTP \(statusCode).\(suffix)"
                )
            case .tokenRefreshMissingAccessToken:
                return SourceFetchErrorPresentation(
                    shortMessage: "Gemini auth issue",
                    detailedMessage: "Gemini token refresh succeeded but returned no access token."
                )
            case .oauthClientUnavailable:
                return SourceFetchErrorPresentation(
                    shortMessage: "Gemini OAuth config missing",
                    detailedMessage: "Could not resolve Gemini OAuth app credentials. Set GEMINI_OAUTH_CLIENT_ID and GEMINI_OAUTH_CLIENT_SECRET, or reinstall Gemini CLI."
                )
            case let .loadCodeAssistFailed(statusCode, body):
                let suffix = body.isEmpty ? "" : " Response: \(body)"
                return SourceFetchErrorPresentation(
                    shortMessage: "Gemini API error (\(statusCode))",
                    detailedMessage: "Gemini loadCodeAssist request failed with HTTP \(statusCode).\(suffix)"
                )
            case let .retrieveUserQuotaFailed(statusCode, body):
                let suffix = body.isEmpty ? "" : " Response: \(body)"
                return SourceFetchErrorPresentation(
                    shortMessage: "Gemini API error (\(statusCode))",
                    detailedMessage: "Gemini retrieveUserQuota request failed with HTTP \(statusCode).\(suffix)"
                )
            }
        }

        if let urlError = error as? URLError {
            return SourceFetchErrorPresentation(
                shortMessage: "Network error",
                detailedMessage: "Network request to Gemini failed (\(urlError.code.rawValue)). Check connectivity, VPN/proxy settings, and try again."
            )
        }

        let nsError = error as NSError
        return SourceFetchErrorPresentation(
            shortMessage: "Gemini fetch failed",
            detailedMessage: "Unable to fetch Gemini usage. \(nsError.localizedDescription)"
        )
    }

    public func resolveProjectId(from response: GeminiLoadCodeAssistResponse, envProject: String?) -> String? {
        if let project = response.cloudaicompanionProject, !project.isEmpty {
            return project
        }
        if let envProject, !envProject.isEmpty {
            return envProject
        }
        return nil
    }

    public func parseUsage(from buckets: [GeminiQuotaBucket]) -> UsageResult? {
        guard let bucket = selectPreferredBucket(from: buckets) else { return nil }
        return parseUsage(from: bucket)
    }

    public func parseUsageByMetric(from buckets: [GeminiQuotaBucket]) -> [String: UsageResult] {
        var parsed: [String: UsageResult] = [:]
        let expectedIds = Set(metrics.map(\.id))
        for bucket in buckets {
            guard let modelId = bucket.modelId, expectedIds.contains(modelId) else { continue }
            guard let usage = parseUsage(from: bucket) else { continue }
            parsed[modelId] = usage
        }

        return parsed
    }

    private func parseUsage(from bucket: GeminiQuotaBucket) -> UsageResult? {
        guard let fraction = bucket.remainingFraction, fraction >= 0 else {
            return nil
        }
        let resetDate = parseResetDate(bucket.resetTime)
        let cycleStartDate = resetDate?.addingTimeInterval(-(24 * 3600))

        // Gemini may return either:
        // 1) remainingAmount + remainingFraction (absolute quota)
        // 2) remainingFraction only (percentage-style quota)
        if let remainingString = bucket.remainingAmount,
           let remaining = Double(remainingString),
           remaining.isFinite,
           fraction > 0 {
            let limit = round(remaining / fraction)
            guard limit.isFinite, limit > 0 else { return nil }
            return UsageResult(remaining: remaining, limit: limit, resetDate: resetDate, cycleStartDate: cycleStartDate)
        }

        let normalizedRemaining = min(max(fraction, 0), 1) * 100
        return UsageResult(remaining: normalizedRemaining, limit: 100, resetDate: resetDate, cycleStartDate: cycleStartDate)
    }

    public func selectPreferredBucket(from buckets: [GeminiQuotaBucket]) -> GeminiQuotaBucket? {
        for metric in metrics {
            if let bucket = buckets.first(where: { $0.modelId == metric.id }) {
                return bucket
            }
        }
        return nil
    }

    public func forecast(for metricId: String, current: UsageResult, history: [UsageSnapshot]) -> ForecastResult? {
        guard let resetDate = current.resetDate, resetDate > Date() else { return nil }
        return resetWindowForecast(
            sourceLabel: name,
            current: current,
            history: history,
            resetDate: resetDate,
            historyWindowHours: 24
        )
    }

    private func readCredentials() throws -> GeminiOAuthCredentials {
        let url = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".gemini/oauth_creds.json")
        do {
            let data = try Data(contentsOf: url)
            return try JSONDecoder().decode(GeminiOAuthCredentials.self, from: data)
        } catch {
            let nsError = error as NSError
            if nsError.domain == NSCocoaErrorDomain, nsError.code == NSFileReadNoSuchFileError {
                throw GeminiFetchError.credentialsMissing(path: url.path)
            }
            throw GeminiFetchError.credentialsReadFailed(message: nsError.localizedDescription)
        }
    }

    private func validAccessToken(from credentials: GeminiOAuthCredentials) async throws -> String {
        let nowMs = Date().timeIntervalSince1970 * 1000
        if let expiry = credentials.expiryDateMs,
           expiry > (nowMs + 60_000),
           let token = credentials.accessToken,
           !token.isEmpty {
            return token
        }

        guard let refreshToken = credentials.refreshToken, !refreshToken.isEmpty else {
            throw GeminiFetchError.accessTokenExpiredNoRefresh
        }

        return try await refreshAccessToken(refreshToken: refreshToken, existing: credentials)
    }

    private static let tokenEndpoint = URL(string: "https://oauth2.googleapis.com/token")!

    private func refreshAccessToken(refreshToken: String, existing: GeminiOAuthCredentials) async throws -> String {
        let oauthClient = try resolveOAuthClient()
        let body: [String: String] = [
            "client_id": oauthClient.id,
            "client_secret": oauthClient.secret,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
        ]

        var request = URLRequest(url: Self.tokenEndpoint)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GeminiFetchError.tokenRefreshFailed(statusCode: -1, bodySnippet: "Non-HTTP response")
        }
        guard http.statusCode == 200 else {
            throw GeminiFetchError.tokenRefreshFailed(
                statusCode: http.statusCode,
                bodySnippet: bodySnippet(from: data)
            )
        }

        let refreshResponse = try JSONDecoder().decode(GeminiTokenRefreshResponse.self, from: data)
        guard let newToken = refreshResponse.accessToken, !newToken.isEmpty else {
            throw GeminiFetchError.tokenRefreshMissingAccessToken
        }

        let newExpiryMs = Date().timeIntervalSince1970 * 1000 + Double(refreshResponse.expiresIn ?? 3600) * 1000
        let updated = GeminiOAuthCredentials(
            accessToken: newToken,
            expiryDateMs: newExpiryMs,
            refreshToken: refreshToken,
            scope: existing.scope,
            tokenType: refreshResponse.tokenType ?? existing.tokenType,
            idToken: refreshResponse.idToken ?? existing.idToken
        )

        let credsURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".gemini/oauth_creds.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let updatedData = try encoder.encode(updated)
        try updatedData.write(to: credsURL, options: Data.WritingOptions.atomic)

        return newToken
    }

    private func resolveOAuthClient() throws -> (id: String, secret: String) {
        if let envId = ProcessInfo.processInfo.environment["GEMINI_OAUTH_CLIENT_ID"],
           let envSecret = ProcessInfo.processInfo.environment["GEMINI_OAUTH_CLIENT_SECRET"],
           !envId.isEmpty, !envSecret.isEmpty {
            return (id: envId, secret: envSecret)
        }

        if let parsed = parseOAuthClientFromInstalledGeminiCLI() {
            return parsed
        }

        throw GeminiFetchError.oauthClientUnavailable
    }

    private func parseOAuthClientFromInstalledGeminiCLI() -> (id: String, secret: String)? {
        let candidatePaths = [
            "/opt/homebrew/lib/node_modules/@google/gemini-cli/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js",
            "/usr/local/lib/node_modules/@google/gemini-cli/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js",
            "~/.nvm/versions/node/current/lib/node_modules/@google/gemini-cli/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js",
            "~/.local/share/pnpm/global/5/node_modules/@google/gemini-cli/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js",
            "~\\AppData\\Roaming\\npm\\node_modules\\@google\\gemini-cli\\node_modules\\@google\\gemini-cli-core\\dist\\src\\code_assist\\oauth2.js",
        ]

        for path in candidatePaths {
            let expanded = NSString(string: path).expandingTildeInPath
            guard let text = try? String(contentsOfFile: expanded, encoding: .utf8) else { continue }
            guard let id = captureFirst(in: text, pattern: #"const\s+OAUTH_CLIENT_ID\s*=\s*'([^']+)'"#),
                  let secret = captureFirst(in: text, pattern: #"const\s+OAUTH_CLIENT_SECRET\s*=\s*'([^']+)'"#),
                  !id.isEmpty, !secret.isEmpty else {
                continue
            }
            return (id: id, secret: secret)
        }

        return nil
    }

    private func captureFirst(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges >= 2,
              let valueRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        return String(text[valueRange])
    }

    private func loadCodeAssist(accessToken: String) async throws -> GeminiLoadCodeAssistResponse {
        let requestBody = GeminiLoadCodeAssistRequest(
            cloudaicompanionProject: ProcessInfo.processInfo.environment["GOOGLE_CLOUD_PROJECT"] ??
                ProcessInfo.processInfo.environment["GOOGLE_CLOUD_PROJECT_ID"],
            metadata: GeminiClientMetadata(
                ideType: "GEMINI_CLI",
                platform: "PLATFORM_UNSPECIFIED",
                pluginType: "GEMINI",
                duetProject: ProcessInfo.processInfo.environment["GOOGLE_CLOUD_PROJECT"] ??
                    ProcessInfo.processInfo.environment["GOOGLE_CLOUD_PROJECT_ID"]
            )
        )

        var request = URLRequest(url: loadCodeAssistURL)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GeminiFetchError.loadCodeAssistFailed(statusCode: -1, bodySnippet: "Non-HTTP response")
        }
        guard http.statusCode == 200 else {
            throw GeminiFetchError.loadCodeAssistFailed(
                statusCode: http.statusCode,
                bodySnippet: bodySnippet(from: data)
            )
        }

        return try JSONDecoder().decode(GeminiLoadCodeAssistResponse.self, from: data)
    }

    private func retrieveUserQuota(accessToken: String, projectId: String) async throws -> GeminiRetrieveUserQuotaResponse {
        let requestBody = GeminiRetrieveUserQuotaRequest(project: projectId)
        var request = URLRequest(url: retrieveUserQuotaURL)
        request.httpMethod = "POST"
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw GeminiFetchError.retrieveUserQuotaFailed(statusCode: -1, bodySnippet: "Non-HTTP response")
        }
        guard http.statusCode == 200 else {
            throw GeminiFetchError.retrieveUserQuotaFailed(
                statusCode: http.statusCode,
                bodySnippet: bodySnippet(from: data)
            )
        }

        return try JSONDecoder().decode(GeminiRetrieveUserQuotaResponse.self, from: data)
    }

    private func parseResetDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) {
            return date
        }
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        return standard.date(from: raw)
    }

    private func bodySnippet(from data: Data) -> String {
        let text = String(data: data, encoding: .utf8)?
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return String(text.prefix(200))
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

public enum GeminiFetchError: Error {
    case credentialsMissing(path: String)
    case credentialsReadFailed(message: String)
    case projectResolutionFailed
    case noUsableQuotaBucket(modelId: String)
    case accessTokenExpiredNoRefresh
    case tokenRefreshFailed(statusCode: Int, bodySnippet: String)
    case tokenRefreshMissingAccessToken
    case oauthClientUnavailable
    case loadCodeAssistFailed(statusCode: Int, bodySnippet: String)
    case retrieveUserQuotaFailed(statusCode: Int, bodySnippet: String)
}

public struct GeminiOAuthCredentials: Codable {
    public let accessToken: String?
    public let expiryDateMs: Double?
    public let refreshToken: String?
    public let scope: String?
    public let tokenType: String?
    public let idToken: String?

    public init(accessToken: String?, expiryDateMs: Double?, refreshToken: String?, scope: String?, tokenType: String?, idToken: String?) {
        self.accessToken = accessToken
        self.expiryDateMs = expiryDateMs
        self.refreshToken = refreshToken
        self.scope = scope
        self.tokenType = tokenType
        self.idToken = idToken
    }

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiryDateMs = "expiry_date"
        case refreshToken = "refresh_token"
        case scope
        case tokenType = "token_type"
        case idToken = "id_token"
    }
}

public struct GeminiLoadCodeAssistRequest: Encodable {
    public let cloudaicompanionProject: String?
    public let metadata: GeminiClientMetadata

    public init(cloudaicompanionProject: String?, metadata: GeminiClientMetadata) {
        self.cloudaicompanionProject = cloudaicompanionProject
        self.metadata = metadata
    }
}

public struct GeminiClientMetadata: Encodable {
    public let ideType: String
    public let platform: String
    public let pluginType: String
    public let duetProject: String?

    public init(ideType: String, platform: String, pluginType: String, duetProject: String?) {
        self.ideType = ideType
        self.platform = platform
        self.pluginType = pluginType
        self.duetProject = duetProject
    }
}

public struct GeminiLoadCodeAssistResponse: Decodable {
    public let cloudaicompanionProject: String?

    public init(cloudaicompanionProject: String?) {
        self.cloudaicompanionProject = cloudaicompanionProject
    }
}

public struct GeminiRetrieveUserQuotaRequest: Encodable {
    public let project: String

    public init(project: String) {
        self.project = project
    }
}

public struct GeminiRetrieveUserQuotaResponse: Decodable {
    public let buckets: [GeminiQuotaBucket]?

    public init(buckets: [GeminiQuotaBucket]?) {
        self.buckets = buckets
    }
}

public struct GeminiQuotaBucket: Decodable {
    public let remainingAmount: String?
    public let remainingFraction: Double?
    public let resetTime: String?
    public let tokenType: String?
    public let modelId: String?

    public init(remainingAmount: String?, remainingFraction: Double?, resetTime: String?, tokenType: String?, modelId: String?) {
        self.remainingAmount = remainingAmount
        self.remainingFraction = remainingFraction
        self.resetTime = resetTime
        self.tokenType = tokenType
        self.modelId = modelId
    }
}

public struct GeminiTokenRefreshResponse: Decodable {
    public let accessToken: String?
    public let expiresIn: Int?
    public let tokenType: String?
    public let idToken: String?

    public init(accessToken: String?, expiresIn: Int?, tokenType: String?, idToken: String?) {
        self.accessToken = accessToken
        self.expiresIn = expiresIn
        self.tokenType = tokenType
        self.idToken = idToken
    }

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case tokenType = "token_type"
        case idToken = "id_token"
    }
}
