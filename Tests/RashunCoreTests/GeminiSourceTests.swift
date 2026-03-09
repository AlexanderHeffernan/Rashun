import XCTest
@testable import RashunCore

final class GeminiSourceTests: XCTestCase {
    let source = GeminiSource()

    func testSelectPreferredBucket_prefersFirstConfiguredMetric() {
        let buckets = [
            GeminiQuotaBucket(remainingAmount: "100", remainingFraction: 0.5, resetTime: nil, tokenType: nil, modelId: "gemini-3-flash-preview"),
            GeminiQuotaBucket(remainingAmount: "200", remainingFraction: 0.4, resetTime: nil, tokenType: nil, modelId: "gemini-2.5-flash"),
        ]

        let selected = source.selectPreferredBucket(from: buckets)
        XCTAssertEqual(selected?.modelId, "gemini-2.5-flash")
    }

    func testParseUsage_usesPrimaryProPreviewBucket() {
        let buckets = [
            GeminiQuotaBucket(remainingAmount: "40", remainingFraction: 0.2, resetTime: nil, tokenType: nil, modelId: "gemini-3-pro-preview"),
        ]

        let usage = source.parseUsage(from: buckets)
        XCTAssertNotNil(usage)
        XCTAssertEqual(usage!.remaining, 40, accuracy: 0.001)
        XCTAssertEqual(usage!.limit, 200, accuracy: 0.001)
    }

    func testParseUsage_supportsFractionOnlyBuckets() {
        let buckets = [
            GeminiQuotaBucket(remainingAmount: nil, remainingFraction: 0.56, resetTime: "2026-03-03T23:25:50Z", tokenType: "REQUESTS", modelId: "gemini-3-pro-preview"),
        ]

        let usage = source.parseUsage(from: buckets)
        XCTAssertNotNil(usage)
        XCTAssertEqual(usage!.remaining, 56, accuracy: 0.001)
        XCTAssertEqual(usage!.limit, 100, accuracy: 0.001)
        XCTAssertNotNil(usage!.resetDate)
    }

    func testParseUsage_returnsNilWhenOnlyUnknownModelsExist() {
        let buckets = [
            GeminiQuotaBucket(remainingAmount: nil, remainingFraction: 0.90, resetTime: nil, tokenType: "REQUESTS", modelId: "gemini-unknown-a"),
            GeminiQuotaBucket(remainingAmount: nil, remainingFraction: 0.80, resetTime: nil, tokenType: "REQUESTS", modelId: "gemini-unknown-b"),
        ]

        XCTAssertNil(source.parseUsage(from: buckets))
    }

    func testParseUsage_returnsNilForInvalidFraction() {
        let buckets = [
            GeminiQuotaBucket(remainingAmount: "40", remainingFraction: 0, resetTime: nil, tokenType: nil, modelId: "gemini-3-pro-preview"),
        ]

        XCTAssertNotNil(source.parseUsage(from: buckets))
    }

    func testResolveProjectId_prefersServerProject() {
        let response = GeminiLoadCodeAssistResponse(cloudaicompanionProject: "server-project")
        let project = source.resolveProjectId(from: response, envProject: "env-project")
        XCTAssertEqual(project, "server-project")
    }

    func testResolveProjectId_fallsBackToEnvProject() {
        let response = GeminiLoadCodeAssistResponse(cloudaicompanionProject: nil)
        let project = source.resolveProjectId(from: response, envProject: "env-project")
        XCTAssertEqual(project, "env-project")
    }

    func testForecast_jumpsTo100AtReset() {
        let now = Date()
        let reset = now.addingTimeInterval(3 * 3600)
        let current = UsageResult(remaining: 56, limit: 100, resetDate: reset)
        let history = [
            UsageSnapshot(timestamp: now.addingTimeInterval(-3600), usage: UsageResult(remaining: 70, limit: 100, resetDate: reset)),
            UsageSnapshot(timestamp: now.addingTimeInterval(-1800), usage: UsageResult(remaining: 63, limit: 100, resetDate: reset)),
        ]

        let forecast = source.forecast(for: "gemini-3-pro-preview", current: current, history: history)
        XCTAssertNotNil(forecast)
        XCTAssertEqual(forecast!.points.last!.value, 100, accuracy: 0.001)
        XCTAssertFalse(forecast!.summary.isEmpty)
    }
}
