import Foundation
import XCTest
@testable import RashunCLI
import RashunCore

final class SkillGeneratorTests: XCTestCase {
    func testGenerateIncludesMarkersAndAgentDetails() {
        let source = StubSource(
            name: "TestSource",
            agentNameOverride: "Test Agent"
        )

        let text = SkillGenerator.generate(for: source)

        XCTAssertTrue(text.contains(SkillGenerator.startMarker))
        XCTAssertTrue(text.contains(SkillGenerator.endMarker))
        XCTAssertTrue(text.contains("You are Test Agent"))
        XCTAssertTrue(text.contains("\"TestSource\" quota"))
        XCTAssertTrue(text.contains("rashun status testsource --json"))
        XCTAssertTrue(text.contains("rashun forecast testsource --json"))
    }
}

private struct StubSource: AISource {
    let name: String
    let requirements: String = "test"
    let metrics: [AISourceMetric] = [AISourceMetric(id: "test", title: "Test")]
    let agentNameOverride: String?

    init(name: String, agentNameOverride: String? = nil) {
        self.name = name
        self.agentNameOverride = agentNameOverride
    }

    var agentName: String {
        agentNameOverride ?? name
    }
}
