import XCTest
@testable import RashunCore

final class CursorSourceTests: XCTestCase {
    let source = CursorSource()

    func testMetricBadges() {
        XCTAssertEqual(source.metrics.map(\.menuBarBadgeText), [
            "Auto",
            "API",
        ])
    }

    func testMetricIds() {
        XCTAssertEqual(source.metrics.map(\.id), [
            "cursor-auto",
            "cursor-api",
        ])
    }

    func testParseUsageByMetric_liveResponse() {
        // Shape captured from Cursor's GetCurrentPeriodUsage endpoint (free tier, exhausted).
        // autoPercentUsed: 100 -> 0% remaining (the bucket that actually gates usage).
        // apiPercentUsed: 0 -> 100% remaining (but gated out for free users at fetch time).
        let response = CursorUsageResponse(
            billingCycleStart: "1783547816429",
            billingCycleEnd: "1786226216429",
            planUsage: CursorPlanUsage(
                autoPercentUsed: 100,
                apiPercentUsed: 0
            )
        )

        let usages = source.parseUsageByMetric(from: response)

        let auto = usages["cursor-auto"]
        XCTAssertNotNil(auto)
        XCTAssertEqual(auto!.remaining, 0, accuracy: 0.001)
        XCTAssertEqual(auto!.limit, 100, accuracy: 0.001)

        let api = usages["cursor-api"]
        XCTAssertNotNil(api)
        XCTAssertEqual(api!.remaining, 100, accuracy: 0.001)
        XCTAssertEqual(api!.limit, 100, accuracy: 0.001)

        // Both share the billing-cycle window derived from the ms-string timestamps.
        let expectedReset = Date(timeIntervalSince1970: 1786226216429 / 1000)
        let expectedCycleStart = Date(timeIntervalSince1970: 1783547816429 / 1000)
        for usage in usages.values {
            XCTAssertEqual(usage.resetDate!.timeIntervalSince1970, expectedReset.timeIntervalSince1970, accuracy: 0.001)
            XCTAssertEqual(usage.cycleStartDate!.timeIntervalSince1970, expectedCycleStart.timeIntervalSince1970, accuracy: 0.001)
        }
    }

    func testParseUsageByMetric_partialUsage() {
        let response = CursorUsageResponse(
            billingCycleStart: "1783547816429",
            billingCycleEnd: "1786226216429",
            planUsage: CursorPlanUsage(autoPercentUsed: 44, apiPercentUsed: 10)
        )

        let usages = source.parseUsageByMetric(from: response)
        XCTAssertEqual(usages["cursor-auto"]!.remaining, 56, accuracy: 0.001)
        XCTAssertEqual(usages["cursor-api"]!.remaining, 90, accuracy: 0.001)
    }

    func testParseUsageByMetric_clampsOverage() {
        let response = CursorUsageResponse(
            billingCycleStart: "1783547816429",
            billingCycleEnd: "1786226216429",
            planUsage: CursorPlanUsage(autoPercentUsed: 130, apiPercentUsed: 100)
        )

        let usages = source.parseUsageByMetric(from: response)
        XCTAssertEqual(usages["cursor-auto"]!.remaining, 0, accuracy: 0.001)
        XCTAssertEqual(usages["cursor-api"]!.remaining, 0, accuracy: 0.001)
    }

    func testParseUsageByMetric_skipsMissingFields() {
        let response = CursorUsageResponse(
            billingCycleStart: "1783547816429",
            billingCycleEnd: "1786226216429",
            planUsage: CursorPlanUsage(autoPercentUsed: nil, apiPercentUsed: 10)
        )

        let usages = source.parseUsageByMetric(from: response)
        XCTAssertNil(usages["cursor-auto"])
        XCTAssertEqual(usages["cursor-api"]!.remaining, 90, accuracy: 0.001)
    }

    func testParseUsageByMetric_emptyWhenPlanUsageMissing() {
        let response = CursorUsageResponse(
            billingCycleStart: "1783547816429",
            billingCycleEnd: "1786226216429",
            planUsage: nil
        )

        XCTAssertTrue(source.parseUsageByMetric(from: response).isEmpty)
    }

    func testFetchUsage_unsupportedMetricThrows() async {
        do {
            _ = try await source.fetchUsage(for: "not-a-cursor-metric")
            XCTFail("Expected unsupported metric error")
        } catch {
            // expected
        }
    }

    func testPlanType_recognizesKnownTiers() {
        XCTAssertEqual(CursorPlanType(raw: "free"), .free)
        XCTAssertEqual(CursorPlanType(raw: "pro"), .pro)
        XCTAssertEqual(CursorPlanType(raw: "pro_ultra"), .proUltra)
        XCTAssertEqual(CursorPlanType(raw: "business"), .business)
        XCTAssertEqual(CursorPlanType(raw: "enterprise"), .enterprise)
    }

    func testPlanType_unknownDefaultsToFree() {
        XCTAssertEqual(CursorPlanType(raw: ""), .free)
        XCTAssertEqual(CursorPlanType(raw: "unknown"), .free)
        XCTAssertEqual(CursorPlanType(raw: "FREE"), .free)
    }

    func testFetchUsage_apiMetricThrowsOnFreePlan() async {
        // Free users have no separate API quota. The source should surface a plan-specific
        // error rather than a misleading 100% ring. We can't easily inject the DB read in a
        // unit test, so we verify the error type + mapping directly.
        let error = CursorFetchError.metricNotAvailableOnPlan(metricId: "cursor-api", plan: "free")
        let mapped = source.mapFetchError(for: "cursor-api", error)
        XCTAssertEqual(mapped.shortMessage, "API models unavailable on Free")
        XCTAssertTrue(mapped.detailedMessage.contains("Free plan"))
        XCTAssertTrue(mapped.detailedMessage.contains("Pro"))
    }

    func testForecast_jumpsTo100AtReset() {
        let now = Date()
        let reset = now.addingTimeInterval(3 * 3600)
        let current = UsageResult(remaining: 56, limit: 100, resetDate: reset)
        let history = [
            UsageSnapshot(timestamp: now.addingTimeInterval(-3600), usage: UsageResult(remaining: 70, limit: 100, resetDate: reset)),
            UsageSnapshot(timestamp: now.addingTimeInterval(-1800), usage: UsageResult(remaining: 63, limit: 100, resetDate: reset)),
        ]

        let forecast = source.forecast(for: "cursor-auto", current: current, history: history)
        XCTAssertNotNil(forecast)
        XCTAssertEqual(forecast!.points.last!.value, 100, accuracy: 0.001)
        XCTAssertFalse(forecast!.summary.isEmpty)
    }
}
