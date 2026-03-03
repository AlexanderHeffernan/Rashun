import Foundation

struct GeminiSource: AISource {
    let name = "Gemini 3 Pro"
    let requirements = "Requires Gemini CLI with Google login and local credentials at ~/.gemini/oauth_creds.json. Tracks gemini-3-pro-preview usage."
    let supportsPacingAlert = true
    func pacingLookbackStart(current: UsageResult, history: [UsageSnapshot], now: Date) -> Date? {
        current.cycleStartDate
    }

    private let loadCodeAssistURL = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:loadCodeAssist")!
    private let retrieveUserQuotaURL = URL(string: "https://cloudcode-pa.googleapis.com/v1internal:retrieveUserQuota")!
    private let primaryModelId = "gemini-3-pro-preview"
    private let secondaryModelId = "gemini-3-pro-preview_vertex"

    func fetchUsage() async throws -> UsageResult {
        let credentials = try readCredentials()
        let accessToken = try await validAccessToken(from: credentials)

        let loadResponse = try await loadCodeAssist(accessToken: accessToken)
        let envProject = ProcessInfo.processInfo.environment["GOOGLE_CLOUD_PROJECT"] ??
            ProcessInfo.processInfo.environment["GOOGLE_CLOUD_PROJECT_ID"]
        guard let projectId = resolveProjectId(from: loadResponse, envProject: envProject) else {
            throw NSError(
                domain: "GeminiSource",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Could not resolve Gemini Code Assist project ID"]
            )
        }

        let quotaResponse = try await retrieveUserQuota(accessToken: accessToken, projectId: projectId)
        guard let usage = parseUsage(from: quotaResponse.buckets ?? []) else {
            throw NSError(
                domain: "GeminiSource",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "No usable quota bucket found for \(primaryModelId)"]
            )
        }

        return usage
    }

    func resolveProjectId(from response: GeminiLoadCodeAssistResponse, envProject: String?) -> String? {
        if let project = response.cloudaicompanionProject, !project.isEmpty {
            return project
        }
        if let envProject, !envProject.isEmpty {
            return envProject
        }
        return nil
    }

    func parseUsage(from buckets: [GeminiQuotaBucket]) -> UsageResult? {
        guard let bucket = selectPreferredBucket(from: buckets),
              let fraction = bucket.remainingFraction,
              fraction >= 0 else {
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

    func selectPreferredBucket(from buckets: [GeminiQuotaBucket]) -> GeminiQuotaBucket? {
        if let primary = buckets.first(where: { $0.modelId == primaryModelId }) {
            return primary
        }

        if let secondary = buckets.first(where: { $0.modelId == secondaryModelId }) {
            return secondary
        }

        return nil
    }

    func forecast(current: UsageResult, history: [UsageSnapshot]) -> ForecastResult? {
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
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(GeminiOAuthCredentials.self, from: data)
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
            throw NSError(
                domain: "GeminiSource",
                code: -3,
                userInfo: [NSLocalizedDescriptionKey: "Gemini access token is expired and no refresh token available. Open Gemini CLI once to refresh login."]
            )
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
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(
                domain: "GeminiSource",
                code: -4,
                userInfo: [NSLocalizedDescriptionKey: "Failed to refresh Gemini access token. Open Gemini CLI once to re-authenticate."]
            )
        }

        let refreshResponse = try JSONDecoder().decode(GeminiTokenRefreshResponse.self, from: data)
        guard let newToken = refreshResponse.accessToken, !newToken.isEmpty else {
            throw NSError(
                domain: "GeminiSource",
                code: -5,
                userInfo: [NSLocalizedDescriptionKey: "Gemini token refresh returned no access token."]
            )
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
        try updatedData.write(to: credsURL, options: .atomic)

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

        throw NSError(
            domain: "GeminiSource",
            code: -8,
            userInfo: [NSLocalizedDescriptionKey: "Could not resolve Gemini OAuth app credentials. Set GEMINI_OAUTH_CLIENT_ID and GEMINI_OAUTH_CLIENT_SECRET, or reinstall Gemini CLI."]
        )
    }

    private func parseOAuthClientFromInstalledGeminiCLI() -> (id: String, secret: String)? {
        let candidatePaths = [
            "/opt/homebrew/lib/node_modules/@google/gemini-cli/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js",
            "/usr/local/lib/node_modules/@google/gemini-cli/node_modules/@google/gemini-cli-core/dist/src/code_assist/oauth2.js",
        ]

        for path in candidatePaths {
            guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
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
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(
                domain: "GeminiSource",
                code: -6,
                userInfo: [NSLocalizedDescriptionKey: "Gemini loadCodeAssist request failed"]
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
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw NSError(
                domain: "GeminiSource",
                code: -7,
                userInfo: [NSLocalizedDescriptionKey: "Gemini retrieveUserQuota request failed"]
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

struct GeminiOAuthCredentials: Codable {
    let accessToken: String?
    let expiryDateMs: Double?
    let refreshToken: String?
    let scope: String?
    let tokenType: String?
    let idToken: String?

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiryDateMs = "expiry_date"
        case refreshToken = "refresh_token"
        case scope
        case tokenType = "token_type"
        case idToken = "id_token"
    }
}

struct GeminiLoadCodeAssistRequest: Encodable {
    let cloudaicompanionProject: String?
    let metadata: GeminiClientMetadata
}

struct GeminiClientMetadata: Encodable {
    let ideType: String
    let platform: String
    let pluginType: String
    let duetProject: String?
}

struct GeminiLoadCodeAssistResponse: Decodable {
    let cloudaicompanionProject: String?
}

struct GeminiRetrieveUserQuotaRequest: Encodable {
    let project: String
}

struct GeminiRetrieveUserQuotaResponse: Decodable {
    let buckets: [GeminiQuotaBucket]?
}

struct GeminiQuotaBucket: Decodable {
    let remainingAmount: String?
    let remainingFraction: Double?
    let resetTime: String?
    let tokenType: String?
    let modelId: String?
}

struct GeminiTokenRefreshResponse: Decodable {
    let accessToken: String?
    let expiresIn: Int?
    let tokenType: String?
    let idToken: String?

    private enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case expiresIn = "expires_in"
        case tokenType = "token_type"
        case idToken = "id_token"
    }
}
