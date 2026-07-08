import XCTest
@testable import RashunCore

final class SourceErrorMappingTests: XCTestCase {
    func testAmpMapping_missingBinary() {
        let source = AmpSource()
        let error = AmpFetchError.binaryMissing(path: "/Users/test/.amp/bin/amp")
        let mapped = source.mapFetchError(for: source.metrics[0].id, error)
        XCTAssertEqual(mapped.shortMessage, "AMP CLI not found")
        XCTAssertTrue(mapped.detailedMessage.contains("/Users/test/.amp/bin/amp"))
    }

    func testCopilotMapping_missingAuthToken() {
        let source = CopilotSource()
        let error = CopilotFetchError.ghNoToken(stderr: "authentication required")
        let mapped = source.mapFetchError(for: source.metrics[0].id, error)
        XCTAssertEqual(mapped.shortMessage, "Copilot auth missing")
        XCTAssertTrue(mapped.detailedMessage.contains("gh auth login"))
    }

    func testCopilotMapping_apiStatusIncludesCode() {
        let source = CopilotSource()
        let error = CopilotFetchError.apiStatus(statusCode: 401, bodySnippet: "{\"message\":\"Bad credentials\"}")
        let mapped = source.mapFetchError(for: source.metrics[0].id, error)
        XCTAssertEqual(mapped.shortMessage, "Copilot API error (401)")
        XCTAssertTrue(mapped.detailedMessage.contains("HTTP 401"))
    }

    func testCodexMapping_noSessions() {
        let source = CodexSource()
        let error = CodexFetchError.noSessionFiles(path: "/Users/test/.codex/sessions")
        let mapped = source.mapFetchError(for: source.metrics[0].id, error)
        XCTAssertEqual(mapped.shortMessage, "No Codex sessions found")
        XCTAssertTrue(mapped.detailedMessage.contains("/Users/test/.codex/sessions"))
    }

    func testGeminiMapping_loadCodeAssistStatusIncludesCode() {
        let source = GeminiSource()
        let error = GeminiFetchError.loadCodeAssistFailed(statusCode: 403, bodySnippet: "{\"error\":\"forbidden\"}")
        let mapped = source.mapFetchError(for: "gemini-3-pro-preview", error)
        XCTAssertEqual(mapped.shortMessage, "Gemini API error (403)")
        XCTAssertTrue(mapped.detailedMessage.contains("HTTP 403"))
    }

    func testCursorMapping_stateDatabaseMissing() {
        let source = CursorSource()
        let error = CursorFetchError.stateDatabaseMissing(path: "/Users/test/Library/Application Support/Cursor/User/globalStorage/state.vscdb")
        let mapped = source.mapFetchError(for: source.metrics[0].id, error)
        XCTAssertEqual(mapped.shortMessage, "Cursor state database missing")
        XCTAssertTrue(mapped.detailedMessage.contains("state.vscdb"))
    }

    func testCursorMapping_accessTokenExpired() {
        let source = CursorSource()
        let error = CursorFetchError.accessTokenExpired(statusCode: 401)
        let mapped = source.mapFetchError(for: source.metrics[0].id, error)
        XCTAssertEqual(mapped.shortMessage, "Cursor auth expired")
        XCTAssertTrue(mapped.detailedMessage.contains("HTTP 401"))
        XCTAssertTrue(mapped.detailedMessage.contains("Open Cursor"))
    }

    func testCursorMapping_apiNotAvailableOnFreePlan() {
        let source = CursorSource()
        let error = CursorFetchError.metricNotAvailableOnPlan(metricId: "cursor-api", plan: "free")
        let mapped = source.mapFetchError(for: "cursor-api", error)
        XCTAssertEqual(mapped.shortMessage, "API models unavailable on Free")
        XCTAssertTrue(mapped.detailedMessage.contains("Free plan"))
        XCTAssertTrue(mapped.detailedMessage.contains("Pro"))
    }
}
