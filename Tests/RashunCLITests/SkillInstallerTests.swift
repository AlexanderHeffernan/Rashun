import Foundation
import XCTest
@testable import RashunCLI
import RashunCore

final class SkillInstallerTests: XCTestCase {
    func testInstallCreatesFileWhenMissing() throws {
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let path = (tempDir as NSString).appendingPathComponent("AGENTS.md")
        let source = StubSource(name: "Test", instructionPath: path)

        let result = try SkillInstaller.install(for: source)

        if case .installed = result {
        } else {
            XCTFail("Expected install result to be installed")
        }

        let content = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(content.contains(SkillGenerator.startMarker))
        XCTAssertTrue(content.contains(SkillGenerator.endMarker))
    }

    func testInstallAppendsAndCreatesBackupWhenFileExistsWithoutMarkers() throws {
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let path = (tempDir as NSString).appendingPathComponent("AGENTS.md")
        let original = "Existing instructions\nLine two"
        try original.write(toFile: path, atomically: true, encoding: .utf8)

        let source = StubSource(name: "Test", instructionPath: path)
        let result = try SkillInstaller.install(for: source)

        if case .installed = result {
        } else {
            XCTFail("Expected install result to be installed")
        }

        let backupPath = path + ".bak"
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupPath))
        let backupContent = try String(contentsOfFile: backupPath, encoding: .utf8)
        XCTAssertEqual(backupContent, original)

        let updated = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(updated.contains(original))
        XCTAssertTrue(updated.contains(SkillGenerator.startMarker))
    }

    func testInstallReplacesExistingMarkerSection() throws {
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let path = (tempDir as NSString).appendingPathComponent("AGENTS.md")
        let oldSource = StubSource(name: "Old", instructionPath: path, agentNameOverride: "Old Agent")
        let newSource = StubSource(name: "New", instructionPath: path, agentNameOverride: "New Agent")
        let original = "Before\n" + SkillGenerator.generate(for: oldSource) + "\nAfter\n"
        try original.write(toFile: path, atomically: true, encoding: .utf8)

        let result = try SkillInstaller.install(for: newSource)

        if case .updated = result {
        } else {
            XCTFail("Expected install result to be updated")
        }

        let updated = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(updated.contains("You are New Agent"))
        XCTAssertFalse(updated.contains("You are Old Agent"))
        XCTAssertTrue(updated.contains("Before"))
        XCTAssertTrue(updated.contains("After"))
        let occurrences = updated.components(separatedBy: SkillGenerator.startMarker).count - 1
        XCTAssertEqual(occurrences, 1)
    }

    func testRemoveDeletesFileWhenOnlyMarkersPresent() throws {
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let path = (tempDir as NSString).appendingPathComponent("AGENTS.md")
        let source = StubSource(name: "Test", instructionPath: path)
        let text = SkillGenerator.generate(for: source)
        try text.write(toFile: path, atomically: true, encoding: .utf8)

        let result = try SkillInstaller.remove(for: source)

        if case .removed = result {
        } else {
            XCTFail("Expected remove result to be removed")
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
    }

    func testRemoveStripsSectionLeavesOtherContent() throws {
        let tempDir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(atPath: tempDir) }

        let path = (tempDir as NSString).appendingPathComponent("AGENTS.md")
        let source = StubSource(name: "Test", instructionPath: path)
        let content = "Before\n\n" + SkillGenerator.generate(for: source) + "\n\nAfter\n"
        try content.write(toFile: path, atomically: true, encoding: .utf8)

        let result = try SkillInstaller.remove(for: source)

        if case .removed = result {
        } else {
            XCTFail("Expected remove result to be removed")
        }

        let cleaned = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(cleaned.contains("Before"))
        XCTAssertTrue(cleaned.contains("After"))
        XCTAssertFalse(cleaned.contains(SkillGenerator.startMarker))
        XCTAssertFalse(cleaned.contains(SkillGenerator.endMarker))
    }
}

private struct StubSource: AISource {
    let name: String
    let requirements: String = "test"
    let metrics: [AISourceMetric] = [AISourceMetric(id: "test", title: "Test")]
    let instructionPath: String?
    let agentNameOverride: String?

    init(name: String, instructionPath: String?, agentNameOverride: String? = nil) {
        self.name = name
        self.instructionPath = instructionPath
        self.agentNameOverride = agentNameOverride
    }

    var agentInstructionFilePath: String? {
        instructionPath
    }

    var agentName: String {
        agentNameOverride ?? name
    }
}

private func makeTempDirectory() throws -> String {
    let path = (NSTemporaryDirectory() as NSString).appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
}
