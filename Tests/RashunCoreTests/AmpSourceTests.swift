import XCTest

@testable import RashunCore

final class AmpSourceTests: XCTestCase {
    let source = AmpSource()

    // MARK: - parseUsage

    func testMetricBadge() {
        XCTAssertEqual(source.metrics.map(\.menuBarBadgeText), ["Free", "Agent", "Orb"])
        XCTAssertEqual(source.metrics.map(\.defaultEnabled), [false, false, false])
        XCTAssertFalse(source.requiresUsageSampleStability)
        XCTAssertTrue(CodexSource().requiresUsageSampleStability)
    }

    func testDisplayName() {
        XCTAssertEqual(source.displayName, "Amp")
        XCTAssertEqual(source.metrics.map(\.id), ["amp-free", "amp-agent-usage", "amp-orb-usage"])
        XCTAssertEqual(source.metrics.map(\.title), ["Free", "Agent Usage", "Orb Usage"])
    }

    func testParseUsage_validOutput() {
        let result = source.parseUsage(from: "Amp Free: 50% remaining today (resets daily)")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.remaining, 50.0)
        XCTAssertEqual(result?.limit, 100.0)
        XCTAssertNotNil(result?.cycleStartDate)
        XCTAssertNotNil(result?.resetDate)
        XCTAssertGreaterThan(result?.resetDate ?? .distantPast, Date())
    }

    func testParseUsage_zeroRemaining() {
        let result = source.parseUsage(from: "Amp Free: 0% remaining today (resets daily)")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.remaining, 0.0)
        XCTAssertEqual(result?.limit, 100.0)
    }

    func testParseUsage_decimalValues() {
        let result = source.parseUsage(from: "Amp Free: 37.5% remaining today (resets daily)")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.remaining, 37.5)
        XCTAssertEqual(result?.limit, 100.0)
    }

    func testParseUsage_fullRemaining() {
        let result = source.parseUsage(from: "Amp Free: 100% remaining today (resets daily)")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.remaining, 100.0)
        XCTAssertEqual(result?.limit, 100.0)
    }

    func testParseUsage_embeddedInMultilineOutput() {
        let output =
            "Signed in as test\nAmp Free: 75% remaining today (resets daily)\nIndividual credits: $0 remaining"
        let result = source.parseUsage(from: output)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.remaining, 75.0)
        XCTAssertEqual(result?.limit, 100.0)
    }

    func testParseUsage_malformedOutput_returnsNil() {
        XCTAssertNil(source.parseUsage(from: "something else"))
    }

    func testParseUsage_emptyString_returnsNil() {
        XCTAssertNil(source.parseUsage(from: ""))
    }

    func testParseUsage_partialMatch_returnsNil() {
        XCTAssertNil(source.parseUsage(from: "Amp Free: 50% remaining today"))
    }

    func testParseUsage_outOfRangePercentage_returnsNil() {
        XCTAssertNil(source.parseUsage(from: "Amp Free: 101% remaining today (resets daily)"))
    }

    func testParseUsageByMetric_subscriptionOutput() {
        let output = """
            Signed in as test
            Amp Free: 75% remaining today (resets daily)
            Subscription Megawatt: 82.5% other usage and 97.25% orb usage remaining - resets upon renewal in 1 month
            """

        let usages = source.parseUsageByMetric(from: output)

        XCTAssertEqual(usages["amp-free"]?.remaining, 75)
        XCTAssertEqual(usages["amp-agent-usage"]?.remaining, 82.5)
        XCTAssertEqual(usages["amp-agent-usage"]?.limit, 100)
        XCTAssertEqual(usages["amp-orb-usage"]?.remaining, 97.25)
        XCTAssertEqual(usages["amp-orb-usage"]?.limit, 100)
        XCTAssertNil(usages["amp-agent-usage"]?.resetDate)
        XCTAssertNil(usages["amp-orb-usage"]?.resetDate)
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

        XCTAssertNotNil(usages["amp-free"])
        XCTAssertNil(usages["amp-agent-usage"])
        XCTAssertNil(usages["amp-orb-usage"])
    }

    func testParseUsageByMetric_rejectsOutOfRangeSubscriptionPercentage() {
        let output = "Subscription Megawatt: 101% other usage and 50% orb usage remaining"
        let usages = source.parseUsageByMetric(from: output)

        XCTAssertNil(usages["amp-agent-usage"])
        XCTAssertNil(usages["amp-orb-usage"])
    }

    // MARK: - Daily reset schedule (midnight GMT)

    func testParseUsage_resetIsMidnightGMT() {
        let result = source.parseUsage(from: "Amp Free: 50% remaining today (resets daily)")
        guard let reset = result?.resetDate, let cycleStart = result?.cycleStartDate else {
            return XCTFail("Expected cycle start and reset dates")
        }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "GMT")!

        let resetComponents = calendar.dateComponents([.hour, .minute, .second], from: reset)
        XCTAssertEqual(resetComponents.hour, 0)
        XCTAssertEqual(resetComponents.minute, 0)
        XCTAssertEqual(resetComponents.second, 0)

        // Cycle is one GMT calendar day, midnight → midnight.
        let startComponents = calendar.dateComponents([.hour, .minute, .second], from: cycleStart)
        XCTAssertEqual(startComponents.hour, 0)
        XCTAssertEqual(startComponents.minute, 0)
        XCTAssertEqual(startComponents.second, 0)
        XCTAssertEqual(calendar.dateComponents([.day], from: cycleStart, to: reset).day, 1)
        XCTAssertEqual(reset.timeIntervalSince(cycleStart), 24 * 3600, accuracy: 1)

        let now = Date()
        XCTAssertLessThanOrEqual(cycleStart, now)
        XCTAssertGreaterThan(reset, now)
    }

    func testDailyReset_beforeAndAfterMidnightGMT() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "GMT")!

        // 2026-07-14 23:00 GMT — still waiting for midnight Jul 15.
        let beforeMidnight = gmtDate(2026, 7, 14, 23, calendar: calendar)
        // 2026-07-15 00:00 GMT — exactly at reset; next window is Jul 16.
        let atMidnight = gmtDate(2026, 7, 15, 0, calendar: calendar)
        // 2026-07-15 12:00 GMT — midday; next reset is Jul 16 midnight.
        let midday = gmtDate(2026, 7, 15, 12, calendar: calendar)

        let resetBefore = source.dailyResetDate(reference: beforeMidnight)
        let cycleBefore = source.dailyCycleStartDate(reference: beforeMidnight)
        let resetAtBoundary = source.dailyResetDate(reference: atMidnight)
        let cycleAtBoundary = source.dailyCycleStartDate(reference: atMidnight)
        let resetMidday = source.dailyResetDate(reference: midday)
        let cycleMidday = source.dailyCycleStartDate(reference: midday)

        let expectedResetBefore = gmtDate(2026, 7, 15, 0, calendar: calendar)
        let expectedCycleBefore = gmtDate(2026, 7, 14, 0, calendar: calendar)
        let expectedResetAfter = gmtDate(2026, 7, 16, 0, calendar: calendar)
        let expectedCycleAfter = gmtDate(2026, 7, 15, 0, calendar: calendar)

        XCTAssertEqual(resetBefore, expectedResetBefore)
        XCTAssertEqual(cycleBefore, expectedCycleBefore)
        // At/after midnight GMT rolls to the next GMT calendar day at midnight.
        XCTAssertEqual(resetAtBoundary, expectedResetAfter)
        XCTAssertEqual(cycleAtBoundary, expectedCycleAfter)
        XCTAssertEqual(resetMidday, expectedResetAfter)
        XCTAssertEqual(cycleMidday, expectedCycleAfter)

        XCTAssertEqual(
            expectedResetBefore.timeIntervalSince(expectedCycleBefore), 24 * 3600, accuracy: 1)
        XCTAssertEqual(calendar.component(.hour, from: resetBefore!), 0)
        XCTAssertEqual(calendar.component(.hour, from: cycleBefore!), 0)
        XCTAssertEqual(calendar.component(.hour, from: resetMidday!), 0)
        XCTAssertEqual(calendar.component(.hour, from: cycleMidday!), 0)
    }

    func testForecast_usesGMTDailyResetWindow() {
        let usage = source.parseUsage(from: "Amp Free: 40% remaining today (resets daily)")!
        let result = source.forecast(for: source.metrics[0].id, current: usage, history: [])
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.points.last?.value, 100.0)
        if let reset = usage.resetDate, let last = result?.points.last?.date {
            XCTAssertEqual(last.timeIntervalSince1970, reset.timeIntervalSince1970, accuracy: 1)
        }
    }

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
