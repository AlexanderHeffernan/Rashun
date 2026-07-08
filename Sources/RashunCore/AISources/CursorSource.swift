import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Cursor exposes usage data through the same undocumented dashboard endpoint its own app
// calls (`aiserver.v1.DashboardService/GetCurrentPeriodUsage` on api2.cursor.sh). There is
// no official public API, so this source mirrors Cursor's own request and parses the
// response shape observed in the wild. The auth token and plan type are read from Cursor's
// local VS Code-style state database (`state.vscdb`); Cursor refreshes the token itself
// whenever the user opens the app, so this source does not attempt its own refresh.
//
// Metrics:
//   - Auto Models: percentage of the auto/default-models bucket remaining
//     (autoPercentUsed). This is the bucket that actually gates usage on every plan.
//   - API Models: percentage of the named/API-models bucket remaining (apiPercentUsed).
//     Only meaningful on paid plans — free users have no separate API quota, so the source
//     surfaces a plan-specific error instead of a misleading 100%.
public struct CursorSource: AISource {
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

    public let name = "Cursor"
    public let requirements = "OS support: macOS/Linux/Windows (where Cursor is installed). Requires Cursor signed in (auth token read from Cursor's local state database) and the `sqlite3` CLI available on PATH to read that token. Usage is read from Cursor's dashboard usage endpoint."
    public let menuBarBrandColorHex: UInt32 = 0x9A8E7A
    public var pacingBehavior: SourcePacingBehavior { .resetWindow }

    public var agentConfigDirectory: String? { nil }
    public var agentInstructionFilePath: String? { nil }
    public var agentName: String { "Cursor" }
    public var agentRequiresManualSetup: Bool { true }

    public let metrics: [AISourceMetric] = [
        AISourceMetric(id: "cursor-auto", title: "Auto Models", menuBarBadgeText: "Auto"),
        AISourceMetric(id: "cursor-api", title: "API Models", menuBarBadgeText: "API"),
    ]

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

        if metricId == "cursor-api" {
            let plan = try readMembershipType()
            if plan == CursorPlanType.free {
                throw CursorFetchError.metricNotAvailableOnPlan(metricId: metricId, plan: plan.rawValue)
            }
        }
        let usages = try await Self.usageCache.usages {
            try await fetchUsageByMetric()
        }
        guard let usage = usages[metricId] else {
            throw CursorFetchError.metricUnavailable(metricId: metricId)
        }
        return usage
    }

    private func fetchUsageByMetric() async throws -> [String: UsageResult] {
        let accessToken = try readAccessToken()
        let response = try await fetchUsageResponse(accessToken: accessToken)
        let parsed = parseUsageByMetric(from: response)
        guard !parsed.isEmpty else {
            throw CursorFetchError.usagePayloadInvalid
        }
        return parsed
    }

    private let usageURL = URL(string: "https://api2.cursor.sh/aiserver.v1.DashboardService/GetCurrentPeriodUsage")!

    private func fetchUsageResponse(accessToken: String) async throws -> CursorUsageResponse {
        var request = URLRequest(url: usageURL)
        request.httpMethod = "POST"
        request.addValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.addValue("1", forHTTPHeaderField: "Connect-Protocol-Version")
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("{}".utf8)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CursorFetchError.usageAPIStatus(statusCode: -1, bodySnippet: "Non-HTTP response")
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw CursorFetchError.accessTokenExpired(statusCode: http.statusCode)
        }
        guard http.statusCode == 200 else {
            throw CursorFetchError.usageAPIStatus(statusCode: http.statusCode, bodySnippet: bodySnippet(from: data))
        }

        do {
            return try JSONDecoder().decode(CursorUsageResponse.self, from: data)
        } catch {
            throw CursorFetchError.usagePayloadInvalid
        }
    }

    /// Maps a decoded Cursor dashboard response into per-metric usage results.
    /// Both metrics share the same billing-cycle window (derived from
    /// `billingCycleStart` / `billingCycleEnd`). Each bucket is percentage-based
    /// (Cursor reports `autoPercentUsed` / `apiPercentUsed` directly).
    public func parseUsageByMetric(from response: CursorUsageResponse) -> [String: UsageResult] {
        let cycleStart = parseMillis(response.billingCycleStart)
        let resetDate = parseMillis(response.billingCycleEnd)
        var parsed: [String: UsageResult] = [:]

        if let autoUsed = response.planUsage?.autoPercentUsed, autoUsed.isFinite {
            let remaining = clampPercent(100 - autoUsed)
            parsed["cursor-auto"] = UsageResult(remaining: remaining, limit: 100, resetDate: resetDate, cycleStartDate: cycleStart)
        }
        if let apiUsed = response.planUsage?.apiPercentUsed, apiUsed.isFinite {
            let remaining = clampPercent(100 - apiUsed)
            parsed["cursor-api"] = UsageResult(remaining: remaining, limit: 100, resetDate: resetDate, cycleStartDate: cycleStart)
        }
        return parsed
    }

    public func mapFetchError(for metricId: String, _ error: Error) -> SourceFetchErrorPresentation {
        if let cursorError = error as? CursorFetchError {
            switch cursorError {
            case let .stateDatabaseMissing(path):
                return SourceFetchErrorPresentation(
                    shortMessage: "Cursor state database missing",
                    detailedMessage: "Cursor's local state database was not found at \(path). Install Cursor, sign in, and open it at least once, then try again."
                )
            case let .stateDatabaseUnreadable(path):
                return SourceFetchErrorPresentation(
                    shortMessage: "Cursor state unreadable",
                    detailedMessage: "Rashun cannot read Cursor's state database at \(path). Check file permissions and try again."
                )
            case .sqlite3NotFound:
                return SourceFetchErrorPresentation(
                    shortMessage: "sqlite3 not found",
                    detailedMessage: "The `sqlite3` CLI was not found on PATH. It is needed to read Cursor's local auth token. Install it (it ships with macOS Command Line Tools) and ensure it is on PATH, then try again."
                )
            case let .sqliteQueryFailed(exitCode, message):
                return SourceFetchErrorPresentation(
                    shortMessage: "Could not read Cursor auth",
                    detailedMessage: "Reading Cursor's auth token from its state database failed (sqlite3 exit \(exitCode)). \(message)"
                )
            case .accessTokenMissing:
                return SourceFetchErrorPresentation(
                    shortMessage: "Cursor auth missing",
                    detailedMessage: "Cursor's access token was empty. Open Cursor and sign in, then try again."
                )
            case let .accessTokenExpired(statusCode):
                return SourceFetchErrorPresentation(
                    shortMessage: "Cursor auth expired",
                    detailedMessage: "Cursor's usage API rejected the cached access token (HTTP \(statusCode)). Open Cursor once so it refreshes your session, then try again."
                )
            case let .usageAPIStatus(statusCode, bodySnippet):
                let suffix = bodySnippet.isEmpty ? "" : " Response: \(bodySnippet)"
                return SourceFetchErrorPresentation(
                    shortMessage: "Cursor API error (\(statusCode))",
                    detailedMessage: "Cursor usage API returned HTTP \(statusCode).\(suffix)"
                )
            case .usagePayloadInvalid:
                return SourceFetchErrorPresentation(
                    shortMessage: "Unexpected Cursor response",
                    detailedMessage: "Cursor usage API response was missing expected usage fields. If this persists, the endpoint response format may have changed."
                )
            case let .metricUnavailable(metricId):
                return SourceFetchErrorPresentation(
                    shortMessage: "Cursor usage unavailable",
                    detailedMessage: "Cursor usage API did not include data for \(metricId)."
                )
            case let .metricNotAvailableOnPlan(metricId, plan):
                if metricId == "cursor-api" && plan == CursorPlanType.free.rawValue {
                    return SourceFetchErrorPresentation(
                        shortMessage: "API models unavailable on Free",
                        detailedMessage: "The Cursor Free plan does not include a separate API models quota, so API usage cannot be tracked. Upgrade to Cursor Pro to enable API model tracking."
                    )
                }
                return SourceFetchErrorPresentation(
                    shortMessage: "Metric unavailable on \(plan) plan",
                    detailedMessage: "Cursor metric '\(metricId)' is not available on the \(plan) plan."
                )
            }
        }

        if let urlError = error as? URLError {
            return SourceFetchErrorPresentation(
                shortMessage: "Network error",
                detailedMessage: "Network request to Cursor failed (\(urlError.code.rawValue)). Check connectivity, VPN/proxy settings, and try again."
            )
        }

        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == 2 {
            return SourceFetchErrorPresentation(
                shortMessage: "sqlite3 not found",
                detailedMessage: "The `sqlite3` CLI was not found in PATH. It is needed to read Cursor's local auth token. Install it and ensure it is on your shell PATH, then try again."
            )
        }

        return SourceFetchErrorPresentation(
            shortMessage: "Cursor fetch failed",
            detailedMessage: "Unable to fetch Cursor usage. \(nsError.localizedDescription)"
        )
    }

    public func forecast(for metricId: String, current: UsageResult, history: [UsageSnapshot]) -> ForecastResult? {
        guard let resetDate = current.resetDate, resetDate > Date() else { return nil }
        return UsageForecastEngine.resetWindowForecast(
            sourceLabel: name,
            current: current,
            history: history,
            resetDate: resetDate,
            historyWindowHours: forecastHistoryWindowHours(for: metricId) ?? 72
        )
    }

    public func forecastHistoryWindowHours(for metricId: String) -> Double? {
        72
    }

    // MARK: - Auth token + plan retrieval

    private func readAccessToken() throws -> String {
        let sqlitePath = try resolveSqlite3()
        let dbPath = try cursorStateDBPath()
        let raw = try runSqlite(dbPath: dbPath, sqlitePath: sqlitePath, sql: "SELECT value FROM ItemTable WHERE key='cursorAuth/accessToken';")
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            throw CursorFetchError.accessTokenMissing
        }
        return token
    }

    private func readMembershipType() throws -> CursorPlanType {
        let sqlitePath = try resolveSqlite3()
        let dbPath = try cursorStateDBPath()
        let raw = try runSqlite(dbPath: dbPath, sqlitePath: sqlitePath, sql: "SELECT value FROM ItemTable WHERE key='cursorAuth/stripeMembershipType';")
        return CursorPlanType(raw: raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func resolveSqlite3() throws -> String {
        let candidates = [
            "/usr/bin",
            "/bin",
            "/usr/local/bin",
            "/opt/homebrew/bin",
        ]
        guard let path = ExecutableLocator.resolve(command: "sqlite3", additionalCandidates: candidates) else {
            throw CursorFetchError.sqlite3NotFound
        }
        return path
    }

    private func cursorStateDBPath() throws -> String {
        let path = cursorStateDBURL().path
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw CursorFetchError.stateDatabaseMissing(path: path)
        }
        guard FileManager.default.isReadableFile(atPath: path) else {
            throw CursorFetchError.stateDatabaseUnreadable(path: path)
        }
        return path
    }

    private func cursorStateDBURL() -> URL {
        let home = NSHomeDirectory()
        #if os(macOS)
        return URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        #elseif os(Windows)
        let appData = ProcessInfo.processInfo.environment["APPDATA"] ?? (home + "\\AppData\\Roaming")
        return URL(fileURLWithPath: appData)
            .appendingPathComponent("Cursor/User/globalStorage/state.vscdb")
        #else
        let configHome = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"] ?? (home + "/.config")
        return URL(fileURLWithPath: configHome)
            .appendingPathComponent("Cursor/User/globalStorage/state.vscdb")
        #endif
    }

    private func runSqlite(dbPath: String, sqlitePath: String, sql: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sqlitePath)
        process.arguments = [dbPath, sql]
        #if !os(Windows)
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
                throw CursorFetchError.sqlite3NotFound
            }
            throw error
        }
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: stdoutData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        if process.terminationStatus != 0 {
            let stderr = String(data: stderrData, encoding: .utf8)?
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw CursorFetchError.sqliteQueryFailed(
                exitCode: Int(process.terminationStatus),
                message: stderr.isEmpty ? "sqlite3 exited with non-zero status" : stderr
            )
        }
        return output
    }

    // MARK: - Helpers

    private func parseMillis(_ raw: String?) -> Date? {
        guard let raw, let millis = Double(raw), millis.isFinite else { return nil }
        return Date(timeIntervalSince1970: millis / 1000)
    }

    private func clampPercent(_ value: Double) -> Double {
        min(100, max(0, value))
    }

    private func bodySnippet(from data: Data) -> String {
        let text = String(data: data, encoding: .utf8)?
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return String(text.prefix(200))
    }
}

public enum CursorFetchError: Error {
    case stateDatabaseMissing(path: String)
    case stateDatabaseUnreadable(path: String)
    case sqlite3NotFound
    case sqliteQueryFailed(exitCode: Int, message: String)
    case accessTokenMissing
    case accessTokenExpired(statusCode: Int)
    case usageAPIStatus(statusCode: Int, bodySnippet: String)
    case usagePayloadInvalid
    case metricUnavailable(metricId: String)
    case metricNotAvailableOnPlan(metricId: String, plan: String)
}

/// Cursor plan tier, read from `cursorAuth/stripeMembershipType` in the local state DB.
/// Used to gate the API metric: free users have no separate API quota, so reporting
/// `apiPercentUsed: 0` as "100% remaining" would be misleading.
public enum CursorPlanType: String, Sendable {
    case free
    case pro
    case proUltra = "pro_ultra"
    case business
    case enterprise

    /// Unknown/empty values default to `.free` (the safest gate — blocks the API metric
    /// rather than showing a misleading 100%).
    public init(raw: String) {
        switch raw.lowercased() {
        case "free": self = .free
        case "pro": self = .pro
        case "pro_ultra": self = .proUltra
        case "business": self = .business
        case "enterprise": self = .enterprise
        default: self = .free
        }
    }
}

// Cursor's dashboard endpoint encodes 64-bit timestamps as strings (Connect/gRPC-Web style).
// Only the fields Rashun uses are decoded; spend/threshold fields are intentionally omitted.
public struct CursorUsageResponse: Decodable {
    public let billingCycleStart: String?
    public let billingCycleEnd: String?
    public let planUsage: CursorPlanUsage?

    public init(billingCycleStart: String? = nil, billingCycleEnd: String? = nil, planUsage: CursorPlanUsage? = nil) {
        self.billingCycleStart = billingCycleStart
        self.billingCycleEnd = billingCycleEnd
        self.planUsage = planUsage
    }
}

public struct CursorPlanUsage: Decodable {
    public let autoPercentUsed: Double?
    public let apiPercentUsed: Double?

    public init(autoPercentUsed: Double? = nil, apiPercentUsed: Double? = nil) {
        self.autoPercentUsed = autoPercentUsed
        self.apiPercentUsed = apiPercentUsed
    }
}
