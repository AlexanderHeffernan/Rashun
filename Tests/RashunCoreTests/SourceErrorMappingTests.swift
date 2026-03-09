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
}
