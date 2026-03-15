import Foundation
import RashunCore

struct DetectedAgent {
    let source: AISource
    let configDirectory: String
    let instructionFilePath: String?
    let isInstalled: Bool
}

enum AgentDetector {
    static func detectAll(from sources: [AISource] = allSources) -> [DetectedAgent] {
        sources.compactMap { source in
            guard let configDir = source.agentConfigDirectory else { return nil }
            let expanded = NSString(string: configDir).expandingTildeInPath
            let installed = FileManager.default.fileExists(atPath: expanded)
            return DetectedAgent(
                source: source,
                configDirectory: configDir,
                instructionFilePath: source.agentInstructionFilePath,
                isInstalled: installed
            )
        }
    }

    static func detectInstalled(from sources: [AISource] = allSources) -> [DetectedAgent] {
        detectAll(from: sources).filter(\.isInstalled)
    }
}
