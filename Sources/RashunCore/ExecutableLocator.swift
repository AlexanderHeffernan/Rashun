import Foundation

public enum ExecutableLocator {
    public static func resolve(command: String, additionalCandidates: [String] = []) -> String? {
        if command.contains("/") || command.contains("\\") {
            return isExecutable(command) ? command : nil
        }

        let pathSeparator = ProcessInfo.processInfo.environment["PATH"]?.contains(";") == true ? ";" : ":"
        let pathEntries = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: Character(pathSeparator))
            .map(String.init)

        let candidates = pathEntries + additionalCandidates.map(expandHome)
        for directory in candidates where !directory.isEmpty {
            if let match = resolveInDirectory(command: command, directory: directory) {
                return match
            }
        }

        return nil
    }

    private static func resolveInDirectory(command: String, directory: String) -> String? {
        let fileManager = FileManager.default
        let base = URL(fileURLWithPath: directory)

        #if os(Windows)
        let rawExt = ProcessInfo.processInfo.environment["PATHEXT"] ?? ".EXE;.CMD;.BAT;.COM"
        let extensions = rawExt
            .split(separator: ";")
            .map { $0.lowercased() }
        let hasExtension = command.contains(".")
        let probeNames: [String]
        if hasExtension {
            probeNames = [command]
        } else {
            probeNames = [command] + extensions.map { command + $0 }
        }
        #else
        let probeNames = [command]
        #endif

        for probe in probeNames {
            let path = base.appendingPathComponent(probe).path
            if fileManager.isExecutableFile(atPath: path) {
                return path
            }
        }

        return nil
    }

    private static func isExecutable(_ path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: expandHome(path))
    }

    private static func expandHome(_ value: String) -> String {
        guard value.hasPrefix("~") else { return value }
        return NSString(string: value).expandingTildeInPath
    }
}
