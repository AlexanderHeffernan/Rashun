import Foundation
import RashunCore

enum SkillInstallerError: Error {
    case noInstructionFilePath(agentName: String)
}

enum SkillInstaller {
    static func install(for source: AISource) throws -> InstallResult {
        guard let rawPath = source.agentInstructionFilePath else {
            throw SkillInstallerError.noInstructionFilePath(agentName: source.agentName)
        }
        let path = NSString(string: rawPath).expandingTildeInPath
        let fileManager = FileManager.default
        let skillText = SkillGenerator.generate(for: source)

        let parentDir = (path as NSString).deletingLastPathComponent
        if !fileManager.fileExists(atPath: parentDir) {
            try fileManager.createDirectory(atPath: parentDir, withIntermediateDirectories: true)
        }

        if fileManager.fileExists(atPath: path) {
            let existing = try String(contentsOfFile: path, encoding: .utf8)
            if containsMarkers(existing) {
                let updated = replaceMarkerSection(in: existing, with: skillText)
                try updated.write(toFile: path, atomically: true, encoding: .utf8)
                return .updated
            } else {
                try backupIfNeeded(path: path)
                let appended = existing.hasSuffix("\n") ? existing + "\n" + skillText + "\n" : existing + "\n\n" + skillText + "\n"
                try appended.write(toFile: path, atomically: true, encoding: .utf8)
                return .installed
            }
        } else {
            try (skillText + "\n").write(toFile: path, atomically: true, encoding: .utf8)
            return .installed
        }
    }

    static func remove(for source: AISource) throws -> RemoveResult {
        guard let rawPath = source.agentInstructionFilePath else {
            return .notInstalled
        }
        let path = NSString(string: rawPath).expandingTildeInPath

        guard FileManager.default.fileExists(atPath: path) else {
            return .notInstalled
        }

        let existing = try String(contentsOfFile: path, encoding: .utf8)
        guard containsMarkers(existing) else {
            return .notInstalled
        }

        let cleaned = removeMarkerSection(from: existing)
        if cleaned.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            try FileManager.default.removeItem(atPath: path)
        } else {
            try cleaned.write(toFile: path, atomically: true, encoding: .utf8)
        }
        return .removed
    }

    static func isInstalled(for source: AISource) -> Bool {
        guard let rawPath = source.agentInstructionFilePath else { return false }
        let path = NSString(string: rawPath).expandingTildeInPath
        guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
        return containsMarkers(content)
    }

    static func containsMarkers(_ content: String) -> Bool {
        content.contains(SkillGenerator.startMarker) && content.contains(SkillGenerator.endMarker)
    }

    static func replaceMarkerSection(in content: String, with replacement: String) -> String {
        guard let startRange = content.range(of: SkillGenerator.startMarker),
              let endRange = content.range(of: SkillGenerator.endMarker) else {
            return content
        }
        let before = content[content.startIndex..<startRange.lowerBound]
        let after = content[endRange.upperBound...]
        return before + replacement + after
    }

    static func removeMarkerSection(from content: String) -> String {
        guard let startRange = content.range(of: SkillGenerator.startMarker),
              let endRange = content.range(of: SkillGenerator.endMarker) else {
            return content
        }
        let before = String(content[content.startIndex..<startRange.lowerBound])
        let after = String(content[endRange.upperBound...])

        // Clean up extra blank lines left behind
        let trimmedBefore = before.replacingOccurrences(of: "\\n+$", with: "\n", options: .regularExpression)
        let trimmedAfter = after.replacingOccurrences(of: "^\\n+", with: "", options: .regularExpression)

        if trimmedAfter.isEmpty {
            return trimmedBefore
        }
        return trimmedBefore + "\n" + trimmedAfter
    }

    private static func backupIfNeeded(path: String) throws {
        let backupPath = path + ".bak"
        guard !FileManager.default.fileExists(atPath: backupPath) else { return }
        try FileManager.default.copyItem(atPath: path, toPath: backupPath)
    }

    enum InstallResult {
        case installed
        case updated
    }

    enum RemoveResult {
        case removed
        case notInstalled
    }
}
