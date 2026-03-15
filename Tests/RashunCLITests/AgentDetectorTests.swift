import Foundation
import XCTest
@testable import RashunCLI
import RashunCore

final class AgentDetectorTests: XCTestCase {
    func testDetectAllIncludesOnlySourcesWithConfigDirectory() throws {
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let installedSource = StubSource(
            name: "Installed",
            agentConfigDirectoryOverride: tempDir
        )
        let missingSource = StubSource(
            name: "Missing",
            agentConfigDirectoryOverride: tempDir + "/missing"
        )
        let noConfigSource = StubSource(
            name: "None",
            agentConfigDirectoryOverride: nil
        )

        let detected = AgentDetector.detectAll(from: [installedSource, missingSource, noConfigSource])

        XCTAssertEqual(detected.count, 2)
        XCTAssertEqual(detected.map(\.source.name), ["Installed", "Missing"])
        XCTAssertTrue(detected[0].isInstalled)
        XCTAssertFalse(detected[1].isInstalled)
    }

    func testDetectInstalledFiltersToExistingConfigDirectories() throws {
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let installedSource = StubSource(
            name: "Installed",
            agentConfigDirectoryOverride: tempDir
        )
        let missingSource = StubSource(
            name: "Missing",
            agentConfigDirectoryOverride: tempDir + "/missing"
        )

        let detected = AgentDetector.detectInstalled(from: [installedSource, missingSource])

        XCTAssertEqual(detected.map(\.source.name), ["Installed"])
        XCTAssertTrue(detected[0].isInstalled)
    }
}

private struct StubSource: AISource {
    let name: String
    let requirements: String = "test"
    let metrics: [AISourceMetric] = [AISourceMetric(id: "test", title: "Test")]
    let agentConfigDirectoryOverride: String?

    init(name: String, agentConfigDirectoryOverride: String?) {
        self.name = name
        self.agentConfigDirectoryOverride = agentConfigDirectoryOverride
    }

    var agentConfigDirectory: String? {
        agentConfigDirectoryOverride
    }
}

private func makeTempDirectory() throws -> String {
    let path = (NSTemporaryDirectory() as NSString).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
}
