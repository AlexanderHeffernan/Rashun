import XCTest

@testable import RashunCore

final class AmpSourceTests: XCTestCase {
    let source = AmpSource()

    // MARK: - parseUsageByMetric

    func testMetricBadge() {
        XCTAssertEqual(source.metrics.map(\.menuBarBadgeText), ["Agent", "Orb"])
        XCTAssertEqual(source.metrics.map(\.defaultEnabled), [false, false])
        XCTAssertFalse(source.requiresUsageSampleStability)
        XCTAssertTrue(CodexSource().requiresUsageSampleStability)
    }

    func testDisplayName() {
        XCTAssertEqual(source.displayName, "Amp")
        XCTAssertEqual(source.metrics.map(\.id), ["amp-agent-usage", "amp-orb-usage"])
        XCTAssertEqual(source.metrics.map(\.title), ["Agent Usage", "Orb Usage"])
    }

    func testParseUsageByMetric_subscriptionOutput() {
        let output = """
            Signed in as test
            Amp Free: 75% remaining today (resets daily)
            Subscription Megawatt: 82.5% other usage and 97.25% orb usage remaining - resets upon renewal in 1 month
            """

        let usages = source.parseUsageByMetric(from: output)

        XCTAssertNil(usages["amp-free"])
        XCTAssertEqual(usages["amp-agent-usage"]?.remaining, 82.5)
        XCTAssertEqual(usages["amp-agent-usage"]?.limit, 100)
        XCTAssertEqual(usages["amp-orb-usage"]?.remaining, 97.25)
        XCTAssertEqual(usages["amp-orb-usage"]?.limit, 100)
        XCTAssertNil(usages["amp-agent-usage"]?.resetDate)
        XCTAssertNil(usages["amp-orb-usage"]?.resetDate)
    }

    func testParseUsageByMetric_currentSubscriptionOutput() {
        let output = """
            Signed in as test@example.com (test)
            **Amp Megawatt Subscription:** 52% other usage and 92% orb usage remaining - resets upon renewal in 2 days

            # Run `amp usage --details` for more detailed information.
            """

        let usages = source.parseUsageByMetric(from: output)

        XCTAssertEqual(usages["amp-agent-usage"]?.remaining, 52)
        XCTAssertEqual(usages["amp-orb-usage"]?.remaining, 92)
    }

    func testParseUsageByMetric_allowanceFirstSubscriptionOutput() {
        let output = """
            Signed in as test@example.com (test)
            **Amp Megawatt Tier:** agent usage $19.08 of $20 remaining (95%), orb usage 728.3h of 750h a1.small orb hours remaining (97%) - period 2026-08-24 to 2026-09-24, resets upon renewal in 14 days
            **Individual credits:** $44.82 remaining (set up auto-reload to avoid running out) - https://ampcode.com/settings

            # Run `amp usage --details` for more detailed information.
            """

        let usages = source.parseUsageByMetric(from: output)
        let creditBalance = source.parseCreditBalance(from: output)

        XCTAssertEqual(usages["amp-agent-usage"]?.remaining, 95)
        XCTAssertEqual(usages["amp-agent-usage"]?.limit, 100)
        XCTAssertEqual(usages["amp-orb-usage"]?.remaining, 97)
        XCTAssertEqual(usages["amp-orb-usage"]?.limit, 100)
        XCTAssertEqual(creditBalance, AmpCreditBalance(amount: 44.82))
        XCTAssertEqual(creditBalance?.formatted, "$44.82 USD Balance")
    }

    func testParseCreditBalance_acceptsUSDAndThousandsSeparators() {
        let balance = source.parseCreditBalance(
            from: "Individual credits: $1,234.50 USD remaining")

        XCTAssertEqual(balance, AmpCreditBalance(amount: 1_234.50))
        XCTAssertEqual(balance?.formatted, "$1234.50 USD Balance")
        XCTAssertNil(source.parseCreditBalance(from: "Individual credits unavailable"))
    }

    func testAmpRefreshIntervalHonorsEndpointRateLimit() {
        XCTAssertEqual(AmpSource.minimumRefreshInterval, 2 * 60)
    }

    func testParseUsageByMetric_acceptsAgentUsageTerminology() {
        let output =
            "Subscription Gigawatt: 12% agent usage and 34% orb usage remaining - resets upon renewal in 2 weeks"
        let usages = source.parseUsageByMetric(from: output)

        XCTAssertEqual(usages["amp-agent-usage"]?.remaining, 12)
        XCTAssertEqual(usages["amp-orb-usage"]?.remaining, 34)
    }

    func testParseUsageByMetric_freeAccountOmitsSubscriptionMetrics() {
        let usages = source.parseUsageByMetric(
            from: "Amp Free: 50% remaining today (resets daily)")

        XCTAssertNil(usages["amp-free"])
        XCTAssertNil(usages["amp-agent-usage"])
        XCTAssertNil(usages["amp-orb-usage"])
    }

    func testParseUsageByMetric_rejectsOutOfRangeSubscriptionPercentage() {
        let output = "Subscription Megawatt: 101% other usage and 50% orb usage remaining"
        let usages = source.parseUsageByMetric(from: output)

        XCTAssertNil(usages["amp-agent-usage"])
        XCTAssertNil(usages["amp-orb-usage"])
    }

    // MARK: - Subscription cycle inference

    func testSubscriptionMetricsDoNotForecastBeforeRenewalIncrease() {
        let current = UsageResult(remaining: 80, limit: 100)

        XCTAssertNil(
            source.forecast(
                for: "amp-agent-usage", current: current, history: []))
    }

    func testInferredSubscriptionCycleUsesLatestSubstantialIncrease() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "GMT")!
        let history = [
            snapshot(80, at: gmtDate(2026, 2, 12, 8, calendar: calendar)),
            snapshot(30, at: gmtDate(2026, 1, 10, 8, calendar: calendar)),
            snapshot(92, at: gmtDate(2026, 2, 10, 8, calendar: calendar)),
            snapshot(72, at: gmtDate(2026, 1, 20, 8, calendar: calendar)),
            snapshot(90, at: gmtDate(2026, 2, 11, 8, calendar: calendar)),
            snapshot(70, at: gmtDate(2026, 2, 9, 8, calendar: calendar)),
        ]

        let cycle = source.inferredSubscriptionCycle(
            history: history,
            now: gmtDate(2026, 2, 20, 8, calendar: calendar),
            calendar: calendar
        )

        XCTAssertEqual(cycle?.start, gmtDate(2026, 2, 10, 8, calendar: calendar))
        XCTAssertEqual(cycle?.reset, gmtDate(2026, 3, 10, 8, calendar: calendar))
    }

    func testInferredSubscriptionCycleIgnoresSmallCorrectionsAndRollsForward() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "GMT")!
        let history = [
            snapshot(30, at: gmtDate(2026, 1, 14, 9, calendar: calendar)),
            snapshot(85, at: gmtDate(2026, 1, 15, 9, calendar: calendar)),
            snapshot(40, at: gmtDate(2026, 1, 20, 9, calendar: calendar)),
            snapshot(48, at: gmtDate(2026, 2, 1, 9, calendar: calendar)),
        ]

        let cycle = source.inferredSubscriptionCycle(
            history: history,
            now: gmtDate(2026, 3, 1, 9, calendar: calendar),
            calendar: calendar
        )

        XCTAssertEqual(cycle?.start, gmtDate(2026, 2, 15, 9, calendar: calendar))
        XCTAssertEqual(cycle?.reset, gmtDate(2026, 3, 15, 9, calendar: calendar))
    }

    func testSubscriptionForecastUsesInferredMonthlyReset() {
        let now = Date()
        let full = now.addingTimeInterval(-7 * 24 * 3600)
        let history = [
            snapshot(30, at: full.addingTimeInterval(-60)),
            snapshot(92, at: full),
            snapshot(80, at: now.addingTimeInterval(-2 * 24 * 3600)),
            snapshot(70, at: now),
        ]

        let forecast = source.forecast(
            for: "amp-agent-usage", current: history.last!.usage, history: history)

        XCTAssertNotNil(forecast)
        XCTAssertEqual(forecast?.points.last?.value, 100)
        XCTAssertTrue(forecast?.summary.contains("Agent Usage") == true)
        XCTAssertEqual(source.forecastHistoryWindowHours(for: "amp-orb-usage"), 31 * 24)
    }

    func testResolvedUsageDetectsCurrentRenewalAndAddsCycleBoundaries() {
        let now = Date()
        let history = [snapshot(30, at: now.addingTimeInterval(-60))]

        let resolved = source.resolvedUsage(
            for: "amp-orb-usage",
            current: UsageResult(remaining: 92, limit: 100),
            history: history,
            now: now
        )

        XCTAssertEqual(resolved.cycleStartDate, now)
        XCTAssertNotNil(resolved.resetDate)
        XCTAssertGreaterThan(resolved.resetDate ?? .distantPast, now)
    }

    func testResolvedCycleSupportsPacingAssessmentAndGuide() {
        let now = Date()
        let renewal = now.addingTimeInterval(-10 * 24 * 3600)
        var history = [
            snapshot(20, at: renewal.addingTimeInterval(-60)),
            snapshot(90, at: renewal),
        ]
        history.append(
            contentsOf: (1...10).map { day in
                snapshot(
                    90 - Double(day * 5),
                    at: renewal.addingTimeInterval(Double(day) * 24 * 3600))
            })
        let current = history.last!.usage
        let resolved = source.resolvedUsage(
            for: "amp-agent-usage", current: current, history: history, now: now)

        let assessment = source.pacingAssessment(
            for: "amp-agent-usage", current: current, history: history, now: now)
        XCTAssertNotNil(assessment)
        XCTAssertTrue(
            assessment.map {
                [.conserveLightly, .conserve, .conserveHard].contains($0.recommendation)
            } == true)
        XCTAssertNotNil(
            UsageForecastEngine.resetWindowPaceGuide(
                current: resolved,
                history: history,
                resetDate: resolved.resetDate!,
                now: now
            ))

        let pacingRule = source.notificationDefinitions(for: "amp-agent-usage")
            .first(where: { $0.id == "pacingAlert" })!
        let context = NotificationContext(
            sourceName: source.name,
            metricId: "amp-agent-usage",
            metricTitle: "Agent Usage",
            current: resolved,
            previous: history.dropLast().last,
            history: history,
            now: now,
            inputValue: { _, defaultValue in defaultValue }
        )
        XCTAssertNotNil(pacingRule.evaluate(context))
    }

    private func snapshot(_ percentRemaining: Double, at timestamp: Date) -> UsageSnapshot {
        UsageSnapshot(
            timestamp: timestamp,
            usage: UsageResult(remaining: percentRemaining, limit: 100)
        )
    }

    private func gmtDate(
        _ year: Int,
        _ month: Int,
        _ day: Int,
        _ hour: Int,
        calendar: Calendar
    ) -> Date {
        calendar.date(
            from: DateComponents(
                timeZone: TimeZone(identifier: "GMT")!,
                year: year,
                month: month,
                day: day,
                hour: hour,
                minute: 0,
                second: 0
            ))!
    }
}
