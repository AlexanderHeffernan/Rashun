import XCTest
@testable import RashunCore

final class CodexSourceTests: XCTestCase {
    let source = CodexSource()

    func testParseLatestRateLimitSampleParsesInfoRateLimits() {
        let line = #"{"timestamp":"2026-02-05T23:41:03.396Z","type":"event_msg","payload":{"type":"token_count","info":{"rate_limits":{"primary":{"used_percent":73.5,"window_minutes":10080,"resets_at":1770799659}}}}}"#
        let sample = source.parseLatestRateLimitSample(from: line)

        XCTAssertEqual(sample?.timestamp.timeIntervalSince1970 ?? 0, 1_770_334_863.396, accuracy: 0.001)
        XCTAssertEqual(sample?.primary?.usedPercent, 73.5)
        XCTAssertEqual(sample?.primary?.resetsAt, 1770799659)
    }

    func testMetricsExposeFreeWeeklyAndProWindows() {
        XCTAssertEqual(source.metrics.map(\.id), [
            "codex-free-weekly",
            "codex-pro-5h",
            "codex-pro-weekly",
        ])
        XCTAssertEqual(source.metrics.map(\.title), [
            "Free Weekly Usage",
            "Pro 5 Hour",
            "Pro Weekly",
        ])
        XCTAssertEqual(source.metrics.map(\.menuBarBadgeText), [
            "Free",
            "5h",
            "7d",
        ])
    }

    func testParseProUsageByMetricParsesPrimaryAndSecondaryWindows() {
        let response = CodexUsageResponse(
            planType: "pro",
            rateLimit: CodexRateLimit(
                primaryWindow: CodexRateLimitWindow(
                    usedPercent: 37.5,
                    resetAt: 1_778_625_600,
                    limitWindowSeconds: 18_000
                ),
                secondaryWindow: CodexRateLimitWindow(
                    usedPercent: 82,
                    resetAt: 1_779_126_400,
                    limitWindowSeconds: 604_800
                )
            )
        )

        let usages = source.parseProUsageByMetric(from: response)

        XCTAssertEqual(usages["codex-pro-5h"]?.remaining, 62.5)
        XCTAssertEqual(usages["codex-pro-5h"]?.limit, 100)
        XCTAssertEqual(usages["codex-pro-5h"]?.resetDate?.timeIntervalSince1970, 1_778_625_600)
        XCTAssertEqual(usages["codex-pro-5h"]?.cycleStartDate?.timeIntervalSince1970, 1_778_607_600)
        XCTAssertEqual(usages["codex-pro-weekly"]?.remaining, 18)
        XCTAssertEqual(usages["codex-pro-weekly"]?.limit, 100)
    }

    func testParseProUsageByMetricClampsUsedPercent() {
        let overused = CodexUsageResponse(
            rateLimit: CodexRateLimit(
                primaryWindow: CodexRateLimitWindow(usedPercent: 125, limitWindowSeconds: 18_000),
                secondaryWindow: CodexRateLimitWindow(usedPercent: -5, limitWindowSeconds: 604_800)
            )
        )

        let usages = source.parseProUsageByMetric(from: overused)

        XCTAssertEqual(usages["codex-pro-5h"]?.remaining, 0)
        XCTAssertEqual(usages["codex-pro-weekly"]?.remaining, 100)
    }

    func testParseProUsageByMetricClassifiesWeeklyPrimaryWhenFiveHourWindowIsAbsent() {
        let response = CodexUsageResponse(
            rateLimit: CodexRateLimit(
                primaryWindow: CodexRateLimitWindow(
                    usedPercent: 23,
                    resetAt: 1_779_126_400,
                    limitWindowSeconds: 604_800
                )
            )
        )

        let usages = source.parseProUsageByMetric(from: response)

        XCTAssertNil(usages["codex-pro-5h"])
        XCTAssertEqual(usages["codex-pro-weekly"]?.remaining, 77)
        XCTAssertEqual(usages["codex-pro-weekly"]?.cycleStartDate?.timeIntervalSince1970, 1_778_521_600)
    }

    func testParseResetBalanceParsesCreditsObject() throws {
        let data = Data("""
        {
          "plan_type": "pro",
          "rate_limit": {
            "primary_window": { "used_percent": 10, "reset_at": 1783300000 },
            "secondary_window": { "used_percent": 12, "reset_at": 1783800000 }
          },
          "credits": {
            "available": 3,
            "next_expiration_at": "2026-08-05T01:00:00Z"
          }
        }
        """.utf8)

        let balance = source.parseResetBalance(from: data, now: Date(timeIntervalSince1970: 1_783_300_000))

        XCTAssertEqual(balance?.count, 3)
        XCTAssertEqual(balance?.nextExpiration?.timeIntervalSince1970 ?? 0, 1_785_891_600, accuracy: 0.001)
    }

    func testParseResetBalanceParsesRateLimitResetCredits() throws {
        let data = Data("""
        {
          "plan_type": "pro",
          "rate_limit_reset_credits": [
            { "expires_at": "2026-08-01T00:00:00Z" },
            { "expires_at": "2026-08-10T00:00:00Z" },
            { "expires_at": "2026-06-01T00:00:00Z" }
          ]
        }
        """.utf8)

        let balance = source.parseResetBalance(from: data, now: Date(timeIntervalSince1970: 1_783_300_000))

        XCTAssertEqual(balance?.count, 2)
        XCTAssertEqual(balance?.nextExpiration?.timeIntervalSince1970 ?? 0, 1_785_542_400, accuracy: 0.001)
    }

    func testParseResetBalanceParsesNestedRateLimitResetCredits() throws {
        let data = Data("""
        {
          "rate_limit": {
            "primary_window": { "used_percent": 10, "reset_at": 1783300000 },
            "secondary_window": { "used_percent": 12, "reset_at": 1783800000 },
            "rate_limit_reset_credits": [
              { "expires_at": "2026-08-05T01:00:00Z" }
            ]
          }
        }
        """.utf8)

        let balance = source.parseResetBalance(from: data, now: Date(timeIntervalSince1970: 1_783_300_000))

        XCTAssertEqual(balance?.count, 1)
        XCTAssertEqual(balance?.nextExpiration?.timeIntervalSince1970 ?? 0, 1_785_891_600, accuracy: 0.001)
    }

    func testParseResetBalanceParsesNestedCreditExpiration() throws {
        let data = Data("""
        {
          "rate_limit_reset_credits": [
            {
              "rate_limit_reset_credit": {
                "expiresAt": "2026-08-05T01:00:00Z"
              }
            }
          ]
        }
        """.utf8)

        let balance = source.parseResetBalance(from: data, now: Date(timeIntervalSince1970: 1_783_300_000))

        XCTAssertEqual(balance?.count, 1)
        XCTAssertEqual(balance?.nextExpiration?.timeIntervalSince1970 ?? 0, 1_785_891_600, accuracy: 0.001)
    }

    func testParseResetBalanceParsesWhamResetCreditsResponse() throws {
        let data = Data("""
        {
          "credits": [
            {
              "id": "RateLimitResetCredit_1",
              "reset_type": "codex_rate_limits",
              "status": "available",
              "granted_at": "2026-06-27T00:11:01.944811Z",
              "expires_at": "2026-07-27T00:11:01.944811Z",
              "redeem_started_at": null,
              "redeemed_at": null,
              "title": "Full reset (Weekly + 5 hr)"
            },
            {
              "id": "RateLimitResetCredit_2",
              "reset_type": "codex_rate_limits",
              "status": "available",
              "granted_at": "2026-07-01T20:33:55.453066Z",
              "expires_at": "2026-07-31T20:33:55.453066Z",
              "redeem_started_at": null,
              "redeemed_at": null,
              "title": "Full reset (Weekly + 5 hr)"
            }
          ],
          "available_count": 2,
          "total_earned_count": 0
        }
        """.utf8)

        let balance = source.parseResetBalance(from: data, now: Date(timeIntervalSince1970: 1_783_300_000))

        XCTAssertEqual(balance?.count, 2)
        XCTAssertEqual(balance?.nextExpiration?.timeIntervalSince1970 ?? 0, 1_785_111_061.944811, accuracy: 0.001)
    }

    func testParseResetBalanceCountsActiveCreditGrants() throws {
        let data = Data("""
        {
          "usage_resets": {
            "grants": [
              { "expires_at": "2026-08-01T00:00:00Z" },
              { "expires_at": "2026-08-10T00:00:00Z" },
              { "expires_at": "2026-06-01T00:00:00Z" }
            ]
          }
        }
        """.utf8)

        let balance = source.parseResetBalance(from: data, now: Date(timeIntervalSince1970: 1_783_300_000))

        XCTAssertEqual(balance?.count, 2)
        XCTAssertEqual(balance?.nextExpiration?.timeIntervalSince1970 ?? 0, 1_785_542_400, accuracy: 0.001)
    }

    func testParseLatestRateLimitSampleParsesPayloadLevelRateLimits() {
        let line = #"{"timestamp":"2026-03-02T23:13:10.936Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"limit_id":"codex","primary":{"used_percent":4.0,"window_minutes":10080,"resets_at":1772691486}}}}"#
        let sample = source.parseLatestRateLimitSample(from: line)

        XCTAssertEqual(sample?.timestamp.timeIntervalSince1970 ?? 0, 1_772_493_190.936, accuracy: 0.001)
        XCTAssertEqual(sample?.primary?.usedPercent, 4.0)
        XCTAssertEqual(sample?.primary?.resetsAt, 1772691486)
    }

    func testParseLatestRateLimitSampleParsesTopLevelRateLimits() {
        let line = #"{"timestamp":"2026-05-12T22:39:49.548Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1717179}}},"rate_limits":{"limit_id":"codex","primary":{"used_percent":5.0,"window_minutes":300,"resets_at":1778642727},"secondary":{"used_percent":1.0,"window_minutes":10080,"resets_at":1779229527},"plan_type":"plus"}}"#
        let sample = source.parseLatestRateLimitSample(from: line)

        XCTAssertEqual(sample?.timestamp.timeIntervalSince1970 ?? 0, 1_778_625_589.548, accuracy: 0.001)
        XCTAssertEqual(sample?.primary?.usedPercent, 5.0)
        XCTAssertEqual(sample?.primary?.windowMinutes, 300)
        XCTAssertEqual(sample?.primary?.resetsAt, 1_778_642_727)
    }

    func testParseLatestRateLimitSampleParsesSecondaryWindowAndPlan() {
        let line = #"{"timestamp":"2026-05-12T22:39:49.548Z","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1717179}}},"rate_limits":{"limit_id":"codex","primary":{"used_percent":5.0,"window_minutes":300,"resets_at":1778642727},"secondary":{"used_percent":1.0,"window_minutes":10080,"resets_at":1779229527},"plan_type":"plus"}}"#
        let sample = source.parseLatestRateLimitSample(from: line)

        XCTAssertEqual(sample?.planType, "plus")
        XCTAssertEqual(sample?.primary?.usedPercent, 5.0)
        XCTAssertEqual(sample?.primary?.windowMinutes, 300)
        XCTAssertEqual(sample?.secondary?.usedPercent, 1.0)
        XCTAssertEqual(sample?.secondary?.windowMinutes, 10_080)
    }

    func testParseLatestRateLimitSampleIgnoresNonCodexLimitID() {
        let line = #"{"timestamp":"2026-03-02T23:13:10.936Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"limit_id":"something_else","primary":{"used_percent":4.0,"window_minutes":10080,"resets_at":1772691486}}}}"#
        let sample = source.parseLatestRateLimitSample(from: line)

        XCTAssertNil(sample)
    }

    func testParseLatestRateLimitSampleUsesLatestMatchingLine() {
        let content = """
        {"timestamp":"2026-03-02T10:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"rate_limits":{"primary":{"used_percent":90.0}}}}}
        {"timestamp":"2026-03-02T11:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"rate_limits":{"primary":{"used_percent":40.0}}}}}
        """

        let sample = source.parseLatestRateLimitSample(from: content)
        XCTAssertEqual(sample?.primary?.usedPercent, 40.0)
    }

    func testNumericValueSupportsIntDoubleAndNSNumber() {
        XCTAssertEqual(source.numericValue(5), 5)
        XCTAssertEqual(source.numericValue(12.5), 12.5)
        XCTAssertEqual(source.numericValue(NSNumber(value: 8.25)), 8.25)
        XCTAssertNil(source.numericValue("10"))
    }

    func testForecast_jumpsTo100AtReset() {
        let now = Date()
        let reset = now.addingTimeInterval(6 * 3600)
        let current = UsageResult(remaining: 45, limit: 100, resetDate: reset)
        let history = [
            UsageSnapshot(timestamp: now.addingTimeInterval(-2 * 3600), usage: UsageResult(remaining: 70, limit: 100, resetDate: reset)),
            UsageSnapshot(timestamp: now.addingTimeInterval(-3600), usage: UsageResult(remaining: 58, limit: 100, resetDate: reset)),
        ]

        let forecast = source.forecast(for: source.metrics[0].id, current: current, history: history)
        XCTAssertNotNil(forecast)
        XCTAssertEqual(forecast!.points.last!.value, 100, accuracy: 0.001)
        XCTAssertTrue(forecast!.summary.contains("resets"))
    }

    func testForecast_ignoresOldCycleHistoryAfterResetChange() {
        let now = Date()
        let oldReset = now.addingTimeInterval(2 * 3600)
        let newReset = now.addingTimeInterval(5 * 24 * 3600)
        let current = UsageResult(
            remaining: 100,
            limit: 100,
            resetDate: newReset,
            cycleStartDate: now.addingTimeInterval(-30 * 60)
        )
        let history = [
            // Old cycle trend that should not influence the new cycle forecast.
            UsageSnapshot(timestamp: now.addingTimeInterval(-3 * 3600), usage: UsageResult(remaining: 70, limit: 100, resetDate: oldReset)),
            UsageSnapshot(timestamp: now.addingTimeInterval(-2 * 3600), usage: UsageResult(remaining: 40, limit: 100, resetDate: oldReset)),
            // New cycle sample is still full.
            UsageSnapshot(timestamp: now.addingTimeInterval(-10 * 60), usage: UsageResult(remaining: 100, limit: 100, resetDate: newReset)),
        ]

        let forecast = source.forecast(for: source.metrics[0].id, current: current, history: history)
        XCTAssertNotNil(forecast)
        XCTAssertFalse(forecast!.summary.contains("projected 0%"))
        XCTAssertTrue(forecast!.points.allSatisfy { abs($0.value - 100) < 0.001 })
    }
}
