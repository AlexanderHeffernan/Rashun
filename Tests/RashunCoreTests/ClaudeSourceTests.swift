import XCTest
@testable import RashunCore

final class ClaudeSourceTests: XCTestCase {
    let source = ClaudeSource()

    func testMetricIds() {
        XCTAssertEqual(source.metrics.map(\.id), [
            "claude-session",
            "claude-weekly",
            "claude-weekly-fable",
        ])
    }

    func testMetricBadges() {
        XCTAssertEqual(source.metrics.map(\.menuBarBadgeText), [
            "5h",
            "7d",
            "Fable",
        ])
    }

    func testFableWeeklyMetricIsOptIn() {
        XCTAssertEqual(source.metrics.map(\.defaultEnabled), [true, true, false])
    }

    func testParseUsageByMetric_liveResponse() throws {
        // Trimmed shape captured from api.anthropic.com/api/oauth/usage (Max plan).
        let json = """
            {
              "five_hour": {"utilization": 12.0, "resets_at": "2026-09-25T03:09:59.621245+00:00"},
              "seven_day": {"utilization": 30.5, "resets_at": "2026-09-30T07:59:59.621272+00:00"},
              "seven_day_opus": null,
              "extra_usage": {"is_enabled": false},
              "limits": [
                {"kind": "session", "percent": 12, "resets_at": "2026-09-25T03:09:59.621245+00:00"},
                {"kind": "weekly_all", "percent": 30, "resets_at": "2026-09-30T07:59:59.621272+00:00"},
                {"kind": "weekly_scoped", "percent": 45, "resets_at": "2026-09-30T08:00:00+00:00",
                 "scope": {"model": {"id": null, "display_name": "Fable"}}}
              ]
            }
            """
        let response = try JSONDecoder().decode(ClaudeUsageResponse.self, from: Data(json.utf8))
        let usages = source.parseUsageByMetric(from: response)

        let session = try XCTUnwrap(usages["claude-session"])
        XCTAssertEqual(session.remaining, 88, accuracy: 0.001)
        XCTAssertEqual(session.limit, 100, accuracy: 0.001)
        let sessionReset = try XCTUnwrap(
            ClaudeSource.parseTimestamp("2026-09-25T03:09:59+00:00"))
        XCTAssertEqual(session.resetDate, sessionReset)
        XCTAssertEqual(session.cycleStartDate, sessionReset.addingTimeInterval(-5 * 60 * 60))

        let weekly = try XCTUnwrap(usages["claude-weekly"])
        XCTAssertEqual(weekly.remaining, 69.5, accuracy: 0.001)
        let weeklyReset = try XCTUnwrap(weekly.resetDate)
        XCTAssertEqual(
            try XCTUnwrap(weekly.cycleStartDate).timeIntervalSince1970,
            weeklyReset.addingTimeInterval(-7 * 24 * 60 * 60).timeIntervalSince1970,
            accuracy: 0.001)

        let fable = try XCTUnwrap(usages["claude-weekly-fable"])
        XCTAssertEqual(fable.remaining, 55, accuracy: 0.001)
    }

    func testParseUsageByMetric_unstartedWindowHasNoResetDate() {
        let response = ClaudeUsageResponse(
            fiveHour: ClaudeUsageWindow(utilization: 0, resetsAt: nil),
            sevenDay: ClaudeUsageWindow(utilization: 0, resetsAt: nil)
        )
        let usages = source.parseUsageByMetric(from: response)
        XCTAssertEqual(usages["claude-session"]?.remaining, 100)
        XCTAssertNil(usages["claude-session"]?.resetDate)
        XCTAssertNil(usages["claude-session"]?.cycleStartDate)
    }

    func testParseUsageByMetric_clampsOverage() {
        let response = ClaudeUsageResponse(
            fiveHour: ClaudeUsageWindow(utilization: 130, resetsAt: nil),
            sevenDay: ClaudeUsageWindow(utilization: -5, resetsAt: nil)
        )
        let usages = source.parseUsageByMetric(from: response)
        XCTAssertEqual(usages["claude-session"]?.remaining, 0)
        XCTAssertEqual(usages["claude-weekly"]?.remaining, 100)
    }

    func testParseUsageByMetric_fableWeeklyIgnoresOtherModelScopes() {
        let response = ClaudeUsageResponse(
            limits: [
                ClaudeUsageLimit(
                    kind: "weekly_scoped", percent: 80, resetsAt: nil, modelDisplayName: "Opus"),
                ClaudeUsageLimit(
                    kind: "weekly_scoped", percent: 20, resetsAt: nil, modelDisplayName: "Fable"),
            ]
        )
        let usages = source.parseUsageByMetric(from: response)
        XCTAssertEqual(usages["claude-weekly-fable"]?.remaining, 80)
        XCTAssertNil(usages["claude-session"])
        XCTAssertNil(usages["claude-weekly"])
    }

    func testParseUsageByMetric_skipsMissingFableWeekly() {
        let response = ClaudeUsageResponse(
            fiveHour: ClaudeUsageWindow(utilization: 1, resetsAt: nil),
            limits: [
                ClaudeUsageLimit(kind: "session", percent: 1, resetsAt: nil),
                ClaudeUsageLimit(
                    kind: "weekly_scoped", percent: 10, resetsAt: nil, modelDisplayName: "Opus"),
            ]
        )
        let usages = source.parseUsageByMetric(from: response)
        XCTAssertNil(usages["claude-weekly-fable"])
    }

    func testParseCredentials_validToken() throws {
        let json = """
            {"claudeAiOauth": {"accessToken": "sk-ant-oat01-test", "refreshToken": "r", "expiresAt": 2000000000000}}
            """
        let credentials = try source.parseCredentials(
            from: Data(json.utf8), now: Date(timeIntervalSince1970: 1_900_000_000))
        XCTAssertEqual(credentials.accessToken, "sk-ant-oat01-test")
    }

    func testParseCredentials_expiredToken() {
        let json = """
            {"claudeAiOauth": {"accessToken": "sk-ant-oat01-test", "expiresAt": 1000}}
            """
        XCTAssertThrowsError(
            try source.parseCredentials(from: Data(json.utf8), now: Date())
        ) { error in
            guard case ClaudeFetchError.accessTokenExpired = error else {
                return XCTFail("Expected accessTokenExpired, got \(error)")
            }
        }
    }

    func testParseCredentials_missingOAuthBlock() {
        XCTAssertThrowsError(
            try source.parseCredentials(from: Data("{}".utf8), now: Date())
        ) { error in
            guard case ClaudeFetchError.accessTokenMissing = error else {
                return XCTFail("Expected accessTokenMissing, got \(error)")
            }
        }
    }

    private let cachedUsages = ["claude-session": UsageResult(remaining: 80, limit: 100)]

    func testFetchPlan_emptyCacheFetches() {
        XCTAssertEqual(ClaudeSource.fetchPlan(state: ClaudeUsageCacheState(), now: Date()), .fetch)
    }

    func testFetchPlan_recentResultIsReusedWithinMinimumInterval() {
        let now = Date()
        let state = ClaudeUsageCacheState(fetchedAt: now.addingTimeInterval(-60), usages: cachedUsages)
        XCTAssertEqual(ClaudeSource.fetchPlan(state: state, now: now), .useCached(cachedUsages))
    }

    func testFetchPlan_olderResultFetchesAgain() {
        let now = Date()
        let state = ClaudeUsageCacheState(
            fetchedAt: now.addingTimeInterval(-ClaudeSource.minimumFetchInterval - 1),
            usages: cachedUsages)
        XCTAssertEqual(ClaudeSource.fetchPlan(state: state, now: now), .fetch)
    }

    func testFetchPlan_rateLimitedServesStaleResultWithoutFetching() {
        let now = Date()
        let state = ClaudeUsageCacheState(
            fetchedAt: now.addingTimeInterval(-10 * 60), usages: cachedUsages,
            rateLimitedUntil: now.addingTimeInterval(120))
        XCTAssertEqual(ClaudeSource.fetchPlan(state: state, now: now), .useCached(cachedUsages))
    }

    func testFetchPlan_rateLimitedWithoutUsableResultBlocksUntilRetry() {
        let now = Date()
        let retryAt = now.addingTimeInterval(120)
        let tooOld = ClaudeUsageCacheState(
            fetchedAt: now.addingTimeInterval(-ClaudeSource.staleUsageLimit - 1),
            usages: cachedUsages, rateLimitedUntil: retryAt)
        XCTAssertEqual(ClaudeSource.fetchPlan(state: tooOld, now: now), .rateLimited(retryAt: retryAt))

        let empty = ClaudeUsageCacheState(rateLimitedUntil: retryAt)
        XCTAssertEqual(ClaudeSource.fetchPlan(state: empty, now: now), .rateLimited(retryAt: retryAt))
    }

    func testFetchPlan_expiredRateLimitFetches() {
        let now = Date()
        let state = ClaudeUsageCacheState(rateLimitedUntil: now.addingTimeInterval(-1))
        XCTAssertEqual(ClaudeSource.fetchPlan(state: state, now: now), .fetch)
    }

    func testMapping_rateLimitedMentionsRetry() {
        let error = ClaudeFetchError.rateLimited(retryAt: Date().addingTimeInterval(300))
        let mapped = source.mapFetchError(for: source.metrics[0].id, error)
        XCTAssertEqual(mapped.shortMessage, "Claude API rate limited")
        XCTAssertTrue(mapped.detailedMessage.contains("try again after"))
    }

    func testMapping_credentialsMissing() {
        let error = ClaudeFetchError.credentialsMissing(location: "/Users/test/.claude/.credentials.json")
        let mapped = source.mapFetchError(for: source.metrics[0].id, error)
        XCTAssertEqual(mapped.shortMessage, "Claude Code not signed in")
        XCTAssertTrue(mapped.detailedMessage.contains("/Users/test/.claude/.credentials.json"))
    }

    func testMapping_accessTokenExpired() {
        let error = ClaudeFetchError.accessTokenExpired(statusCode: 401)
        let mapped = source.mapFetchError(for: source.metrics[0].id, error)
        XCTAssertEqual(mapped.shortMessage, "Claude auth expired")
        XCTAssertTrue(mapped.detailedMessage.contains("Open Claude Code"))
    }

    func testMapping_apiStatusIncludesCode() {
        let error = ClaudeFetchError.usageAPIStatus(statusCode: 403, bodySnippet: "forbidden")
        let mapped = source.mapFetchError(for: source.metrics[0].id, error)
        XCTAssertEqual(mapped.shortMessage, "Claude API error (403)")
        XCTAssertTrue(mapped.detailedMessage.contains("HTTP 403"))
    }
}
